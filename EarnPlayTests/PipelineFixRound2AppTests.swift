import XCTest
import EarnPlayCore
@testable import EarnPlay

// MARK: - Round 2 Item 1: double-enqueue-failure must not lose new results

/// After a completion enqueue fails, the engine stays completed until the
/// pending log is durable. A restart attempt while the retry still fails
/// must NOT reset: it returns the session-complete state, the new run does
/// not start, and no data is lost. Once the retry succeeds, the old log
/// drains and a subsequent new run records fresh.
final class PipelineRound2Item1Tests: XCTestCase {
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
    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-item1-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testDoubleEnqueueFailureKeepsCompletedUntilDurable() {
        let t0: TimeInterval = 11_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir(), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["old-1", "new-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 7 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)

        clock.now = date(t0)
        _ = engine.startSession()
        XCTAssertEqual(engine.recordingSessionId, "old-1")
        // The only question answered correctly: auto-finish fails.
        clock.now = date(t0 + 10)
        let done = engine.submitAnswer("56")
        XCTAssertEqual(done.composer, .sessionComplete)
        XCTAssertTrue(queue.pending().isEmpty)

        // Restart attempt with the writer STILL failing: must NOT reset.
        clock.now = date(t0 + 50)
        let blocked = engine.startSession()
        XCTAssertEqual(blocked.composer, .sessionComplete,
                       "failed retry must stay complete, not reset into a new run")
        XCTAssertEqual(engine.recordingSessionId, "old-1",
                       "the new run must NOT start while the old log is undrained")
        XCTAssertTrue(queue.pending().isEmpty, "no data may be lost or invented")

        // Heal: the retry drains the old log and the new run starts fresh.
        flag.fail = false
        clock.now = date(t0 + 60)
        let resumed = engine.startSession()
        XCTAssertNotEqual(resumed.composer, .sessionComplete)
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "old-1")
        XCTAssertEqual(queue.pending().first?.endedAt, date(t0 + 10))
        XCTAssertEqual(engine.recordingSessionId, "new-2")

        // The new run records fresh (not short-circuited to the old log).
        clock.now = date(t0 + 70)
        let newDone = engine.submitAnswer("56")
        XCTAssertEqual(newDone.composer, .sessionComplete)
        XCTAssertEqual(queue.pending().count, 2)
        let oldLog = queue.pending().first(where: { $0.sessionId == "old-1" })
        let newLog = queue.pending().first(where: { $0.sessionId == "new-2" })
        XCTAssertNotNil(oldLog)
        XCTAssertNotNil(newLog)
        XCTAssertNotEqual(newLog, oldLog)
        XCTAssertEqual(newLog?.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q1", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 0),
        ])
    }
}

// MARK: - Round 2 Item 2: discard must not lose a failed-enqueue log

/// Discarding the practice view after a failed enqueue hands the finalized
/// log to the app-scoped controller, which retains it and retries through
/// the SAME queue instance, firing delivery on success.
final class PipelineRound2Item2Tests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private final class FailFlag { var fail = true }
    private struct FailWrite: Error {}
    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-item2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testDiscardWithFailedEnqueueHandsToControllerAndRetries() {
        let t0: TimeInterval = 12_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let suite = "round2-item2-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("test defaults unavailable")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let gate = SyncPairingStore.loadOrCreateGate(
            displayName: "EarnPlay-Child", defaults: defaults, key: "test-key")
        let controller = ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store")),
            sessionQueue: queue, pairing: gate)
        var deliveryCount = 0
        controller.onSessionEnqueued = { deliveryCount += 1 }

        // The engine enqueues into the SAME queue instance production uses.
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "discard-1" },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now },
            onEnqueueFailed: { [weak controller] log in
                controller?.handleFailedEnqueue(log)
            })
        var engine: DemoTutorEngine? = DemoTutorEngine(maxQuestions: 1, recording: deps)
        clock.now = date(t0)
        engine?.startSession()
        clock.now = date(t0 + 10)
        _ = engine?.submitAnswer("56") // Auto-finish fails to persist.
        XCTAssertTrue(queue.pending().isEmpty)

        // Discard the view/engine: the controller must hold the log.
        engine = nil
        XCTAssertEqual(controller.pendingFailedLogs.count, 1)
        XCTAssertEqual(controller.pendingFailedLogs.first?.sessionId, "discard-1")

        // Heal: retry drains through the shared queue and delivery fires.
        flag.fail = false
        controller.retryPendingFailedLogs()
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "discard-1")
        XCTAssertTrue(controller.pendingFailedLogs.isEmpty)
        XCTAssertEqual(deliveryCount, 1, "retry success must fire onSessionEnqueued")
    }
}

