import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 fix 4 — a failed `SessionLogQueue.enqueue` must not lose the
/// finalized log: the session stays retryable and a later finish retries
/// THAT log (original records/effort/endedAt, no recompute).
final class FinishRetryAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class FailFlag {
        var fail = true
    }

    private struct FailWrite: Error {}

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-retry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Failing enqueue leaves the session retryable; the retried log is
    /// identical to the first computation even when the retry passes a
    /// later date (the retained log is reused, never recomputed).
    func testFailedEnqueueRetriesIdenticalLog() {
        let t0: TimeInterval = 4_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir(), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-retry-1" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 7 },
            now: { clock.now })
        // Default 3-question session: Q1 correct advances to Q2 without
        // auto-finishing, so the explicit finishes below drive finalize.
        let engine = DemoTutorEngine(recording: deps)

        clock.now = date(t0)
        _ = engine.startSession()
        // Q1 (7x8=56): correct at t0+10.
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56")

        // First finish at t0+20 fails to persist: nil, nothing queued,
        // session still retryable.
        let first = engine.finishRecordingSession(at: date(t0 + 20))
        XCTAssertNil(first)
        XCTAssertTrue(queue.pending().isEmpty)

        // Retry with a LATER explicit date after the writer heals: the
        // retained first computation is enqueued, not a recompute.
        flag.fail = false
        let retried = engine.finishRecordingSession(at: date(t0 + 99))
        XCTAssertNotNil(retried)
        XCTAssertEqual(retried?.sessionId, "test-retry-1")
        XCTAssertEqual(retried?.endedAt, date(t0 + 20))
        XCTAssertEqual(retried?.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 0),
        ])
        XCTAssertEqual(retried?.effort?.threshold, 10)
        XCTAssertNotNil(retried?.effort)

        // Durably enqueued exactly once, equal to the retried log.
        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first, retried)

        // A further finish is a no-op (no duplicate enqueue).
        XCTAssertNil(engine.finishRecordingSession(at: date(t0 + 100)))
        XCTAssertEqual(queue.pending().count, 1)
    }

    /// Independent oracle: the retried log equals a control engine's log
    /// with the identical script finished once at the original date.
    func testRetriedLogMatchesControlComputation() {
        let t0: TimeInterval = 5_000_000
        let flag = FailFlag()

        func scriptedEngine(queue: SessionLogQueue, clock: FakeClock) -> DemoTutorEngine {
            let deps = PracticeRecordingDependencies(
                makeSessionId: { "test-retry-2" },
                logger: DecisionLogger(directory: tempDir()), queue: queue,
                makeScorer: { EffortScorer(threshold: 10) },
                policyVersion: { 7 },
                now: { clock.now })
            let engine = DemoTutorEngine(recording: deps)
            clock.now = date(t0)
            _ = engine.startSession()
            clock.now = date(t0 + 10)
            _ = engine.submitAnswer("56")
            return engine
        }

        // Subject: fail once at t0+20, retry at t0+99.
        let subjectClock = FakeClock(date(t0))
        let subjectQueue = SessionLogQueue(directory: tempDir(), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let subject = scriptedEngine(queue: subjectQueue, clock: subjectClock)
        XCTAssertNil(subject.finishRecordingSession(at: date(t0 + 20)))
        flag.fail = false
        let retried = subject.finishRecordingSession(at: date(t0 + 99))

        // Control: identical script, one successful finish at t0+20.
        let controlClock = FakeClock(date(t0))
        let control = scriptedEngine(
            queue: SessionLogQueue(directory: tempDir()), clock: controlClock)
        let controlLog = control.finishRecordingSession(at: date(t0 + 20))

        XCTAssertNotNil(retried)
        XCTAssertEqual(retried, controlLog)
    }
}
