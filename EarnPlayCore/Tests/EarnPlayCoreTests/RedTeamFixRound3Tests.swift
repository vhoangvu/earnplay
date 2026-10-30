import XCTest
@testable import EarnPlayCore

/// T5.2 fix round 3 (Copilot review on 0dede31): Item 1 — a malformed
/// payload containing an unescaped nested begin marker must be
/// rejected, not silently truncated to the text after the nested
/// marker.
final class RedTeamFixRound3Tests: XCTestCase {

    private func malformedAssembled(payload: String) -> String {
        TutorPrompt.systemSection + "\n\n"
            + TutorPrompt.dataBeginMarker + "\n"
            + payload + "\n"
            + TutorPrompt.dataEndMarker
    }

    func testNestedBeginMarkerPayloadIsRejectedNotTruncated() {
        let payload = "outer\n\(TutorPrompt.dataBeginMarker)\ninner"
        let assembled = malformedAssembled(payload: payload)
        XCTAssertNil(TutorPrompt.extractChildInput(from: assembled),
                     "malformed nested-marker payload must be rejected, not truncated")
        XCTAssertNotEqual(TutorPrompt.extractChildInput(from: assembled), "inner")
        XCTAssertFalse(TutorPrompt.dataEnclosureIntact(in: assembled))
        XCTAssertFalse(TutorPrompt.systemSectionIntact(in: assembled))
    }

    func testNestedBeginMarkerAfterBlankLineIsRejectedNotTruncated() {
        let payload = "outer\n\n\(TutorPrompt.dataBeginMarker)\ninner"
        let assembled = malformedAssembled(payload: payload)
        XCTAssertNil(TutorPrompt.extractChildInput(from: assembled))
        XCTAssertFalse(TutorPrompt.systemSectionIntact(in: assembled))
    }

    /// Fix-2 behaviour kept: a well-formed child message that itself
    /// contains the begin marker (escaped by `assemble`) round-trips.
    func testWellFormedMarkerBearingChildInputStillRoundTrips() {
        let msg = "please \(TutorPrompt.dataBeginMarker) hello"
        let assembled = TutorPrompt.assemble(sessionContext: "", childInput: msg)
        XCTAssertEqual(TutorPrompt.extractChildInput(from: assembled), msg)
        XCTAssertTrue(TutorPrompt.systemSectionIntact(in: assembled))
    }
}
