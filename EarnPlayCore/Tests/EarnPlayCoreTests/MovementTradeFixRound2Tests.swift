import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.1 fix round 2 (issue #17 review): regression coverage for the four
/// round-2 findings. Written failing-first: each test fails on the pre-fix
/// code (b7ab14d) and passes after the fix. Uses only the pre-fix public
/// API so the same file compiles before and after.
@MainActor
final class MovementTradeFixRound2Tests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixR2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private nonisolated static func grantedEntry(session: String, at date: Date = Date())
        -> MovementTradeHistoryEntry {
        MovementTradeHistoryEntry(
            sessionId: session, activity: .jumpingJacks, offeredAt: date,
            outcome: .granted, completedAt: date,
            verifiedReps: 10, targetReps: 10)
    }

    private func realOffer() -> MovementTradeOffer {
        MovementTradeOffer(
            activity: .jumpingJacks, targetReps: 10,
            unlockMinutes: 15, taperApplied: false)
    }

    // MARK: - Finding 1: weekly capacity reserved for outstanding offers

    /// 2 grants recorded under the default cap of 3, then 2 concurrent
    /// sessions attempt offers and complete: at most 1 of the 2 completions
    /// may grant (total <= 3). Pre-fix: both offers succeed and both grant
    /// (total 4).
    func testTwoConcurrentOffersCannotExceedWeeklyCap() {
        let dir = tmpDir("WeeklyRace")
        let seed = MovementTradeHistoryStore(directory: dir)
        seed.record(Self.grantedEntry(session: "w1"))
        seed.record(Self.grantedEntry(session: "w2"))
        XCTAssertEqual(seed.history.completionsInTrailingWeek(), 2)

        let modelA = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        let modelB = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        let offer = realOffer()
        XCTAssertTrue(modelA.presentOffer(offer, sessionId: "r2-sA"))
        // Second concurrent offer must be refused: only one weekly slot left.
        XCTAssertFalse(
            modelB.presentOffer(offer, sessionId: "r2-sB"),
            "second concurrent offer exceeded the weekly cap reservation")

        // Complete whatever was presented; total grants must stay within cap.
        modelA.accept(with: FixRound2StubProvider(available: true))
        modelA.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        modelB.accept(with: FixRound2StubProvider(available: true))
        modelB.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        let total = MovementTradeHistoryStore(directory: dir)
            .history.completionsInTrailingWeek()
        XCTAssertLessThanOrEqual(total, 3, "weekly cap exceeded: \(total) grants")
    }

    /// Grant-time revalidation: even when two outstanding offers slipped
    /// through (decided concurrently before either reservation landed),
    /// at most one completion may grant. The loser finalizes as
    /// `.abandoned`, releasing its slot.
    func testOverlappingCompletionsRevalidateWeeklyCapBeforeGranting() {
        let dir = tmpDir("WeeklyGrantRace")
        let store = MovementTradeHistoryStore(directory: dir)
        XCTAssertTrue(store.record(Self.grantedEntry(session: "g1")))
        XCTAssertTrue(store.record(Self.grantedEntry(session: "g2")))
        let now = Date()
        let first = MovementTradeHistoryEntry(
            sessionId: "c1", activity: .jumpingJacks, offeredAt: now,
            outcome: .offered, verifiedReps: 0, targetReps: 10)
        let second = MovementTradeHistoryEntry(
            sessionId: "c2", activity: .jumpingJacks, offeredAt: now,
            outcome: .offered, verifiedReps: 0, targetReps: 10)
        XCTAssertTrue(store.record(first))
        XCTAssertTrue(store.record(second))
        XCTAssertEqual(store.history.weeklyUsageInTrailingWeek(now: now), 4)
        var grant1 = first
        grant1.outcome = .granted
        grant1.completedAt = now
        grant1.verifiedReps = 10
        var grant2 = second
        grant2.outcome = .granted
        grant2.completedAt = now
        grant2.verifiedReps = 10
        let results = [
            store.tryFinalize(grant1, weeklyCap: 3, now: now),
            store.tryFinalize(grant2, weeklyCap: 3, now: now),
        ]
        XCTAssertEqual(results.filter { $0 == .finalized }.count, 1)
        XCTAssertTrue(results.contains(.weeklyCapExceeded))
        let reread = MovementTradeHistoryStore(directory: dir).history
        XCTAssertEqual(reread.completionsInTrailingWeek(now: now), 3)
        XCTAssertEqual(reread.outstandingOffersInTrailingWeek(now: now), 0)
    }

    // MARK: - Finding 2: fail closed when quota persistence fails

    /// A store whose directory is a file cannot persist: presenting an offer
    /// must report failure and leave no cache-only reservation. Pre-fix:
    /// presentOffer returns true with the reservation only in cache.
    func testOfferFailsWhenQuotaCannotBePersisted() {
        let parent = tmpDir("PersistOffer")
        let fileURL = parent.appendingPathComponent("not-a-directory")
        try! Data("x".utf8).write(to: fileURL)
        let store = MovementTradeHistoryStore(directory: fileURL)
        let model = MovementTradeViewModel(historyStore: store)
        XCTAssertFalse(
            model.presentOffer(realOffer(), sessionId: "persist-s1"),
            "offer backed only by cache reported success")
        XCTAssertEqual(model.screen, .none)
        XCTAssertTrue(
            store.history.entries.isEmpty,
            "failed offer left a cache-only reservation")
    }

    /// Offer presented on a good directory, then the directory is replaced
    /// by a file before completion: the grant must report failure and no
    /// grant may be recorded. Pre-fix: grantMinutes == 15 with the grant
    /// only in cache.
    func testGrantFailsWhenQuotaCannotBePersisted() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixR2-PersistGrant-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MovementTradeHistoryStore(directory: dir)
        let model = MovementTradeViewModel(historyStore: store)
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "persist-s2"))
        model.accept(with: FixRound2StubProvider(available: true))
        // Break persistence before the terminal write lands.
        try FileManager.default.removeItem(at: dir)
        try Data("x".utf8).write(to: dir)
        model.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertNil(
            model.grantMinutes,
            "grant backed only by cache reported success")
        XCTAssertNotEqual(model.lastRecord?.outcome, .granted)
        XCTAssertTrue(
            store.history.entries.allSatisfy { $0.outcome != .granted },
            "failed grant left a cache-only grant")
    }

    // MARK: - Finding 3: motion availability checked before activating

    /// Accepting with an unavailable provider must never transition to
    /// .active: the weekly reservation is released (no lingering .offered)
    /// and a recovery message is shown. Pre-fix: screen becomes .active
    /// with an empty counter and no explanation.
    func testUnavailableProviderNeverActivates() {
        let dir = tmpDir("Unavailable")
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        XCTAssertTrue(model.presentOffer(realOffer(), sessionId: "avail-s1"))
        model.accept(with: FixRound2StubProvider(available: false))
        XCTAssertNotEqual(model.screen, .active, "unavailable motion activated the trade")
        XCTAssertTrue(
            model.statusText.lowercased().contains("unavailable"),
            "no recovery message for unavailable motion: \(model.statusText)")
        XCTAssertNil(model.grantMinutes)
        let entries = MovementTradeHistoryStore(directory: dir).history.entries
        XCTAssertTrue(
            entries.allSatisfy { $0.outcome != .offered },
            "unavailable accept left a lingering .offered reservation")
        XCTAssertTrue(entries.allSatisfy { $0.outcome != .granted })
    }

    // MARK: - Finding 4: movement duration shorter than practice duration

    /// A policy with practice 10 min and the default 15-min movement grant
    /// must not offer (the trade would outlast practice). Pre-fix: decide
    /// returns .offer with 15 minutes.
    func testMovementLongerThanPracticeRefusesOffer() {
        var policy = Policy.defaultPolicy
        policy.unlockDurations = UnlockDurations(practiceMinutes: 10, tradeMinutes: 15)
        // movementSettings.tradeUnlockDurationMinutes stays at default 15.
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1))
        let decision = MovementTradeManager.decide(context: context, policy: policy)
        if case .offer(let offer) = decision {
            XCTFail("offered \(offer.unlockMinutes)-min trade against 10-min practice")
        }
    }

    func testInconsistentDurationsRefuseWhileConsistentOffers() {
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1))
        // Zero / equal / longer movement durations must not offer.
        for movementMinutes in [0, 15, 30] {
            var policy = Policy.defaultPolicy
            policy.unlockDurations = UnlockDurations(practiceMinutes: 15, tradeMinutes: 15)
            policy.movementSettings = MovementSettings(
                allowedActivities: [.jumpingJacks], maxReps: 20,
                tradeUnlockDurationMinutes: movementMinutes)
            if case .offer = MovementTradeManager.decide(context: context, policy: policy) {
                XCTFail("offered with movement \(movementMinutes) vs practice 15")
            }
        }
        // The default consistent policy (15 < 30) still offers.
        let valid = MovementTradeManager.decide(context: context, policy: .defaultPolicy)
        guard case .offer = valid else {
            return XCTFail("consistent policy refused: \(valid)")
        }
    }
}

/// Stub provider with controllable availability; samples are fed directly
/// through `MovementTradeViewModel.ingest(_:)` for determinism.
private final class FixRound2StubProvider: MotionSampleProvider {
    private let available: Bool
    init(available: Bool) { self.available = available }
    var isAvailable: Bool { available }
    func startUpdates(handler _: @escaping @Sendable (MotionSample) -> Void) {}
    func stopUpdates() {}
}
