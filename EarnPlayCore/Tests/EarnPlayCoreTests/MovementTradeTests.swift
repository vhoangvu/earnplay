import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.1 movement trade: injected motion-sample fixtures stand in for
/// CoreMotion (the simulator has no sensor). Genuine cadence verifies and
/// grants; stillness and shaking never verify; caps and the taper rule gate
/// offers in code.
final class MovementTradeTests: XCTestCase {

    // MARK: - Fixtures

    private func floorMetSignals(attempts: Int = 2) -> EffortSignals {
        EffortSignals(activeSeconds: 120, genuineAttempts: attempts, hintInteractions: 1)
    }

    private func offerContext(policy _: Policy = .defaultPolicy,
                              initiation: TradeInitiation = .aiLowMotivation,
                              signals: EffortSignals? = nil,
                              sessionOffersUsed: Int = 0,
                              weeklyCompletions: Int = 0,
                              recent: [Bool] = [],
                              sinceLastOffer: Int? = nil) -> MovementOfferContext {
        MovementOfferContext(
            initiation: initiation,
            signals: signals ?? floorMetSignals(),
            floorSettings: .default,
            sessionOffersUsed: sessionOffersUsed,
            weeklyCompletions: weeklyCompletions,
            recentSessionCompletions: recent,
            sessionsSinceLastMovementOffer: sinceLastOffer)
    }

    private func offeredSession(policy: Policy = .defaultPolicy) -> MovementTradeSession {
        let decision = MovementTradeManager.decide(
            context: offerContext(policy: policy), policy: policy)
        guard case .offer(let offer) = decision else {
            XCTFail("expected offer, got \(decision)")
            return MovementTradeSession(
                sessionId: "unreachable",
                offer: MovementTradeOffer(activity: .jumpingJacks, targetReps: 10,
                                          unlockMinutes: 15, taperApplied: false))
        }
        return MovementTradeSession(sessionId: "s1", offer: offer)
    }

    private func grantedSession(policy: Policy = .defaultPolicy) -> MovementTradeSession {
        var session = offeredSession(policy: policy)
        XCTAssertTrue(session.accept())
        return session
    }

    // MARK: - Automated test: genuine cadence grants

    func testGenuineJumpingJackFixtureCountsToTargetAndGrants() {
        let policy = Policy.defaultPolicy
        var session = grantedSession(policy: policy)
        XCTAssertEqual(session.targetReps, 10)
        let count = session.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertGreaterThanOrEqual(count, 10)
        XCTAssertEqual(session.phase, .granted)
        XCTAssertEqual(session.outcome, .granted)
        let record = try! XCTUnwrap(session.makeRecord())
        XCTAssertEqual(record.outcome, .granted)
        XCTAssertEqual(record.unlockMinutesGranted, 15)
        XCTAssertEqual(record.verifiedReps, session.verifiedCount)
    }

