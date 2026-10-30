import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 — dashboard aggregates over a fixture log set of known sessions.
///
/// Fixture (Gregorian, UTC, weeks start Monday; `now` = Thu 2026-10-29
/// 12:00, so this week = Oct 26–Nov 1, last week = Oct 19–25):
///
/// - s-old-1 (Mon Oct 12, older than last week): q8 division correct,
///   50000ms, 0 hints; effort 6 vs 8; no decisions.
/// - s-last-1 (Tue Oct 20): q6 mult incorrect, 60000ms, 1 hint,
///   "computation"; q7 mult incorrect, 60000ms, 0 hints, "computation";
///   effort 7 vs 9; 1 chore offer-trade + 1 session-judgment.
/// - s-this-1 (Tue Oct 27): q1 mult correct, 45000ms, 0 hints;
///   q2 mult incorrect, 90000ms, 2 hints, "computation";
///   q3 fraction-comparison correct, 60000ms, 1 hint;
///   effort 12 vs 10; 1 movement offer-trade + 1 session-judgment.
/// - s-this-2 (Wed Oct 28): q4 mult correct, 30000ms, 0 hints;
///   q5 fraction-comparison incorrect, 120000ms, 1 hint,
///   "comparison-flip"; effort 9 vs 11; 1 grant-unlock.
///
/// Hand-calculated expectations:
/// 1. Accuracy: mult this 2/3, last 0/2; fraction-comparison this 1/2,
///    last none; division omitted (only in the older week).
/// 2. Active time: 515000ms over 8 questions = 64.375s per question.
/// 3. Hint rate: 4 of 8 questions with hints = 0.5.
/// 4. Top error: "computation" x3 (vs "comparison-flip" x1).
/// 5. Effort trend: 6, 7, 12, 9 oldest-first; direction rising (9 > 6).
/// 6. Trades: 2 total (1 movement, 1 chore), 4 sessions, 2 with trades.
final class DashboardTests: XCTestCase {

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func decision(session: String, type: DecisionType, outcome: String,
                          at: Date, id: String = UUID().uuidString) -> Decision {
        Decision(decisionId: id, sessionId: session, type: type, outcome: outcome,
                 evidenceSummary: "ev", reasoning: "why",
                 alternativeConsidered: "alt", confidence: 0.9, timestamp: at)
    }

    private func question(_ id: String, skill: String, correct: Bool,
                          activeMs: Int, hints: Int, error: String? = nil) -> SessionQuestionRecord {
        SessionQuestionRecord(questionId: id, skill: skill, correct: correct,
                              activeMs: activeMs, hintsUsed: hints, errorType: error)
    }

