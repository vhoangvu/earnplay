import XCTest
import EarnPlayCore
@testable import EarnPlay

// MARK: - Round 3 Item 1a: failed partial enqueue must block, never drop

/// Disappearance finalizes the partial session, but its enqueue FAILS. On
/// reappearance the engine must NOT leave input live on the dead recorder
/// (continued answers would record into it and be dropped by the next
/// finish's short-circuit to the frozen pending log). Instead input is
/// blocked until persistence succeeds; once healed, a fresh recorder takes
/// the continued practice and both logs persist.
@MainActor
final class PipelineRound3Item1aTests: XCTestCase {
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
            .appendingPathComponent("round3-item1a-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testFailedPartialEnqueueBlocksInputUntilDurableThenRecordsFresh() {
        let t0: TimeInterval = 16_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let ids = IdSequence(["r3-1a-1", "r3-1a-2"])
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
        XCTAssertEqual(engine.recordingSessionId, "r3-1a-1")
        // Q1 (7x8=56): correct at t0+10, advancing to Q2.
        clock.now = date(t0 + 10)
        vm.draft = "56"
        vm.submitDraft()
        XCTAssertFalse(vm.isSessionComplete)

        // Disappear at t0+20: the partial finalize's enqueue FAILS.
        clock.now = date(t0 + 20)
        vm.handleDisappeared()
        XCTAssertTrue(queue.pending().isEmpty)

        // Reappear: the resume retry still fails, so input must be blocked
        // (completion state refuses submissions) — never left live on the
        // dead recorder, and no fresh recorder while undrained.
        vm.startIfNeeded()
        XCTAssertTrue(vm.isSessionComplete,
                      "failed resume retry must block input, not leave it live")
        XCTAssertEqual(engine.recordingSessionId, "r3-1a-1",
                       "no fresh recorder while the prior log is undrained")

        // Submissions refused while blocked: nothing recorded, no advance.
        let before = vm.messages.count
        vm.draft = "54"
        vm.submitDraft()
        XCTAssertEqual(vm.messages.count, before, "blocked input must refuse submissions")
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(engine.recordingSessionId, "r3-1a-1")

        // Heal: "Start again" replays the retry — the old log drains, a
        // fresh recorder starts, and the composer goes live again.
        flag.fail = false
        vm.restartSession()
        XCTAssertFalse(vm.isSessionComplete)
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r3-1a-1")
        XCTAssertEqual(engine.recordingSessionId, "r3-1a-2")

        // Q2 (6x9=54): correct at t0+40 in the FRESH session.
        clock.now = date(t0 + 40)
        vm.draft = "54"
        vm.submitDraft()
        clock.now = date(t0 + 50)
        let fresh = engine.finishRecordingSession()
        XCTAssertNotNil(fresh)
        XCTAssertEqual(queue.pending().count, 2)
        let newLog = queue.pending().first(where: { $0.sessionId == "r3-1a-2" })
        XCTAssertEqual(newLog?.questionRecords.map(\.questionId), ["demo-q2"],
                       "continued practice must be recorded, never silently dropped")
        let oldLog = queue.pending().first(where: { $0.sessionId == "r3-1a-1" })
        XCTAssertEqual(oldLog?.questionRecords.map(\.questionId), ["demo-q1"])
    }
}

// MARK: - Round 3 Item 1b: controller-drained resume must not double-deliver

/// The controller drains its handed-off copy first; the engine's resume-time
/// retry of the same log must then be dedupe-safe (one copy, same
/// sessionId) and resume into a fresh recorder for continued practice.
final class PipelineRound3Item1bTests: XCTestCase {
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
            .appendingPathComponent("round3-item1b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    func testControllerDrainedThenResumeHasSingleDeliveryAndRecordsContinued() {
        let t0: TimeInterval = 17_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queue = SessionLogQueue(directory: tempDir("q"), dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        let suite = "round3-item1b-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("test defaults unavailable")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let gate = SyncPairingStore.loadOrCreateGate(
            displayName: "EarnPlay-Child", defaults: defaults, key: "test-key")
        let controller = ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store")),
            sessionQueue: queue, pairing: gate)
        let ids = IdSequence(["r3-1b-1", "r3-1b-2"])
        let deps = PracticeRecordingDependencies(
            makeSessionId: { ids.next() },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now },
            onEnqueueFailed: { [weak controller] log in
                controller?.handleFailedEnqueue(log)
            })
        let engine = DemoTutorEngine(recording: deps)

        clock.now = date(t0)
        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56") // Q1 correct, advancing to Q2.
        clock.now = date(t0 + 20)
        engine.endSession() // Disappearance: enqueue fails, hands off.
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(controller.pendingFailedLogs.count, 1)

        // The controller drains its copy first (healed writer).
        flag.fail = false
        controller.retryPendingFailedLogs()
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r3-1b-1")

        // Resume retries the SAME log: dedupe keeps one copy, and a fresh
        // recorder starts for the continued run.
        engine.resumeSession()
        XCTAssertEqual(queue.pending().count, 1,
                       "engine retry after controller drain must not double-deliver")
        XCTAssertEqual(queue.pending().first?.sessionId, "r3-1b-1")
        XCTAssertEqual(engine.recordingSessionId, "r3-1b-2",
                       "drained resume must start a fresh recording session")

        // Q2 (6x9=54): correct at t0+30 in the resumed session.
        clock.now = date(t0 + 30)
        _ = engine.submitAnswer("54")
        clock.now = date(t0 + 40)
        let resumed = engine.finishRecordingSession()
        XCTAssertNotNil(resumed)
        XCTAssertEqual(queue.pending().count, 2)
        let newLog = queue.pending().first(where: { $0.sessionId == "r3-1b-2" })
        XCTAssertEqual(newLog?.questionRecords.map(\.questionId), ["demo-q2"],
                       "continued practice must be recorded, not dropped")
    }
}

