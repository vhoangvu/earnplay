import Foundation

/// Trade offer logic (T3.3) — movement vs chore vs no offer.
///
/// Decides mid-session whether to offer a movement trade, a chore trade,
/// or no offer at all. Deterministic code only: the tutor model proposes
/// the moment, this code disposes. The T3.1 (`MovementTradeManager`) and
/// T3.2 (`ChoreTradeSession.selectNextOffer`) engines are consumed as-is
/// — their gates, caps, rotation, and time-of-day fit are never
/// re-implemented here.
///
/// Gate order (first failure wins; all short-circuits are no-offer):
/// 1. Effort floor (absolute): the T1.4 floor, read with the policy's
///    `EffortFloorSettings`, must hold. Below the floor no alternative
///    currency is ever offered, however long the session idles.
/// 2. Patience: the stalling classification must be `.stalling` (patience
///    exhausted while the child still wants the unlock — presence in a
///    practice session is the intent proxy; no T1.4/T1.5 signal names
///    intent separately). `.trying` means a motivated session that must
///    never be interrupted; `.uncertain` defaults to a probe (LLD §4),
///    never a trade.
/// 3. Session cap: combined movement + chore offers this session must be
///    below `tradeCaps.maxTradesPerSession` (across both trade types —
///    neither engine sees the other, so this module enforces the shared
///    cap and passes the combined count into the movement gate).
/// 4. Engine eligibility: the movement engine's verdict
///    (`MovementTradeManager.decide`, called with `.aiLowMotivation` —
///    the stalling gate above IS the AI low-motivation judgment) and the
///    chore engine's pick (`selectNextOffer` over the pool pre-filtered
///    for policy-level and per-entry weekly caps). The caller supplies
///    the resolved chore pool (`ChoreTradePoolSource.resolve(policy).pool`,
///    so a parent-authored empty pool stays empty) and weekly usage the
///    engines do not track themselves.
/// 5. Variation: uniform draw over the available choices, no offer
///    included — both eligible: movement / chore / none (1/3 each); one
///    eligible: that offer / none (1/2 each). No learnable pattern, by
///    the same mechanism as the T1.4 threshold draw: production draws
///    from the system RNG, tests inject a seeded generator.
///
/// Every decision — INCLUDING no-offer — is written to the T1.6 decision
/// log through `decideAndLog`, which decides and appends atomically: if
/// logging throws, the caller presents nothing. Offers log as
/// `.offerTrade`; no-offer logs as `.sessionJudgment` (the LLD §7
/// patience/offer-condition judgment). The logged sequence is what "no
/// predictable pattern" is checked against, not impression.

// MARK: - Context

/// Inputs to one offer decision at one session moment.
///
/// Counts the caller supplies (this module keeps no history):
/// - `sessionOffersUsed`: movement + chore offers already made this
///   session (the shared session-cap numerator).
/// - `weeklyMovementUsage`: trailing-week movement grants plus
///   outstanding offers (`MovementTradeHistory.weeklyUsageInTrailingWeek`).
/// - `weeklyChoreUsage`: trailing-week chore grants plus outstanding
///   offers at policy level (T3.2 keeps no history; the host tracks it).
/// - `weeklyUsageByChore`: trailing-week usage per chore text for the
///   per-entry `ChorePoolEntry.weeklyCap` filter.
/// - `recentSessionCompletions` / `sessionsSinceLastMovementOffer`: the
///   movement taper inputs (see `MovementOfferContext`).
public struct TradeOfferContext: Equatable, Sendable {
    public var signals: EffortSignals
    public var stalling: StallClassification
    public var sessionOffersUsed: Int
    public var weeklyMovementUsage: Int
    public var weeklyChoreUsage: Int
    public var weeklyUsageByChore: [String: Int]
    public var recentSessionCompletions: [Bool]
    public var sessionsSinceLastMovementOffer: Int?
    /// Resolved chore pool (see `ChoreTradePoolSource.resolve`).
    public var chorePool: [ChorePoolEntry]
    /// Chore texts declined earlier this session (T3.2 exclusion).
    public var declinedChores: Set<String>
    /// Chore names offered before, oldest first, for rotation.
    public var choreHistory: [String]
    public var now: Date
    public var calendar: Calendar

