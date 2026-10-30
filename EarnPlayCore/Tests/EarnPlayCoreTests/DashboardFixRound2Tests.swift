import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.2 fix round 2 (issue #21 review, head b30ba76).
///
/// Item 1 REFUTED (no code change): old-only sessions with questions leave
/// skillAccuracies empty (scoped message, already fixed) while aggregates
/// 2-4 show data -- lines 143/168/183 never render under that premise.
/// Item 2 VERIFY-ONLY confirmed fixed, no rework.
/// Items 3-4 below failed before the fix and pass after.
final class DashboardFixRound2Tests: XCTestCase {

    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardFixRound2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

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

    private func sessionLog(_ id: String, at: Date) -> SessionLog {
        SessionLog(sessionId: id, startedAt: at, endedAt: at.addingTimeInterval(600),
                   decisions: [], policyVersion: 1)
    }

    // MARK: - Item 3: session-store change notification (view auto-refresh seam)

    /// A completed sync (storeResult .stored) must post so the Progress view
    /// can reload without a manual Refresh. Failed pre-fix: no such API.
    func testSessionLogStorePostsDidChangeOnStored() {
        let store = SessionLogStore(directory: dir("store"))
        let exp = expectation(forNotification: SessionLogStore.didChangeNotification,
                              object: store, handler: nil)
        let log = sessionLog("s-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(store.storeResult(log), .stored)
        wait(for: [exp], timeout: 1.0)
    }

    /// Duplicates change nothing, so they must stay silent (no stale-refresh
    /// churn, no ack-loop side effects).
    func testSessionLogStoreSilentOnDuplicate() {
        let store = SessionLogStore(directory: dir("store"))
        let log = sessionLog("s-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(store.storeResult(log), .stored)
        let exp = expectation(forNotification: SessionLogStore.didChangeNotification,
                              object: store, handler: nil)
        exp.isInverted = true
        XCTAssertEqual(store.storeResult(log), .duplicate)
        wait(for: [exp], timeout: 0.5)
    }

    // MARK: - Item 4: decode-path invariant normalization

    private func decodeQuestion(_ json: String) throws -> SessionQuestionRecord {
        let d = JSONDecoder()
        return try d.decode(SessionQuestionRecord.self, from: Data(json.utf8))
    }

    /// Decoded records must satisfy the same invariants as constructed ones:
    /// trimmed skill, clamped counts, errorType cleared when correct.
    func testDecodedQuestionRecordNormalizesInvariants() throws {
        let q = try decodeQuestion("""
        {"questionId":"q1","skill":"  division  ","correct":true,\
        "activeMs":-5000,"hintsUsed":-2,"errorType":"computation"}
        """)
        XCTAssertEqual(q.skill, "division")
        XCTAssertEqual(q.activeMs, 0)
        XCTAssertEqual(q.hintsUsed, 0)
        XCTAssertNil(q.errorType)
    }

    /// Incorrect answers: padded error types trim, blank collapses to nil.
    func testDecodedQuestionRecordTrimsErrorType() throws {
        let padded = try decodeQuestion("""
        {"questionId":"q2","skill":"mult","correct":false,\
        "activeMs":1000,"hintsUsed":1,"errorType":" computation "}
        """)
        XCTAssertEqual(padded.errorType, "computation")
        let blank = try decodeQuestion("""
        {"questionId":"q3","skill":"mult","correct":false,\
        "activeMs":1000,"hintsUsed":0,"errorType":"   "}
        """)
        XCTAssertNil(blank.errorType)
    }

    /// Unnormalized decode values must not reach the dashboard: the violating
    /// record below would split the skill bucket, drag active totals
    /// negative, and (if counted) pollute topError.
    func testDecodedViolationsDoNotReachDashboard() throws {
        let c = utcCalendar()
        let now = date(c, 2026, 10, 29, 12)
        let at = date(c, 2026, 10, 28, 10)
        let json = """
        {"sessionId":"s-1","startedAt":\(at.timeIntervalSinceReferenceDate),\
        "endedAt":\(at.addingTimeInterval(600).timeIntervalSinceReferenceDate),\
        "decisions":[],"policyVersion":1,"questionRecords":[\
        {"questionId":"q1","skill":"  division  ","correct":true,\
        "activeMs":-5000,"hintsUsed":-2,"errorType":"computation"}]}
        """
        let log = try SessionLogCodec.decode(Data(json.utf8))
        XCTAssertEqual(log.questionRecords.count, 1)
        XCTAssertEqual(log.questionRecords[0].skill, "division")
        XCTAssertEqual(log.questionRecords[0].activeMs, 0)
        XCTAssertNil(log.questionRecords[0].errorType)
        let report = Dashboard.compute(logs: [log], now: now, calendar: c)
        XCTAssertEqual(report.skillAccuracies.map(\.skill), ["division"])
        XCTAssertEqual(report.activeTime.totalActiveMs, 0)
        XCTAssertEqual(report.activeTime.questionCount, 1)
        XCTAssertNil(report.topError)
    }
}
