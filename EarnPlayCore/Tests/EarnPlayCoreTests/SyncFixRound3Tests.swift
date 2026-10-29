import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.6 fix round 3 (issue #23): regression tests, one per finding.
final class SyncFixRound3Tests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFixRound3-\(UUID().uuidString)", isDirectory: true)
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
    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; Thread.sleep(forTimeInterval: 0.01) }
        XCTFail("condition not met within \(timeout)s")
    }

    /// Transport wrapper that throws on the first N sends, then works.
    private final class FlakySendTransport: SyncTransport, @unchecked Sendable {
        let inner: InMemorySyncTransport
        var failuresRemaining: Int
        var onReceive: ((Data) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        init(inner: InMemorySyncTransport, failures: Int) {
            self.inner = inner; self.failuresRemaining = failures
        }
        var isConnected: Bool { inner.isConnected }
        func start() {
            inner.onReceive = { [weak self] in self?.onReceive?($0) }
            inner.onConnectionChange = { [weak self] in self?.onConnectionChange?($0) }
            inner.start()
        }
        func stop() { inner.stop() }
        func send(_ data: Data) throws {
            if failuresRemaining > 0 { failuresRemaining -= 1; throw SyncTransportError.notConnected }
            try inner.send(data)
        }
    }

    private let admin1 = PeerIdentity(stableID: "admin-stable-1", displayName: "EarnPlay-Admin")
    private let admin2 = PeerIdentity(stableID: "admin-stable-2", displayName: "EarnPlay-Admin")
    private let childPeer = PeerIdentity(stableID: "child-stable-1", displayName: "EarnPlay-Child")

    // F1: same displayName, different stable identity is a different peer.
    func testF1_SecondAdminSameDisplayNameRefused() throws {
        let gate = SyncPairingGate(code: "123456")
        XCTAssertTrue(gate.confirmPairing(enteredCode: "123456", peer: admin1))
        XCTAssertEqual(gate.pairedPeer, admin1)
        XCTAssertFalse(gate.confirmPairing(enteredCode: "123456", peer: admin2),
                       "second admin with same displayName but different identity must be refused")
        XCTAssertFalse(gate.markPaired(peer: admin2))
        XCTAssertTrue(gate.isPaired(to: admin1))
        XCTAssertFalse(gate.isPaired(to: admin2))
        XCTAssertFalse(PeerAdmission.shouldAccept(livePeer: nil, candidate: admin2, trustedPairedPeer: admin1))
        XCTAssertTrue(PeerAdmission.shouldAccept(livePeer: nil, candidate: admin1, trustedPairedPeer: admin1))
    }

    // F2: invitation carries identity only, never the secret; mutual
    // challenge-response requires knowledge of the peer's code that
    // was only ever shown on that peer's screen.
    func testF2_NoSecretInInvitationMutualChallengeResponse() throws {
        let invitation = PairingInvitation(inviter: admin1)
        let data = try PairingInvitation.encode(invitation)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("654321"), "invitation must not contain the child's code")
        XCTAssertFalse(text.contains("111111"), "invitation must not contain the admin's code")
        XCTAssertEqual(try PairingInvitation.decode(data), invitation)

        let adminGate = SyncPairingGate(code: "111111", identity: admin1) // admin's own code, shown on admin
        let childGate = SyncPairingGate(code: "654321", identity: childPeer) // child's own code, shown on child
        XCTAssertTrue(adminGate.preparePairing(enteredCode: "654321")) // admin user entered child's code
        XCTAssertTrue(childGate.preparePairing(enteredCode: "111111")) // child user entered admin's code

        // Child proves to admin it knows the admin's code (entered by child user).
        let adminChallenge = "nonce-admin"
        let childResponse = try XCTUnwrap(childGate.challengeResponse(toChallenge: adminChallenge, verifier: admin1))
        XCTAssertTrue(adminGate.verifyChallengeResponse(childResponse, toChallenge: adminChallenge, prover: childPeer))
        // Admin proves to child it knows the child's code (entered by admin user).
        let childChallenge = "nonce-child"
        let adminResponse = try XCTUnwrap(adminGate.challengeResponse(toChallenge: childChallenge, verifier: childPeer))
        XCTAssertTrue(childGate.verifyChallengeResponse(adminResponse, toChallenge: childChallenge, prover: admin1))

        // Rogue advertiser: accepted an invitation but never saw the
        // admin's code out-of-band, so it cannot answer the challenge.
        let rogueGate = SyncPairingGate(code: "999999")
        let rogueResponse = rogueGate.challengeResponse(toChallenge: adminChallenge, verifier: admin1)
        if let rogueResponse {
            XCTAssertFalse(adminGate.verifyChallengeResponse(rogueResponse, toChallenge: adminChallenge, prover: admin2))
        }
        XCTAssertFalse(adminGate.isPaired(to: admin2), "rogue gains no paired state")
        // Wrong-code response never verifies.
        let wrongGate = SyncPairingGate(code: "000000")
        _ = wrongGate.preparePairing(enteredCode: "000000")
        let wrong = try XCTUnwrap(wrongGate.challengeResponse(toChallenge: adminChallenge, verifier: admin1))
        XCTAssertFalse(adminGate.verifyChallengeResponse(wrong, toChallenge: adminChallenge, prover: childPeer))
    }

    // F5: invitations are deferred until a code is supplied; Pair
    // retry returns a failed peer to invitation candidates.
    func testF5_DeferredInvitationAndRetryClearsFailure() throws {
        XCTAssertFalse(PeerAdmission.shouldInviteNow(hasPeerCode: false, livePeer: nil,
                                                     pendingPeer: nil, candidate: childPeer, trustedPairedPeer: nil))
        XCTAssertTrue(PeerAdmission.shouldInviteNow(hasPeerCode: true, livePeer: nil,
                                                    pendingPeer: nil, candidate: childPeer, trustedPairedPeer: nil))
        var book = DiscoveredPeerBook()
        book.retain(childPeer)
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: false, livePeer: nil, trustedPairedPeer: nil), [])
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil), [childPeer])
        book.markInvited(childPeer); book.markFailed(childPeer)
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil), [])
        XCTAssertEqual(book.retryCandidates(), [childPeer], "Pair retry must clear failed state")
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil), [childPeer])
    }

    // F6: trusted paired peer may be reinvited after a drop; others may not.
    func testF6_TrustedPeerReconnectionAllowed() throws {
        XCTAssertTrue(PeerAdmission.shouldInvite(livePeer: nil, pendingPeer: nil,
                                                 candidate: childPeer, trustedPairedPeer: childPeer),
                      "trusted paired peer must be reinvitable after disconnect")
        let other = PeerIdentity(stableID: "child-stable-2", displayName: "EarnPlay-Child")
        XCTAssertFalse(PeerAdmission.shouldInvite(livePeer: nil, pendingPeer: nil,
                                                  candidate: other, trustedPairedPeer: childPeer))
        XCTAssertFalse(PeerAdmission.shouldInvite(livePeer: childPeer, pendingPeer: nil,
                                                  candidate: other, trustedPairedPeer: childPeer),
                       "a live connection still blocks other peers")
        XCTAssertTrue(PeerAdmission.shouldInviteNow(hasPeerCode: false, livePeer: nil, pendingPeer: nil,
                                                    candidate: childPeer, trustedPairedPeer: childPeer),
                      "trusted reconnection needs no code re-entry")
    }

    // F7+F8: retries continue past maxRetries and after transient
    // send failures, until acked, with no manual flush.
    func testF7F8_RetriesContinuePastMaxAndAfterTransientFailure() throws {
        let retry = SyncRetryConfiguration(ackTimeout: 0.05, maxRetries: 2, backoffMultiplier: 1, maxDelay: 0.05)
        let (at, ct, _) = InMemorySyncTransport.pair()
        // 6 transient failures > maxRetries(2): pre-fix delivery stops permanently.
        let flaky = FlakySendTransport(inner: ct, failures: 6)
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")), transport: at, retry: retry)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: flaky, retry: retry)
        admin.start(); child.start()
        try child.sendSessionLog(log("s-f78"))
        waitUntil { admin.sessionStore.allLogs.map(\.sessionId) == ["s-f78"] }
        waitUntil { child.sessionQueue.pending().isEmpty }
        XCTAssertEqual(admin.sessionStore.allLogs.count, 1)
    }

    // F9 (policy side): retry is cancelled only after removal succeeds.
    func testF9_RetryCancelledOnlyAfterRemovalSucceeds() throws {
        var failWrites = false
        let writer: (Data, URL) throws -> Void = { data, url in
            if failWrites { throw NSError(domain: "test", code: 1) }
            try data.write(to: url, options: [.atomic])
        }
        let retry = SyncRetryConfiguration(ackTimeout: 0.05, maxRetries: 5, backoffMultiplier: 1, maxDelay: 0.05)
        let (at, ct, _) = InMemorySyncTransport.pair()
        let queue = PolicyUpdateQueue(directory: dir("aq"), dataWriter: writer)
        let admin = AdminSyncService(policyQueue: queue,
                                     sessionStore: SessionLogStore(directory: dir("as")), transport: at, retry: retry)
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")), transport: ct, retry: retry)
        admin.start(); child.start()
        try queue.enqueue(policy(version: 1, practice: 45))
        failWrites = true // removal persist will fail when the ack arrives
        admin.flushPending() // child applies + acks synchronously; removal fails
        XCTAssertEqual(child.policyStore.storedVersion, 1)
        XCTAssertEqual(queue.pendingUpdates().count, 1, "failed removal must keep the update queued")
        failWrites = false // storage recovers; retained retry must redeliver + clear
        waitUntil { queue.pendingUpdates().isEmpty }
    }
}