    /// The known-session fixture plus the fixed `now` it is judged against.
    private func fixture() -> (logs: [SessionLog], now: Date, calendar: Calendar) {
        let c = utcCalendar()
        // Guard the weekday assumptions the hand math rests on.
        XCTAssertEqual(c.component(.weekday, from: date(c, 2026, 10, 26, 12)), 2) // Monday
        XCTAssertEqual(c.component(.weekday, from: date(c, 2026, 10, 29, 12)), 5) // Thursday
        let now = date(c, 2026, 10, 29, 12)

        let old = SessionLog(
            sessionId: "s-old-1", startedAt: date(c, 2026, 10, 12, 10),
            endedAt: date(c, 2026, 10, 12, 10, 20), decisions: [], policyVersion: 3,
            questionRecords: [question("q8", skill: "division", correct: true, activeMs: 50000, hints: 0)],
            effort: SessionEffortRecord(score: 6, threshold: 8))
        let last = SessionLog(
            sessionId: "s-last-1", startedAt: date(c, 2026, 10, 20, 10),
            endedAt: date(c, 2026, 10, 20, 10, 25),
            decisions: [
                decision(session: "s-last-1", type: .offerTrade,
                         outcome: "Offered chore trade: \"Tidy desk\" for 20 minutes.",
                         at: date(c, 2026, 10, 20, 10, 15)),
                decision(session: "s-last-1", type: .sessionJudgment,
                         outcome: "No trade offered: variation draw picked none.",
                         at: date(c, 2026, 10, 20, 10, 5)),
            ],
            policyVersion: 3,
            questionRecords: [
                question("q6", skill: "multiplication-facts", correct: false,
                         activeMs: 60000, hints: 1, error: "computation"),
                question("q7", skill: "multiplication-facts", correct: false,
                         activeMs: 60000, hints: 0, error: "computation"),
            ],
            effort: SessionEffortRecord(score: 7, threshold: 9))
        let this1 = SessionLog(
            sessionId: "s-this-1", startedAt: date(c, 2026, 10, 27, 10),
            endedAt: date(c, 2026, 10, 27, 10, 30),
            decisions: [
                decision(session: "s-this-1", type: .offerTrade,
                         outcome: "Offered movement trade: jumping-jacks, 20 reps for 15 minutes.",
                         at: date(c, 2026, 10, 27, 10, 20)),
                decision(session: "s-this-1", type: .sessionJudgment,
                         outcome: "No trade offered: patience not exhausted (trying).",
                         at: date(c, 2026, 10, 27, 10, 5)),
            ],
            policyVersion: 4,
            questionRecords: [
                question("q1", skill: "multiplication-facts", correct: true,
                         activeMs: 45000, hints: 0),
                question("q2", skill: "multiplication-facts", correct: false,
                         activeMs: 90000, hints: 2, error: "computation"),
                question("q3", skill: "fraction-comparison", correct: true,
                         activeMs: 60000, hints: 1),
            ],
            effort: SessionEffortRecord(score: 12, threshold: 10))
        let this2 = SessionLog(
            sessionId: "s-this-2", startedAt: date(c, 2026, 10, 28, 10),
            endedAt: date(c, 2026, 10, 28, 10, 22),
            decisions: [
                decision(session: "s-this-2", type: .grantUnlock,
                         outcome: "Granted unlock of app for 30 minutes (score 9 vs threshold 11, floor met).",
                         at: date(c, 2026, 10, 28, 10, 20)),
            ],
            policyVersion: 4,
            questionRecords: [
                question("q4", skill: "multiplication-facts", correct: true,
                         activeMs: 30000, hints: 0),
                question("q5", skill: "fraction-comparison", correct: false,
                         activeMs: 120000, hints: 1, error: "comparison-flip"),
            ],
            effort: SessionEffortRecord(score: 9, threshold: 11))
        // Deliberately shuffled: the report must not depend on input order.
        return (logs: [this2, old, this1, last], now: now, calendar: c)
    }

    // MARK: - Aggregate 1: accuracy per skill, this week vs last

    func testAccuracyPerSkillWeekOverWeek() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        XCTAssertEqual(report.skillAccuracies.map(\.skill),
                       ["fraction-comparison", "multiplication-facts"])

        let frac = report.skillAccuracies[0]
        XCTAssertEqual(frac.thisWeekCorrect, 1)
        XCTAssertEqual(frac.thisWeekTotal, 2)
        XCTAssertEqual(frac.thisWeekAccuracy ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(frac.lastWeekTotal, 0)
        XCTAssertNil(frac.lastWeekAccuracy)

        let mult = report.skillAccuracies[1]
        XCTAssertEqual(mult.thisWeekCorrect, 2)
        XCTAssertEqual(mult.thisWeekTotal, 3)
        XCTAssertEqual(mult.thisWeekAccuracy ?? -1, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(mult.lastWeekCorrect, 0)
        XCTAssertEqual(mult.lastWeekTotal, 2)
        XCTAssertEqual(mult.lastWeekAccuracy ?? -1, 0.0, accuracy: 1e-9)
    }

    // MARK: - Aggregate 2: active time per question

    func testActiveTimePerQuestion() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        XCTAssertEqual(report.activeTime.totalActiveMs, 515_000)
        XCTAssertEqual(report.activeTime.questionCount, 8)
        XCTAssertEqual(report.activeTime.averageSecondsPerQuestion ?? -1, 64.375, accuracy: 1e-9)
    }

    // MARK: - Aggregate 3: hint rate

