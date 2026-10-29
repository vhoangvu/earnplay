import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.3 trade offer logic: the floor is absolute, a motivated session is
/// never interrupted, and above-floor stalling moments vary across
/// movement / chore / no offer with no learnable pattern. Every decision
/// — including no-offer — is written to the T1.6 decision log.
///
/// The two required automated tests are `testBelowFloorAlwaysNoOffer`
/// (100/100 runs, seeded sweep) and `testAboveFloorLowMotivationMix`
/// (100 seeded runs: movement and chore both appear, neither dominates).
final class TradeOfferLogicTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TradeOfferLogicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let future = Date(timeIntervalSince1970: 2_000_000_000)

    /// Fixed UTC calendar so daypart fit never depends on the machine.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Above-floor signals: genuine attempts plus hint use.
    private func aboveFloorSignals() -> EffortSignals {
        EffortSignals(activeSeconds: 180, genuineAttempts: 2, hintInteractions: 1)
    }

    /// Below-floor fixture A: idle time, no attempts, no hint use.
    private func idleSignals() -> EffortSignals {
        EffortSignals(activeSeconds: 600)
    }

    /// Below-floor fixture B: guessing — attempts but no hint interaction.
    private func guessingSignals() -> EffortSignals {
        EffortSignals(activeSeconds: 120, genuineAttempts: 5)
    }

    private func entry(_ chore: String, minutes: Int = 10,
                       weeklyCap: Int = 3) -> ChorePoolEntry {
        ChorePoolEntry(chore: chore, unlockMinutes: minutes,
                       expiry: Self.future, weeklyCap: weeklyCap,
                       verificationMode: .parentConfirm)
    }

    /// Neutral names (no daypart keywords) so eligibility never depends
    /// on time of day — fit only orders, but neutrality keeps it obvious.
    private func pool() -> [ChorePoolEntry] {
        [entry("Wash the car", minutes: 10), entry("Paint the fence", minutes: 15)]
    }

    private func policy(pool: [ChorePoolEntry]? = nil) -> Policy {
        Policy(version: 1,
               alwaysAllowed: Policy.defaultPolicy.alwaysAllowed,
               unblockable: [],
               neverUnlockableOverrides: [],
               unlockDurations: .default,
               effortFloorSettings: .default,
               tradeCaps: .default,
               chorePool: pool ?? self.pool(),
               movementSettings: .default)
    }

    /// Low-motivation moment: above floor, stalling, fresh caps, both
    /// engines eligible. The resolved pool rides in the context (the host
    /// resolves it via `ChoreTradePoolSource.resolve`).
    private func lowMotivationContext(signals: EffortSignals? = nil,
                                      stalling: StallClassification = .stalling,
                                      chorePool: [ChorePoolEntry]? = nil,
                                      sessionOffersUsed: Int = 0,
                                      weeklyMovementUsage: Int = 0,
                                      weeklyChoreUsage: Int = 0) -> TradeOfferContext {
        TradeOfferContext(signals: signals ?? aboveFloorSignals(),
                          stalling: stalling,
                          sessionOffersUsed: sessionOffersUsed,
                          weeklyMovementUsage: weeklyMovementUsage,
                          weeklyChoreUsage: weeklyChoreUsage,
                          chorePool: chorePool ?? pool(),
                          now: Self.now,
                          calendar: Self.utcCalendar)
    }

    private func decide(context: TradeOfferContext, policy: Policy,
                        seed: UInt64) -> TradeOfferDecision {
        var generator = EffortSeededRNG(seed: seed)
        return TradeOfferDecider.decide(context: context, policy: policy, using: &generator)
    }

    // MARK: - Required automated test 1: floor is absolute

    func testBelowFloorAlwaysNoOffer() {
        let policy = policy()
        for seed in 0..<100 {
            for signals in [idleSignals(), guessingSignals()] {
                // Worst case: stalling with fresh caps — the floor still wins.
                let context = lowMotivationContext(signals: signals)
                let decision = decide(context: context, policy: policy,
                                      seed: UInt64(seed))
                XCTAssertEqual(decision.outcome, .noOffer(.floorNotMet),
                               "seed \(seed), signals \(signals)")
                // Engines never consulted below the floor.
                XCTAssertNil(decision.movementGate)
                XCTAssertNil(decision.choreCandidate)
            }
        }
    }

    // MARK: - Required automated test 2: mix with dominance bound

    /// Dominance bound: neither currency may exceed 80 of 100 runs.
    private static let dominanceBound = 80

    func testAboveFloorLowMotivationMix() {
        let policy = policy()
        let context = lowMotivationContext()
        var movement = 0
        var chore = 0
        var noOffer = 0
        for seed in 0..<100 {
            switch decide(context: context, policy: policy, seed: UInt64(seed)).outcome {
            case .movement: movement += 1
            case .chore: chore += 1
            case .noOffer: noOffer += 1
            }
        }
        XCTAssertGreaterThan(movement, 0, "movement never offered in 100 runs")
        XCTAssertGreaterThan(chore, 0, "chore never offered in 100 runs")
        XCTAssertGreaterThan(noOffer, 0, "no-offer never drawn in 100 runs")
        XCTAssertLessThanOrEqual(movement, Self.dominanceBound,
                                "movement dominates: \(movement)/100")
        XCTAssertLessThanOrEqual(chore, Self.dominanceBound,
                                "chore dominates: \(chore)/100")
    }

    // MARK: - Gates

    func testMotivatedSessionIsNeverInterrupted() {
        let policy = policy()
        for classification in [StallClassification.trying, .uncertain] {
            for seed in 0..<20 {
                let decision = decide(context: lowMotivationContext(stalling: classification),
                                      policy: policy, seed: UInt64(seed))
                XCTAssertEqual(decision.outcome, .noOffer(.patienceNotExhausted),
                               "\(classification), seed \(seed)")
                XCTAssertNil(decision.movementGate)
                XCTAssertNil(decision.choreCandidate)
            }
        }
    }

    func testSessionCapBlocksBothCurrencies() {
        let policy = policy()
        for seed in 0..<20 {
            let decision = decide(
                context: lowMotivationContext(sessionOffersUsed: 1),
                policy: policy, seed: UInt64(seed))
            XCTAssertEqual(decision.outcome, .noOffer(.sessionCapReached),
                           "seed \(seed)")
        }
    }

    func testSameSeedReproducesSameDecision() {
        let policy = policy()
        let context = lowMotivationContext()
        for seed in [UInt64(0), 1, 7, 42, 99] {
            XCTAssertEqual(decide(context: context, policy: policy, seed: seed),
                           decide(context: context, policy: policy, seed: seed),
                           "seed \(seed)")
        }
    }

    // MARK: - Single-eligible variation

    func testMovementOnlyVariesBetweenOfferAndNone() {
        let policy = policy()
        // Empty resolved pool (a parent-authored empty pool stays empty):
        // movement or deliberate none, never chore.
        let context = lowMotivationContext(chorePool: [])
        var movement = 0
        var noOffer = 0
        for seed in 0..<100 {
            switch decide(context: context, policy: policy, seed: UInt64(seed)).outcome {
            case .movement(let offer):
                movement += 1
                XCTAssertEqual(offer.activity, .jumpingJacks)
                XCTAssertNil(decide(context: context, policy: policy,
                                   seed: UInt64(seed)).choreCandidate)
            case .chore:
                XCTFail("chore offered from an empty pool, seed \(seed)")
            case .noOffer(let reason):
                noOffer += 1
                XCTAssertEqual(reason, .variationNoOffer, "seed \(seed)")
            }
        }
        XCTAssertGreaterThan(movement, 0)
        XCTAssertGreaterThan(noOffer, 0)
    }

    func testChoreOnlyVariesBetweenOfferAndNone() {
        let policy = policy()
        // Movement weekly cap filled: chore or deliberate none, never movement.
        let context = lowMotivationContext(weeklyMovementUsage: 3)
        var chore = 0
        var noOffer = 0
        for seed in 0..<100 {
            let decision = decide(context: context, policy: policy, seed: UInt64(seed))
            XCTAssertEqual(decision.movementGate, .refuse(.weeklyCapReached),
                           "seed \(seed)")
            switch decision.outcome {
            case .movement:
                XCTFail("movement offered past its weekly cap, seed \(seed)")
            case .chore(let entry):
                chore += 1
                XCTAssertTrue(pool().map(\.chore).contains(entry.chore))
            case .noOffer(let reason):
                noOffer += 1
                XCTAssertEqual(reason, .variationNoOffer, "seed \(seed)")
            }
        }
        XCTAssertGreaterThan(chore, 0)
        XCTAssertGreaterThan(noOffer, 0)
    }

    func testNoEligibleOfferWhenBothEnginesUnavailable() {
        let policy = policy()
        let context = lowMotivationContext(chorePool: [], weeklyMovementUsage: 3)
        for seed in 0..<20 {
            let decision = decide(context: context, policy: policy, seed: UInt64(seed))
            XCTAssertEqual(decision.outcome, .noOffer(.noEligibleOffer),
                           "seed \(seed)")
            XCTAssertEqual(decision.movementGate, .refuse(.weeklyCapReached))
            XCTAssertNil(decision.choreCandidate)
        }
    }

    // MARK: - Chore caps (T3.3 owns what T3.2 does not enforce)

    func testPolicyWeeklyChoreCapRemovesChoreCurrency() {
        let policy = policy()
        let context = lowMotivationContext(weeklyChoreUsage: 3)
        for seed in 0..<20 {
            let decision = decide(context: context, policy: policy, seed: UInt64(seed))
            XCTAssertNil(decision.choreCandidate, "seed \(seed)")
            if case .chore = decision.outcome {
                XCTFail("chore offered past its policy weekly cap, seed \(seed)")
            }
        }
    }

    func testPerEntryWeeklyCapFiltersOnlyThatChore() {
        let capped = entry("Wash the car")
        let open = entry("Paint the fence")
        var context = lowMotivationContext(chorePool: [capped, open])
        // "Wash the car" already at its per-entry cap of 3.
        context.weeklyUsageByChore = ["Wash the car": 3]
        let policy = policy()
        for seed in 0..<20 {
            var generator = EffortSeededRNG(seed: UInt64(seed))
            let decision = TradeOfferDecider.decide(
                context: context, policy: policy, using: &generator)
            XCTAssertEqual(decision.choreCandidate?.chore, "Paint the fence",
                           "seed \(seed)")
            if case .chore(let picked) = decision.outcome {
                XCTAssertEqual(picked.chore, "Paint the fence", "seed \(seed)")
            }
        }
    }

    func testMovementTaperRefusalStillLeavesChoreAvailable() {
        let policy = policy()
        var context = lowMotivationContext()
        // 4-of-5 pattern with a recent offer: movement tapered into cooldown.
        context.recentSessionCompletions = [true, true, true, true, false]
        context.sessionsSinceLastMovementOffer = 0
        for seed in 0..<20 {
            let decision = decide(context: context, policy: policy, seed: UInt64(seed))
            XCTAssertEqual(decision.movementGate, .refuse(.taperedCooldown),
                           "seed \(seed)")
            if case .movement = decision.outcome {
                XCTFail("tapered movement offered, seed \(seed)")
            }
        }
    }

    // MARK: - Decision log: every decision, including no-offer

    func testOffersLogAsOfferTradeAndNoOffersAsSessionJudgment() throws {
        let logger = DecisionLogger(directory: directory)
        let policy = policy()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Find one seed per outcome kind (the mix test proves all occur).
        var seen: [String: TradeOfferDecision] = [:]
        for seed in 0..<100 where seen.count < 3 {
            let decision = decide(context: lowMotivationContext(),
                                  policy: policy, seed: UInt64(seed))
            switch decision.outcome {
            case .movement: seen["movement"] = decision
            case .chore: seen["chore"] = decision
            case .noOffer: seen["none"] = decision
            }
        }
        XCTAssertEqual(seen.count, 3, "expected all three outcome kinds, got \(seen.keys)")
        var index = 0
        for key in ["movement", "chore", "none"] {
            // Log this decision's justification through the matching typed
            // seam — the same mapping `decideAndLog` applies.
            let decision = seen[key]!
            let justification = TradeOfferDecider.justification(
                for: decision, context: lowMotivationContext(), policy: policy)
            let record: Decision
            switch justification.type {
            case .offerTrade:
                record = try logger.logTradeOffer(
                    sessionId: "session-\(key)", outcome: justification.outcome,
                    evidenceSummary: justification.evidenceSummary,
                    reasoning: justification.reasoning,
                    alternativeConsidered: justification.alternativeConsidered,
                    confidence: justification.confidence,
                    timestamp: base.addingTimeInterval(TimeInterval(index)),
                    decisionId: "decision-\(key)")
            default:
                record = try logger.logSessionJudgment(
                    sessionId: "session-\(key)", outcome: justification.outcome,
                    evidenceSummary: justification.evidenceSummary,
                    reasoning: justification.reasoning,
                    alternativeConsidered: justification.alternativeConsidered,
                    confidence: justification.confidence,
                    timestamp: base.addingTimeInterval(TimeInterval(index)),
                    decisionId: "decision-\(key)")
            }
            XCTAssertTrue(record.isComplete, "\(key): \(record.incompleteFields)")
            index += 1
        }
        let records = logger.decisions
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].type, .offerTrade)
        XCTAssertEqual(records[1].type, .offerTrade)
        XCTAssertEqual(records[2].type, .sessionJudgment)
        XCTAssertTrue(records.allSatisfy(\.isComplete))
    }

    func testDecideAndLogRecordsTheFullDecisionSequence() throws {
        let logger = DecisionLogger(directory: directory)
        let policy = policy()
        let context = lowMotivationContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var movement = 0
        var chore = 0
        var none = 0
        for seed in 0..<100 {
            var generator = EffortSeededRNG(seed: UInt64(seed))
            let result = try TradeOfferDecider.decideAndLog(
                context: context, policy: policy, logger: logger,
                sessionId: "session-\(seed)",
                timestamp: base.addingTimeInterval(TimeInterval(seed)),
                decisionId: "decision-\(seed)",
                using: &generator)
            XCTAssertTrue(result.record.isComplete,
                          "seed \(seed): \(result.record.incompleteFields)")
            switch (result.decision.outcome, result.record.type) {
            case (.movement, .offerTrade): movement += 1
            case (.chore, .offerTrade): chore += 1
            case (.noOffer, .sessionJudgment): none += 1
            default:
                XCTFail("seed \(seed): outcome \(result.decision.outcome)"
                    + " logged as \(result.record.type)")
            }
        }
        // The logged sequence IS the variation data: all three kinds present.
        XCTAssertEqual(logger.decisions.count, 100)
        XCTAssertGreaterThan(movement, 0)
        XCTAssertGreaterThan(chore, 0)
        XCTAssertGreaterThan(none, 0)
        XCTAssertTrue(logger.decisions.allSatisfy(\.isComplete))
    }

    func testDecideAndLogFailurePresentsNothing() {
        let failing = DecisionLogger(directory: directory, dataWriter: { _, _ in
            throw NSError(domain: "test", code: 1)
        })
        var generator = EffortSeededRNG(seed: 0)
        XCTAssertThrowsError(try TradeOfferDecider.decideAndLog(
            context: lowMotivationContext(), policy: policy(),
            logger: failing, sessionId: "s", decisionId: "d",
            using: &generator)) { error in
            XCTAssertEqual(error as? DecisionLogError, .persistenceFailed)
        }
        XCTAssertTrue(failing.decisions.isEmpty)
    }

    func testJustificationIsDeterministic() {
        let policy = policy()
        let context = lowMotivationContext()
        let decision = decide(context: context, policy: policy, seed: 42)
        let first = TradeOfferDecider.justification(for: decision, context: context,
                                                    policy: policy)
        let second = TradeOfferDecider.justification(for: decision, context: context,
                                                     policy: policy)
        XCTAssertEqual(first.type, second.type)
        XCTAssertEqual(first.outcome, second.outcome)
        XCTAssertEqual(first.evidenceSummary, second.evidenceSummary)
        XCTAssertEqual(first.reasoning, second.reasoning)
        XCTAssertEqual(first.alternativeConsidered, second.alternativeConsidered)
        XCTAssertEqual(first.confidence, second.confidence)
    }
}