    public init(signals: EffortSignals,
                stalling: StallClassification,
                sessionOffersUsed: Int = 0,
                weeklyMovementUsage: Int = 0,
                weeklyChoreUsage: Int = 0,
                weeklyUsageByChore: [String: Int] = [:],
                recentSessionCompletions: [Bool] = [],
                sessionsSinceLastMovementOffer: Int? = nil,
                chorePool: [ChorePoolEntry] = [],
                declinedChores: Set<String> = [],
                choreHistory: [String] = [],
                now: Date = Date(),
                calendar: Calendar = .current) {
        self.signals = signals
        self.stalling = stalling
        self.sessionOffersUsed = sessionOffersUsed
        self.weeklyMovementUsage = weeklyMovementUsage
        self.weeklyChoreUsage = weeklyChoreUsage
        self.weeklyUsageByChore = weeklyUsageByChore
        self.recentSessionCompletions = recentSessionCompletions
        self.sessionsSinceLastMovementOffer = sessionsSinceLastMovementOffer
        self.chorePool = chorePool
        self.declinedChores = declinedChores
        self.choreHistory = choreHistory
        self.now = now
        self.calendar = calendar
    }
}

// MARK: - Outcome

/// Why no trade was offered. Recorded in the decision log.
public enum TradeOfferNoOfferReason: String, Equatable, Sendable {
    /// The T1.4 floor is not met. Absolute: no variation draw runs.
    case floorNotMet
    /// Patience is not exhausted (`.trying` or `.uncertain`): a motivated
    /// session is never interrupted, and uncertainty probes, never trades.
    case patienceNotExhausted
    /// The shared session cap already holds this session's offers.
    case sessionCapReached
    /// Both engines unavailable: movement refused and no chore eligible.
    /// The decision's engine details name the underlying causes.
    case noEligibleOffer
    /// At least one engine was eligible but the variation draw picked
    /// none, so offers stay unpredictable.
    case variationNoOffer
}

/// The offer choice: one movement offer, one chore, or no offer.
public enum TradeOfferOutcome: Equatable, Sendable {
    case movement(MovementTradeOffer)
    case chore(ChorePoolEntry)
    case noOffer(TradeOfferNoOfferReason)
}

/// One offer decision plus the engine evidence behind it.
///
/// `movementGate` / `choreCandidate` are nil when a gate short-circuited
/// before the engines were consulted (floor, patience, session cap) —
/// the engines were not asked. Otherwise they carry exactly what each
/// engine said, so the logged justification is auditable.
public struct TradeOfferDecision: Equatable, Sendable {
    public var outcome: TradeOfferOutcome
    public var movementGate: MovementOfferDecision?
    public var choreCandidate: ChorePoolEntry?

    public init(outcome: TradeOfferOutcome,
                movementGate: MovementOfferDecision? = nil,
                choreCandidate: ChorePoolEntry? = nil) {
        self.outcome = outcome
        self.movementGate = movementGate
        self.choreCandidate = choreCandidate
    }
}

// MARK: - Decider

