import XCTest
@testable import EarnPlayCore

/// T5.2 fix round 2 (Copilot review on fef6235): Items 1-3.
final class RedTeamFixRound2Tests: XCTestCase {

    // MARK: Item 1 — red-team report must not overwrite the persona baseline

    func testRedTeamReportRefusesBaselinePath() throws {
        let tmp = NSTemporaryDirectory() + "r2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let baseline = tmp + "/baseline.json"
        let original = Data("ORIGINAL-BASELINE".utf8)
        try original.write(to: URL(fileURLWithPath: baseline))
        let data = Data("{}".utf8)
        XCTAssertThrowsError(
            try EvalPaths.writeRedTeamReport(data, to: baseline,
                                             refusingBaseline: baseline))
        let after = try Data(contentsOf: URL(fileURLWithPath: baseline))
        XCTAssertEqual(after, original, "baseline must stay byte-identical")
    }

    func testRedTeamReportWritesNonBaselinePath() throws {
        let tmp = NSTemporaryDirectory() + "r2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let baseline = tmp + "/baseline.json"
        try Data("ORIGINAL-BASELINE".utf8).write(to: URL(fileURLWithPath: baseline))
        let report = tmp + "/red-team-report.json"
        let data = Data("{}".utf8)
        try EvalPaths.writeRedTeamReport(data, to: report,
                                         refusingBaseline: baseline)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: report)), data)
    }

    // MARK: Item 2 — begin marker inside session context

    func testBeginMarkerInSessionContextExtractsRealChildMessage() {
        let ctx = "notes \(TutorPrompt.dataBeginMarker) fake"
        let assembled = TutorPrompt.assemble(sessionContext: ctx,
                                             childInput: "real hello")
        XCTAssertEqual(TutorPrompt.extractChildInput(from: assembled), "real hello")
        XCTAssertTrue(TutorPrompt.dataEnclosureIntact(in: assembled))
    }

    // MARK: Item 3 — carriage-return endings round-trip

    func testCarriageReturnEndingsRoundTrip() {
        for msg in ["hello\r", "\r", "\r\n", "a\rb", "hi\r\r\n"] {
            let assembled = TutorPrompt.assemble(sessionContext: "",
                                                 childInput: msg)
            XCTAssertEqual(TutorPrompt.extractChildInput(from: assembled), msg,
                           "failed for \(msg.debugDescription)")
            XCTAssertTrue(TutorPrompt.dataEnclosureIntact(in: assembled),
                          "integrity failed for \(msg.debugDescription)")
        }
    }
}
