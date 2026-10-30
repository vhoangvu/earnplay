import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 6 (issue #21 review, head e078785).
///
/// UNPUBLISHED week-boundary finding: the fix-round-4 foreground reload seam
/// tracked time-zone changes but NOT week-definition changes. `reload`
/// recomputed via `Dashboard.compute` with the current calendar and stored
/// only `lastReloadNow`/`lastReloadTimeZone`, while `reloadNeeded`
/// re-evaluated the OLD instant under the NEW calendar on both sides. After
/// a region change (Sunday-start weeks to Monday-start), both instants can
/// fall in the same new-calendar week while the cached buckets (computed
/// under the OLD week definition) belong to a different week, so the check
/// returned false and "This week" stayed stale until a manual Refresh. Same
/// class for calendar-identifier changes, and the significant-time-change
/// handler does not fire for locale changes, so a region change while open
/// also left stale totals.
///
/// The view now tracks the week definition (firstWeekday + calendar
/// identifier) at last reload for the foreground path and reloads
/// unconditionally on locale change. The reload decision lives on
/// `Dashboard` in EarnPlayCore (EarnPlayAdmin has no test target) — the
/// same pattern as the fix-round-3/4 seams. The seam tests below failed
/// before the fix (missing API) and pass after; the condition test stages
/// the stale totals the review describes.
final class DashboardFixRound6Tests: XCTestCase {

    private func calendar(firstWeekday: Int, timeZoneID: String = "GMT",
                          identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var c = Calendar(identifier: identifier)
        c.timeZone = TimeZone(identifier: timeZoneID)!
        c.firstWeekday = firstWeekday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int,
                      _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Condition: identical logs, different buckets across a week-definition change

    /// Stages the review's repro: last reload Mon 00:30 GMT under
    /// Sunday-start weeks, then a region change to Monday-start where both
    /// instants fall in the same new-calendar week. The same logs compute
    /// different buckets — so a cached report is stale until reloaded.
    func testSameLogsShiftBucketsAcrossFirstWeekdayChangeWithSameNewCalendarWeek() {
        let sundayStart = calendar(firstWeekday: 1)
        let mondayStart = calendar(firstWeekday: 2)
        // Guard the weekday assumptions the bucket math rests on.
        XCTAssertEqual(sundayStart.component(.weekday, from: date(sundayStart, 2026, 10, 25, 12)), 1) // Sunday
        XCTAssertEqual(sundayStart.component(.weekday, from: date(sundayStart, 2026, 10, 26, 12)), 2) // Monday
        // Guard the time-zone assumption: GMT on both sides, zero offset.
        let previousNow = date(sundayStart, 2026, 10, 26, 0, 30) // Mon 00:30 GMT
        let now = date(mondayStart, 2026, 10, 26, 10, 0) // Mon 10:00 GMT
        XCTAssertEqual(sundayStart.timeZone.secondsFromGMT(for: previousNow), 0)
        XCTAssertEqual(mondayStart.timeZone.secondsFromGMT(for: now), 0)

        let log = SessionLog(
            sessionId: "s-sun", startedAt: date(sundayStart, 2026, 10, 25, 10),
            endedAt: date(sundayStart, 2026, 10, 25, 10, 20), decisions: [], policyVersion: 1,
            questionRecords: [SessionQuestionRecord(questionId: "q1", skill: "addition",
                                              correct: true, activeMs: 30_000, hintsUsed: 0)])
        // Mon Oct 26 00:30 GMT under Sunday-start: the session's week
        // (Oct 25-31) is this week.
        let before = Dashboard.compute(logs: [log], now: previousNow, calendar: sundayStart)
        XCTAssertEqual(before.skillAccuracies.count, 1)
        XCTAssertEqual(before.skillAccuracies[0].thisWeekTotal, 1)
        XCTAssertEqual(before.skillAccuracies[0].lastWeekTotal, 0)
        // Mon Oct 26 10:00 GMT under Monday-start: the session's week is
        // now last week.
        let after = Dashboard.compute(logs: [log], now: now, calendar: mondayStart)
        XCTAssertEqual(after.skillAccuracies.count, 1)
        XCTAssertEqual(after.skillAccuracies[0].thisWeekTotal, 0)
        XCTAssertNil(after.skillAccuracies[0].thisWeekAccuracy)
        XCTAssertEqual(after.skillAccuracies[0].lastWeekTotal, 1)
        // The cached report disagrees with the current week definition: stale.
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Blind spot: the old checks miss the week-definition move

    /// The pre-fix seam re-evaluates the OLD instant under the NEW calendar:
    /// both Monday instants share the Monday-start week and the time zone
    /// is unchanged, so the old week-only check AND the old timezone-aware
    /// seam both read false even though the cached buckets are stale.
    /// Documents the bug; passes before and after (old API unchanged).
    func testOldChecksMissFirstWeekdayMove() {
        let sundayStart = calendar(firstWeekday: 1)
        let mondayStart = calendar(firstWeekday: 2)
        let previousNow = date(sundayStart, 2026, 10, 26, 0, 30)
        let now = date(mondayStart, 2026, 10, 26, 10, 0)
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: previousNow, now: now, calendar: mondayStart))
        XCTAssertFalse(Dashboard.reloadNeeded(
            since: previousNow, previousTimeZone: sundayStart.timeZone,
            now: now, currentTimeZone: mondayStart.timeZone, calendar: mondayStart))
    }

    // MARK: - Seam: week-definition-aware reload decision

    /// A firstWeekday change reloads even when both instants fall in the
    /// same new-calendar week with an unchanged time zone. Failed pre-fix:
    /// no such API.
    func testReloadNeededDetectsFirstWeekdayChangeInSameWeek() {
        let sundayStart = calendar(firstWeekday: 1)
        let mondayStart = calendar(firstWeekday: 2)
        let previousNow = date(sundayStart, 2026, 10, 26, 0, 30)
        let now = date(mondayStart, 2026, 10, 26, 10, 0)
        XCTAssertTrue(Dashboard.reloadNeeded(
            since: previousNow, previousTimeZone: sundayStart.timeZone,
            now: now, currentTimeZone: mondayStart.timeZone,
            previousFirstWeekday: sundayStart.firstWeekday,
            currentFirstWeekday: mondayStart.firstWeekday,
            previousCalendarIdentifier: sundayStart.identifier,
            currentCalendarIdentifier: mondayStart.identifier,
            calendar: mondayStart))
    }

    /// A calendar-identifier change reloads even when the week, time zone,
    /// and firstWeekday are all unchanged — week computation depends on the
    /// calendar system, so any identifier change is a conservative reload,
    /// same as a time-zone identifier change. Failed pre-fix: no such API.
    func testReloadNeededDetectsCalendarIdentifierChange() {
        let gregorian = calendar(firstWeekday: 2, identifier: .gregorian)
        let buddhist = calendar(firstWeekday: 2, identifier: .buddhist)
        let previousNow = date(gregorian, 2026, 10, 26, 0, 30)
        let now = date(gregorian, 2026, 10, 26, 10, 0)
        XCTAssertTrue(Dashboard.reloadNeeded(
            since: previousNow, previousTimeZone: gregorian.timeZone,
            now: now, currentTimeZone: buddhist.timeZone,
            previousFirstWeekday: gregorian.firstWeekday,
            currentFirstWeekday: buddhist.firstWeekday,
            previousCalendarIdentifier: gregorian.identifier,
            currentCalendarIdentifier: buddhist.identifier,
            calendar: buddhist))
    }

    /// Same calendar week plus same time zone plus same week definition
    /// leaves the report alone — the no-reload optimization is preserved
    /// for the nothing-moved case. Failed pre-fix: no such API.
    func testReloadNeededPreservesNoChangeOptimizationWithWeekDefinition() {
        let mondayStart = calendar(firstWeekday: 2)
        XCTAssertFalse(Dashboard.reloadNeeded(
            since: date(mondayStart, 2026, 10, 26, 0, 30),
            previousTimeZone: mondayStart.timeZone,
            now: date(mondayStart, 2026, 10, 26, 10, 0),
            currentTimeZone: mondayStart.timeZone,
            previousFirstWeekday: mondayStart.firstWeekday,
            currentFirstWeekday: mondayStart.firstWeekday,
            previousCalendarIdentifier: mondayStart.identifier,
            currentCalendarIdentifier: mondayStart.identifier,
            calendar: mondayStart))
        XCTAssertFalse(Dashboard.reloadNeeded(
            since: date(mondayStart, 2026, 10, 29, 12),
            previousTimeZone: mondayStart.timeZone,
            now: date(mondayStart, 2026, 10, 29, 12),
            currentTimeZone: mondayStart.timeZone,
            previousFirstWeekday: mondayStart.firstWeekday,
            currentFirstWeekday: mondayStart.firstWeekday,
            previousCalendarIdentifier: mondayStart.identifier,
            currentCalendarIdentifier: mondayStart.identifier,
            calendar: mondayStart))
    }
}
