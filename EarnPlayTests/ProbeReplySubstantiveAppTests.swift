import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 Fix 1 — non-substantive probe replies must not score.
///
/// `DemoTutorEngine`'s probe-reply branch must gate on
/// `StallingDetector.isSubstantiveReply`: a substantive explanation records
/// follow-up + explanation effort, while "ok"/"???"-style replies record
/// only a timing interaction. Awaiting-probe clearing is unchanged.
final class ProbeReplySubstantiveAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(to date: Date) { now = date }
    }

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-fix1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Runs one single-question session (incorrect -> probe reply ->
    /// correct, auto-enqueued on completion) and returns the logged effort
    /// score. Hand math (Band B weights: attempt=2, followUp=1,
    /// revision=1, explanation=2; 15s active so 0 minutes):
    /// - 2 genuine attempts = 4, 1 revision = 1 on both paths.
    /// - Substantive reply adds follow-up 1 + explanation 2 = 3 (total 8).
    /// - Non-substantive reply adds nothing (total 5).
    private func effortScore(probeReply: String, file: StaticString = #filePath,
                             line: UInt = #line) -> Int? {
        let t0: TimeInterval = 4_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-fix1-\(UUID().uuidString)" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)

        clock.advance(to: date(t0))
        _ = engine.startSession()
        clock.advance(to: date(t0 + 5))
        let wrong = engine.submitAnswer("0")
        XCTAssertTrue(wrong.turns.contains {
            if case .tutor(let m) = $0 { return m.kind == .probe }
            return false
        }, "incorrect first attempt must raise a probe", file: file, line: line)
        clock.advance(to: date(t0 + 10))
        let reply = engine.submitAnswer(probeReply)
        XCTAssertFalse(reply.submittedTurnIsRevision,
                       "probe reply must not be labelled a revision", file: file, line: line)
        clock.advance(to: date(t0 + 15))
        let done = engine.submitAnswer("56")
        XCTAssertEqual(done.composer, .sessionComplete, file: file, line: line)

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1, file: file, line: line)
        return pending.first?.effort?.score
    }

    func testNonSubstantiveProbeReplyScoresNothing() {
        XCTAssertFalse(StallingDetector().isSubstantiveReply("ok"))
        XCTAssertEqual(effortScore(probeReply: "ok"), 5)
    }

    func testPunctuationOnlyProbeReplyScoresNothing() {
        XCTAssertFalse(StallingDetector().isSubstantiveReply("???"))
        XCTAssertEqual(effortScore(probeReply: "???"), 5)
    }

    func testSubstantiveProbeReplyStillScores() {
        XCTAssertTrue(StallingDetector().isSubstantiveReply("I multiplied six by nine"))
        XCTAssertEqual(effortScore(probeReply: "I multiplied six by nine"), 8)
    }
}
