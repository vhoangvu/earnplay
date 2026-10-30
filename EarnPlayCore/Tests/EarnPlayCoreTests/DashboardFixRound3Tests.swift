import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 3 (issue #21 review, head 0e9062c).
///
/// Item 1 (MEDIUM): Progress cached its report across a backgrounded week
/// boundary — `.onAppear` never refires for an already-visible view and no
/// sync lands on pure time passing, so "This week" kept showing the
/// previous week's totals. The view now reloads on foreground
/// (`scenePhase` → active) and on significant time change whenever the
/// this-week/last-week comparison window moved. The window check lives on
/// `Dashboard` in EarnPlayCore (EarnPlayAdmin has no test target) — the
/// same pattern as the tested trade prefixes. The seam tests below failed
/// before the fix (missing API) and pass after; the condition test stages
/// the stale totals the review describes.
final class DashboardFixRound3Tests: XCTestCase {

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int,
                      _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Condition: identical logs, different windows across a boundary

    /// Stages the review's repro: one session mid-week, judged first
    /// while its week is "this week", then after the week turns over.
    /// The same logs compute different buckets — so a cached report is
    /// stale until reloaded.
    func testSameLogsShiftWeekBucketsAcrossWeekBoundary() {
        let c = utcCalendar()
        // Guard the weekday assumptions the bucket math rests on.
        XCTAssertEqual(c.component(.weekday, from: date(c, 2026, 10, 26, 12)), 2) // Monday
        XCTAssertEqual(c.component(.weekday, from: date(c, 2026, 11, 2, 12)), 2) // next Monday
        let log = SessionLog(
            sessionId: "s-tue", startedAt: date(c, 2026, 10, 27, 10),
            endedAt: date(c, 2026, 10, 27, 10, 20), decisions: [], policyVersion: 1,
            questionRecords: [SessionQuestionRecord(questionId: "q1", skill: "division",
                                              correct: true, activeMs: 30_000, hintsUsed: 0)])
        // Thu Oct 29: the session's week (Oct 26–Nov 1) is this week.
        let before = Dashboard.compute(logs: [log], now: date(c, 2026, 10, 29, 12), calendar: c)
        XCTAssertEqual(before.skillAccuracies.count, 1)
        XCTAssertEqual(before.skillAccuracies[0].thisWeekTotal, 1)
        XCTAssertEqual(before.skillAccuracies[0].lastWeekTotal, 0)
        // Mon Nov 2: the session's week is now last week.
        let after = Dashboard.compute(logs: [log], now: date(c, 2026, 11, 2, 0, 1), calendar: c)
        XCTAssertEqual(after.skillAccuracies.count, 1)
        XCTAssertEqual(after.skillAccuracies[0].thisWeekTotal, 0)
        XCTAssertNil(after.skillAccuracies[0].thisWeekAccuracy)
        XCTAssertEqual(after.skillAccuracies[0].lastWeekTotal, 1)
        // The cached report disagrees with the current week: stale.
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Seam: comparison-window change detection

    /// Crossing into a new week moves the window: adjacent weeks, the
    /// exact Sunday→Monday boundary, and multi-week jumps all read true.
    /// Failed pre-fix: no such API.
    func testComparisonWindowChangedAcrossWeekBoundary() {
        let c = utcCalendar()
        XCTAssertTrue(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 10, 29, 12), now: date(c, 2026, 11, 2, 0, 1), calendar: c))
        XCTAssertTrue(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 11, 1, 23, 59), now: date(c, 2026, 11, 2, 0, 1), calendar: c))
        XCTAssertTrue(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 10, 29, 12), now: date(c, 2026, 11, 9, 12), calendar: c))
    }

    /// Same calendar week (Monday 00:01 through Sunday 23:59 here),
    /// identical instants, and same-day revisits leave the window alone.
    /// Failed pre-fix: no such API.
    func testComparisonWindowUnchangedWithinSameWeek() {
        let c = utcCalendar()
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 10, 26, 0, 1), now: date(c, 2026, 11, 1, 23, 59), calendar: c))
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 10, 29, 12), now: date(c, 2026, 10, 29, 12), calendar: c))
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: date(c, 2026, 10, 29, 12), now: date(c, 2026, 10, 29, 18), calendar: c))
    }
}