/// Pure offer-choice gate. See the file header for gate order.
public enum TradeOfferDecider {
    /// Decides with an injected RNG (seeded in tests, system in
    /// production). Only the variation draw consumes randomness; every
    /// gate is a pure function of context and policy.
    public static func decide<RNG: RandomNumberGenerator>(
        context: TradeOfferContext, policy: Policy, using generator: inout RNG
    ) -> TradeOfferDecision {
        // 1. Floor — absolute, before anything else.
        let floor = EffortScorer(threshold: EffortScorer.thresholdRange.lowerBound,
                                 floorSettings: policy.effortFloorSettings)
        guard floor.floorMet(for: context.signals) else {
            return TradeOfferDecision(outcome: .noOffer(.floorNotMet))
        }
        // 2. Patience — stalling only.
        guard context.stalling == .stalling else {
            return TradeOfferDecision(outcome: .noOffer(.patienceNotExhausted))
        }
        // 3. Shared session cap — across both trade types.
        guard context.sessionOffersUsed < max(0, policy.tradeCaps.maxTradesPerSession) else {
            return TradeOfferDecision(outcome: .noOffer(.sessionCapReached))
        }
        // 4. Engine eligibility — consumed, never re-implemented.
        let movementContext = MovementOfferContext(
            initiation: .aiLowMotivation,
            signals: context.signals,
            floorSettings: .default,
            sessionOffersUsed: context.sessionOffersUsed,
            weeklyCompletions: context.weeklyMovementUsage,
            recentSessionCompletions: context.recentSessionCompletions,
            sessionsSinceLastMovementOffer: context.sessionsSinceLastMovementOffer)
        let movementGate = MovementTradeManager.decide(context: movementContext, policy: policy)
        let choreCandidate: ChorePoolEntry?
        if context.weeklyChoreUsage < max(0, policy.tradeCaps.weeklyMaxChoreTrades) {
            let hour = context.calendar.component(.hour, from: context.now)
            choreCandidate = ChoreTradeSession.selectNextOffer(
                pool: cappedPool(context: context),
                declined: context.declinedChores,
                history: context.choreHistory,
                now: context.now,
                hour: hour)
        } else {
            choreCandidate = nil
        }
        let movementOffer: MovementTradeOffer?
        if case .offer(let offer) = movementGate {
            movementOffer = offer
        } else {
            movementOffer = nil
        }
        // 5. Variation — uniform over available choices, none included.
        let outcome: TradeOfferOutcome
        switch (movementOffer, choreCandidate) {
        case (let movement?, let chore?):
            switch Int.random(in: 0..<3, using: &generator) {
            case 0: outcome = .movement(movement)
            case 1: outcome = .chore(chore)
            default: outcome = .noOffer(.variationNoOffer)
            }
        case (let movement?, nil):
            outcome = Bool.random(using: &generator)
                ? .movement(movement) : .noOffer(.variationNoOffer)
        case (nil, let chore?):
            outcome = Bool.random(using: &generator)
                ? .chore(chore) : .noOffer(.variationNoOffer)
        case (nil, nil):
            outcome = .noOffer(.noEligibleOffer)
        }
        return TradeOfferDecision(outcome: outcome,
                                  movementGate: movementGate,
                                  choreCandidate: choreCandidate)
    }

    /// Decides with the system RNG (production path).
    public static func decide(context: TradeOfferContext, policy: Policy) -> TradeOfferDecision {
        var generator = SystemRandomNumberGenerator()
        return decide(context: context, policy: policy, using: &generator)
    }

    /// Pool entries still under their per-entry weekly cap. A cap of 0
    /// means never offered (matching the movement fail-closed treatment
    /// of degenerate caps); usage defaults to 0 for unrecorded chores.
    static func cappedPool(context: TradeOfferContext) -> [ChorePoolEntry] {
        context.chorePool.filter { entry in
            (context.weeklyUsageByChore[entry.chore] ?? 0) < max(0, entry.weeklyCap)
        }
    }

    // MARK: - Justification (pure; T1.6 mapping)

    /// Confidence levels: rule-determined gates 0.9, the stalling
    /// classification 0.8, randomized outcomes among eligible options 0.7
    /// (an offer and a deliberate none were both defensible).
    public static func confidence(for outcome: TradeOfferOutcome) -> Double {
        switch outcome {
        case .movement, .chore:
            return 0.7
        case .noOffer(.variationNoOffer):
            return 0.7
        case .noOffer(.patienceNotExhausted):
            return 0.8
        case .noOffer(.floorNotMet), .noOffer(.sessionCapReached), .noOffer(.noEligibleOffer):
            return 0.9
        }
    }

