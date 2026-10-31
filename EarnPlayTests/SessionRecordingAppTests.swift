import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 — child app pipeline: scripted `DemoTutorEngine` practice
/// session with recording fakes. Hand math matches the Core script (see
/// `PracticeSessionRecordingTests`): the engine's verified questions,
/// solver verdicts, and hint ladder drive the recorder, and the queue
/// carries the exact hand values.
final class SessionRecordingAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(to date: Date) { now = date }
    }

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-app-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Script: Q1 hint + correct, Q2 incorrect + probe reply + correct
    /// (revision), Q3 hint + incorrect, manual finish with the incorrect
    /// final. Timeline t0..t0+60 mirrors the Core hand math:
    /// - demo-q1: 10000ms, 1 hint, correct.
    /// - demo-q2: 15000ms, 0 hints, correct (final).
    /// - demo-q3: 30000ms, 1 hint, incorrect, nil error (no source exists).
    /// Effort: 4 attempts, 2 hints, 1 follow-up, 1 revision, 1
    /// explanation, 55s active (0 minutes) = 16 vs threshold 10.
    func testScriptedPracticeSessionEnqueuesHandMathLog() {
        let t0: TimeInterval = 1_000_000
        let clock = FakeClock(date(t0))
        let logger = DecisionLogger(directory: tempDir())
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-session-1" },
            logger: logger, queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 7 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)

        clock.advance(to: date(t0))
        let opening = engine.startSession()
        XCTAssertEqual(engine.recordingSessionId, "test-session-1")
        XCTAssertEqual(opening.progress?.totalQuestions, 3)

        // Q1 (7x8=56): hint, then correct.
        clock.advance(to: date(t0 + 5))
        let q1Hint = engine.requestHint()
        XCTAssertEqual(q1Hint.turns.count, 1)
        clock.advance(to: date(t0 + 10))
        let q1Done = engine.submitAnswer("56")
        XCTAssertNotEqual(q1Done.composer, .sessionComplete)

        // Q2 (6x9=54): incorrect, probe reply, then correct (revision).
        clock.advance(to: date(t0 + 12))
        let q2Wrong = engine.submitAnswer("0")
        XCTAssertTrue(q2Wrong.turns.contains {
            if case .tutor(let m) = $0 { return m.kind == .probe }
            return false
        })
        clock.advance(to: date(t0 + 15))
        let q2Reply = engine.submitAnswer("I multiplied six by nine")
        XCTAssertFalse(q2Reply.submittedTurnIsRevision)
        clock.advance(to: date(t0 + 25))
        let q2Done = engine.submitAnswer("54")
        XCTAssertTrue(q2Done.submittedTurnIsRevision)
        XCTAssertNotEqual(q2Done.composer, .sessionComplete)

        // Q3 (11x9=99): hint, then incorrect (left incorrect).
        clock.advance(to: date(t0 + 30))
        _ = engine.requestHint()
        clock.advance(to: date(t0 + 35))
        let q3Wrong = engine.submitAnswer("0")
        XCTAssertNotEqual(q3Wrong.composer, .sessionComplete)

        clock.advance(to: date(t0 + 60))
        let log = engine.finishRecordingSession()
        XCTAssertNotNil(log)
        // Second finish is a no-op (no duplicate enqueue).
        XCTAssertNil(engine.finishRecordingSession())

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        guard let queued = pending.first else { return }
        XCTAssertEqual(queued, log)
        XCTAssertEqual(queued.sessionId, "test-session-1")
        XCTAssertEqual(queued.startedAt, date(t0))
        XCTAssertEqual(queued.endedAt, date(t0 + 60))
        XCTAssertEqual(queued.policyVersion, 7)
        XCTAssertTrue(queued.decisions.isEmpty)
        XCTAssertTrue(logger.decisions(for: "test-session-1").isEmpty)

        XCTAssertEqual(queued.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 1),
            SessionQuestionRecord(questionId: "demo-q2", skill: "multiplicationFacts",
                                  correct: true, activeMs: 15000, hintsUsed: 0),
            SessionQuestionRecord(questionId: "demo-q3", skill: "multiplicationFacts",
                                  correct: false, activeMs: 30000, hintsUsed: 1),
        ])
        XCTAssertNil(queued.questionRecords[2].errorType)
        XCTAssertEqual(queued.effort, SessionEffortRecord(score: 16, threshold: 10))
    }

    /// A completed session (all correct) enqueues automatically on the
    /// session-complete update, with no manual finish call.
    func testCompletedSessionEnqueuesAutomatically() {
        let t0: TimeInterval = 2_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-complete-1" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 8) },
            policyVersion: { 3 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)

        clock.advance(to: date(t0))
        _ = engine.startSession()
        clock.advance(to: date(t0 + 10))
        let done = engine.submitAnswer("56")
        XCTAssertEqual(done.composer, .sessionComplete)

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sessionId, "test-complete-1")
        XCTAssertEqual(pending.first?.questionRecords.count, 1)
        XCTAssertEqual(pending.first?.questionRecords.first?.correct, true)
        XCTAssertNotNil(pending.first?.effort)
    }

    /// Started but unanswered: finish yields empty records and nil effort,
    /// still enqueued as a decisions-only-shaped log (never invented).
    func testUnansweredSessionFinishesEmpty() {
        let t0: TimeInterval = 3_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-empty-1" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)
        _ = engine.startSession()
        clock.advance(to: date(t0 + 30))
        let log = engine.finishRecordingSession()
        XCTAssertNotNil(log)
        XCTAssertTrue(log?.questionRecords.isEmpty ?? false)
        XCTAssertNil(log?.effort)
        XCTAssertEqual(queue.pending().count, 1)
    }

    /// Recording disabled (default): no session id, finish is nil, and no
    /// filesystem writes exist to assert (backwards-compatible demo path).
    func testRecordingDisabledByDefault() {
        let engine = DemoTutorEngine()
        _ = engine.startSession()
        XCTAssertNil(engine.recordingSessionId)
        _ = engine.submitAnswer("56")
        XCTAssertNil(engine.finishRecordingSession())
    }
}
