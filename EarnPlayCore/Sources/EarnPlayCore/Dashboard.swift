import Foundation

/// Dashboard aggregates (T4.2, LLD-dashboard) — progress at a glance from
/// synced session logs only.
///
/// Pure, deterministic functions over `[SessionLog]`: the same logs, `now`,
/// and calendar always yield the same report. No networking, no storage, no
/// randomness, no sample data — when the input carries no signal, the
/// corresponding aggregate is nil/empty (the view renders an explicit
/// "not yet" state), never a zero dressed as real data.
///
/// Aggregation definitions:
/// 1. Accuracy per skill, this week vs last: per skill, correct/total over
///    questions in sessions whose `startedAt` falls in the calendar week
///    containing `now` vs the immediately preceding week. A week with no
///    questions yields nil, not 0. Skills with no questions in either week
///    are omitted.
/// 2. Active time per question: total `activeMs` over all questions in all
///    logs divided by the question count. Nil when there are no questions.
/// 3. Hint rate: share of questions with at least one hint used
///    (`hintsUsed > 0`) over all questions. Nil when there are none.
/// 4. Most common error type: the mode of `errorType` over incorrect
///    questions with a recorded type. Ties break alphabetically (Unicode
///    scalar order — locale-independent). Nil when no error is recorded.
/// 5. Effort trend: per-session (`score`, `threshold`) snapshots in
///    chronological order; sessions without a snapshot are skipped, never
///    zero-filled. Direction compares the last point to the first: higher
///    is rising, equal is steady, lower is dipping; fewer than two points
///    yields no direction.
/// 6. Trade frequency: count of `.offerTrade` decisions across all logs,
///    split into movement vs chore by the deterministic outcome prefixes
///    produced by `TradeOfferDecider.justification` (anything else counts
///    as other, never dropped), plus trades per synced session.
public enum Dashboard {

    // MARK: - Result types

    /// Per-skill correct/total for this week vs last week.
    public struct SkillWeekAccuracy: Equatable, Sendable {
        public var skill: String
        public var thisWeekCorrect: Int
        public var thisWeekTotal: Int
        public var lastWeekCorrect: Int
        public var lastWeekTotal: Int
        /// Nil when the week has no questions for this skill.
        public var thisWeekAccuracy: Double? {
            thisWeekTotal == 0 ? nil : Double(thisWeekCorrect) / Double(thisWeekTotal)
        }
        /// Nil when the week has no questions for this skill.
        public var lastWeekAccuracy: Double? {
            lastWeekTotal == 0 ? nil : Double(lastWeekCorrect) / Double(lastWeekTotal)
        }
        public init(skill: String, thisWeekCorrect: Int, thisWeekTotal: Int,
                    lastWeekCorrect: Int, lastWeekTotal: Int) {
            self.skill = skill
            self.thisWeekCorrect = thisWeekCorrect
            self.thisWeekTotal = thisWeekTotal
            self.lastWeekCorrect = lastWeekCorrect
            self.lastWeekTotal = lastWeekTotal
        }
    }

    /// Total and mean idle-paused active time over all questions.
    public struct ActiveTime: Equatable, Sendable {
        public var totalActiveMs: Int
        public var questionCount: Int
        /// Mean seconds per question; nil when there are no questions.
        public var averageSecondsPerQuestion: Double? {
            questionCount == 0 ? nil : Double(totalActiveMs) / Double(questionCount) / 1000.0
        }
        public init(totalActiveMs: Int, questionCount: Int) {
            self.totalActiveMs = totalActiveMs
            self.questionCount = questionCount
        }
    }

    /// Share of questions where at least one hint was used.
    public struct HintRate: Equatable, Sendable {
        public var questionsWithHints: Int
        public var questionCount: Int
        /// Nil when there are no questions.
        public var rate: Double? {
            questionCount == 0 ? nil : Double(questionsWithHints) / Double(questionCount)
        }
        public init(questionsWithHints: Int, questionCount: Int) {
            self.questionsWithHints = questionsWithHints
            self.questionCount = questionCount
        }
    }

    /// The most common recorded error type and its occurrence count.
    public struct TopError: Equatable, Sendable {
        public var errorType: String
        public var count: Int
        public init(errorType: String, count: Int) {
            self.errorType = errorType
            self.count = count
        }
    }

    /// One session's effort snapshot on the trend line.
    public struct EffortPoint: Equatable, Sendable {
        public var sessionId: String
        public var startedAt: Date
        public var score: Int
        public var threshold: Int
        public init(sessionId: String, startedAt: Date, score: Int, threshold: Int) {
            self.sessionId = sessionId
            self.startedAt = startedAt
            self.score = score
            self.threshold = threshold
        }
    }

    /// Trend direction: last point vs first point.
    public enum EffortDirection: String, Equatable, Sendable {
        case rising
        case steady
        case dipping
    }