    func testHintRate() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        XCTAssertEqual(report.hintRate.questionsWithHints, 4)
        XCTAssertEqual(report.hintRate.questionCount, 8)
        XCTAssertEqual(report.hintRate.rate, 0.5)
    }

    // MARK: - Aggregate 4: most common error type

    func testTopErrorType() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        XCTAssertEqual(report.topError, Dashboard.TopError(errorType: "computation", count: 3))
    }

    func testTopErrorTieBreaksAlphabetically() {
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12)
        let log = SessionLog(
            sessionId: "s-tie", startedAt: date(c, 2026, 10, 28, 10),
            endedAt: date(c, 2026, 10, 28, 10, 20), decisions: [], policyVersion: 1,
            questionRecords: [
                question("a", skill: "division", correct: false, activeMs: 1000, hints: 0, error: "zebra"),
                question("b", skill: "division", correct: false, activeMs: 1000, hints: 0, error: "apple"),
                question("c", skill: "division", correct: false, activeMs: 1000, hints: 0, error: "zebra"),
                question("d", skill: "division", correct: false, activeMs: 1000, hints: 0, error: "apple"),
            ])
        let report = Dashboard.compute(logs: [log], now: now, calendar: c)
        XCTAssertEqual(report.topError, Dashboard.TopError(errorType: "apple", count: 2))
    }

    // MARK: - Aggregate 5: effort-score trend

    func testEffortTrend() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        let trend = report.effortTrend
        XCTAssertEqual(trend.points.map(\.sessionId),
                       ["s-old-1", "s-last-1", "s-this-1", "s-this-2"])
        XCTAssertEqual(trend.points.map(\.score), [6, 7, 12, 9])
        XCTAssertEqual(trend.points.map(\.threshold), [8, 9, 10, 11])
        XCTAssertEqual(trend.direction, .rising)
    }

    func testEffortTrendSkipsUnscoredSessionsAndNeedsTwoPoints() {
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12)
        let scored = SessionLog(
            sessionId: "s-scored", startedAt: date(c, 2026, 10, 28, 10),
            endedAt: date(c, 2026, 10, 28, 10, 20), decisions: [], policyVersion: 1,
            effort: SessionEffortRecord(score: 9, threshold: 10))
        let unscored = SessionLog(
            sessionId: "s-unscored", startedAt: date(c, 2026, 10, 27, 10),
            endedAt: date(c, 2026, 10, 27, 10, 20), decisions: [], policyVersion: 1)
        let report = Dashboard.compute(logs: [scored, unscored], now: now, calendar: c)
        XCTAssertEqual(report.effortTrend.points.map(\.sessionId), ["s-scored"])
        XCTAssertNil(report.effortTrend.direction)
    }

    // MARK: - Aggregate 6: trade frequency

    func testTradeFrequency() {
        let f = fixture()
        let report = Dashboard.compute(logs: f.logs, now: f.now, calendar: f.calendar)
        let trades = report.tradeFrequency
        XCTAssertEqual(trades.totalTrades, 2)
        XCTAssertEqual(trades.movementTrades, 1)
        XCTAssertEqual(trades.choreTrades, 1)
        XCTAssertEqual(trades.otherTrades, 0)
        XCTAssertEqual(trades.sessionCount, 4)
        XCTAssertEqual(trades.sessionsWithTrades, 2)
        XCTAssertEqual(trades.tradesPerSession, 0.5)
    }

    func testTradeClassificationMatchesProducerWording() {
        // Guards the Dashboard prefixes against T3.3 wording drift: live
        // `TradeOfferDecider.justification` output must classify correctly.
        let c = utcCalendar()
        let context = TradeOfferContext(
            signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2, hintInteractions: 1),
            stalling: .stalling, now: date(c, 2026, 10, 28, 10), calendar: c)
        let policy = Policy.defaultPolicy
        let movement = TradeOfferDecision(outcome: .movement(
            MovementTradeOffer(activity: .jumpingJacks, targetReps: 20,
                               unlockMinutes: 15, taperApplied: false)))
        let chore = TradeOfferDecision(outcome: .chore(
            ChorePoolEntry(chore: "Tidy desk", unlockMinutes: 20,
                           expiry: date(c, 2026, 11, 30, 0),
                           weeklyCap: 2, verificationMode: .parentConfirm)))
        let movementJustification = TradeOfferDecider.justification(
            for: movement, context: context, policy: policy)
        let choreJustification = TradeOfferDecider.justification(
            for: chore, context: context, policy: policy)
        XCTAssertEqual(movementJustification.type, .offerTrade)
        XCTAssertEqual(choreJustification.type, .offerTrade)
        XCTAssertTrue(movementJustification.outcome.hasPrefix(Dashboard.movementTradePrefix))
        XCTAssertTrue(choreJustification.outcome.hasPrefix(Dashboard.choreTradePrefix))

        let at = date(c, 2026, 10, 28, 10)
        let movementDecision = decision(session: "s", type: movementJustification.type,
                                        outcome: movementJustification.outcome, at: at)
        let choreDecision = decision(session: "s", type: choreJustification.type,
                                     outcome: choreJustification.outcome, at: at)
        XCTAssertEqual(Dashboard.tradeKind(of: movementDecision), .movement)
        XCTAssertEqual(Dashboard.tradeKind(of: choreDecision), .chore)

        let unknown = decision(session: "s", type: .offerTrade,
                               outcome: "Offered something unexpected.", at: at)
        XCTAssertEqual(Dashboard.tradeKind(of: unknown), .other)
    }

    // MARK: - Empty and partial states

    func testEmptyLogsReportExplicitEmpty() {
        let c = utcCalendar()
        let report = Dashboard.compute(logs: [], now: date(c, 2026, 10, 29, 12), calendar: c)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.sessionCount, 0)
        XCTAssertTrue(report.skillAccuracies.isEmpty)
        XCTAssertEqual(report.activeTime.questionCount, 0)
        XCTAssertNil(report.activeTime.averageSecondsPerQuestion)
        XCTAssertNil(report.hintRate.rate)
        XCTAssertNil(report.topError)
        XCTAssertTrue(report.effortTrend.points.isEmpty)
        XCTAssertNil(report.effortTrend.direction)
        XCTAssertEqual(report.tradeFrequency.totalTrades, 0)
        XCTAssertNil(report.tradeFrequency.tradesPerSession)
    }

    func testDecisionsOnlySessionsShowTradesButNoQuestionData() {
        // The current child shape: decisions synced, no practice detail yet.
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12)
        let at = date(c, 2026, 10, 28, 10)
        let log = SessionLog(
            sessionId: "s-decisions", startedAt: at,
            endedAt: date(c, 2026, 10, 28, 10, 20),
            decisions: [decision(session: "s-decisions", type: .sessionJudgment,
                                 outcome: "Demo session completed", at: at)],
            policyVersion: 1)
        let report = Dashboard.compute(logs: [log], now: now, calendar: c)
        XCTAssertFalse(report.isEmpty)
        XCTAssertTrue(report.skillAccuracies.isEmpty)
        XCTAssertNil(report.activeTime.averageSecondsPerQuestion)
        XCTAssertNil(report.hintRate.rate)
        XCTAssertNil(report.topError)
        XCTAssertTrue(report.effortTrend.points.isEmpty)
        XCTAssertEqual(report.tradeFrequency.totalTrades, 0)
        XCTAssertEqual(report.tradeFrequency.tradesPerSession, 0.0)
    }

    // MARK: - Sync compatibility

    func testSessionLogDecodesPreT42JSON() throws {
        // Logs persisted/synced before T4.2 carry no detail keys; they must
        // still decode (as decisions-only) and round-trip through the codec.
        // deferredToDate intervals (seconds since the 2001 reference date).
        let oldJSON = """
        {"decisions":[{"alternativeConsidered":"alt","confidence":0.9,\
        "decisionId":"d1","evidenceSummary":"ev","outcome":"done",\
        "reasoning":"why","sessionId":"s-1",\
        "timestamp":721692800.0,"type":"session-judgment"}],\
        "endedAt":721693400.0,"policyVersion":3,"sessionId":"s-1",\
        "startedAt":721692800.0}
        """
        let decoded = try SessionLogCodec.decode(Data(oldJSON.utf8))
        XCTAssertEqual(decoded.sessionId, "s-1")
        XCTAssertEqual(decoded.decisions.count, 1)
        XCTAssertEqual(decoded.endedAt.timeIntervalSince(decoded.startedAt), 600)
        XCTAssertTrue(decoded.questionRecords.isEmpty)
        XCTAssertNil(decoded.effort)

        let f = fixture()
        let roundTripped = try SessionLogCodec.decodeList(
            SessionLogCodec.encode(f.logs))
        XCTAssertEqual(roundTripped, f.logs)
    }
}
