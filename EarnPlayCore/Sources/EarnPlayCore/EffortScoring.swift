import Foundation

/// Effort scoring (T1.4) — deterministic, never delegated to a model.
///
/// Scores genuine effort from active minutes, attempts, hint
/// interactions, answer revisions, and explanations given. Correctness
/// is never an input: a session of wrong answers with genuine trying
/// passes, and an idle session fails. See `Docs/EffortScoring.md`.
///
/// Signals and consumption contract for later tasks (T1.5/T1.6/T3.1/
/// T5.1):
/// - Record interactions with `EffortSessionRecorder` (it also conforms
///   to `HintListenEventSink`, so a `ReadAloudService` hint listen is
///   counted as a recorded hint interaction), or build an
///   `EffortSignals` value directly.
/// - Score with `EffortScorer.evaluate(_:)`, which returns an
///   `EffortScore` carrying `(score, threshold, floorMet)`, the
///   grant/deny `decision` for T1.6, and `narration` naming the effort.
///
/// Hint-ladder note: T1.3's hint ladder is not present on this branch's
/// base. Following the task rule, the ladder is not re-implemented here;
/// this module scores from *recorded* hint interactions (direct
/// `recordHintInteraction()` calls and `HintListenEvent`s). When T1.3
/// lands, its ladder should record through the same recorder/signals.

// MARK: - Weights (Band B, grades 3-5)

/// Per-signal point weights. Demo scope is Band B (grades 3-5), in
/// which verbal explanations are weighed alongside retries, hint use,
/// attempts, and revisions. Band A weights are v1 scope (T6.7/T6.8)
/// and are deliberately not defined here.
public struct EffortWeights: Equatable, Sendable {
    public var perActiveMinute: Int
    public var perGenuineAttempt: Int
    public var perHintInteraction: Int
    public var perFollowUpInteraction: Int
    public var perAnswerRevision: Int
    public var perExplanation: Int

    public init(perActiveMinute: Int = 1, perGenuineAttempt: Int = 2,
                perHintInteraction: Int = 2, perFollowUpInteraction: Int = 1,
                perAnswerRevision: Int = 1, perExplanation: Int = 2) {
        self.perActiveMinute = perActiveMinute
        self.perGenuineAttempt = perGenuineAttempt
        self.perHintInteraction = perHintInteraction
        self.perFollowUpInteraction = perFollowUpInteraction
        self.perAnswerRevision = perAnswerRevision
        self.perExplanation = perExplanation
    }

    /// Band B (grades 3-5) weights used by the demo.
    public static let bandB = EffortWeights()
    /// Alias naming the current shipping band explicitly.
    public static let `default` = EffortWeights.bandB
}

// MARK: - Signals

/// Raw effort signals for one session. Counts are clamped to zero on
/// construction so downstream code never sees negative effort.
public struct EffortSignals: Equatable, Sendable {
    /// Active seconds, already idle-paused (see `ActiveTimeTracker`).
    public var activeSeconds: Int
    public var genuineAttempts: Int
    public var hintInteractions: Int
    public var followUpInteractions: Int
    public var answerRevisions: Int
    /// Verbal explanations given by the child (Band B signal).
    public var explanations: Int

    public init(activeSeconds: Int = 0, genuineAttempts: Int = 0,
                hintInteractions: Int = 0, followUpInteractions: Int = 0,
                answerRevisions: Int = 0, explanations: Int = 0) {
        self.activeSeconds = max(0, activeSeconds)
        self.genuineAttempts = max(0, genuineAttempts)
        self.hintInteractions = max(0, hintInteractions)
        self.followUpInteractions = max(0, followUpInteractions)
        self.answerRevisions = max(0, answerRevisions)
        self.explanations = max(0, explanations)
    }

    /// Whole active minutes (partial minutes never score).
    public var activeMinutes: Int { activeSeconds / 60 }
    /// Hint + follow-up interactions, the hint side of the floor rule.
    public var hintOrFollowUpInteractions: Int { hintInteractions + followUpInteractions }
}

// MARK: - Active time

