import SwiftUI
import XCTest
import EarnPlayCore
@testable import EarnPlay

// MARK: - Round 4 Item 1a: background finalizes, foreground resumes fresh

/// The app's only scenePhase handler retries ALREADY-finalized logs; nothing
/// forwards the background transition to the active chat session. Answering
/// questions and then backgrounding left the partial session only in memory,
/// so an iOS termination lost it even with healthy storage. The view model
/// now maps scene phases to its existing hooks (background -> endSession via
/// `handleDisappeared`, foreground -> `resumeSession` via `startIfNeeded`):
/// background finalizes and queues, a second background is a no-op (the
/// ended-guard: no second log), a later disappear does not double-log, and
/// foreground resumes a fresh recorder for continued practice.
@MainActor
final class PipelineRound4Item1aTests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
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
            .appendingPathComponent("round4-item1a-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testBackgroundFinalizesAndForegroundResumesFresh() {
        let t0: TimeInterval = 19_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let ids = IdSequence(["r4-bg-1", "r4-bg-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))

        clock.now = date(t0)
        vm.startIfNeeded()
        XCTAssertEqual(engine.recordingSessionId, "r4-bg-1")
        // Q1 (7x8=56): correct at t0+10, advancing to Q2.
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        XCTAssertFalse(vm.isSessionComplete)

        // A transient inactive (notification shade, control center) is not a
        // backgrounding: nothing finalizes, the session stays active.
        vm.handleScenePhase(.inactive)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(engine.recordingSessionId, "r4-bg-1")
        XCTAssertFalse(vm.isSessionComplete)

        // Background at t0+20: the partial session finalizes and queues.
        clock.now = date(t0 + 20)
        vm.handleScenePhase(.background)
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r4-bg-1")
        XCTAssertEqual(queue.pending().first?.questionRecords.map(\.questionId), ["demo-q1"])

        // Double-finalize stays safe: a second background is a no-op, not a
        // second log — and neither is a later view disappearance.
        vm.handleScenePhase(.background)
        XCTAssertEqual(queue.pending().count, 1,
                       "a second background finalize must not produce a second log")
        vm.handleDisappeared()
        XCTAssertEqual(queue.pending().count, 1,
                       "background finalize + view disappear must not double-log")

        // Foreground: recording resumes fresh for the continued run, with
        // live input. A second foreground/appear is a no-op, not a new
        // session: the resume fires once.
        vm.handleScenePhase(.active)
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r4-bg-2")
        vm.startIfNeeded()
        XCTAssertEqual(engine.recordingSessionId, "r4-bg-2",
                       "resume must fire once per backgrounding")

        // Q2 (6x9=54): correct at t0+40 in the FRESH session.
        clock.now = date(t0 + 40)
        vm.draft = "54"
        vm.submitDraft()
        clock.now = date(t0 + 50)
        let fresh = engine.finishRecordingSession()
        XCTAssertNotNil(fresh)
        XCTAssertEqual(queue.pending().count, 2)
        let newLog = queue.pending().first(where: { $0.sessionId == "r4-bg-2" })
        XCTAssertEqual(newLog?.questionRecords.map(\.questionId), ["demo-q2"],
                       "continued practice after foreground must be recorded")
        let oldLog = queue.pending().first(where: { $0.sessionId == "r4-bg-1" })
        XCTAssertEqual(oldLog?.questionRecords.map(\.questionId), ["demo-q1"])
    }
}

// MARK: - Round 4 Item 1b: failed background finalize blocks the foreground resume

/// When the background finalize's enqueue FAILS, the foreground resume must
/// respect the round-3 blocked state: no fresh recorder and no live input
/// until the pending log drains — never resume on top of it.
@MainActor
final class PipelineRound4Item1bTests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private final class FailFlag { var fail = true }
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
            .appendingPathComponent("round4-item1b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testFailedBackgroundFinalizeBlocksForegroundUntilDrained() {
        let t0: TimeInterval = 19_100_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["r4-bgb-1", "r4-bgb-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))

        clock.now = date(t0)
        vm.startIfNeeded()
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        XCTAssertFalse(vm.isSessionComplete)

        // Background finalize's enqueue FAILS: nothing queues, the log stays
        // retained and retryable in the engine.
        clock.now = date(t0 + 20)
        vm.handleScenePhase(.background)
        XCTAssertTrue(queue.pending().isEmpty)

        // Foreground must respect the blocked state: input blocked, no fresh
        // recorder — never resume on top of the undrained pending log.
        vm.handleScenePhase(.active)
        XCTAssertTrue(vm.isSessionComplete,
                      "failed background finalize must block the foreground, not resume live")
        XCTAssertEqual(engine.recordingSessionId, "r4-bgb-1",
                       "no fresh recorder while the background log is undrained")
        let before = vm.messages.count
        vm.draft = "54"
        vm.submitDraft()
        XCTAssertEqual(vm.messages.count, before, "blocked input must refuse submissions")

        // Heal: "Start again" drains the background log and resumes fresh.
        flag.fail = false
        vm.restartSession()
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r4-bgb-1")
        XCTAssertEqual(engine.recordingSessionId, "r4-bgb-2")

        clock.now = date(t0 + 40)
        vm.draft = "54"
        vm.submitDraft()
        clock.now = date(t0 + 50)
        XCTAssertNotNil(engine.finishRecordingSession())
        XCTAssertEqual(queue.pending().count, 2)
        let newLog = queue.pending().first(where: { $0.sessionId == "r4-bgb-2" })
        XCTAssertEqual(newLog?.questionRecords.map(\.questionId), ["demo-q2"])
    }
}

// MARK: - Round 4 Item 2: Start-again clears the pending probe

/// The mid-run "Start again" path (pending log drains, fresh recorder,
/// re-presented question) never cleared `awaitingProbeReply` — only the
/// completed-restart branch did. A probe pending across a failed disappear
/// then swallowed the child's next submission after "Start again" as an
/// unseen explanation: acknowledged, not graded, not recorded as an answer.
@MainActor
final class PipelineRound4Item2Tests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private final class FailFlag { var fail = true }
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
            .appendingPathComponent("round4-item2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testStartAgainAfterBlockedReappearanceGradesNextAnswer() {
        let t0: TimeInterval = 19_200_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["r4-probe-1", "r4-probe-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)
        let vm = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))

        clock.now = date(t0)
        vm.startIfNeeded()
        // Q1 (7x8): a wrong first attempt leaves a probe reply pending.
        clock.now = date(t0 + 10)
        vm.draft = "55"
        vm.submitDraft()
        XCTAssertTrue(vm.tutorMessages.contains(where: { $0.kind == .probe }),
                      "wrong first attempt must leave a probe pending")

        // Disappear with a failing writer, then a blocked reappearance.
        clock.now = date(t0 + 20)
        vm.handleDisappeared()
        XCTAssertTrue(queue.pending().isEmpty)
        vm.startIfNeeded()
        XCTAssertTrue(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r4-probe-1")

        // Storage heals; "Start again" drains and re-presents Q1 live.
        flag.fail = false
        vm.restartSession()
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r4-probe-2")

        // The next correct answer must be graded and recorded — not consumed
        // as the stale probe reply (which would acknowledge without grading,
        // advancing, or recording).
        clock.now = date(t0 + 40)
        vm.draft = "56"
        vm.submitDraft()
        XCTAssertTrue(vm.tutorMessages.contains(where: { $0.id == "demo-q2" }),
                      "correct answer after Start again must advance, not be swallowed as a probe reply")
        clock.now = date(t0 + 50)
        XCTAssertNotNil(engine.finishRecordingSession())
        let freshLog = queue.pending().first(where: { $0.sessionId == "r4-probe-2" })
        XCTAssertEqual(freshLog?.questionRecords.count, 1)
        XCTAssertEqual(freshLog?.questionRecords.first?.questionId, "demo-q1")
        XCTAssertEqual(freshLog?.questionRecords.first?.correct, true,
                       "correct answer after Start again must be recorded as an answer")
    }
}

