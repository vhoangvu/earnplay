import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 4 (issue #21 review, head 514ff5c).
///
/// MEDIUM: Progress cached its report across a time-zone change — `reload`
/// recomputed via `Dashboard.compute` with the default calendar and stored
/// only `lastReloadNow`, while `reloadIfWeekChanged` re-evaluated the OLD
/// instant under the NEW calendar on both sides. After a TZ change both
/// instants can fall in the same new-calendar week while the cached buckets
/// (computed under the OLD time zone) belong to a different week, so the
/// check returned false and "This week" stayed stale until a manual Refresh.
/// Same class for DST shifts near a boundary.
///
/// The view now reloads unconditionally on significant time change and tracks
/// the time zone at last reload for the foreground path. The reload decision
/// lives on `Dashboard` in EarnPlayCore (EarnPlayAdmin has no test target) —
/// the same pattern as the tested trade prefixes and the fix-round-3 window
/// seam. The seam tests below failed before the fix (missing API) and pass
/// after; the condition test stages the stale totals the review describes.
final class DashboardFixRound4Tests: XCTestCase {

    private func calendar(timeZoneID: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZoneID)!
        c.firstWeekday = 2 // Monday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int,
                      _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Condition: identical logs, different buckets across a TZ change

    /// Stages the review's repro: last reload Sunday 23:00 PT, then travel
    /// to ET where both instants fall in the same new-calendar week. The
    /// same logs compute different buckets — so a cached report is stale
    /// until reloaded.
    func testSameLogsShiftBucketsAcrossTimeZoneChangeWithSameNewCalendarWeek() {
        let pt = calendar(timeZoneID: "America/Los_Angeles")
        let et = calendar(timeZoneID: "America/New_York")
        // Guard the weekday assumptions the bucket math rests on.
        XCTAssertEqual(pt.component(.weekday, from: date(pt, 2026, 10, 19, 12)), 2) // Monday
        XCTAssertEqual(pt.component(.weekday, from: date(pt, 2026, 10, 25, 12)), 1) // Sunday
        XCTAssertEqual(et.component(.weekday, from: date(et, 2026, 10, 26, 12)), 2) // next Monday
        // Guard the DST assumptions: both dates in daylight time, 3h apart.
        let previousNow = date(pt, 2026, 10, 25, 23, 0) // Sun 23:00 PT
        let now = date(et, 2026, 10, 26, 10, 0) // Mon 10:00 ET
        XCTAssertEqual(pt.timeZone.secondsFromGMT(for: previousNow), -7 * 3600) // PDT
        XCTAssertEqual(et.timeZone.secondsFromGMT(for: now), -4 * 3600) // EDT

        let log = SessionLog(
            sessionId: "s-tue", startedAt: date(pt, 2026, 10, 20, 10),
            endedAt: date(pt, 2026, 10, 20, 10, 20), decisions: [], policyVersion: 1,
            questionRecords: [SessionQuestionRecord(questionId: "q1", skill: "division",
                                              correct: true, activeMs: 30_000, hintsUsed: 0)])
        // Sun Oct 25 23:00 PT: the session's week (Oct 19-25 PT) is this week.
        let before = Dashboard.compute(logs: [log], now: previousNow, calendar: pt)
        XCTAssertEqual(before.skillAccuracies.count, 1)
        XCTAssertEqual(before.skillAccuracies[0].thisWeekTotal, 1)
        XCTAssertEqual(before.skillAccuracies[0].lastWeekTotal, 0)
        // Mon Oct 26 10:00 ET: the session's week is now last week.
        let after = Dashboard.compute(logs: [log], now: now, calendar: et)
        XCTAssertEqual(after.skillAccuracies.count, 1)
        XCTAssertEqual(after.skillAccuracies[0].thisWeekTotal, 0)
        XCTAssertNil(after.skillAccuracies[0].thisWeekAccuracy)
        XCTAssertEqual(after.skillAccuracies[0].lastWeekTotal, 1)
        // The cached report disagrees with the current time zone: stale.
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Blind spot: the old week-only check misses the TZ move

    /// The pre-fix check re-evaluates the OLD instant under the NEW calendar:
    /// Sun 23:00 PT is Mon 02:00 ET, so both instants share the ET week and
    /// the old seam reads false even though the cached buckets are stale.
    /// Documents the bug; passes before and after (old API unchanged).
    func testOldWeekCheckMissesTimeZoneMove() {
        let pt = calendar(timeZoneID: "America/Los_Angeles")
        let et = calendar(timeZoneID: "America/New_York")
        let previousNow = date(pt, 2026, 10, 25, 23, 0)
        let now = date(et, 2026, 10, 26, 10, 0)
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: previousNow, now: now, calendar: et))
    }

    // MARK: - Seam: timezone-aware reload decision

    /// A time-zone change reloads even when both instants fall in the same
    /// new-calendar week. Failed pre-fix: no such API.
    func testReloadNeededDetectsTimeZoneChangeInSameWeek() {
        let pt = calendar(timeZoneID: "America/Los_Angeles")
        let et = calendar(timeZoneID: "America/New_York")
        let previousNow = date(pt, 2026, 10, 25, 23, 0)
        let now = date(et, 2026, 10, 26, 10, 0)
        XCTAssertTrue(Dashboard.reloadNeeded(
            since: previousNow, previousTimeZone: pt.timeZone,
            now: now, currentTimeZone: et.timeZone, calendar: et))
    }

    /// Same calendar week plus same time zone leaves the report alone —
    /// the week-boundary optimization is preserved for the no-change case.
    /// Failed pre-fix: no such API.
    func testReloadNeededPreservesNoChangeOptimization() {
        let et = calendar(timeZoneID: "America/New_York")
        XCTAssertFalse(Dashboard.reloadNeeded(
            since: date(et, 2026, 10, 26, 0, 1), previousTimeZone: et.timeZone,
            now: date(et, 2026, 10, 26, 10, 0), currentTimeZone: et.timeZone, calendar: et))
        XCTAssertFalse(Dashboard.reloadNeeded(
            since: date(et, 2026, 10, 29, 12), previousTimeZone: et.timeZone,
            now: date(et, 2026, 10, 29, 12), currentTimeZone: et.timeZone, calendar: et))
    }

    /// A week boundary crossed with an unchanged time zone still reloads.
    /// Failed pre-fix: no such API.
    func testReloadNeededStillDetectsWeekChangeWithSameTimeZone() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertTrue(Dashboard.reloadNeeded(
            since: date(c, 2026, 10, 29, 12), previousTimeZone: c.timeZone,
            now: date(c, 2026, 11, 2, 0, 1), currentTimeZone: c.timeZone, calendar: c))
    }

    /// A DST offset shift reloads even when the zone identifier is unchanged
    /// and both instants share the same week. Failed pre-fix: no such API.
    func testReloadNeededDetectsDSTOffsetChangeWithSameIdentifier() {
        let pt = calendar(timeZoneID: "America/Los_Angeles")
        // US DST 2026 ends Sun Nov 1 02:00 -> 01:00; both dates share the
        // Mon Oct 26 - Sun Nov 1 week but carry different offsets.
        let beforeFallBack = date(pt, 2026, 10, 31, 12, 0) // PDT (-7)
        let afterFallBack = date(pt, 2026, 11, 1, 12, 0) // PST (-8)
        XCTAssertEqual(pt.timeZone.secondsFromGMT(for: beforeFallBack), -7 * 3600)
        XCTAssertEqual(pt.timeZone.secondsFromGMT(for: afterFallBack), -8 * 3600)
        XCTAssertFalse(Dashboard.comparisonWindowChanged(
            since: beforeFallBack, now: afterFallBack, calendar: pt))
        XCTAssertTrue(Dashboard.reloadNeeded(
            since: beforeFallBack, previousTimeZone: pt.timeZone,
            now: afterFallBack, currentTimeZone: pt.timeZone, calendar: pt))
    }
}
