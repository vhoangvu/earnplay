import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 1 (issue #21 review, head 9d6840e).
///
/// Items 2-4 are user-visible copy/accessibility fixes in `DashboardView`
/// (EarnPlayAdmin target, which has no test target), so the fixed strings
/// live behind minimal seams on `Dashboard` in EarnPlayCore — the same
/// pattern as the tested trade prefixes. Each seam test below failed
/// before the fix (missing API) and passes after. The two condition
/// tests stage the misleading states from the review and lock the
/// underlying aggregate behavior they rest on.
final class DashboardFixRound1Tests: XCTestCase {

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - Item 2: accuracy empty state scoped to the comparison window

    /// Stages the review's repro: synced sessions older than last week.
    /// Aggregate 1 is empty for them by design, while aggregates 2-4
    /// still show their data — so the old "No questions synced yet."
    /// message was misleading there.
    func testOldSessionsEmptySkillAccuraciesButPopulateOtherCards() {
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12) // Thu; this week = Oct 26+, last = Oct 19-25
        let log = SessionLog(
            sessionId: "s-old", startedAt: date(c, 2026, 10, 12, 10),
            endedAt: date(c, 2026, 10, 12, 10), decisions: [], policyVersion: 1,
            questions: [SessionQuestionRecord(questionId: "q1", skill: "division",
                                              correct: true, activeMs: 30_000, hintsUsed: 0)])
        let report = Dashboard.compute(logs: [log], now: now, calendar: c)
        XCTAssertTrue(report.skillAccuracies.isEmpty)
        XCTAssertEqual(report.activeTime.questionCount, 1)
        XCTAssertNotNil(report.activeTime.averageSecondsPerQuestion)
        XCTAssertNotNil(report.hintRate.rate)
    }

    func testSkillAccuracyEmptyMessageIsScopedToWindow() {
        XCTAssertEqual(Dashboard.noRecentQuestionsMessage,
                       "No questions synced for this week or last week.")
    }

    // MARK: - Item 3: untyped mistakes vs no mistake types

    /// Stages the review's repro: an incorrect answer with no errorType.
    /// `topError` is nil (it tracks recorded types only) even though a
    /// known incorrect answer exists — so "No mistakes recorded yet."
    /// hid it.
    func testIncorrectAnswerWithoutErrorTypeLeavesTopErrorNil() {
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12)
        let log = SessionLog(
            sessionId: "s-1", startedAt: date(c, 2026, 10, 28, 10),
            endedAt: date(c, 2026, 10, 28, 10), decisions: [], policyVersion: 1,
            questions: [SessionQuestionRecord(questionId: "q1", skill: "division",
                                              correct: false, activeMs: 30_000, hintsUsed: 0,
                                              errorType: nil)])
        XCTAssertFalse(log.questions[0].correct)
        XCTAssertNil(log.questions[0].errorType)
        let report = Dashboard.compute(logs: [log], now: now, calendar: c)
        XCTAssertNil(report.topError)
        XCTAssertEqual(report.activeTime.questionCount, 1)
    }

    func testNoMistakeTypesMessage() {
        XCTAssertEqual(Dashboard.noMistakeTypesMessage,
                       "No mistake types recorded yet.")
    }

    // MARK: - Item 4: effort-bar accessibility labels

    func testEffortBarLabelFirstSnapshotHasNoPredecessor() {
        XCTAssertEqual(
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 9, previousScore: nil),
            "Monday, first trying snapshot")
    }

    func testEffortBarLabelRelativeDirection() {
        XCTAssertEqual(
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 12, previousScore: 9),
            "Monday, trying higher than previous session")
        XCTAssertEqual(
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 7, previousScore: 9),
            "Monday, trying lower than previous session")
        XCTAssertEqual(
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 9, previousScore: 9),
            "Monday, trying unchanged from previous session")
    }

    /// Raw scores stay hidden: with a digit-free date, the label carries
    /// no decimal digits at all (the view's real date text still carries
    /// the calendar day, which is identity, not a score).
    func testEffortBarLabelHidesNumericScores() {
        let labels = [
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 12, previousScore: nil),
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 12, previousScore: 6),
            Dashboard.effortBarAccessibilityLabel(dateText: "Monday", score: 6, previousScore: 12),
        ]
        for label in labels {
            XCTAssertTrue(label.rangeOfCharacter(from: .decimalDigits) == nil,
                          "label leaks a numeric score: \(label)")
        }
    }
}