    /// Deterministic justification for a decision. Pure and total: the
    /// same decision, context, and policy always yield the same type,
    /// outcome, evidence, reasoning, alternative, and confidence.
    public static func justification(for decision: TradeOfferDecision,
                                     context: TradeOfferContext,
                                     policy: Policy)
    -> (type: DecisionType, outcome: String, evidenceSummary: String,
        reasoning: String, alternativeConsidered: String, confidence: Double) {
        let signals = context.signals
        let floorMet = EffortScorer(threshold: EffortScorer.thresholdRange.lowerBound,
                                    floorSettings: policy.effortFloorSettings)
            .floorMet(for: signals)
        var evidence = "Evidence: \(signals.genuineAttempts) genuine attempts,"
            + " \(signals.hintOrFollowUpInteractions) hint/follow-up interactions,"
            + " \(signals.activeMinutes) active minutes;"
            + " floor \(floorMet ? "met" : "not met");"
            + " stalling classification \(context.stalling.rawValue);"
            + " session offers used \(context.sessionOffersUsed)"
            + " of \(policy.tradeCaps.maxTradesPerSession);"
            + " weekly movement usage \(context.weeklyMovementUsage)"
            + " of \(policy.tradeCaps.weeklyMaxMovementTrades);"
            + " weekly chore usage \(context.weeklyChoreUsage)"
            + " of \(policy.tradeCaps.weeklyMaxChoreTrades)."
        if let movementGate = decision.movementGate {
            switch movementGate {
            case .offer(let offer):
                evidence += " Movement engine: offer \(offer.activity.rawValue),"
                    + " \(offer.targetReps) reps, \(offer.unlockMinutes) minutes"
                    + (offer.taperApplied ? " (taper applied)." : ".")
            case .refuse(let refusal):
                evidence += " Movement engine: refused (\(refusal.rawValue))."
            }
        } else {
            evidence += " Movement engine: not consulted (gate short-circuit)."
        }
        if let chore = decision.choreCandidate {
            evidence += " Chore engine: picked \"\(chore.chore)\""
                + " (\(chore.unlockMinutes) minutes)."
        } else if decision.movementGate == nil {
            evidence += " Chore engine: not consulted (gate short-circuit)."
        } else {
            evidence += " Chore engine: no eligible chore."
        }
        let outcome: TradeOfferOutcome = decision.outcome
        let type: DecisionType
        let outcomeText: String
        let reasoning: String
        let alternative: String
        switch outcome {
        case .movement(let offer):
            type = .offerTrade
            outcomeText = "Offered movement trade: \(offer.activity.rawValue),"
                + " \(offer.targetReps) reps for \(offer.unlockMinutes) minutes."
            reasoning = "Floor met and patience exhausted; the movement engine"
                + " cleared its gates and the variation draw picked movement"
                + " among the eligible options, so offer it."
            alternative = "Alternative was the other currency or no offer;"
                + " rejected because the draw chose movement and withholding"
                + " an eligible trade every time would itself be learnable."
        case .chore(let entry):
            type = .offerTrade
            outcomeText = "Offered chore trade: \"\(entry.chore)\""
                + " for \(entry.unlockMinutes) minutes."
            reasoning = "Floor met and patience exhausted; the chore engine"
                + " picked an eligible chore and the variation draw picked"
                + " chore among the eligible options, so offer it."
            alternative = "Alternative was the other currency or no offer;"
                + " rejected because the draw chose chore and withholding"
                + " an eligible trade every time would itself be learnable."
        case .noOffer(.floorNotMet):
            type = .sessionJudgment
            outcomeText = "No trade offered: effort floor not met."
            reasoning = "Floor not met (\(signals.genuineAttempts) genuine"
                + " attempts, \(signals.hintOrFollowUpInteractions)"
                + " hint/follow-up interactions): the floor is absolute and"
                + " no alternative currency is offered before a genuine"
                + " practice attempt, so offer nothing."
            alternative = "Alternative was to offer a trade despite the"
                + " missing floor; rejected because the floor is mandatory."
        case .noOffer(.patienceNotExhausted):
            type = .sessionJudgment
            outcomeText = "No trade offered: patience not exhausted"
                + " (\(context.stalling.rawValue))."
            reasoning = "Classification is \(context.stalling.rawValue), not"
                + " stalling: a motivated session must never be interrupted,"
                + " and uncertainty probes rather than trades, so offer nothing."
            alternative = "Alternative was to offer a trade anyway; rejected"
                + " because only exhausted patience earns an alternative currency."
        case .noOffer(.sessionCapReached):
            type = .sessionJudgment
            outcomeText = "No trade offered: session trade cap reached"
                + " (\(context.sessionOffersUsed) of"
                + " \(policy.tradeCaps.maxTradesPerSession))."
            reasoning = "Session offers used (\(context.sessionOffersUsed))"
                + " already reach the shared cap"
                + " (\(policy.tradeCaps.maxTradesPerSession) across both trade"
                + " types), so offer nothing more this session."
            alternative = "Alternative was a further offer; rejected because"
                + " the cap bounds offers per session."
        case .noOffer(.noEligibleOffer):
            type = .sessionJudgment
            outcomeText = "No trade offered: no eligible trade."
            reasoning = "Floor met and patience exhausted, but the movement"
                + " engine refused and no chore is eligible, so nothing can"
                + " be offered."
            alternative = "Alternative was to offer despite engine refusal;"
                + " rejected because caps, taper, and pool eligibility bind."
        case .noOffer(.variationNoOffer):
            type = .sessionJudgment
            outcomeText = "No trade offered: variation draw picked none."
            reasoning = "Floor met and patience exhausted with at least one"
                + " eligible trade, but the variation draw picked none among"
                + " the available choices, so offers stay unpredictable."
            alternative = "Alternative was to offer the eligible trade;"
                + " rejected this time because always offering when eligible"
                + " would make stalling a reliable way to summon a trade."
        }
        return (type, outcomeText, evidence, reasoning, alternative,
                confidence(for: outcome))
    }

