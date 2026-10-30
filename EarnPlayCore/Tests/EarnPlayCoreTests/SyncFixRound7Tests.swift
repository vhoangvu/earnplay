import Foundation
import XCTest
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif
@testable import EarnPlayCore

/// T4.6 fix round 7 (issue #23): item 1 — a trusted invitation that
/// fails before .connected must retry with backoff (no new discovery
/// event needed); item 2 was REFUTED by construction trace (see the
/// fix-round-7 log entry) and gets a service-level regression test
/// proving save-while-connected flushes through the real wiring.
final class SyncFixRound7Tests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFixRound7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ n: String) -> URL { directory.appendingPathComponent(n, isDirectory: true) }
    private func waitUntil(_ timeout: TimeInterval = 6, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; Thread.sleep(forTimeInterval: 0.01) }
        XCTFail("condition not met within \(timeout)s")
    }

    private let admin = PeerIdentity(stableID: "admin-r7", displayName: "EarnPlay-Admin")
    private let child = PeerIdentity(stableID: "child-r7", displayName: "EarnPlay-Child")

#if canImport(MultipeerConnectivity)
    private func makeSession() -> MCSession {
        MCSession(peer: MCPeerID(displayName: "probe"), securityIdentity: nil, encryptionPreference: .required)
    }
    /// Browser transport with a persisted (trusted) pairing to the
    /// child, started and told the child was discovered — the
    /// relaunch state of item 1. The child MCPeerID is returned.
    private func discoveredTrustedBrowser(gate: SyncPairingGate) -> (MultipeerSyncTransport, MCPeerID) {
        let transport = MultipeerSyncTransport(role: .browser, displayName: "EarnPlay-Admin", pairing: gate)
        transport.start()
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "EarnPlay-Admin"),
                                             serviceType: MultipeerSyncTransport.serviceType)
        let childPeer = MCPeerID(displayName: child.displayName)
        transport.browser(browser, foundPeer: childPeer,
                          withDiscoveryInfo: ["sid": child.stableID, "dn": child.displayName])
        return (transport, childPeer)
    }

    // Item 1: after relaunch with a persisted pairing, an invitation
    // that fails BEFORE .connected must be retried with backoff and
    // without another discovery event. (Once a retry connects, the
    // handshake opens the data plane and SyncService.flushPending
    // drains queued data — that drain is covered by SyncServiceTests;
    // the missing link proved here is the automatic re-invitation.)
    func testR7_1_TrustedPreConnectionFailureRetriesWithBackoff() {
        let gate = SyncPairingGate(code: "111111", identity: admin)
        XCTAssertTrue(gate.markPaired(peer: child))
        let (transport, childPeer) = discoveredTrustedBrowser(gate: gate)
        XCTAssertNotNil(transport.outstandingInvitationHandleForTesting,
                        "discovery of the trusted peer must issue an owned invitation")
        // The invitation fails before any .connected callback.
        transport.session(makeSession(), peer: childPeer, didChange: .notConnected)
        XCTAssertNil(transport.outstandingInvitationHandleForTesting,
                     "the failed invitation's ownership must be consumed by its failure")
        // Backoff retry (first attempt ~1s) re-invites on its own.
        waitUntil { transport.outstandingInvitationHandleForTesting != nil }
        transport.stop()
        XCTAssertNil(transport.outstandingInvitationHandleForTesting, "stop() must clear invitation ownership")
    }

    // Item 1 (isolation): a duplicate claimant's disconnect must not
    // consume the genuine peer's outstanding invitation (round 6/7).
    func testR7_1_DuplicateDisconnectKeepsOutstandingInvitation() {
        let gate = SyncPairingGate(code: "111111", identity: admin)
        XCTAssertTrue(gate.markPaired(peer: child))
        let (transport, childPeer) = discoveredTrustedBrowser(gate: gate)
        let owned = transport.outstandingInvitationHandleForTesting
        XCTAssertNotNil(owned)
        let duplicate = MCPeerID(displayName: child.displayName)
        transport.session(makeSession(), peer: duplicate, didChange: .notConnected)
        XCTAssertEqual(transport.outstandingInvitationHandleForTesting, owned,
                       "a duplicate handle's failure must not consume the genuine invitation")
        transport.session(makeSession(), peer: childPeer, didChange: .notConnected)
        XCTAssertNil(transport.outstandingInvitationHandleForTesting)
        transport.stop()
    }

    // Item 1 (scope): an UNTRUSTED invitation failure is cleaned up
    // but never auto-retried — retry is persisted-pairing only.
    func testR7_1_UntrustedPreConnectionFailureIsNotRetried() {
        let gate = SyncPairingGate(code: "111111", identity: admin)
        XCTAssertTrue(gate.preparePairing(enteredCode: "654321"))
        let (transport, childPeer) = discoveredTrustedBrowser(gate: gate)
        XCTAssertNotNil(transport.outstandingInvitationHandleForTesting)
        transport.session(makeSession(), peer: childPeer, didChange: .notConnected)
        XCTAssertNil(transport.outstandingInvitationHandleForTesting)
        Thread.sleep(forTimeInterval: 2.5) // beyond the first backoff delay
        XCTAssertNil(transport.outstandingInvitationHandleForTesting,
                     "untrusted invitations must not be retried automatically")
        transport.stop()
    }
#endif

    // Item 2 (refuted — regression): the editor and the app-scope
    // service own DISTINCT PolicyUpdateQueue instances over the same
    // directory (PolicyEditorView.swift:18 vs EarnPlayAdminApp.swift:8).
    // Enqueue through the editor's instance, then fire exactly what
    // PolicyEditorView.save() fires (onPolicySaved ->
    // notifyPolicyEnqueued) while connected: the update must reach
    // the child with no second connection/flush event.
    func testR7_2_SaveWhileConnectedFlushesViaNotifyPolicyEnqueued() throws {
        let (at, ct, _) = InMemorySyncTransport.pair()
        let queueDir = dir("admin-queue")
        let editorQueue = PolicyUpdateQueue(directory: queueDir)
        let service = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: queueDir),
                                       sessionStore: SessionLogStore(directory: dir("admin-sessions")),
                                       transport: at)
        let childService = ChildSyncService(policyStore: PolicyStore(directory: dir("child-store")),
                                            sessionQueue: SessionLogQueue(directory: dir("child-queue")),
                                            transport: ct)
        service.start(); childService.start()
        var policy = Policy.defaultPolicy.withVersion(1)
        policy.unlockDurations = UnlockDurations(practiceMinutes: 45, tradeMinutes: 15)
        try editorQueue.enqueue(policy)
        service.notifyPolicyEnqueued()
        XCTAssertEqual(childService.policyStore.storedVersion, 1,
                       "save-while-connected must deliver without another event")
        XCTAssertTrue(service.policyQueue.pendingUpdates().isEmpty,
                      "the acked update must leave the service queue")
    }
}