/// Active-time accounting with the ~20-second idle pause.
///
/// Anchors are the session start plus every interaction. Each gap
/// between consecutive anchors (and the gap to the evaluation time)
/// contributes at most `idlePauseSeconds`: time after about 20 seconds
/// with no interaction is paused and never scores, and active time
/// resumes when interaction resumes without counting the idle gap.
public enum ActiveTimeTracker {
    public static let defaultIdlePauseSeconds: TimeInterval = 20

    /// Active seconds from second-offsets relative to any epoch.
    public static func activeSeconds(interactionOffsets: [TimeInterval],
                                     startedAt: TimeInterval,
                                     evaluatedAt: TimeInterval,
                                     idlePauseSeconds: TimeInterval = defaultIdlePauseSeconds) -> Int {
        let pause = max(0, idlePauseSeconds)
        let end = max(startedAt, evaluatedAt)
        var anchors = [startedAt]
        anchors += interactionOffsets.filter { $0 >= startedAt && $0 <= end }
        anchors.sort()
        anchors.append(end)
        var total: TimeInterval = 0
        for index in 1..<anchors.count {
            let gap = anchors[index] - anchors[index - 1]
            if gap > 0 { total += min(gap, pause) }
        }
        return Int(total)
    }

    /// Active seconds from `Date` interaction timestamps.
    public static func activeSeconds(interactionDates: [Date],
                                     startedAt: Date, evaluatedAt: Date,
                                     idlePauseSeconds: TimeInterval = defaultIdlePauseSeconds) -> Int {
        activeSeconds(
            interactionOffsets: interactionDates.map { $0.timeIntervalSince(startedAt) },
            startedAt: 0, evaluatedAt: evaluatedAt.timeIntervalSince(startedAt),
            idlePauseSeconds: idlePauseSeconds)
    }
}

// MARK: - Result

/// Grant/deny decision fed to T1.6.
public enum EffortUnlockDecision: String, Equatable, Sendable {
    case granted
    case denied
}

/// Per-signal point breakdown behind an `EffortScore`.
public struct EffortBreakdown: Equatable, Sendable {
    public var activeMinutes: Int
    public var activeMinutePoints: Int
    public var attemptPoints: Int
    public var hintPoints: Int
    public var followUpPoints: Int
    public var revisionPoints: Int
    public var explanationPoints: Int

    public init(activeMinutes: Int, activeMinutePoints: Int, attemptPoints: Int,
                hintPoints: Int, followUpPoints: Int, revisionPoints: Int,
                explanationPoints: Int) {
        self.activeMinutes = activeMinutes
        self.activeMinutePoints = activeMinutePoints
        self.attemptPoints = attemptPoints
        self.hintPoints = hintPoints
        self.followUpPoints = followUpPoints
        self.revisionPoints = revisionPoints
        self.explanationPoints = explanationPoints
    }
}

/// Scoring result: `(score, threshold, floorMet)` plus the unlock
/// decision for T1.6 and narration naming the effort observed.
public struct EffortScore: Equatable, Sendable {
    public var score: Int
    public var threshold: Int
    public var floorMet: Bool
    public var signals: EffortSignals
    public var breakdown: EffortBreakdown
    /// Narration naming the specific effort observed. On a grant this
    /// is the reward narration ("You earned this unlock by ..."); on a
    /// denial it names the effort so far and never claims the unlock.
    public var narration: String

    public init(score: Int, threshold: Int, floorMet: Bool, signals: EffortSignals,
                breakdown: EffortBreakdown, narration: String) {
        self.score = score
        self.threshold = threshold
        self.floorMet = floorMet
        self.signals = signals
        self.breakdown = breakdown
        self.narration = narration
    }

    /// True only when threshold and floor both hold.
    public var unlockGranted: Bool { floorMet && score >= threshold }
    public var decision: EffortUnlockDecision { unlockGranted ? .granted : .denied }
}

// MARK: - Deterministic RNG for reproducible threshold draws

/// SplitMix64 generator so scripted fixtures can reproduce a session's
/// threshold draws exactly. Production sessions use the system RNG.
public struct EffortSeededRNG: RandomNumberGenerator, Equatable, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Scorer

/// Scores one session against a per-session variable threshold.
///
/// The threshold is drawn once per scorer (i.e. per session) from
/// 8...14, so the target cannot be learned across sessions. Construct
/// one scorer per session; do not reuse a scorer across sessions.
public struct EffortScorer: Equatable, Sendable {
    /// Per-session threshold range; the drawn target is never outside it.
    public static let thresholdRange = 8...14