// MARK: - Round 2 Item 3: reappearance must not accept unrecorded answers

/// Disappear ends recording; reappearance must either start a fresh
/// recording session (the continued answers are recorded) or refuse the
/// answers. The composer must never accept answers with no active recording.
@MainActor
final class PipelineRound2Item3Tests: XCTestCase {
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
            .appendingPathComponent("round2-item3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testDisappearReappearAnswerIsRecordedInFreshSession() {
        let t0: TimeInterval = 13_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let ids = IdSequence(["resume-1", "resume-2"])
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
        XCTAssertEqual(engine.recordingSessionId, "resume-1")
        // Q1 (7x8=56): correct at t0+10, advancing to Q2.
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        XCTAssertFalse(vm.isSessionComplete)

        // Disappear at t0+20: the partial session finalizes.
        clock.now = date(t0 + 20)
        vm.handleDisappeared()
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "resume-1")

        // Reappear: a fresh recording session must start (or the composer
        // must refuse answers — either way, no unrecorded acceptance).
        vm.startIfNeeded()
        XCTAssertEqual(engine.recordingSessionId, "resume-2",
                       "reappearance must start a fresh recording session")

        // Q2 (6x9=54): correct at t0+30 in the resumed session.
        clock.now = date(t0 + 30)
        let before = vm.messages.count
        vm.draft = "54"
        vm.submitDraft()
        XCTAssertGreaterThan(vm.messages.count, before, "the answer was accepted")

        // Finish the resumed session explicitly at t0+40.
        clock.now = date(t0 + 40)
        let resumed = engine.finishRecordingSession()
        XCTAssertNotNil(resumed)
        XCTAssertEqual(queue.pending().count, 2)
        let resumedLog = queue.pending().first(where: { $0.sessionId == "resume-2" })
        XCTAssertNotNil(resumedLog, "the post-reappear answer must be recorded, not omitted")
        // Resumed recorder started at reappear (t0+20); Q2 answered at
        // t0+30: 10000ms, no hints, correct. Q1 belongs to the old log.
        XCTAssertEqual(resumedLog?.questionRecords, [
            SessionQuestionRecord(questionId: "demo-q2", skill: "multiplicationFacts",
                                  correct: true, activeMs: 10000, hintsUsed: 0),
        ])
        let oldLog = queue.pending().first(where: { $0.sessionId == "resume-1" })
        XCTAssertEqual(oldLog?.questionRecords.map(\.questionId), ["demo-q1"])
    }
}

// MARK: - Round 2 Item 4: practice logs carry the post-setup policy version

