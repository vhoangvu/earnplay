import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 Fix 5 — composer activity (typing, number-pad taps, draft
/// edits) must extend recorded active time: each draft change is a timing
/// anchor on the current question, never an attempt or hint count.
@MainActor
final class ComposerActivityAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-fix5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Typing across a 60s gap must extend Q1 active time past the 20s
    /// single-gap cap: anchors at t0+15/+30/+45 plus the answer at t0+60
    /// give 15+15+15+15 = 60s = 60000ms (pre-fix: one 60s gap capped at
    /// 20000ms). Score hand math (Band B: minute=1, attempt=2): 1 minute
    /// + 1 genuine attempt = 3 — proving the anchors added no
    /// attempt/hint/follow-up/revision/explanation counts.
    func testComposerActivityExtendsActiveTimePastSingleGapCap() {
        let t0: TimeInterval = 5_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-fix5-1" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))

        clock.now = date(t0)
        vm.startIfNeeded()
        // Typing: three draft edits spread across the minute.
        clock.now = date(t0 + 15)
        vm.draft = "5"
        clock.now = date(t0 + 30)
        vm.draft = "5?"
        clock.now = date(t0 + 45)
        vm.draft = "56?"
        // Correct answer at t0+60 auto-finishes the single question.
        clock.now = date(t0 + 60)
        vm.draft = "56"
        vm.submitDraft()

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        guard let queued = pending.first else { return }
        XCTAssertEqual(queued.questionRecords.count, 1)
        XCTAssertEqual(queued.questionRecords.first?.activeMs, 60000)
        XCTAssertEqual(queued.effort, SessionEffortRecord(score: 3, threshold: 10))
    }

    /// Draft edits reach the engine: one call per draft mutation (the
    /// protocol default no-op keeps the six older scripted fakes
    /// compiling; this counting fake proves the view-model wiring).
    func testDraftChangesForwardToEngine() {
        final class CountingEngine: ChatTutorEngine {
            var activityCalls = 0
            func startSession() -> ChatEngineUpdate { ChatEngineUpdate() }
            func submitAnswer(_ plainText: String) -> ChatEngineUpdate { ChatEngineUpdate() }
            func requestHint() -> ChatEngineUpdate { ChatEngineUpdate() }
            func recordComposerActivity() { activityCalls += 1 }
        }
        let engine = CountingEngine()
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))
        vm.startIfNeeded()
        XCTAssertEqual(engine.activityCalls, 0)
        vm.draft = "5"
        vm.draft = "56"
        XCTAssertEqual(engine.activityCalls, 2)
        vm.draft = ""
        XCTAssertEqual(engine.activityCalls, 3)
    }

    /// Draft edits outside a recording session (before start, after the
    /// session finished) are ignored: no crash, no record, no extra log.
    func testComposerActivityOutsideSessionIsIgnored() {
        let t0: TimeInterval = 5_100_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-fix5-2" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))

        // Before the session starts: no recorder exists yet.
        vm.draft = "early typing"
        clock.now = date(t0)
        vm.startIfNeeded()
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        // After the session auto-finished: recording already ended.
        clock.now = date(t0 + 20)
        vm.draft = "late typing"

        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        guard let queued = pending.first else { return }
        XCTAssertEqual(queued.questionRecords.first?.activeMs, 10000)
    }
}