    public let threshold: Int
    public let floorSettings: EffortFloorSettings
    public let weights: EffortWeights

    /// Session scorer with a threshold drawn from the system RNG.
    public init(floorSettings: EffortFloorSettings = .default,
                weights: EffortWeights = .bandB) {
        var rng = SystemRandomNumberGenerator()
        self.init(threshold: Self.drawThreshold(using: &rng),
                  floorSettings: floorSettings, weights: weights)
    }

    /// Session scorer with a threshold drawn from a seeded RNG, for
    /// reproducible scripted sessions and tests.
    public init(seed: UInt64, floorSettings: EffortFloorSettings = .default,
                weights: EffortWeights = .bandB) {
        var rng = EffortSeededRNG(seed: seed)
        self.init(threshold: Self.drawThreshold(using: &rng),
                  floorSettings: floorSettings, weights: weights)
    }

    /// Scorer with an explicit threshold, clamped into 8...14.
    public init(threshold: Int, floorSettings: EffortFloorSettings = .default,
                weights: EffortWeights = .bandB) {
        self.threshold = Self.clampThreshold(threshold)
        self.floorSettings = floorSettings
        self.weights = weights
    }

    public static func clampThreshold(_ value: Int) -> Int {
        min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }

    public static func drawThreshold<R: RandomNumberGenerator>(using generator: inout R) -> Int {
        Int.random(in: thresholdRange, using: &generator)
    }

    /// Floor rule: at least the configured number of genuine attempts
    /// plus at least the configured number of real hint or follow-up
    /// interactions. Below the floor no amount of time unlocks.
    public func floorMet(for signals: EffortSignals) -> Bool {
        signals.genuineAttempts >= max(0, floorSettings.minGenuineAttempts)
            && signals.hintOrFollowUpInteractions >= max(0, floorSettings.minHintOrFollowUpInteractions)
    }

    /// Scores the signals and returns the full decision record.
    public func evaluate(_ signals: EffortSignals) -> EffortScore {
        let breakdown = EffortBreakdown(
            activeMinutes: signals.activeMinutes,
            activeMinutePoints: signals.activeMinutes * weights.perActiveMinute,
            attemptPoints: signals.genuineAttempts * weights.perGenuineAttempt,
            hintPoints: signals.hintInteractions * weights.perHintInteraction,
            followUpPoints: signals.followUpInteractions * weights.perFollowUpInteraction,
            revisionPoints: signals.answerRevisions * weights.perAnswerRevision,
            explanationPoints: signals.explanations * weights.perExplanation)
        let score = breakdown.activeMinutePoints + breakdown.attemptPoints
            + breakdown.hintPoints + breakdown.followUpPoints
            + breakdown.revisionPoints + breakdown.explanationPoints
        let met = floorMet(for: signals)
        let granted = met && score >= threshold
        return EffortScore(
            score: score, threshold: threshold, floorMet: met, signals: signals,
            breakdown: breakdown,
            narration: Self.narration(signals: signals, granted: granted))
    }

    /// Convenience alias for `evaluate(_:)`.
    public func score(_ signals: EffortSignals) -> EffortScore { evaluate(signals) }

    /// Legacy placeholder-era entry point, kept for existing callers.
    /// Now scored with Band B weights (active minutes + attempts only).
    public func points(activeSeconds: Int, attempts: Int) -> Int {
        evaluate(EffortSignals(activeSeconds: activeSeconds, genuineAttempts: attempts)).score
    }

    // MARK: Narration