// MARK: - Round 3 Item 3: retained failed logs must survive app quit

/// A failed-enqueue log handed to the controller must survive a
/// quit-equivalent (a fresh controller instance) and drain on retry.
final class PipelineRound3Item3Tests: XCTestCase {
    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
    private final class FailFlag { var fail = true }
    private struct FailWrite: Error {}
    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("round3-item3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
    private func testGate(_ suite: String) -> SyncPairingGate? {
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SyncPairingStore.loadOrCreateGate(
            displayName: "EarnPlay-Child", defaults: defaults, key: "test-key")
    }

    func testFailedLogSurvivesQuitEquivalentAndDrainsOnRetry() {
        let t0: TimeInterval = 18_000_000
        let clock = FakeClock(date(t0))
        let flag = FailFlag()
        let queueDir = tempDir("q")
        let queue = SessionLogQueue(directory: queueDir, dataWriter: { _, _ in
            if flag.fail { throw FailWrite() }
        })
        guard let gate1 = testGate("round3-item3-a-\(UUID().uuidString)") else {
            return XCTFail("test defaults unavailable")
        }
        let retentionDir = tempDir("retention")
        let retentionFile = retentionDir.appendingPathComponent(
            ChildSyncController.failedLogRetentionFileName)
        var controller1: ChildSyncController? = ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store1")),
            sessionQueue: queue, pairing: gate1,
            retentionDirectory: retentionDir)
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "r3-3-1" },
            logger: DecisionLogger(directory: tempDir("log")), queue: queue,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now },
            onEnqueueFailed: { [weak controller1] log in
                controller1?.handleFailedEnqueue(log)
            })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)
        clock.now = date(t0)
        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56") // Auto-finish fails; hands off.
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertEqual(controller1?.pendingFailedLogs.count, 1)
        // The retention write lands beside the queue (persist path).
        XCTAssertTrue(FileManager.default.fileExists(atPath: retentionFile.path),
                      "handoff must persist the retained log")

        // Quit-equivalent: drop the controller; a fresh instance must load
        // the retained log and drain it on retry.
        controller1 = nil
        XCTAssertTrue(flag.fail)
        flag.fail = false
        guard let gate2 = testGate("round3-item3-b-\(UUID().uuidString)") else {
            return XCTFail("test defaults unavailable")
        }
        let controller2 = ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store2")),
            sessionQueue: SessionLogQueue(directory: queueDir), pairing: gate2,
            retentionDirectory: retentionDir)
        XCTAssertEqual(controller2.pendingFailedLogs.count, 1,
                       "retained log must load after quit-equivalent")
        XCTAssertEqual(controller2.pendingFailedLogs.first?.sessionId, "r3-3-1")
        controller2.retryPendingFailedLogs()
        XCTAssertEqual(controller2.sessionQueue.pending().count, 1)
        XCTAssertEqual(controller2.sessionQueue.pending().first?.sessionId, "r3-3-1")
        XCTAssertTrue(controller2.pendingFailedLogs.isEmpty)
        // Delete-on-drain: the retention file persists the emptied list.
        let retainedAfterDrain = (try? Data(contentsOf: retentionFile))
            .flatMap { try? SessionLogCodec.decodeList($0) }
        XCTAssertEqual(retainedAfterDrain, [],
                       "drain must clear the retained-log file")
    }

    /// When the retention write itself fails (unwritable directory, the
    /// disk-full shape), memory retention still holds the log and the
    /// lifecycle retry still drains it — persistence is best-effort.
    func testRetentionWriteFailureKeepsMemoryAndStillDrains() {
        let t0: TimeInterval = 18_100_000
        let clock = FakeClock(date(t0))
        let queueDir = tempDir("q")
        let queue = SessionLogQueue(directory: queueDir)
        // A file where a directory must be: createDirectory fails, so the
        // retention write fails while the queue (temp dir) works.
        let blocker = tempDir("blocker").appendingPathComponent("file")
        try? "x".write(to: blocker, atomically: true, encoding: .utf8)
        let unwritable = blocker.appendingPathComponent("sub")
        guard let gate = testGate("round3-item3-c-\(UUID().uuidString)") else {
            return XCTFail("test defaults unavailable")
        }
        let controller = ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store")),
            sessionQueue: queue, pairing: gate,
            retentionDirectory: unwritable)
        // A real finalized log, built by an engine over a scratch queue.
        let scratch = SessionLogQueue(directory: tempDir("scratch"))
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "r3-3-mem" },
            logger: DecisionLogger(directory: tempDir("log")), queue: scratch,
            makeScorer: { EffortScorer(threshold: 10) },
            policyVersion: { 1 },
            now: { clock.now })
        let engine = DemoTutorEngine(maxQuestions: 1, recording: deps)
        clock.now = date(t0)
        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56")
        guard let log = scratch.pending().first else {
            return XCTFail("scratch engine produced no log")
        }
        // Handoff with broken retention: memory must still retain.
        controller.handleFailedEnqueue(log)
        XCTAssertEqual(controller.pendingFailedLogs.count, 1,
                       "retention-write failure must keep memory retention")
        // The lifecycle retry still drains through the shared queue.
        controller.retryPendingFailedLogs()
        XCTAssertEqual(queue.pending().count, 1)
        XCTAssertEqual(queue.pending().first?.sessionId, "r3-3-mem")
        XCTAssertTrue(controller.pendingFailedLogs.isEmpty)
    }
}