/// Setup commits through a separate `PolicyStore`; the controller's cache
/// stays stale until restart. Practice logs must read the persisted version
/// per log (one file read per session), so a setup-commits-then-log sequence
/// carries the NEW version with no restart.
final class PipelineRound2Item4Tests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("round2-item4-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    // The pre-fix wiring (a cached controller-store closure, as
    // EarnPlayApp passed before round 2) carries version 0 here — that
    // failing-first run proved the staleness. The fixed wiring reads the
    // persisted version per log, carrying version 1 with no restart.
    func testSetupCommitsThenLogCarriesNewVersion() {
        let shared = tempDir()
        // Controller created at app launch (pre-setup, version 0).
        let controllerStore = PolicyStore(directory: shared)
        XCTAssertEqual(controllerStore.storedVersion, 0)
        // Setup commits v1 through its SEPARATE store over the same dir.
        let setupStore = PolicyStore(directory: shared)
        XCTAssertEqual(setupStore.apply(Policy.defaultPolicy.withVersion(1)), .applied)
        XCTAssertEqual(controllerStore.storedVersion, 0,
                       "the controller cache stays stale until restart (the bug)")
        XCTAssertEqual(PolicyStore(directory: shared).storedVersion, 1,
                       "the persisted version is new; only the cache is stale")

        // Fixed wiring (round 2 item 4, as production now passes): a fresh
        // read per log — one file read per session log.
        let freshVersion = { PolicyStore(directory: shared).storedVersion }
        let t0: TimeInterval = 14_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir())
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "policy-1" },
            logger: DecisionLogger(directory: tempDir()), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: freshVersion,
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)
        clock.now = date(t0)
        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56")
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.policyVersion, 1,
                       "practice log must carry the post-setup version with no restart")
    }
}

// MARK: - Round 2 Item 5: hint playback reaches the session recorder

/// Successful hint playback in production chat must reach the CURRENT
/// session's effort recorder: listen effort + timing anchor recorded,
/// `hintsUsed` still tied to ladder-show events only (no double-count).
@MainActor
final class PipelineRound2Item5Tests: XCTestCase {
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
            .appendingPathComponent("round2-item5-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testHintPlaybackRecordsListenEffortWithoutDoubleCountingHintsUsed() {
        let t0: TimeInterval = 15_000_000
        let clock = FakeClock(date(t0))
        let queue = SessionLogQueue(directory: tempDir("q"))
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "hint-1" },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        // Default 3-question engine: Q1 answered below advances to Q2
        // without auto-finishing, so the explicit finish drives finalize.
        let engine = DemoTutorEngine(recording: deps)
        let speech = ReadAloudService(band: GradeBand(grade: "4"),
                                      engine: AlwaysSpeakEngine(),
                                      now: { clock.now })
        let vm = ChatConversationViewModel(engine: engine, speech: speech)

        clock.now = date(t0)
        vm.startIfNeeded()
        // Q1 hint shown at t0+10 (ladder event: hintsUsed=1, 1 hint effort).
        clock.now = date(t0 + 10)
        vm.requestHint()
        guard let hint = vm.tutorMessages.last(where: { $0.kind == .hint }) else {
            return XCTFail("hint turn missing after requestHint")
        }
        // Hint listened at t0+70 through the production wiring.
        clock.now = date(t0 + 70)
        speech.speak(hint)
        XCTAssertEqual(speech.hintListenEvents.count, 1)
        // Q1 (7x8=56): correct at t0+140.
        clock.now = date(t0 + 140)
        vm.draft = "56"
        vm.submitDraft()
        // Explicit finish at t0+150 (Q2/Q3 unanswered: Q1 only).
        clock.now = date(t0 + 150)
        let log = engine.finishRecordingSession()
        XCTAssertNotNil(log)

        // hintsUsed counts ladder shows only — the listen adds none.
        XCTAssertEqual(log?.questionRecords.count, 1)
        XCTAssertEqual(log?.questionRecords.first?.hintsUsed, 1,
                       "listen must not double-count hintsUsed")
        // Round 3 item 2: the listen at t0+70 must anchor question timing,
        // splitting the 130s gap: 10 + 20 + 20 = 50s active.
        XCTAssertEqual(log?.questionRecords.first?.activeMs, 50000,
                       "hint listen must anchor question timing")
        // Listen effort + anchor: 2 hint interactions (show + listen),
        // 1 genuine attempt, and 60s active (10 + 20 + 20 + 10) = 1
        // minute: 4 + 2 + 1 = 7 vs threshold 10. Without the wiring the
        // listen is omitted: 1 hint, 40s (0 min), score 4.
        XCTAssertEqual(log?.effort, SessionEffortRecord(score: 7, threshold: 10))
    }
}
