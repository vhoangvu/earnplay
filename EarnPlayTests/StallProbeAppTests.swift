import XCTest
import EarnPlayCore

/// App-target coverage for T1.5: the stalling-probe path the child app's
/// session UI drives, exercised on the simulator through the same
/// `StallProbeSession` the preview view owns. Mirrors the package suite's
/// acceptance fixtures: exactly one probe on a stalling stream, none on a
/// varied stream, and a substantive reply recorded as T1.4 effort.
final class StallProbeAppTests: XCTestCase {
    func testStallingStreamFiresOneProbeAndReplyRecordsEffort() {
        let start = Date(timeIntervalSince1970: 200_000)
        let session = StallProbeSession(startedAt: start)
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(5)))
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(15)))
        let probe = session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(25))
        XCTAssertNotNil(probe)
        XCTAssertEqual(session.probesFired.count, 1)
        // At most once per episode: further identical answers stay silent.
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(35)))
        XCTAssertEqual(session.probesFired.count, 1)

        XCTAssertEqual(session.submitProbeReply(
            "I tried adding the tops", at: start.addingTimeInterval(50)),
            .substantive(probeSequenceNumber: 1))
        let signals = session.signals(at: start.addingTimeInterval(51))
        XCTAssertEqual(signals.followUpInteractions, 1)
        XCTAssertEqual(signals.explanations, 1)
    }

    func testVariedStreamFiresNoProbe() {
        let start = Date(timeIntervalSince1970: 210_000)
        let session = StallProbeSession(startedAt: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordRevision(at: start.addingTimeInterval(12))
        session.recordAttempt(answer: "14", isCorrect: false,
                              at: start.addingTimeInterval(30))
        session.recordAttempt(answer: "13", isCorrect: false,
                              at: start.addingTimeInterval(60))
        XCTAssertTrue(session.probesFired.isEmpty)
        XCTAssertNil(session.pendingProbe)
    }
}
