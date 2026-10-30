import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.6 — sync over a transport stub (issue allows stub in place of two
/// devices): PolicyUpdate down, SessionLog up, offline queue drain,
/// exactly-once on reconnect, newer-version-wins.
final class SyncServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }
    private func policy(version: Int, practice: Int = 30) -> Policy {
        var p = Policy.defaultPolicy.withVersion(version)
        p.unlockDurations = UnlockDurations(practiceMinutes: practice, tradeMinutes: 15)
        return p
    }
    private func decision(session: String, id: String = UUID().uuidString) -> Decision {
        Decision(decisionId: id, sessionId: session, type: .sessionJudgment,
                 outcome: "done", evidenceSummary: "ev", reasoning: "why",
                 alternativeConsidered: "alt", confidence: 0.9,
                 timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }
    private func sessionLog(_ id: String) -> SessionLog {
        SessionLog(sessionId: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                   endedAt: Date(timeIntervalSince1970: 1_700_000_600),
                   decisions: [decision(session: id)], policyVersion: 3)
    }
    private struct Fixture {
        let adminStore: PolicyStore; let adminQueue: PolicyUpdateQueue
        let adminSessions: SessionLogStore
        let childStore: PolicyStore; let childQueue: SessionLogQueue
        let admin: AdminSyncService; let child: ChildSyncService
        let link: InMemorySyncLink
    }
    private func fixture() -> Fixture {
        let (at, ct, link) = InMemorySyncTransport.pair()
        let f = Fixture(
            adminStore: PolicyStore(directory: dir("admin-store")),
            adminQueue: PolicyUpdateQueue(directory: dir("admin-queue")),
            adminSessions: SessionLogStore(directory: dir("admin-sessions")),
            childStore: PolicyStore(directory: dir("child-store")),
            childQueue: SessionLogQueue(directory: dir("child-queue")),
            admin: AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("admin-queue")),
                                    sessionStore: SessionLogStore(directory: dir("admin-sessions")), transport: at),
            child: ChildSyncService(policyStore: PolicyStore(directory: dir("child-store")),
                                    sessionQueue: SessionLogQueue(directory: dir("child-queue")), transport: ct),
            link: link)
        // Services own their own store instances over the same dirs; expose
        // fresh readers via the services in assertions below.
        return f
    }

    func testPolicyUpdateReachesChildAndApplies() throws {
        let f = fixture(); f.admin.start(); f.child.start()
        let update = policy(version: 1, practice: 45)
        try f.adminQueue.enqueue(update)
        f.admin.flushPending()
        XCTAssertEqual(f.child.policyStore.storedVersion, 1)
        XCTAssertEqual(f.child.policyStore.currentPolicy.unlockDurations.practiceMinutes, 45)
        XCTAssertTrue(f.admin.policyQueue.pendingUpdates().isEmpty, "acked update must leave admin queue")
    }

    func testSessionLogReachesAdminAndStores() throws {
        let f = fixture(); f.admin.start(); f.child.start()
        try f.child.sendSessionLog(sessionLog("s-1"))
        XCTAssertEqual(f.admin.sessionStore.allLogs.map(\.sessionId), ["s-1"])
        XCTAssertEqual(f.admin.sessionStore.allLogs.first?.decisions.count, 1)
        XCTAssertTrue(f.child.sessionQueue.pending().isEmpty, "acked log must leave child queue")
    }

    func testOfflineQueueDrainsExactlyOnceAfterTransportKillAndRestore() throws {
        let f = fixture(); f.admin.start(); f.child.start()
        f.link.isUp = false // kill transport mid-flow
        try f.child.sendSessionLog(sessionLog("s-offline"))
        XCTAssertTrue(f.admin.sessionStore.allLogs.isEmpty)
        XCTAssertEqual(f.child.sessionQueue.pending().map(\.sessionId), ["s-offline"])
        f.link.isUp = true // restore; reconnect drains without re-running anything
        f.child.handleReconnect()
        XCTAssertEqual(f.admin.sessionStore.allLogs.map(\.sessionId), ["s-offline"])
        XCTAssertTrue(f.child.sessionQueue.pending().isEmpty)
        // Simulate the ack having been lost: the same payload is redelivered.
        let duplicate = try SyncMessageCodec.encode(.sessionLog(sessionLog("s-offline")))
        f.admin.handleReceived(duplicate)
        XCTAssertEqual(f.admin.sessionStore.allLogs.count, 1, "redelivery must not duplicate the log entry")
        // Queue persisted across relaunch-equivalent reopen.
        try f.child.sendSessionLog(sessionLog("s-offline-2"))
        f.link.isUp = false
        try f.child.sendSessionLog(sessionLog("s-offline-3"))
        let reopened = SessionLogQueue(directory: dir("child-queue"))
        XCTAssertEqual(reopened.pending().map(\.sessionId), ["s-offline-3"])
    }

    func testNewerVersionWinsStaleIsDiscardedAndAcked() throws {
        let f = fixture(); f.admin.start(); f.child.start()
        try f.adminQueue.enqueue(policy(version: 2, practice: 50)); f.admin.flushPending()
        XCTAssertEqual(f.child.policyStore.currentPolicy.unlockDurations.practiceMinutes, 50)
        // Stale v1 arrives late (replay / out-of-order): discarded, newer stays.
        f.child.handleReceived(try SyncMessageCodec.encode(.policyUpdate(policy(version: 1, practice: 99))))
        XCTAssertEqual(f.child.policyStore.storedVersion, 2)
        XCTAssertEqual(f.child.policyStore.currentPolicy.unlockDurations.practiceMinutes, 50)
        // Newer v3 wins.
        try f.adminQueue.enqueue(policy(version: 3, practice: 60)); f.admin.flushPending()
        XCTAssertEqual(f.child.policyStore.currentPolicy.unlockDurations.practiceMinutes, 60)
    }

    func testSessionLogStoreDeduplicatesBySessionId() throws {
        let store = SessionLogStore(directory: dir("store"))
        XCTAssertTrue(store.store(sessionLog("s-1")))
        XCTAssertFalse(store.store(sessionLog("s-1")))
        XCTAssertEqual(store.allLogs.count, 1)
        XCTAssertEqual(SessionLogStore(directory: dir("store")).allLogs.count, 1)
    }
}
