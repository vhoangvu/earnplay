import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.1 fix round 1 (issue #17 review): regression coverage for the nine
/// review findings. Core-side findings are reproduced here against the
/// deterministic types; app-target findings (provider selection, preview
/// session IDs) are covered in EarnPlayTests.
@MainActor
final class MovementTradeFixRound1Tests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixR1-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private nonisolated static func entry(session: String, outcome: MovementTradeOutcome) -> MovementTradeHistoryEntry {
        MovementTradeHistoryEntry(
            sessionId: session, activity: .jumpingJacks, offeredAt: Date(),
            outcome: outcome, completedAt: outcome == .granted ? Date() : nil,
            verifiedReps: outcome == .granted ? 10 : 0, targetReps: 10)
    }

    // MARK: - Finding 2: policy effort floor honored

    func testPolicyStrongerAttemptFloorRefusesWeakSession() {
        // The finding's example: a policy requiring three genuine attempts
        // must refuse a 1-attempt/1-hint session even though the context's
        // defaulted floor settings would pass it.
        var policy = Policy.defaultPolicy
        policy.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 3, minHintOrFollowUpInteractions: 1)
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 1, hintInteractions: 1))
        XCTAssertEqual(
            MovementTradeManager.decide(context: context, policy: policy),
            .refuse(.floorNotMet))
    }

    func testPolicyStrongerHintFloorRefusesWeakSession() {
        var policy = Policy.defaultPolicy
        policy.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 1, minHintOrFollowUpInteractions: 2)
        let weak = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 3, hintInteractions: 1))
        XCTAssertEqual(
            MovementTradeManager.decide(context: weak, policy: policy),
            .refuse(.floorNotMet))
        let strong = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 3, hintInteractions: 2))
        guard case .offer = MovementTradeManager.decide(context: strong, policy: policy) else {
            return XCTFail("policy-floor-met session refused")
        }
    }

    func testPolicyFloorMetStillOffers() {
        var policy = Policy.defaultPolicy
        policy.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 3, minHintOrFollowUpInteractions: 1)
        let context = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 3, hintInteractions: 1))
        guard case .offer = MovementTradeManager.decide(context: context, policy: policy) else {
            return XCTFail("policy-floor-met session refused")
        }
    }

    // MARK: - Finding 3: high rotation disarms the detector

    /// The finding's attack: 10 arm/complete endpoint pairs joined by
    /// high-rotation intervals must not verify across the rejected gap.
    func testHighRotationIntervalBetweenEndpointsVerifiesNothing() {
        var samples: [MotionSample] = []
        var t = 0.0
        let dt = 1.0 / MotionFixtures.sampleRateHz
        for _ in 0..<10 {
            samples.append(MotionSample(timestamp: t, ax: 0, ay: 0, az: 1.8))
            t += dt
            for _ in 0..<48 {
                samples.append(MotionSample(
                    timestamp: t, ax: 0, ay: 0, az: 1.0, gx: 20, gy: 0, gz: 0))
                t += dt
            }
            samples.append(MotionSample(timestamp: t, ax: 0, ay: 0, az: 0.2))
            t += dt
        }
        var counter = VerifiedRepCounter(targetReps: 10)
        XCTAssertEqual(counter.ingest(samples), 0)
        XCTAssertFalse(counter.isComplete)
    }

    /// Disarm is per-swing, not per-stream: rare spikes cost at most the
    /// swing in progress; the rest of a genuine set still verifies.
    func testGenuineSetWithRareRotationSpikesStillVerifies() {
        var samples = MotionFixtures.genuineJumpingJacks(repCount: 12)
        var spikes = 0
        for index in samples.indices where index % 100 == 50 {
            samples[index].gx = 20
            spikes += 1
        }
        XCTAssertGreaterThan(spikes, 0)
        var counter = VerifiedRepCounter(targetReps: 12)
        let count = counter.ingest(samples)
        XCTAssertGreaterThanOrEqual(count, 12 - spikes)
    }

    // MARK: - Finding 4: multi-seed shaking rejection

    func testShakingRejectedAcrossSeeds() {
        for seed in UInt64(0)..<UInt64(10) {
            var counter = VerifiedRepCounter(targetReps: 10)
            XCTAssertEqual(
                counter.ingest(MotionFixtures.shakingInHand(seed: seed)), 0,
                "shaking seed \(seed) verified")
        }
    }

    func testShakingCannotGrantWhenMaxRepsIsOne() {
        // With maxReps == 1 a single verified rep grants; shaking must not
        // produce even one on the previously-verifying seeds.
        for seed in [UInt64(1), UInt64(7)] {
            var counter = VerifiedRepCounter(targetReps: 1)
            counter.ingest(MotionFixtures.shakingInHand(seed: seed))
            XCTAssertFalse(counter.isComplete, "shaking seed \(seed) completed")
        }
    }

    // MARK: - Finding 7: cross-instance history serialization

    func testTwoStoresRecordingSequentiallyKeepBothEntries() {
        let dir = tmpDir("TwoStores")
        let first = MovementTradeHistoryStore(directory: dir)
        let second = MovementTradeHistoryStore(directory: dir)
        first.record(Self.entry(session: "a", outcome: .granted))
        second.record(Self.entry(session: "b", outcome: .declined))
        let entries = MovementTradeHistoryStore(directory: dir).history.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.sessionId)), ["a", "b"])
    }

    func testConcurrentRecordsAcrossInstancesLoseNothing() {
        let dir = tmpDir("ConcurrentStores")
        let first = MovementTradeHistoryStore(directory: dir)
        let second = MovementTradeHistoryStore(directory: dir)
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            let store = index % 2 == 0 ? first : second
            store.record(Self.entry(session: "s\(index)", outcome: .granted))
        }
        let entries = MovementTradeHistoryStore(directory: dir).history.entries
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(Set(entries.map(\.sessionId)).count, 50)
    }

    // MARK: - Finding 6: taper window includes practice-only sessions

    func testFullSessionWindowDilutesSeparatedGrants() {
        var history = MovementTradeHistory()
        history.entries = ["s1", "s2", "s3", "s4"].map {
            Self.entry(session: $0, outcome: .granted)
        }
        // Four grants separated by practice-only sessions are not a
        // pattern when the full session order is supplied ...
        let diluted = history.recentSessionCompletions(allSessionsInOrder: [
            "s1", "p1", "s2", "p2", "s3", "p3", "s4",
        ])
        XCTAssertEqual(diluted, [true, false, true, false, true])
        XCTAssertFalse(TaperRule.isPattern(diluted))
        // ... but four straight grants still taper ...
        let straight = history.recentSessionCompletions(allSessionsInOrder: [
            "s1", "s2", "s3", "s4",
        ])
        XCTAssertEqual(straight, [true, true, true, true])
        XCTAssertTrue(TaperRule.isPattern(straight))
        // ... and practice-only sessions after a pattern clear it.
        let cleared = history.recentSessionCompletions(allSessionsInOrder: [
            "s1", "s2", "s3", "s4", "p1", "p2",
        ])
        XCTAssertEqual(cleared, [true, true, true, false, false])
        XCTAssertFalse(TaperRule.isPattern(cleared))
    }

    func testFullSessionWindowReadsNonGrantedSessionsAsFalse() {
        var history = MovementTradeHistory()
        history.entries = [
            Self.entry(session: "s1", outcome: .granted),
            Self.entry(session: "s2", outcome: .declined),
        ]
        XCTAssertEqual(
            history.recentSessionCompletions(
                allSessionsInOrder: ["s1", "practice", "s2"]),
            [true, false, false])
    }

    // MARK: - Finding 9: reduced verification confidence

    func testDeviceConfidenceMapping() {
        XCTAssertEqual(MovementVerificationConfidence.forDevice(isPad: true), .reduced)
        XCTAssertEqual(MovementVerificationConfidence.forDevice(isPad: false), .full)
    }

    func testReducedConfidenceForwardedToRecord() {
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: tmpDir("ReducedConf")),
            verificationConfidence: .reduced)
        model.presentOffer(
            MovementTradeOffer(
                activity: .jumpingJacks, targetReps: 10,
                unlockMinutes: 15, taperApplied: false),
            sessionId: "conf-s1")
        model.accept(with: FixRound1StubProvider())
        model.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        let record = try! XCTUnwrap(model.lastRecord)
        XCTAssertEqual(record.outcome, .granted)
        XCTAssertEqual(record.verificationConfidence, .reduced)
        XCTAssertTrue(record.confidence.contains("reduced"))
    }

    func testDefaultConfidenceIsFull() {
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: tmpDir("FullConf")))
        model.presentOffer(
            MovementTradeOffer(
                activity: .jumpingJacks, targetReps: 10,
                unlockMinutes: 15, taperApplied: false),
            sessionId: "conf-s2")
        model.accept(with: FixRound1StubProvider())
        model.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertEqual(model.lastRecord?.verificationConfidence, .full)
    }

    // MARK: - Finding 8: quota reservation at presentation

    func testPresentOfferReservesSessionQuota() {
        let dir = tmpDir("ReserveQuota")
        let model = MovementTradeViewModel(
            historyStore: MovementTradeHistoryStore(directory: dir))
        let offer = MovementTradeOffer(
            activity: .jumpingJacks, targetReps: 10,
            unlockMinutes: 15, taperApplied: false)
        XCTAssertTrue(model.presentOffer(offer, sessionId: "quota-s1"))
        // A recreated UI (fresh store instance) sees the pending offer.
        let reread = MovementTradeHistoryStore(directory: dir).history
        XCTAssertEqual(reread.offersInSession("quota-s1"), 1)
        // The gate therefore refuses a second offer for the same session.
        let decision = MovementTradeManager.decide(
            context: MovementOfferContext(
                initiation: .aiLowMotivation,
                signals: EffortSignals(
                    activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1),
                sessionOffersUsed: reread.offersInSession("quota-s1")),
            policy: .defaultPolicy)
        XCTAssertEqual(decision, .refuse(.sessionCapReached))
        // Completion updates the reservation in place: one terminal entry.
        model.decline()
        let final = MovementTradeHistoryStore(directory: dir).history
        XCTAssertEqual(final.entries.count, 1)
        XCTAssertEqual(final.entries.first?.outcome, .declined)
    }
}

/// Synchronous stub provider: samples are fed directly through
/// `MovementTradeViewModel.ingest(_:)` for determinism.
private final class FixRound1StubProvider: MotionSampleProvider {
    var isAvailable: Bool { true }
    func startUpdates(handler _: @escaping @Sendable (MotionSample) -> Void) {}
    func stopUpdates() {}
}
