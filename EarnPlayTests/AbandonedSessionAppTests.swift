import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 fix 2 — abandoning a practice session must finalize it: view
/// disappearance enqueues the partial session (last solver verdict per
/// practised question, nil effort when nothing was graded), and starting a
/// new session finalizes a prior unfinished one first (Fix 4 retryable
/// semantics: the retained log is reused, never recomputed).
@MainActor
final class AbandonedSessionAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class FailFlag {
        var fail = false
    }

    private struct FailWrite: Error {}

    private final class IdSequence {
        private var ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        func next() -> String {
            guard ids.count > 1 else { return ids[0] }
            return ids.removeFirst()
        }
    }

    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-abandon-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func deps(sessionIds: IdSequence, clock: FakeClock, queue: SessionLogQueue,
                      threshold: Int = 10, policy: Int = 7) -> PracticeRecordingDependencies {
        PracticeRecordingDependencies(
            makeSessionId: { sessionIds.next() },
            logger: DecisionLogger(directory: tempDir("log")),
            queue: queue,
            makeScorer: { EffortScorer(threshold: threshold) },
            policyVersion: { policy },
            now: { clock.now })
    }

    private func viewModel(engine: DemoTutorEngine) -> ChatConversationViewModel {
        ChatConversationViewModel(engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))
    }

    /// Abandoning mid-session via view disappearance enqueues one partial
    /// log: Q1 correct, Q2 incorrect (last solver verdict preserved even
    /// though Q2 never finished), effort present. A second disappearance
    /// enqueues nothing more.
    func testViewDisappearanceEnqueuesPartialSession() {
        let t0: TimeInterval = 6_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let engine = DemoTutorEngine(recording: deps(
            sessionIds: IdSequence(["test-abandon-1"]), clock: clock, queue: queue))
        let vm = viewModel(engine: engine)

        clock.now = date(t0)
        vm.startIfNeeded()
        // Q1 (7x8=56): correct at t0+10.
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        // Q2 (6x9=54): incorrect at t0+12 (probe pending, never answered).
        clock.now = date(t0 + 12)
        vm.draft = "0"
        vm.submitDraft()
        XCTAssertFalse(vm.isSessionComplete)

        // Abandon at t0+20: disappearance finalizes the session.
        clock.now = date(t0 + 20)
        vm.handleDisappeared()

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        guard let queued = pending.first else { return }
        XCTAssertEqual(queued.sessionId, "test-abandon-1")
        XCTAssertEqual(queued.startedAt, date(t0))
        XCTAssertEqual(queued.endedAt, date(t0 + 20))
        XCTAssertEqual(queued.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 0),
            SessionQuestionRecord(questionId: "demo-q2", skill: "multiplicationFacts",
                                  correct: false, activeMs: 10000, hintsUsed: 0),
        ])
        XCTAssertNil(queued.questionRecords[1].errorType)
        XCTAssertNotNil(queued.effort)
        XCTAssertEqual(queued.effort?.threshold, 10)

        // Second disappearance is a no-op (no duplicate enqueue).
        vm.handleDisappeared()
        XCTAssertEqual(queue.pending().count, 1)
    }

    /// Abandoning with no graded answers still finalizes, but with no
    /// records and nil effort (never invented).
    func testViewDisappearanceWithNoAnswersProducesEmptyRecordsNilEffort() {
        let t0: TimeInterval = 7_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let engine = DemoTutorEngine(recording: deps(
            sessionIds: IdSequence(["test-abandon-empty-1"]), clock: clock, queue: queue))
        let vm = viewModel(engine: engine)

        clock.now = date(t0)
        vm.startIfNeeded()
        clock.now = date(t0 + 30)
        vm.handleDisappeared()

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.questionRecords, [])
        XCTAssertNil(pending.first?.effort)
        XCTAssertEqual(pending.first?.endedAt, date(t0 + 30))
    }

    /// Restart path: when the completion auto-finish failed to persist (Fix
    /// 4 retryable state), starting the new session finalizes the prior one
    /// first — the retained log (original endedAt/records) is enqueued —
    /// and the new session starts under a fresh session id.
    func testRestartFinalizesPriorUnfinishedSession() {
        let t0: TimeInterval = 8_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        flag.fail = true
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["test-restart-1", "test-restart-2"])
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps(
            sessionIds: ids, clock: clock, queue: queue))

        clock.now = date(t0)
        _ = engine.startSession()
        XCTAssertEqual(engine.recordingSessionId, "test-restart-1")
        // The only question answered correctly: auto-finish fails to
        // persist, so the session stays unfinished (retryable).
        clock.now = date(t0 + 10)
        let done = engine.submitAnswer("56")
        XCTAssertEqual(done.composer, .sessionComplete)
        XCTAssertTrue(queue.pending().isEmpty)

        // Restart with a healed writer: prior session finalized first.
        flag.fail = false
        clock.now = date(t0 + 50)
        _ = engine.startSession()

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sessionId, "test-restart-1")
        XCTAssertEqual(pending.first?.endedAt, date(t0 + 10))
        XCTAssertEqual(pending.first?.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 0),
        ])
        // The new session records under a fresh id.
        XCTAssertEqual(engine.recordingSessionId, "test-restart-2")
    }

    /// Restart after a normally finished session enqueues nothing new: the
    /// prior log is already durable and the fresh session starts empty.
    func testRestartAfterFinishedSessionEnqueuesNothingNew() {
        let t0: TimeInterval = 9_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let ids = IdSequence(["test-restart-ok-1", "test-restart-ok-2"])
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps(
            sessionIds: ids, clock: clock, queue: queue))

        clock.now = date(t0)
        _ = engine.startSession()
        clock.now = date(t0 + 10)
        let done = engine.submitAnswer("56")
        XCTAssertEqual(done.composer, .sessionComplete)
        XCTAssertEqual(queue.pending().count, 1)

        clock.now = date(t0 + 50)
        _ = engine.startSession()

        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "test-restart-ok-1")
        XCTAssertEqual(engine.recordingSessionId, "test-restart-ok-2")
    }
}
