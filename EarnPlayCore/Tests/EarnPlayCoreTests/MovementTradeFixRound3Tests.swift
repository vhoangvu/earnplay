import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.1 fix round 3 (issue #17 review): regression coverage for the four
/// round-3 findings. Findings 1–3 add new API (failure propagation,
/// orphan reconciliation, atomic session cap), so their pre-fix repro is
/// code-level plus the PreFixProbe run (error discarded, no recovery
/// path, double reservation); finding 4 is failing-first against the
/// pre-fix counter (phase 0 → 12, phase 0.2 → 0).
@MainActor
final class MovementTradeFixRound3Tests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixR3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func realOffer() -> MovementTradeOffer {
        MovementTradeOffer(
            activity: .jumpingJacks, targetReps: 10,
            unlockMinutes: 15, taperApplied: false)
    }

    private nonisolated static func offeredEntry(session: String, at date: Date = Date())
        -> MovementTradeHistoryEntry {
        MovementTradeHistoryEntry(
            sessionId: session, activity: .jumpingJacks, offeredAt: date,
            outcome: .offered, verifiedReps: 0, targetReps: 10)
    }

    // MARK: - Finding 1: motion stream failures stop the trade

    /// A provider delivering an error finalizes the active trade with a
    /// recovery message and releases the weekly reservation (no lingering
    /// .offered). Pre-fix: the CoreMotion error was discarded and the
    /// trade stayed active indefinitely with its reservation held.
    func testStreamFailureFinalizesTradeWithRecovery() async {
        let dir = tmpDir("StreamFail")
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "fail-s1"))
        let provider = FixRound3FailingProvider()
        model.accept(with: provider)
        XCTAssertEqual(model.screen, .active)
        XCTAssertTrue(provider.started)

        provider.fail()
        for _ in 0..<100 {
            if model.screen == .finished { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.screen, .finished, "stream failure left the trade active")
        XCTAssertNil(model.grantMinutes)
        XCTAssertTrue(
            model.statusText.lowercased().contains("unexpectedly"),
            "no recovery message for stream failure: \(model.statusText)")
        XCTAssertTrue(provider.stopped)
        let entries = MovementTradeHistoryStore(directory: dir).history.entries
        XCTAssertTrue(
            entries.allSatisfy { $0.outcome != .offered },
            "stream failure left a lingering .offered reservation")
        XCTAssertTrue(entries.allSatisfy { $0.outcome != .granted })
        XCTAssertEqual(entries.first?.outcome, .abandoned)
    }

    /// A provider that never fails keeps the trade active (the failure
    /// path does not trigger spuriously).
    func testHealthyStreamStaysActive() async {
        let dir = tmpDir("StreamHealthy")
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "fail-s2"))
        model.accept(with: FixRound3FailingProvider())
        XCTAssertEqual(model.screen, .active)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.screen, .active)
        XCTAssertEqual(
            MovementTradeHistoryStore(directory: dir).history
                .outstandingOffersInTrailingWeek(), 1)
    }

    // MARK: - Finding 2: orphaned offers reconciled after termination

    /// Terminated sessions' .offered entries no longer block weekly
    /// capacity after recovery, while an active session's reservation is
    /// untouched. Session-offer history is preserved (entries stay, only
    /// the outcome changes). Pre-fix: no recovery path existed; three
    /// interruptions exhausted the default cap for seven days.
    func testReconcileOrphanedOffersReleasesStaleButPreservesActive() {
        let dir = tmpDir("Orphan")
        let store = MovementTradeHistoryStore(directory: dir)
        let now = Date()
        XCTAssertTrue(store.record(Self.offeredEntry(session: "dead-1", at: now)))
        XCTAssertTrue(store.record(Self.offeredEntry(session: "dead-2", at: now)))
        XCTAssertTrue(store.record(Self.offeredEntry(session: "live", at: now)))
        XCTAssertEqual(store.history.weeklyUsageInTrailingWeek(now: now), 3)

        let reconciled = store.reconcileOrphanedOffers(activeSessionIds: ["live"])
        XCTAssertEqual(reconciled, 2)
        let history = MovementTradeHistoryStore(directory: dir).history
        let bySession = Dictionary(grouping: history.entries, by: \.sessionId)
        XCTAssertEqual(bySession["dead-1"]?.first?.outcome, .abandoned)
        XCTAssertEqual(bySession["dead-2"]?.first?.outcome, .abandoned)
        XCTAssertEqual(bySession["live"]?.first?.outcome, .offered)
        // Session history preserved: dead sessions still show their offer.
        XCTAssertEqual(history.offersInSession("dead-1"), 1)
        XCTAssertEqual(history.offersInSession("live"), 1)
        // Weekly capacity released: only the live reservation counts.
        XCTAssertEqual(history.weeklyUsageInTrailingWeek(now: now), 1)
        // A fresh session can now reserve (pre-fix: weeklyCapReached).
        let fresh = Self.offeredEntry(session: "fresh", at: now)
        XCTAssertEqual(store.tryRecordOffer(fresh, weeklyCap: 3, now: now), .reserved)
    }

    /// Reconciling with no orphans is a no-op; reconciling everything
    /// with an empty active set clears all outstanding offers.
    func testReconcileOrphanedOffersEdgeCases() {
        let dir = tmpDir("OrphanEdges")
        let store = MovementTradeHistoryStore(directory: dir)
        XCTAssertEqual(store.reconcileOrphanedOffers(activeSessionIds: []), 0)
        let now = Date()
        XCTAssertTrue(store.record(Self.offeredEntry(session: "a", at: now)))
        XCTAssertEqual(
            store.reconcileOrphanedOffers(activeSessionIds: ["a"]), 0,
            "active reservation was released")
        XCTAssertEqual(store.history.outstandingOffersInTrailingWeek(now: now), 1)
        XCTAssertEqual(store.reconcileOrphanedOffers(activeSessionIds: []), 1)
        XCTAssertEqual(store.history.outstandingOffersInTrailingWeek(now: now), 0)
    }

    // MARK: - Finding 3: session cap enforced atomically

    /// Two concurrent presentations for the SAME session through separate
    /// view models: at most one reserves under the default session cap
    /// (the policy's maxTradesPerSession == 1). Pre-fix: both reserved
    /// and both could grant.
    func testTwoConcurrentPresentationsForSameSession() {
        let dir = tmpDir("SessRace")
        XCTAssertEqual(TradeCaps.default.maxTradesPerSession, 1)
        let modelA = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        let modelB = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        let offer = realOffer()
        let first = modelA.presentOffer(offer, sessionId: "race-s1")
        let second = modelB.presentOffer(offer, sessionId: "race-s1")
        XCTAssertTrue(first)
        XCTAssertFalse(second, "second same-session presentation reserved past the session cap")
        XCTAssertEqual(
            MovementTradeHistoryStore(directory: dir).history.offersInSession("race-s1"), 1)
        // The winner still completes normally.
        modelA.accept(with: FixRound3FailingProvider())
        modelA.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertEqual(modelA.grantMinutes, 15)
    }

    /// The atomic session check honors the passed limit (the policy's
    /// session cap), not a hardcoded 1: with sessionCap 2, two
    /// same-session reservations succeed and the third is refused.
    func testAtomicSessionCapHonorsPolicyLimit() {
        let dir = tmpDir("SessLimit")
        let store = MovementTradeHistoryStore(directory: dir)
        let now = Date()
        for _ in 0..<2 {
            XCTAssertEqual(
                store.tryRecordOffer(
                    Self.offeredEntry(session: "multi", at: now),
                    weeklyCap: 3, sessionCap: 2, now: now),
                .reserved)
        }
        XCTAssertEqual(
            store.tryRecordOffer(
                Self.offeredEntry(session: "multi", at: now),
                weeklyCap: 3, sessionCap: 2, now: now),
            .sessionCapReached)
        // A different session is unaffected by the first session's fills.
        XCTAssertEqual(
            store.tryRecordOffer(
                Self.offeredEntry(session: "other", at: now),
                weeklyCap: 5, sessionCap: 2, now: now),
            .reserved)
    }

    // MARK: - Finding 4: rep timing tolerant of sampling phase

    /// Clean 12-cycle 2 Hz vertical sinusoid (no noise, no rotation):
    /// verifies across starting phases. Pre-fix: phase 0 → 12, phase
    /// 0.2 → 0 (a true 0.25s swing measured 0.24s and was rejected).
    /// Partial edge cycles may cost one rep, so the bar is >= 11.
    func testPhaseVariedSinusoidVerifiesAcrossPhases() {
        for phase in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.57, 3.14] {
            var counter = VerifiedRepCounter(targetReps: 12)
            let count = counter.ingest(Self.cleanSinusoid(phase: phase))
            XCTAssertGreaterThanOrEqual(
                count, 11, "phase \(phase) verified \(count)/12")
        }
    }

    /// The tolerance does not open the door to shaking: multi-seed
    /// shaking still verifies nothing, stillness verifies nothing, and
    /// genuine cadence still counts exactly.
    func testToleranceKeepsShakingRejected() {
        for seed in UInt64(0)..<UInt64(10) {
            var counter = VerifiedRepCounter(targetReps: 10)
            XCTAssertEqual(
                counter.ingest(MotionFixtures.shakingInHand(seed: seed)), 0,
                "shaking seed \(seed) verified after tolerance")
        }
        var still = VerifiedRepCounter(targetReps: 10)
        XCTAssertEqual(still.ingest(MotionFixtures.phoneOnTable()), 0)
        var jumpingJacks = VerifiedRepCounter(targetReps: 12)
        XCTAssertEqual(jumpingJacks.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12)), 12)
        var running = VerifiedRepCounter(targetReps: 12)
        XCTAssertEqual(running.ingest(MotionFixtures.genuineRunningInPlace(repCount: 12)), 12)
    }

    // MARK: - Helpers

    /// Clean vertical sinusoid at the 2 Hz exercise edge: 12 full cycles
    /// plus a neutral tail, no noise, no rotation — sampling phase is
    /// the only variable.
    private nonisolated static func cleanSinusoid(phase: Double) -> [MotionSample] {
        let sampleRateHz = MotionFixtures.sampleRateHz
        let dt = 1.0 / sampleRateHz
        let cadenceHz = 2.0
        let exerciseSeconds = 12.0 / cadenceHz
        let total = Int((exerciseSeconds + 0.5) * sampleRateHz)
        return (0..<total).map { index in
            let time = Double(index) * dt
            let swing = time < exerciseSeconds
                ? 0.8 * sin(2.0 * .pi * cadenceHz * time + phase) : 0
            return MotionSample(timestamp: time, ax: 0, ay: 0, az: 1.0 + swing)
        }
    }
}

/// Stub provider that captures the failure closure so tests can deliver
/// a mid-stream error deterministically.
private final class FixRound3FailingProvider: MotionSampleProvider {
    var isAvailable: Bool { true }
    private(set) var started = false
    private(set) var stopped = false
    private var failureHandler: (@Sendable (Error) -> Void)?

    func startUpdates(handler _: @escaping @Sendable (MotionSample) -> Void) {
        started = true
    }

    func startUpdates(handler _: @escaping @Sendable (MotionSample) -> Void,
                      onFailure: @escaping @Sendable (Error) -> Void) {
        started = true
        failureHandler = onFailure
    }

    func stopUpdates() {
        stopped = true
    }

    func fail() {
        failureHandler?(NSError(
            domain: "FixRound3Tests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated stream failure"]))
    }
}
