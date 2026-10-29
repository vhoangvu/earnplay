import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.6 fix round 2 (issue #23): regression tests, one per finding.
final class SyncFixRound2Tests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFixRound2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ n: String) -> URL { directory.appendingPathComponent(n, isDirectory: true) }
    private func policy(version: Int, practice: Int = 30) -> Policy {
        var p = Policy.defaultPolicy.withVersion(version)
        p.unlockDurations = UnlockDurations(practiceMinutes: practice, tradeMinutes: 15)
        return p
    }
    private func log(_ id: String) -> SessionLog {
        SessionLog(sessionId: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                   endedAt: Date(timeIntervalSince1970: 1_700_000_600),
                   decisions: [Decision(decisionId: "d-\(id)", sessionId: id, type: .sessionJudgment,
                                        outcome: "done", evidenceSummary: "ev", reasoning: "why",
                                        alternativeConsidered: "alt", confidence: 0.9,
                                        timestamp: Date(timeIntervalSince1970: 1_700_000_000))],
                   policyVersion: 3)
    }
    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; Thread.sleep(forTimeInterval: 0.01) }
        XCTFail("condition not met within \(timeout)s")
    }

    /// Transport wrapper that drops the first N ack sends (lost ack).
    private final class AckDropper: SyncTransport, @unchecked Sendable {
        let inner: InMemorySyncTransport
        var dropsRemaining: Int
        var onReceive: ((Data) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        init(inner: InMemorySyncTransport, drops: Int) { self.inner = inner; self.dropsRemaining = drops }
        var isConnected: Bool { inner.isConnected }
        func start() {
            inner.onReceive = { [weak self] in self?.onReceive?($0) }
            inner.onConnectionChange = { [weak self] in self?.onConnectionChange?($0) }
            inner.start()
        }
        func stop() { inner.stop() }
        func send(_ data: Data) throws {
            if let m = try? SyncMessageCodec.decode(data) {
                switch m {
                case .ackSession, .ackPolicy:
                    if dropsRemaining > 0 { dropsRemaining -= 1; return }
                default: break
                }
            }
            try inner.send(data)
        }
    }

    // F1: unpaired peer rejected / no data; paired peer syncs.
    func testF1_UnpairedBlockedPairedSyncs() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let adminGate = SyncPairingGate(code: "123456")
        let childGate = SyncPairingGate(code: "123456")
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")),
                                     transport: at, pairing: adminGate)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")),
                                     transport: ct, pairing: childGate)
        admin.start(); child.start()
        try admin.policyQueue.enqueue(policy(version: 1, practice: 45))
        admin.flushPending()
        XCTAssertEqual(child.policyStore.storedVersion, 0, "unpaired: no policy data may flow")
        try child.sendSessionLog(log("s-unpaired"))
        XCTAssertTrue(admin.sessionStore.allLogs.isEmpty, "unpaired: no session data may flow")
        let childID = PeerIdentity(stableID: "child-1", displayName: "EarnPlay-Child")
        let adminID = PeerIdentity(stableID: "admin-1", displayName: "EarnPlay-Admin")
        XCTAssertFalse(adminGate.confirmPairing(enteredCode: "000000", peer: childID))
        XCTAssertFalse(adminGate.isPaired)
        XCTAssertTrue(adminGate.confirmPairing(enteredCode: "123456", peer: childID))
        XCTAssertTrue(childGate.confirmPairing(enteredCode: "123456", peer: adminID))
        admin.flushPending(); child.flushPending()
        XCTAssertEqual(child.policyStore.storedVersion, 1)
        XCTAssertEqual(admin.sessionStore.allLogs.map(\.sessionId), ["s-unpaired"])
    }

    // F2: second peer cannot pair/invite while paired; first child unaffected.
    func testF2_SinglePeerEnforced() throws {
        let childA = PeerIdentity(stableID: "child-A", displayName: "EarnPlay-Child")
        let childB = PeerIdentity(stableID: "child-B", displayName: "EarnPlay-Child")
        let gate = SyncPairingGate(code: "123456")
        XCTAssertTrue(gate.confirmPairing(enteredCode: "123456", peer: childA))
        XCTAssertFalse(gate.confirmPairing(enteredCode: "123456", peer: childB),
                       "second peer must be refused while paired")
        XCTAssertEqual(gate.pairedPeer, childA)
        XCTAssertFalse(PeerAdmission.shouldInvite(livePeer: childA, pendingPeer: nil, candidate: childB, trustedPairedPeer: childA))
        XCTAssertFalse(PeerAdmission.shouldAccept(livePeer: childA, candidate: childB, trustedPairedPeer: childA))
        XCTAssertTrue(PeerAdmission.shouldAccept(livePeer: childA, candidate: childA, trustedPairedPeer: childA))
        XCTAssertTrue(PeerAdmission.shouldInvite(livePeer: nil, pendingPeer: nil, candidate: childB, trustedPairedPeer: nil))
    }

    // F3: persist failure -> no ack, outbox retained, redelivery stores once.
    func testF3_PersistFailureNoAckThenStoresOnce() throws {
        var failWrites = true
        let writer: (Data, URL) throws -> Void = { data, url in
            if failWrites { throw NSError(domain: "test", code: 1) }
            try data.write(to: url, options: [.atomic])
        }
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as"), dataWriter: writer),
                                     transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: ct)
        admin.start(); child.start()
        XCTAssertEqual(admin.sessionStore.storeResult(log("s-x")), .failed)
        try child.sendSessionLog(log("s-f3"))
        XCTAssertEqual(child.sessionQueue.pending().map(\.sessionId), ["s-f3"],
                       "failed persistence must not be acked; outbox entry retained")
        XCTAssertTrue(admin.sessionStore.allLogs.isEmpty, "unpersisted log must not be cached")
        failWrites = false
        child.flushPending()
        XCTAssertEqual(admin.sessionStore.allLogs.map(\.sessionId), ["s-f3"])
        XCTAssertTrue(child.sessionQueue.pending().isEmpty)
        let dup = try SyncMessageCodec.encode(.sessionLog(log("s-f3")))
        admin.handleReceived(dup)
        XCTAssertEqual(admin.sessionStore.allLogs.count, 1)
        XCTAssertEqual(admin.sessionStore.storeResult(log("s-f3")), .duplicate)
    }

    // F4: child snapshot publishes on policy applied / ack without manual refresh.
    func testF4_ChildSnapshotPublishes() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")), transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: ct)
        admin.start(); child.start()
        var published: [ChildSyncSnapshot] = []
        child.onSnapshotChange = { published.append($0) }
        try admin.policyQueue.enqueue(policy(version: 1, practice: 45)); admin.flushPending()
        XCTAssertEqual(child.snapshot.policyVersion, 1)
        XCTAssertEqual(child.snapshot.practiceMinutes, 45)
        XCTAssertFalse(published.isEmpty, "snapshot must be published on policy apply")
        try child.sendSessionLog(log("s-f4"))
        XCTAssertEqual(child.snapshot.pendingUploads, 0, "snapshot must publish ack removal")
    }

    // F5: admin snapshot publishes when a log arrives.
    func testF5_AdminSnapshotPublishes() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")), transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: ct)
        admin.start(); child.start()
        var published: [AdminSyncSnapshot] = []
        admin.onSnapshotChange = { published.append($0) }
        try child.sendSessionLog(log("s-f5"))
        XCTAssertEqual(admin.snapshot.storedSessionCount, 1)
        XCTAssertEqual(admin.snapshot.sessionIDs, ["s-f5"])
        XCTAssertFalse(published.isEmpty)
    }

    // F6+F7: service running independent of tab; save notifies flush, no reconnect needed.
    func testF6F7_SaveFlushesImmediatelyWhileConnected() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let adminStore = PolicyStore(directory: dir("admin-store"))
        let queue = PolicyUpdateQueue(directory: dir("aq"))
        let admin = AdminSyncService(policyQueue: queue,
                                     sessionStore: SessionLogStore(directory: dir("as")), transport: at)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: ct)
        admin.start(); child.start() // app-scope start, Policy tab only (no Sessions visit)
        var draft = Policy.defaultPolicy; draft.unlockDurations = UnlockDurations(practiceMinutes: 77, tradeMinutes: 15)
        _ = try PolicyEditorSave.save(draft: draft, adminStore: adminStore, queue: queue)
        admin.notifyPolicyEnqueued()
        XCTAssertEqual(child.policyStore.currentPolicy.unlockDurations.practiceMinutes, 77)
        XCTAssertTrue(queue.pendingUpdates().isEmpty)
    }

    // F8: dropped ack -> bounded backoff retries, delivery succeeds, no duplicates.
    func testF8_DroppedAckRetriedWithBackoff() throws {
        let retry = SyncRetryConfiguration(ackTimeout: 0.05, maxRetries: 5, backoffMultiplier: 2, maxDelay: 0.5)
        let (at, ct, _) = InMemorySyncTransport.pair()
        let dropping = AckDropper(inner: at, drops: 1)
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")),
                                     transport: dropping, retry: retry)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")),
                                     transport: ct, retry: retry)
        admin.start(); child.start()
        try child.sendSessionLog(log("s-f8"))
        XCTAssertEqual(admin.sessionStore.allLogs.count, 1)
        XCTAssertEqual(child.sessionQueue.pending().count, 1, "dropped ack leaves log queued")
        waitUntil { child.sessionQueue.pending().isEmpty }
        XCTAssertEqual(admin.sessionStore.allLogs.count, 1, "retries must not duplicate the log")
        // Admin policy side: dropped ackPolicy also retries.
        let (at2, ct2, _) = InMemorySyncTransport.pair()
        let dropping2 = AckDropper(inner: ct2, drops: 1)
        let admin2 = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq2")),
                                      sessionStore: SessionLogStore(directory: dir("as2")),
                                      transport: at2, retry: retry)
        let child2 = ChildSyncService(policyStore: PolicyStore(directory: dir("cs2")),
                                      sessionQueue: SessionLogQueue(directory: dir("cq2")),
                                      transport: dropping2, retry: retry)
        admin2.start(); child2.start()
        try admin2.policyQueue.enqueue(policy(version: 1, practice: 55)); admin2.flushPending()
        XCTAssertEqual(child2.policyStore.storedVersion, 1)
        XCTAssertEqual(admin2.policyQueue.pendingUpdates().count, 1)
        waitUntil { admin2.policyQueue.pendingUpdates().isEmpty }
    }
}