    /// Chronological effort snapshots plus the overall direction.
    public struct EffortTrend: Equatable, Sendable {
        /// Oldest first; sessions without a snapshot are absent.
        public var points: [EffortPoint]
        /// Nil with fewer than two points.
        public var direction: EffortDirection?
        public init(points: [EffortPoint], direction: EffortDirection?) {
            self.points = points
            self.direction = direction
        }
    }

    /// Trade counts from `.offerTrade` decisions.
    public struct TradeFrequency: Equatable, Sendable {
        public var totalTrades: Int
        public var movementTrades: Int
        public var choreTrades: Int
        /// Offer-trade decisions with unrecognized wording: counted, never dropped.
        public var otherTrades: Int
        public var sessionCount: Int
        public var sessionsWithTrades: Int
        /// Nil when there are no sessions.
        public var tradesPerSession: Double? {
            sessionCount == 0 ? nil : Double(totalTrades) / Double(sessionCount)
        }
        public init(totalTrades: Int, movementTrades: Int, choreTrades: Int,
                    otherTrades: Int, sessionCount: Int, sessionsWithTrades: Int) {
            self.totalTrades = totalTrades
            self.movementTrades = movementTrades
            self.choreTrades = choreTrades
            self.otherTrades = otherTrades
            self.sessionCount = sessionCount
            self.sessionsWithTrades = sessionsWithTrades
        }
    }

    /// All six aggregates over one synced-log set.
    public struct Report: Equatable, Sendable {
        public var sessionCount: Int
        /// One entry per skill with questions this or last week, A–Z.
        public var skillAccuracies: [SkillWeekAccuracy]
        public var activeTime: ActiveTime
        public var hintRate: HintRate
        /// Nil when no error type is recorded on any incorrect question.
        public var topError: TopError?
        public var effortTrend: EffortTrend
        public var tradeFrequency: TradeFrequency
        /// True when no sessions synced: the view must show the explicit
        /// empty state, never zeroes.
        public var isEmpty: Bool { sessionCount == 0 }
        public init(sessionCount: Int, skillAccuracies: [SkillWeekAccuracy],
                    activeTime: ActiveTime, hintRate: HintRate,
                    topError: TopError?, effortTrend: EffortTrend,
                    tradeFrequency: TradeFrequency) {
            self.sessionCount = sessionCount
            self.skillAccuracies = skillAccuracies
            self.activeTime = activeTime
            self.hintRate = hintRate
            self.topError = topError
            self.effortTrend = effortTrend
            self.tradeFrequency = tradeFrequency
        }
    }

    // MARK: - Trade classification

    /// Outcome prefixes produced by `TradeOfferDecider.justification` for
    /// movement vs chore offers. Classification keys on these exact
    /// prefixes; `DashboardTests` guards them against producer drift by
    /// classifying live `justification` output.
    public static let movementTradePrefix = "Offered movement trade:"
    public static let choreTradePrefix = "Offered chore trade:"

    public enum TradeKind: Equatable, Sendable {
        case movement
        case chore
        case other
    }

    /// Classifies one `.offerTrade` decision outcome. Deterministic and
    /// total: unrecognized wording is `.other`, never dropped or thrown.
    public static func tradeKind(of decision: Decision) -> TradeKind {
        if decision.outcome.hasPrefix(movementTradePrefix) { return .movement }
        if decision.outcome.hasPrefix(choreTradePrefix) { return .chore }
        return .other
    }

    // MARK: - View copy (fix round 1: tested seams for DashboardView)

    /// Empty-state copy for the accuracy card. Aggregate 1 covers this
    /// week and last week only, while sibling cards span all synced
    /// sessions — so the message names the window instead of claiming
    /// nothing synced.
    public static let noRecentQuestionsMessage = "No questions synced for this week or last week."

    /// Empty-state copy for the mistake card when questions exist but no
    /// incorrect answer carries a recorded error type. An untyped
    /// incorrect answer is still a known incorrect answer, so the message
    /// names the missing classification, not the mistakes.
    public static let noMistakeTypesMessage = "No mistake types recorded yet."

    /// Combined accessibility description for one effort-bar row: the
    /// row's date plus its engagement relative to the preceding session
    /// (points are oldest-first, so the predecessor is the previous
    /// index). Raw scores never appear — the direction words carry the
    /// same relative shape the bars show visually.
    public static func effortBarAccessibilityLabel(dateText: String, score: Int,
                                                 previousScore: Int?) -> String {
        guard let previousScore else { return "\(dateText), first trying snapshot" }
        if score > previousScore { return "\(dateText), trying higher than previous session" }
        if score < previousScore { return "\(dateText), trying lower than previous session" }
        return "\(dateText), trying unchanged from previous session"
    }

    // MARK: - Week bucketing

    private enum WeekBucket { case thisWeek, lastWeek }