    static func narration(signals: EffortSignals, granted: Bool) -> String {
        var phrases: [String] = []
        if signals.activeMinutes > 0 {
            phrases.append("sticking with it for \(signals.activeMinutes) active "
                + (signals.activeMinutes == 1 ? "minute" : "minutes"))
        }
        if signals.genuineAttempts > 0 {
            phrases.append(signals.genuineAttempts == 1
                ? "trying 1 time" : "trying \(signals.genuineAttempts) times")
        }
        if signals.hintInteractions > 0 {
            phrases.append(signals.hintInteractions == 1
                ? "using a hint" : "using \(signals.hintInteractions) hints")
        }
        if signals.followUpInteractions > 0 {
            phrases.append(signals.followUpInteractions == 1
                ? "answering a follow-up question"
                : "answering \(signals.followUpInteractions) follow-up questions")
        }
        if signals.answerRevisions > 0 {
            phrases.append(signals.answerRevisions == 1
                ? "revising an answer" : "revising answers \(signals.answerRevisions) times")
        }
        if signals.explanations > 0 {
            phrases.append(signals.explanations == 1
                ? "explaining your thinking" : "explaining your thinking \(signals.explanations) times")
        }
        let effort: String
        switch phrases.count {
        case 0: effort = "working on your practice"
        case 1: effort = phrases[0]
        case 2: effort = phrases.joined(separator: " and ")
        default: effort = phrases.dropLast().joined(separator: ", ") + ", and " + phrases[phrases.count - 1]
        }
        if granted {
            return "You earned this unlock by \(effort)."
        }
        return "Keep going — so far you have been \(effort). "
            + "Try an answer and use a hint or follow-up question to keep building your effort."
    }
}

// MARK: - Session recorder

/// Records one session's interactions and builds its `EffortSignals`.
///
/// Every recorded event also counts as an interaction for active-time
/// accounting. Conforms to `HintListenEventSink`, so wiring it as a
/// `ReadAloudService.hintListenSink` counts each hint listen as a
/// recorded hint interaction. This is the recorded-hint-interaction
/// interface T1.3's ladder should also record through when it lands.
public final class EffortSessionRecorder: HintListenEventSink, @unchecked Sendable {
    public let startedAt: Date
    public let idlePauseSeconds: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var interactionDates: [Date] = []
    private var genuineAttempts = 0
    private var hintInteractions = 0
    private var followUpInteractions = 0
    private var answerRevisions = 0
    private var explanations = 0

    public init(startedAt: Date, idlePauseSeconds: TimeInterval = ActiveTimeTracker.defaultIdlePauseSeconds,
                now: @escaping () -> Date = Date.init) {
        self.startedAt = startedAt
        self.idlePauseSeconds = idlePauseSeconds
        self.now = now
    }

    private func record(count: (EffortSessionRecorder) -> Void, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        interactionDates.append(date)
        count(self)
    }

    /// Any interaction (tap, typing, speaking) that resets the idle pause.
    public func recordInteraction(at date: Date? = nil) {
        record(count: { _ in }, at: date ?? now())
    }

    /// A genuine answer attempt. Non-genuine events still count as
    /// interaction but never toward the floor or the score.
    public func recordAttempt(isGenuine: Bool = true, at date: Date? = nil) {
        record(count: { if isGenuine { $0.genuineAttempts += 1 } }, at: date ?? now())
    }

    public func recordHintInteraction(at date: Date? = nil) {
        record(count: { $0.hintInteractions += 1 }, at: date ?? now())
    }

    /// `HintListenEventSink`: a hint read aloud is a hint interaction.
    public func recordHintListen(_ event: HintListenEvent) {
        record(count: { $0.hintInteractions += 1 }, at: event.emittedAt)
    }

    public func recordFollowUpInteraction(at date: Date? = nil) {
        record(count: { $0.followUpInteractions += 1 }, at: date ?? now())
    }

    public func recordAnswerRevision(at date: Date? = nil) {
        record(count: { $0.answerRevisions += 1 }, at: date ?? now())
    }

    public func recordExplanation(at date: Date? = nil) {
        record(count: { $0.explanations += 1 }, at: date ?? now())
    }

    /// Signals as of `date` (defaults to the recorder's clock).
    public func signals(at date: Date? = nil) -> EffortSignals {
        let evaluatedAt = date ?? now()
        lock.lock(); defer { lock.unlock() }
        return EffortSignals(
            activeSeconds: ActiveTimeTracker.activeSeconds(
                interactionDates: interactionDates, startedAt: startedAt,
                evaluatedAt: evaluatedAt, idlePauseSeconds: idlePauseSeconds),
            genuineAttempts: genuineAttempts, hintInteractions: hintInteractions,
            followUpInteractions: followUpInteractions,
            answerRevisions: answerRevisions, explanations: explanations)
    }

    /// Scores the recorded session as of now.
    public func evaluate(_ scorer: EffortScorer) -> EffortScore {
        scorer.evaluate(signals())
    }
}
