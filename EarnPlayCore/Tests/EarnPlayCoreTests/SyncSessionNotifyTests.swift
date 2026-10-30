import Foundation
import XCTest
@testable import EarnPlayCore

/// Issue #63 fix 3 — the child production path enqueues directly into
/// `SessionLogQueue` (it cannot use `sendSessionLog`), and the outbox is
/// not polled: delivery needs the explicit `notifySessionEnqueued()`
/// kick, mirroring the admin notifyPolicyEnqueued->flushPending pattern.
final class SyncSessionNotifyTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSessionNotifyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }
    private func sessionLog(_ id: String) -> SessionLog {
        let decision = Decision(decisionId: UUID().uuidString, sessionId: id, type: .sessionJudgment,
                                outcome: "done", evidenceSummary: "ev", reasoning: "why",
                                alternativeConsidered: "alt", confidence: 0.9,
                                timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        return SessionLog(sessionId: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_700_000_600),
                          decisions: [decision], policyVersion: 3)
    }

    /// Direct enqueue + notify delivers exactly like sendSessionLog: the
    /// admin stores the log and the ack drains the child outbox.
    func testDirectEnqueuePlusNotifyDeliversAndDrains() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("admin-queue")),
                                     sessionStore: SessionLogStore(directory: dir("admin-sessions")),
                                     transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("child-store")),
                                     sessionQueue: SessionLogQueue(directory: dir("child-queue")),
                                     transport: ct)
        admin.start(); child.start()
        // Production path: enqueue directly, then kick delivery.
        try child.sessionQueue.enqueue(sessionLog("s-notify-1"))
        child.notifySessionEnqueued()
        XCTAssertEqual(admin.sessionStore.allLogs.map(\.sessionId), ["s-notify-1"])
        XCTAssertTrue(child.sessionQueue.pending().isEmpty, "acked log must leave child queue")
        XCTAssertEqual(child.snapshot.pendingUploads, 0)
    }

    /// Without the kick the log waits (no polling): it stays queued
    /// until a notify (or reconnect) flushes it.
    func testDirectEnqueueWithoutNotifyStaysQueued() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("admin-queue")),
                                     sessionStore: SessionLogStore(directory: dir("admin-sessions")),
                                     transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("child-store")),
                                     sessionQueue: SessionLogQueue(directory: dir("child-queue")),
                                     transport: ct)
        admin.start(); child.start()
        try child.sessionQueue.enqueue(sessionLog("s-quiet-1"))
        XCTAssertTrue(admin.sessionStore.allLogs.isEmpty, "no poll: nothing delivered without notify")
        XCTAssertEqual(child.sessionQueue.pending().map(\.sessionId), ["s-quiet-1"])
        child.notifySessionEnqueued()
        XCTAssertEqual(admin.sessionStore.allLogs.map(\.sessionId), ["s-quiet-1"])
    }
}