    func testCounterCountsExactRepsOnCleanFixtures() {
        var jumpingJacks = VerifiedRepCounter(targetReps: 12)
        XCTAssertEqual(jumpingJacks.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12)), 12)
        XCTAssertTrue(jumpingJacks.isComplete)
        var running = VerifiedRepCounter(targetReps: 12)
        XCTAssertEqual(running.ingest(MotionFixtures.genuineRunningInPlace(repCount: 12)), 12)
        XCTAssertTrue(running.isComplete)
    }

    // MARK: - Automated test: unverified motion never grants

    func testPhoneOnTableNeverVerifies() {
        var counter = VerifiedRepCounter(targetReps: 10)
        XCTAssertEqual(counter.ingest(MotionFixtures.phoneOnTable()), 0)
        XCTAssertFalse(counter.isComplete)
        var session = grantedSession()
        XCTAssertEqual(session.ingest(MotionFixtures.phoneOnTable()), 0)
        XCTAssertEqual(session.phase, .active)
        XCTAssertNil(session.outcome)
        XCTAssertNil(session.makeRecord())
    }

    func testShakingInHandDoesNotReachVerifiedCount() {
        var counter = VerifiedRepCounter(targetReps: 10)
        let samples = MotionFixtures.shakingInHand()
        XCTAssertEqual(counter.ingest(samples), 0)
        XCTAssertFalse(counter.isComplete)
        // The fixture moved plenty — it was rejected, not absent.
        XCTAssertGreaterThan(counter.rejectedNoiseEvents, 0)
        var session = grantedSession()
        XCTAssertEqual(session.ingest(MotionFixtures.shakingInHand()), 0)
        XCTAssertEqual(session.phase, .active)
        XCTAssertNil(session.makeRecord())
    }

    func testGrantOnlyOnGenuineFixture() {
        let genuine = MotionFixtures.genuineJumpingJacks(repCount: 12)
        let unfruitful = [MotionFixtures.phoneOnTable(), MotionFixtures.shakingInHand()]
        var genuineSession = grantedSession()
        genuineSession.ingest(genuine)
        XCTAssertEqual(genuineSession.outcome, .granted)
        for fixture in unfruitful {
            var session = grantedSession()
            session.ingest(fixture)
            XCTAssertNil(session.outcome, "unverified motion must not grant")
        }
    }

    func testExtremeRotationSamplesAreIgnoredNeverCounted() {
        let spinning = MotionFixtures.genuineJumpingJacks(repCount: 12).map {
            MotionSample(timestamp: $0.timestamp, ax: $0.ax, ay: $0.ay, az: $0.az,
                         gx: 20, gy: 0, gz: 0)
        }
        var counter = VerifiedRepCounter(targetReps: 10)
        XCTAssertEqual(counter.ingest(spinning), 0)
    }

    // MARK: - Automated test: caps

    func testSecondOfferInSameSessionIsRefused() {
        let policy = Policy.defaultPolicy // maxTradesPerSession == 1
        let first = MovementTradeManager.decide(
            context: offerContext(policy: policy, sessionOffersUsed: 0), policy: policy)
        guard case .offer = first else { return XCTFail("first offer refused: \(first)") }
        let second = MovementTradeManager.decide(
            context: offerContext(policy: policy, sessionOffersUsed: 1), policy: policy)
        XCTAssertEqual(second, .refuse(.sessionCapReached))
    }

    func testOfferBeyondWeeklyCapIsRefused() {
        let policy = Policy.defaultPolicy // weeklyMaxMovementTrades == 3
        let atCap = MovementTradeManager.decide(
            context: offerContext(policy: policy, weeklyCompletions: 2), policy: policy)
        guard case .offer = atCap else { return XCTFail("offer below cap refused: \(atCap)") }
        let beyond = MovementTradeManager.decide(
            context: offerContext(policy: policy, weeklyCompletions: 3), policy: policy)
        XCTAssertEqual(beyond, .refuse(.weeklyCapReached))
    }

    func testCapsEnforcedFromHistoryStore() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovementCapTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MovementTradeHistoryStore(directory: directory)
        let now = Date()
        for index in 0..<3 {
            store.record(MovementTradeHistoryEntry(
                sessionId: "week-\(index)", activity: .jumpingJacks,
                offeredAt: now.addingTimeInterval(-Double(index + 1) * 24 * 3600),
                outcome: .granted, completedAt: now.addingTimeInterval(-Double(index + 1) * 24 * 3600),
                verifiedReps: 10, targetReps: 10))
        }
        let history = store.history
        XCTAssertEqual(history.completionsInTrailingWeek(now: now), 3)
        let decision = MovementTradeManager.decide(
            context: offerContext(weeklyCompletions: history.completionsInTrailingWeek(now: now)),
            policy: .defaultPolicy)
        XCTAssertEqual(decision, .refuse(.weeklyCapReached))
    }

    // MARK: - Acceptance: shorter trade grant

    func testTradeGrantIsShorterThanPracticeUnlockInSamePolicy() {
        let policy = Policy.defaultPolicy
        let decision = MovementTradeManager.decide(context: offerContext(policy: policy), policy: policy)
        guard case .offer(let offer) = decision else { return XCTFail("no offer: \(decision)") }
        XCTAssertEqual(offer.unlockMinutes, 15)
        XCTAssertEqual(policy.unlockDurations.practiceMinutes, 30)
        XCTAssertLessThan(offer.unlockMinutes, policy.unlockDurations.practiceMinutes)
        var session = MovementTradeSession(sessionId: "s1", offer: offer)
        session.accept()
        session.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        XCTAssertEqual(try! XCTUnwrap(session.makeRecord()).unlockMinutesGranted, 15)
    }

    // MARK: - Offer gating: initiation, floor, activity

    func testOfferRequiresAIInitiation() {
        for initiation in [TradeInitiation.childRequest, .none] {
            let decision = MovementTradeManager.decide(
                context: offerContext(initiation: initiation), policy: .defaultPolicy)
            XCTAssertEqual(decision, .refuse(.notAIInitiated), "initiation \(initiation)")
        }
    }

    func testOfferRequiresEffortFloor() {
        let belowFloor = [
            EffortSignals(activeSeconds: 600, genuineAttempts: 0, hintInteractions: 2),
            EffortSignals(activeSeconds: 600, genuineAttempts: 3, hintInteractions: 0),
            EffortSignals(activeSeconds: 3600),
        ]
        for signals in belowFloor {
            let decision = MovementTradeManager.decide(
                context: offerContext(signals: signals), policy: .defaultPolicy)
            XCTAssertEqual(decision, .refuse(.floorNotMet), "signals \(signals)")
        }
        // Follow-up interaction satisfies the hint side, as in T1.4.
        let followUp = EffortSignals(activeSeconds: 120, genuineAttempts: 1,
                                     hintInteractions: 0, followUpInteractions: 1)
        let decision = MovementTradeManager.decide(
            context: offerContext(signals: followUp), policy: .defaultPolicy)
        guard case .offer = decision else { return XCTFail("floor-met offer refused: \(decision)") }
    }

    func testNoAllowedActivityRefuses() {
        var policy = Policy.defaultPolicy
        policy.movementSettings.allowedActivities = []
        let decision = MovementTradeManager.decide(context: offerContext(), policy: policy)
        XCTAssertEqual(decision, .refuse(.noAllowedActivity))
    }

    func testOfferPicksFirstCanonicalAllowedActivity() {
        var policy = Policy.defaultPolicy
        policy.movementSettings.allowedActivities = [.runningInPlace, .squats]
        let decision = MovementTradeManager.decide(context: offerContext(), policy: policy)
        guard case .offer(let offer) = decision else { return XCTFail("no offer: \(decision)") }
        XCTAssertEqual(offer.activity, .runningInPlace)
    }

    func testTargetRepsClampedToPolicyMax() {
        XCTAssertEqual(MovementTradeManager.targetReps(maxReps: 20), 10)
        XCTAssertEqual(MovementTradeManager.targetReps(maxReps: 5), 5)
        XCTAssertEqual(MovementTradeManager.targetReps(maxReps: 1), 1)
    }

    // MARK: - Taper rule

    func testTaperPatternDetection() {
        XCTAssertTrue(TaperRule.isPattern([true, true, true, true, false]))
        XCTAssertTrue(TaperRule.isPattern([true, true, true, true, true]))
        XCTAssertTrue(TaperRule.isPattern([true, true, true, true])) // 4-of-4
        XCTAssertFalse(TaperRule.isPattern([true, true, false, false, false]))
        XCTAssertFalse(TaperRule.isPattern([true, true, true])) // too little history
        XCTAssertFalse(TaperRule.isPattern([]))
    }

    func testTaperedSessionRequiresCooldownThenPractice() {
        let pattern = [true, true, true, true, false]
        // Offered last session: must skip ("offer less often").
        let cooldown = MovementTradeManager.decide(
            context: offerContext(signals: floorMetSignals(attempts: 5),
                                  recent: pattern, sinceLastOffer: 1),
            policy: .defaultPolicy)
        XCTAssertEqual(cooldown, .refuse(.taperedCooldown))
        // Cooldown satisfied but only the floor attempt: practice first.
        let practice = MovementTradeManager.decide(
            context: offerContext(signals: floorMetSignals(attempts: 1),
                                  recent: pattern, sinceLastOffer: 2),
            policy: .defaultPolicy)
        XCTAssertEqual(practice, .refuse(.taperedPracticeRequired))
        // Both satisfied: offer, flagged as tapered.
        let tapered = MovementTradeManager.decide(
            context: offerContext(signals: floorMetSignals(attempts: 3),
                                  recent: pattern, sinceLastOffer: 2),
            policy: .defaultPolicy)
        guard case .offer(let offer) = tapered else {
            return XCTFail("tapered offer refused: \(tapered)")
        }
        XCTAssertTrue(offer.taperApplied)
    }

    func testUntaperedOfferIsNotFlagged() {
        let decision = MovementTradeManager.decide(
            context: offerContext(recent: [true, false, false]),
            policy: .defaultPolicy)
        guard case .offer(let offer) = decision else {
            return XCTFail("no offer: \(decision)")
        }
        XCTAssertFalse(offer.taperApplied)
    }

    // MARK: - Session state machine

    func testDeclineAndAbandonGrantNothing() {
        var declined = offeredSession()
        XCTAssertTrue(declined.decline())
        XCTAssertEqual(declined.outcome, .declined)
        let declinedRecord = try! XCTUnwrap(declined.makeRecord())
        XCTAssertNil(declinedRecord.unlockMinutesGranted)
        var abandoned = grantedSession()
        abandoned.ingest(Array(MotionFixtures.genuineJumpingJacks(repCount: 12).prefix(100)))
        XCTAssertTrue(abandoned.abandon())
        XCTAssertEqual(abandoned.outcome, .abandoned)
        XCTAssertNil(try! XCTUnwrap(abandoned.makeRecord()).unlockMinutesGranted)
    }

    func testSessionGuardsRejectOutOfOrderTransitions() {
        var session = grantedSession() // already accepted
        XCTAssertFalse(session.accept())
        XCTAssertFalse(session.decline())
        var offered = MovementTradeSession(
            sessionId: "s2",
            offer: MovementTradeOffer(activity: .jumpingJacks, targetReps: 10,
                                      unlockMinutes: 15, taperApplied: false))
        XCTAssertFalse(offered.abandon())
        XCTAssertEqual(offered.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12)), 0)
        XCTAssertEqual(offered.phase, .offered)
    }

    // MARK: - Trade record handoff (T1.6/T4.x)

    func testTradeRecordCarriesDecisionFieldsAndTaperFlag() throws {
        let offer = MovementTradeOffer(activity: .jumpingJacks, targetReps: 10,
                                       unlockMinutes: 15, taperApplied: true)
        var session = MovementTradeSession(sessionId: "s9", offer: offer)
        XCTAssertNil(session.makeRecord())
        XCTAssertNil(session.makeHistoryEntry())
        session.accept()
        session.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        let record = try XCTUnwrap(session.makeRecord())
        XCTAssertTrue(record.taperApplied)
        XCTAssertTrue(record.taperPatternFlagged)
        XCTAssertFalse(record.evidenceSummary.isEmpty)
        XCTAssertFalse(record.reasoning.isEmpty)
        XCTAssertFalse(record.alternativeConsidered.isEmpty)
        XCTAssertFalse(record.confidence.isEmpty)
        XCTAssertTrue(record.evidenceSummary.contains("10/10"))
        // Self-contained: JSON round-trips with no other module.
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(MovementTradeRecord.self, from: data), record)
        let entry = try XCTUnwrap(session.makeHistoryEntry())
        XCTAssertEqual(entry.outcome, .granted)
        XCTAssertEqual(entry.sessionId, "s9")
    }

    func testReducedConfidenceRecordForNonPocketCarry() {
        var session = grantedSession()
        session.ingest(MotionFixtures.genuineJumpingJacks(repCount: 12))
        let record = try! XCTUnwrap(session.makeRecord(verificationConfidence: .reduced))
        XCTAssertEqual(record.verificationConfidence, .reduced)
        XCTAssertTrue(record.confidence.contains("reduced"))
    }

    // MARK: - History windows

    func testHistoryWindowsAndSessionGrouping() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let day: TimeInterval = 24 * 3600
        var history = MovementTradeHistory()
        // Two recent grants, one grant 8 days ago (outside the window),
        // one declined offer in its own session.
        history.entries = [
            MovementTradeHistoryEntry(sessionId: "old", activity: .jumpingJacks,
                                      offeredAt: now - 8 * day, outcome: .granted,
                                      completedAt: now - 8 * day, verifiedReps: 10, targetReps: 10),
            MovementTradeHistoryEntry(sessionId: "a", activity: .jumpingJacks,
                                      offeredAt: now - 2 * day, outcome: .granted,
                                      completedAt: now - 2 * day, verifiedReps: 10, targetReps: 10),
            MovementTradeHistoryEntry(sessionId: "b", activity: .runningInPlace,
                                      offeredAt: now - 1 * day, outcome: .declined,
                                      completedAt: nil, verifiedReps: 0, targetReps: 10),
            MovementTradeHistoryEntry(sessionId: "c", activity: .jumpingJacks,
                                      offeredAt: now, outcome: .granted,
                                      completedAt: now, verifiedReps: 10, targetReps: 10),
        ]
        XCTAssertEqual(history.completionsInTrailingWeek(now: now), 2)
        XCTAssertEqual(history.offersInSession("b"), 1)
        XCTAssertEqual(history.offersInSession("zzz"), 0)
        XCTAssertEqual(history.recentSessionCompletions(limit: 5), [true, true, false, true])
        XCTAssertEqual(history.recentSessionCompletions(limit: 2), [false, true])
    }

    func testHistoryStorePersistsAndFallsBackToEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MovementHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MovementTradeHistoryStore(directory: directory)
        XCTAssertEqual(store.history.entries.count, 0)
        let entry = MovementTradeHistoryEntry(
            sessionId: "s1", activity: .jumpingJacks, offeredAt: Date(),
            outcome: .granted, completedAt: Date(), verifiedReps: 10, targetReps: 10)
        store.record(entry)
        let reopened = MovementTradeHistoryStore(directory: directory)
        XCTAssertEqual(reopened.history.entries, [entry])
        // Corrupt file: empty history, never a crash.
        try "not json".write(to: directory.appendingPathComponent("movement-trades.json"),
                             atomically: true, encoding: .utf8)
        XCTAssertEqual(MovementTradeHistoryStore(directory: directory).history.entries.count, 0)
    }
}
