import SwiftUI
import XCTest
import EarnPlayCore
@testable import EarnPlay

// MARK: - Round 5 Item 1: background drain then Start-again clears the pending probe

/// Round 4 cleared `awaitingProbeReply` on only two `startSession` paths —
/// the completed-restart branch and the mid-run drain-success fall-through.
/// A third path missed it: a probe is pending, background/foreground
/// persistence attempts fail and block input, then a LATER background
/// successfully drains the log. Now `pendingFinishedLog` is nil, so a
/// subsequent "Start again" SKIPS the retry branch entirely and falls
/// through to the fresh-recorder branch, which never cleared the flag. The
/// re-presented question is then answered with the flag still true, so the
/// child's next correct answer is consumed as an unseen explanation — not
/// graded, not recorded. Copilot's shape: probe pending -> failed finalize
/// attempts block input -> later background drains the log -> "Start again"
/// -> the next correct answer is graded and recorded.
@MainActor
final class PipelineRound5Item1Tests: XCTestCase {
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
            .appendingPathComponent("round5-item1-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testBackgroundDrainThenStartAgainGradesNextAnswer() {
        let t0: TimeInterval = 19_400_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["r5-probe-1", "r5-probe-2"])
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

        // Background finalize FAILS, then the foreground resume attempt
        // fails too and blocks input — no fresh recorder.
        clock.now = date(t0 + 20)
        vm.handleScenePhase(.background)
        XCTAssertTrue(queue.pending().isEmpty)
        vm.handleScenePhase(.active)
        XCTAssertTrue(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r5-probe-1")

        // Storage heals; a LATER background drains the pending log via the
        // round-4 background finalize (no fresh recorder: backgrounding is
        // finalize-only, and the view model still renders blocked).
        flag.fail = false
        clock.now = date(t0 + 30)
        vm.handleScenePhase(.background)
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r5-probe-1")
        XCTAssertEqual(engine.recordingSessionId, "r5-probe-1")

        // "Start again" skips the retry branch (nothing pending) and falls
        // through to the fresh-recorder branch, re-presenting Q1 live.
        vm.restartSession()
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r5-probe-2")

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
        let freshLog = queue.pending().first(where: { $0.sessionId == "r5-probe-2" })
        XCTAssertEqual(freshLog?.questionRecords.count, 1)
        XCTAssertEqual(freshLog?.questionRecords.first?.questionId, "demo-q1")
        XCTAssertEqual(freshLog?.questionRecords.first?.correct, true,
                       "correct answer after Start again must be recorded as an answer")
    }
}

// MARK: - Round 5 Item 2: replay after resume attributes to the originating question

/// The hint-ownership map lives PER RECORDER, and every resume builds a
/// brand-new recorder — so after any background/foreground or
/// disappear/reappear the map is empty. The chat keeps the earlier hint
/// bubbles, so replaying Q1's hint while Q2 is current falls back to
/// current (Q2) and misattributes. Copilot's shape: Q1 hint shown, resume
/// (new recorder), replay Q1's hint while Q2 is current -> the anchor
/// resolves to Q1 (whose session already finalized, so it contributes no
/// question time anywhere) and Q2 keeps its single capped 20s gap
/// (20,000ms, not the 40,000ms a fallback would record). The
/// session-level listen event is still recorded either way.
@MainActor
final class PipelineRound5Item2Tests: XCTestCase {
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
            .appendingPathComponent("round5-item2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testReplayAfterResumeAttributesToOriginatingQuestion() {
        let t0: TimeInterval = 19_500_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let ids = IdSequence(["r5-hint-1", "r5-hint-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
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
        XCTAssertEqual(engine.recordingSessionId, "r5-hint-1")
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
        // Disappear at t0+20: the partial session finalizes and queues.
        clock.now = date(t0 + 20)
        vm.handleDisappeared()
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r5-hint-1")

        // Reappear: a BRAND-NEW recorder resumes Q2 at t0+20 with the
        // earlier hint bubbles kept in the thread — the ownership map
        // must survive the replacement.
        vm.startIfNeeded()
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(engine.recordingSessionId, "r5-hint-2")

        // Q1's hint replayed at t0+50 through its own speaker button while
        // Q2 is current, via the production wiring.
        clock.now = date(t0 + 50)
        speech.speak(q1Hint)
        XCTAssertEqual(speech.hintListenEvents.count, 1)
        XCTAssertEqual(speech.hintListenEvents.first?.messageID, q1Hint.id)
        // Q2 (6x9=54): correct at t0+80.
        clock.now = date(t0 + 80)
        vm.draft = "54"
        vm.submitDraft()
        // Explicit finish at t0+90 (Q3 unanswered: Q2 only in session 2).
        clock.now = date(t0 + 90)
        let log = engine.finishRecordingSession()
        XCTAssertNotNil(log)

        // The resumed session records Q2 only: start t0+20, answer/end
        // t0+80 = one 60s gap capped at 20s. Attributed to its originating
        // Q1 (already finalized in session 1), the t0+50 listen lands on
        // no live question and contributes no time anywhere; fallen back
        // to current, it would split Q2 into 30+30 = 40s.
        let freshLog = queue.pending().first(where: { $0.sessionId == "r5-hint-2" })
        XCTAssertEqual(freshLog?.questionRecords.count, 1)
        XCTAssertEqual(freshLog?.questionRecords.first?.questionId, "demo-q2")
        XCTAssertEqual(freshLog?.questionRecords.first?.activeMs, 20000,
                       "replayed earlier hint after resume must not inflate the current question's time")
        XCTAssertEqual(freshLog?.questionRecords.first?.hintsUsed, 0,
                       "carried ownership must not count as new hint shows")
        // Session-level: 1 hint interaction (the listen), 1 genuine
        // attempt, and 50s active (30 + 30 + 10 capped 20 + 20 + 10) =
        // 0 minutes: 2 + 2 + 0 = 4 vs threshold 10. Without the listen
        // event the score would be 2.
        XCTAssertEqual(freshLog?.effort, SessionEffortRecord(score: 4, threshold: 10),
                       "the session-level listen event must still be recorded")
        // The finalized first session is intact: Q1 (start t0, hint t0+5,
        // answer/end t0+10 = 10s, 1 hint show).
        let oldLog = queue.pending().first(where: { $0.sessionId == "r5-hint-1" })
        XCTAssertEqual(oldLog?.questionRecords.map(\.questionId), ["demo-q1"])
        XCTAssertEqual(oldLog?.questionRecords.first?.activeMs, 10000)
        XCTAssertEqual(oldLog?.questionRecords.first?.hintsUsed, 1)
    }
}
