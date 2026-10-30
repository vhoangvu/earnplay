import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 5 (issue #21 review, head 3e0ce51).
///
/// UNPUBLISHED FINDING: Progress cached its effort-bar date formatter —
/// `DashboardView.shortDayFormatter` was a static `DateFormatter` created
/// once per process with no explicit time zone, so it kept formatting
/// under the zone it was created in after a time-zone change (an existing
/// formatter's zone does not track system changes). Fix round 4 made the
/// REPORT recompute on zone change, but the bar date STRINGS still
/// rendered under the stale zone: a session near midnight showed the wrong
/// day in both the visible bar text and the VoiceOver label (both fed by
/// the same `dateText`) until the process restarted.
///
/// The formatting seam lives on `Dashboard` in EarnPlayCore (EarnPlayAdmin
/// has no test target) — the same pattern as the trade prefixes and the
/// fix-round-3/4 reload seams. The seam tests below failed before the fix
/// (missing API) and pass after.
final class DashboardFixRound5Tests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")

    /// A fixed instant on different days under two zones: Sunday Oct 25
    /// 2026 23:00 PT == Monday Oct 26 2026 02:00 ET.
    private func nearMidnightInstant() -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23))!
    }

    /// Guards the DST assumptions the day-split assertions rest on: both
    /// zones still in daylight time on Oct 25-26 2026 (US DST ends Nov 1),
    /// 3h apart.
    func testNearMidnightInstantFallsOnDifferentDays() {
        let instant = nearMidnightInstant()
        let pt = TimeZone(identifier: "America/Los_Angeles")!
        let et = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(pt.secondsFromGMT(for: instant), -7 * 3600) // PDT
        XCTAssertEqual(et.secondsFromGMT(for: instant), -4 * 3600) // EDT
        var c = Calendar(identifier: .gregorian)
        c.timeZone = pt
        XCTAssertEqual(c.component(.day, from: instant), 25)
        c.timeZone = et
        XCTAssertEqual(c.component(.day, from: instant), 26)
    }

    /// The rendered day follows the Pacific zone. Failed pre-fix: no such API.
    func testEffortBarDateTextFollowsPacificZone() {
        XCTAssertEqual(
            Dashboard.effortBarDateText(
                for: nearMidnightInstant(),
                timeZone: TimeZone(identifier: "America/Los_Angeles")!,
                locale: posix),
            "Oct 25")
    }

    /// The same instant renders the next day under the Eastern zone.
    /// Failed pre-fix: no such API.
    func testEffortBarDateTextFollowsEasternZone() {
        XCTAssertEqual(
            Dashboard.effortBarDateText(
                for: nearMidnightInstant(),
                timeZone: TimeZone(identifier: "America/New_York")!,
                locale: posix),
            "Oct 26")
    }

    /// The default zone is the live system zone evaluated at call time, not
    /// a captured one: the defaulted call matches an explicit `.current`
    /// call on any machine. Failed pre-fix: no such API.
    func testEffortBarDateTextDefaultMatchesCurrentTimeZone() {
        XCTAssertEqual(
            Dashboard.effortBarDateText(for: nearMidnightInstant(), locale: posix),
            Dashboard.effortBarDateText(
                for: nearMidnightInstant(), timeZone: .current, locale: posix))
    }
}