    // MARK: - Atomic decide-and-log boundary

    /// Decides and logs the decision atomically with an injected RNG.
    ///
    /// The session-decision boundary for trade effects: one call decides
    /// and appends the offer-trade / session-judgment Decision via
    /// `logger`, and the caller presents the offer only when this
    /// returns. If logging throws (invalid context, duplicate ID, or
    /// persistence failure), nothing returns and no record exists, so the
    /// caller cannot mistake an unlogged evaluation for a decided one.
    /// On success returns both the decision and its persisted Decision.
    public static func decideAndLog<RNG: RandomNumberGenerator>(
        context: TradeOfferContext, policy: Policy, logger: DecisionLogger,
        sessionId: String, timestamp: Date = Date(),
        decisionId: String = UUID().uuidString,
        using generator: inout RNG
    ) throws -> (decision: TradeOfferDecision, record: Decision) {
        let decision = decide(context: context, policy: policy, using: &generator)
        let justification = justification(for: decision, context: context, policy: policy)
        let record: Decision
        switch justification.type {
        case .offerTrade:
            record = try logger.logTradeOffer(
                sessionId: sessionId, outcome: justification.outcome,
                evidenceSummary: justification.evidenceSummary,
                reasoning: justification.reasoning,
                alternativeConsidered: justification.alternativeConsidered,
                confidence: justification.confidence,
                timestamp: timestamp, decisionId: decisionId)
        default:
            record = try logger.logSessionJudgment(
                sessionId: sessionId, outcome: justification.outcome,
                evidenceSummary: justification.evidenceSummary,
                reasoning: justification.reasoning,
                alternativeConsidered: justification.alternativeConsidered,
                confidence: justification.confidence,
                timestamp: timestamp, decisionId: decisionId)
        }
        return (decision, record)
    }

    /// Decides and logs with the system RNG (production path). See the
    /// injected-RNG overload for the atomicity contract.
    public static func decideAndLog(
        context: TradeOfferContext, policy: Policy, logger: DecisionLogger,
        sessionId: String, timestamp: Date = Date(),
        decisionId: String = UUID().uuidString
    ) throws -> (decision: TradeOfferDecision, record: Decision) {
        var generator = SystemRandomNumberGenerator()
        return try decideAndLog(context: context, policy: policy, logger: logger,
                                sessionId: sessionId, timestamp: timestamp,
                                decisionId: decisionId, using: &generator)
    }
}