// MARK: - Round 4 Item 3: replayed hint timing attributes to its question

/// The recorder anchored every hint listen to the CURRENT question, ignoring
/// the event's messageID — so replaying Q1's hint through its speaker button
/// while Q2 was current misattributed the anchor to Q2. Copilot's shape:
/// Q2 started 10s, answered 70s, Q1-hint listen at 40s. Misattributed, the
/// listen splits Q2's 60s gap into two capped 20s segments (40,000ms); fixed,
/// the listen attributes to Q1 (out-of-window there, so no time anywhere)
/// and Q2 keeps its single capped 20s gap (20,000ms). The session-level
/// listen event is still recorded either way.
@MainActor
final class PipelineRound4Item3Tests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private final class AlwaysSpeakEngine: SpeechEngine {
        var onPlaybackFinished: (() -> Void)?
        var isSpeaking = false
        @discardableResult
        func speak(text: String) -> Bool { isSpeaking = true; return true }
        func stopSpeaking() { isSpeaking = false }
    }
    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("round4-item3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testReplayedEarlierHintAttributesToItsQuestion() {
        let t0: TimeInterval = 19_300_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "r4-hint-1" },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(recording: deps)
        let speech = ReadAloudService(band: GradeBand(grade: "4"),
                                      engine: AlwaysSpeakEngine(),
                                      now: { clock.now })
        let vm = ChatConversationViewModel(engine: engine, speech: speech)

        clock.now = date(t0)
        vm.startIfNeeded()
        // Q1 hint shown at t0+5 (ladder event: hintsUsed=1, 1 hint effort).
        clock.now = date(t0 + 5)
        vm.requestHint()
        guard let q1Hint = vm.tutorMessages.last(where: { $0.kind == .hint }) else {
            return XCTFail("hint turn missing after requestHint")
        }
        // Q1 (7x8=56): correct at t0+10 — Q2 starts at t0+10.
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        // Q1's hint replayed at t0+40 through its own speaker button while
        // Q2 is current, via the production wiring.
        clock.now = date(t0 + 40)
        speech.speak(q1Hint)
        XCTAssertEqual(speech.hintListenEvents.count, 1)
        XCTAssertEqual(speech.hintListenEvents.first?.messageID, q1Hint.id)
        // Q2 (6x9=54): correct at t0+70.
        clock.now = date(t0 + 70)
        vm.draft = "54"
        vm.submitDraft()
        // Explicit finish at t0+80 (Q3 unanswered: Q1+Q2 only).
        clock.now = date(t0 + 80)
        let log = engine.finishRecordingSession()
        XCTAssertNotNil(log)

        // Q1: hint show only — start t0, hint t0+5, answer/end t0+10 = 10s.
        // The replayed listen attributes to Q1 but falls outside its ended
        // window, so it contributes no time.
        XCTAssertEqual(log?.questionRecords.count, 2)
        XCTAssertEqual(log?.questionRecords.first?.questionId, "demo-q1")
        XCTAssertEqual(log?.questionRecords.first?.activeMs, 10000)
        XCTAssertEqual(log?.questionRecords.first?.hintsUsed, 1,
                       "listen must not double-count hintsUsed")
        // Q2: start t0+10, answer/end t0+70 = one 60s gap capped at 20s.
        // Misattributed, the t0+40 listen would split it into 30+30 = 40s.
        XCTAssertEqual(log?.questionRecords.last?.questionId, "demo-q2")
        XCTAssertEqual(log?.questionRecords.last?.activeMs, 20000,
                       "replayed earlier hint must not inflate the current question's time")
        // Session-level: 2 hint interactions (show + listen), 2 genuine
        // attempts, and 60s active (5 + 5 + 20 + 20 + 10) = 1 minute:
        // 4 + 4 + 1 = 9 vs threshold 10. Without the listen event the
        // score would be 6 (1 hint, 40s, 0 minutes).
        XCTAssertEqual(log?.effort, SessionEffortRecord(score: 9, threshold: 10),
                       "the session-level listen event must still be recorded")
    }
}