    /// Which aggregate week `date` falls in relative to `now`: the calendar
    /// week containing `now`, the immediately preceding week, or nil for
    /// older (or weekless) dates. Pure in (`date`, `now`, `calendar`).
    private static func weekBucket(of date: Date, now: Date, calendar: Calendar) -> WeekBucket? {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
        if thisWeek.contains(date) { return .thisWeek }
        let weekBefore = thisWeek.start.addingTimeInterval(-1)
        guard let lastWeek = calendar.dateInterval(of: .weekOfYear, for: weekBefore),
              lastWeek.contains(date) else { return nil }
        return .lastWeek
    }

    /// Whether the this-week/last-week comparison window moved between two
    /// `now` values (fix round 3: the Progress view's foreground/time-change
    /// reload seam). Same calendar week on both sides reads false; a week
    /// boundary crossed in either direction reads true. A week that cannot
    /// be computed reads true — reload rather than risk stale "This week"
    /// totals. Pure in (`previousNow`, `now`, `calendar`).
    public static func comparisonWindowChanged(since previousNow: Date, now: Date,
                                               calendar: Calendar = .current) -> Bool {
        guard let previousWeek = calendar.dateInterval(of: .weekOfYear, for: previousNow),
              let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return true
        }
        return previousWeek.start != currentWeek.start
    }

    // MARK: - Report

    /// Computes all six aggregates over `logs` (typically
    /// `SessionLogStore.allLogs`). Sessions bucket into weeks by
    /// `startedAt`; every question in a session shares its bucket.
    public static func compute(logs: [SessionLog], now: Date,
                               calendar: Calendar = .current) -> Report {
        // Aggregate 1: per-skill correct/total for this week vs last.
        var thisCorrect: [String: Int] = [:]
        var thisTotal: [String: Int] = [:]
        var lastCorrect: [String: Int] = [:]
        var lastTotal: [String: Int] = [:]
        for log in logs {
            guard let bucket = weekBucket(of: log.startedAt, now: now, calendar: calendar) else { continue }
            for q in log.questions {
                switch bucket {
                case .thisWeek:
                    thisTotal[q.skill, default: 0] += 1
                    if q.correct { thisCorrect[q.skill, default: 0] += 1 }
                case .lastWeek:
                    lastTotal[q.skill, default: 0] += 1
                    if q.correct { lastCorrect[q.skill, default: 0] += 1 }
                }
            }
        }
        let skills = Set(thisTotal.keys).union(lastTotal.keys).sorted()
        let accuracies = skills.map { skill in
            SkillWeekAccuracy(skill: skill,
                              thisWeekCorrect: thisCorrect[skill, default: 0],
                              thisWeekTotal: thisTotal[skill, default: 0],
                              lastWeekCorrect: lastCorrect[skill, default: 0],
                              lastWeekTotal: lastTotal[skill, default: 0])
        }

        // Aggregates 2–4: over every question in every log.
        var totalMs = 0
        var questionCount = 0
        var withHints = 0
        var errorCounts: [String: Int] = [:]
        for log in logs {
            for q in log.questions {
                questionCount += 1
                totalMs += q.activeMs
                if q.hintsUsed > 0 { withHints += 1 }
                if !q.correct, let type = q.errorType {
                    errorCounts[type, default: 0] += 1
                }
            }
        }
        let topError: TopError? = errorCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first
            .map { TopError(errorType: $0.key, count: $0.value) }

        // Aggregate 5: effort snapshots oldest-first; direction last vs first.
        let points = logs
            .compactMap { log -> EffortPoint? in
                guard let effort = log.effort else { return nil }
                return EffortPoint(sessionId: log.sessionId, startedAt: log.startedAt,
                                   score: effort.score, threshold: effort.threshold)
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.sessionId < $1.sessionId
            }
        let direction: EffortDirection? = {
            guard points.count >= 2,
                  let first = points.first, let last = points.last else { return nil }
            if last.score > first.score { return .rising }
            if last.score == first.score { return .steady }
            return .dipping
        }()

        // Aggregate 6: offer-trade decisions, split by kind.
        var movement = 0
        var chore = 0
        var other = 0
        var sessionsWithTrades = 0
        for log in logs {
            var hadTrade = false
            for d in log.decisions where d.type == .offerTrade {
                hadTrade = true
                switch tradeKind(of: d) {
                case .movement: movement += 1
                case .chore: chore += 1
                case .other: other += 1
                }
            }
            if hadTrade { sessionsWithTrades += 1 }
        }

        return Report(
            sessionCount: logs.count,
            skillAccuracies: accuracies,
            activeTime: ActiveTime(totalActiveMs: totalMs, questionCount: questionCount),
            hintRate: HintRate(questionsWithHints: withHints, questionCount: questionCount),
            topError: topError,
            effortTrend: EffortTrend(points: points, direction: direction),
            tradeFrequency: TradeFrequency(
                totalTrades: movement + chore + other,
                movementTrades: movement, choreTrades: chore, otherTrades: other,
                sessionCount: logs.count, sessionsWithTrades: sessionsWithTrades))
    }
}
