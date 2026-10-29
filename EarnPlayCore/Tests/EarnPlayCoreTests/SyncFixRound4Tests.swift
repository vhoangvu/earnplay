import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.6 fix round 4 (issue #23): H1, H2, H3, H4, M6, M7.
final class SyncFixRound4Tests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFixRound4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "SyncFixRound4-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        defaults?.removePersistentDomain(forName: suiteName)
        directory = nil; defaults = nil; suiteName = nil
    }
    private func dir(_ n: String) -> URL { directory.appendingPathComponent(n, isDirectory: true) }
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

    private let admin1 = PeerIdentity(stableID: "admin-stable-1", displayName: "EarnPlay-Admin")
    private let admin2 = PeerIdentity(stableID: "admin-stable-2", displayName: "EarnPlay-Admin")
    private let childPeer = PeerIdentity(stableID: "child-stable-1", displayName: "EarnPlay-Child")
    private let otherChild = PeerIdentity(stableID: "child-stable-2", displayName: "EarnPlay-Child")

    // H2: two peers sharing one displayName resolve to distinct
    // identities by stableID; a rediscovered peer (new handle, same
    // stableID) resolves to the same identity; send filtering by the
    // paired stableID targets only the paired peer.
    func testH2_SameDisplayNameDistinctStableIdentities() {
        let resolver = PeerIdentityResolver()
        resolver.bind(admin1, handle: "handle-A1")
        resolver.bind(admin2, handle: "handle-A2")
        XCTAssertEqual(resolver.identity(forHandle: "handle-A1", fallbackDisplayName: "EarnPlay-Admin"), admin1)
        XCTAssertEqual(resolver.identity(forHandle: "handle-A2", fallbackDisplayName: "EarnPlay-Admin"), admin2)
        // Rediscovery: new handle, same stable identity (learned from sid).
        resolver.bind(admin1, handle: "handle-A1-rediscovered")
        XCTAssertEqual(resolver.identity(forHandle: "handle-A1-rediscovered", fallbackDisplayName: "EarnPlay-Admin"), admin1)
        XCTAssertEqual(resolver.handle(forStableID: admin1.stableID), "handle-A1-rediscovered",
                       "latest handle for the stable identity must win for sending")
        // Unbound handles never share a synthetic identity.
        let u1 = resolver.identity(forHandle: "handle-X", fallbackDisplayName: "EarnPlay-Admin")
        let u2 = resolver.identity(forHandle: "handle-Y", fallbackDisplayName: "EarnPlay-Admin")
        XCTAssertNotEqual(u1, u2, "unbound peers must not collide on a display-name identity")
        // Send filtering targets the paired stable identity only.
        let connected = [resolver.identity(forHandle: "handle-A1-rediscovered", fallbackDisplayName: "EarnPlay-Admin"),
                         resolver.identity(forHandle: "handle-A2", fallbackDisplayName: "EarnPlay-Admin")]
        XCTAssertEqual(connected.filter { $0 == admin1 }, [admin1])
    }

    // H1: concurrent bind/resolve stress must not race or corrupt,
    // and concurrent gate access must stay consistent.
    func testH1_ConcurrentResolverAndGateAccess() {
        let resolver = PeerIdentityResolver()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let peer = i % 2 == 0 ? admin1 : admin2
            resolver.bind(peer, handle: "h-\(i % 8)")
            _ = resolver.identity(forHandle: "h-\(i % 8)", fallbackDisplayName: "EarnPlay-Admin")
            _ = resolver.identity(forStableID: peer.stableID)
        }
        // Every handle resolves to one of the two real identities, never a mix.
        for h in 0..<8 {
            let resolved = resolver.identity(forHandle: "h-\(h)", fallbackDisplayName: "EarnPlay-Admin")
            XCTAssertTrue(resolved == admin1 || resolved == admin2)
        }
        let gate = SyncPairingGate(code: "111111", identity: admin1)
        _ = gate.preparePairing(enteredCode: "654321")
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            _ = gate.isPaired; _ = gate.pairedPeer; _ = gate.hasEnteredPeerCode
            _ = gate.challengeResponse(toChallenge: "n", verifier: childPeer)
        }
        XCTAssertFalse(gate.isPaired)
    }

    // H3: a trusted reconnect must prove possession of the pairing
    // secret established at pairing time. A spoofed stableID without
    // the secret cannot produce a valid proof; the secret is neither
    // the user-entered code nor the broadcast stableID.
    func testH3_TrustedProofRequiresPairingSecret() {
        let adminGate = SyncPairingGate(code: "111111", identity: admin1)
        let childGate = SyncPairingGate(code: "654321", identity: childPeer)
        _ = adminGate.preparePairing(enteredCode: "654321")
        _ = childGate.preparePairing(enteredCode: "111111")
        // Complete mutual pairing (M6 path) and establish the secret.
        XCTAssertTrue(adminGate.beginProvisional(peer: childPeer))
        XCTAssertTrue(childGate.beginProvisional(peer: admin1))
        XCTAssertFalse(adminGate.recordRemoteVerified(peer: childPeer))
        XCTAssertTrue(adminGate.recordPeerVerifiedLocal(peer: childPeer))
        XCTAssertFalse(childGate.recordRemoteVerified(peer: admin1))
        XCTAssertTrue(childGate.recordPeerVerifiedLocal(peer: admin1))
        XCTAssertTrue(adminGate.isPaired(to: childPeer))
        let secret = adminGate.takeSecretToShare(for: childPeer)
        let shared = try! XCTUnwrap(secret, "pairing must establish a secret to share")
        childGate.adoptSharedSecret(shared, from: admin1)
        XCTAssertEqual(adminGate.pairingSecret(for: childPeer), shared)
        XCTAssertEqual(childGate.pairingSecret(for: admin1), shared)
        XCTAssertNotEqual(shared, "111111"); XCTAssertNotEqual(shared, "654321")
        XCTAssertNotEqual(shared, admin1.stableID); XCTAssertNotEqual(shared, childPeer.stableID)
        // Trusted proof round-trip.
        let nonce = "trusted-nonce-1"
        let proof = try! XCTUnwrap(childGate.trustedResponse(toChallenge: nonce, peer: admin1))
        XCTAssertTrue(adminGate.verifyTrustedResponse(proof, toChallenge: nonce, prover: childPeer))
        // Spoofed stableID, no secret: no proof, verification fails.
        let spoofer = SyncPairingGate(code: "654321", identity: childPeer)
        XCTAssertNil(spoofer.trustedResponse(toChallenge: nonce, peer: admin1),
                     "a device that only copied the broadcast stableID has no secret and cannot prove")
        let forged = PairingAuthenticator.trustedResponse(challenge: nonce, prover: childPeer,
                                                          verifier: admin1, secret: childPeer.stableID)
        XCTAssertFalse(adminGate.verifyTrustedResponse(forged, toChallenge: nonce, prover: childPeer))
        // No secret for a peer -> gate must not claim trusted proof is possible.
        let fresh = SyncPairingGate(code: "111111", identity: admin2)
        XCTAssertNil(fresh.trustedResponse(toChallenge: nonce, peer: childPeer))
    }

    // H4: rediscovery clears failed/invited state for the trusted
    // candidate; backoff grows and caps; other identities stay
    // blocked while a trusted peer exists.
    func testH4_RediscoveryClearsFailedAndBackoff() {
        var book = DiscoveredPeerBook()
        book.retain(childPeer)
        book.markInvited(childPeer); book.markFailed(childPeer)
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: false, livePeer: nil, trustedPairedPeer: childPeer), [])
        book.retain(childPeer) // rediscovery
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: false, livePeer: nil, trustedPairedPeer: childPeer), [childPeer],
                       "rediscovery must make the trusted peer invitable again")
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: childPeer), [childPeer])
        // A different identity remains blocked by the trusted peer.
        book.retain(otherChild)
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: childPeer), [childPeer])
        // Backoff: grows, capped, always positive.
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(forAttempt: 0), 1, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(forAttempt: 1), 2, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(forAttempt: 2), 4, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(forAttempt: 10), 30, accuracy: 0.001)
    }

    // M6: admin mistypes the child's code; child enters correctly.
    // Neither side may end paired; both reset to a retryable state
    // and corrected codes complete pairing without starting over.
    func testM6_MistypedCodeBothSidesRecoverable() throws {
        let adminGate = SyncPairingGate(code: "111111", identity: admin1)
        let childGate = SyncPairingGate(code: "654321", identity: childPeer)
        XCTAssertTrue(adminGate.preparePairing(enteredCode: "000000")) // mistyped child code
        XCTAssertTrue(childGate.preparePairing(enteredCode: "111111")) // correct admin code
        XCTAssertTrue(adminGate.beginProvisional(peer: childPeer))
        XCTAssertTrue(childGate.beginProvisional(peer: admin1))
        // Child's response verifies on admin (child knew admin's code).
        let adminNonce = "n-admin"
        let childResp = try XCTUnwrap(childGate.challengeResponse(toChallenge: adminNonce, verifier: admin1))
        XCTAssertTrue(adminGate.verifyChallengeResponse(childResp, toChallenge: adminNonce, prover: childPeer))
        XCTAssertFalse(adminGate.recordRemoteVerified(peer: childPeer),
                       "one-sided verification must stay provisional, not paired")
        XCTAssertFalse(adminGate.isPaired)
        // Admin's response fails on child (admin mistyped child's code).
        let childNonce = "n-child"
        let adminResp = try XCTUnwrap(adminGate.challengeResponse(toChallenge: childNonce, verifier: childPeer))
        XCTAssertFalse(childGate.verifyChallengeResponse(adminResp, toChallenge: childNonce, prover: admin1))
        // Failure propagates: both sides reset the attempt.
        childGate.failProvisionalAttempt(peer: admin1)
        adminGate.failProvisionalAttempt(peer: childPeer)
        XCTAssertFalse(adminGate.isPaired); XCTAssertFalse(childGate.isPaired)
        XCTAssertNil(adminGate.provisionalPeer); XCTAssertNil(childGate.provisionalPeer)
        // Corrected codes are accepted (pre-fix the paired admin refused).
        XCTAssertTrue(adminGate.preparePairing(enteredCode: "654321"))
        XCTAssertTrue(childGate.preparePairing(enteredCode: "111111"))
        XCTAssertTrue(adminGate.beginProvisional(peer: childPeer))
        XCTAssertTrue(childGate.beginProvisional(peer: admin1))
        let r1 = try XCTUnwrap(childGate.challengeResponse(toChallenge: "m1", verifier: admin1))
        XCTAssertTrue(adminGate.verifyChallengeResponse(r1, toChallenge: "m1", prover: childPeer))
        _ = adminGate.recordRemoteVerified(peer: childPeer)
        _ = adminGate.recordPeerVerifiedLocal(peer: childPeer)
        let r2 = try XCTUnwrap(adminGate.challengeResponse(toChallenge: "m2", verifier: childPeer))
        XCTAssertTrue(childGate.verifyChallengeResponse(r2, toChallenge: "m2", prover: admin1))
        _ = childGate.recordRemoteVerified(peer: admin1)
        _ = childGate.recordPeerVerifiedLocal(peer: admin1)
        XCTAssertTrue(adminGate.isPaired(to: childPeer))
        XCTAssertTrue(childGate.isPaired(to: admin1))
    }

    // M7: identity, code, paired peer and secret survive a relaunch
    // (new gate instance, same store); unpair clears pairing+secret.
    func testM7_PersistedIdentityPairingAndSecret() {
        let key = "earnplay.pairing.test.v1"
        let gate1 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        let identity1 = gate1.localIdentity; let code1 = gate1.localCode
        XCTAssertTrue(gate1.beginProvisional(peer: admin1))
        _ = gate1.recordRemoteVerified(peer: admin1)
        XCTAssertTrue(gate1.recordPeerVerifiedLocal(peer: admin1))
        let secret = gate1.takeSecretToShare(for: admin1)
        XCTAssertNotNil(secret)
        // Relaunch: a fresh instance from the same store is the same device.
        let gate2 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        XCTAssertEqual(gate2.localIdentity, identity1, "relaunch must keep the installation identity")
        XCTAssertEqual(gate2.localCode, code1, "relaunch must keep the pairing code")
        XCTAssertTrue(gate2.isPaired(to: admin1), "relaunch must retain the paired peer")
        XCTAssertEqual(gate2.pairingSecret(for: admin1), secret, "relaunch must retain the pairing secret")
        XCTAssertNotNil(gate2.trustedResponse(toChallenge: "post-relaunch", peer: admin1),
                        "post-relaunch trusted proof must work from the persisted secret")
        // Reset/Unpair clears pairing and secret but keeps identity.
        gate2.unpair()
        XCTAssertFalse(gate2.isPaired)
        XCTAssertNil(gate2.pairingSecret(for: admin1))
        let gate3 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        XCTAssertEqual(gate3.localIdentity, identity1)
        XCTAssertFalse(gate3.isPaired)
    }

    // M7 one-sided relaunch: A (child) relaunches while B (admin)
    // keeps running; A is the same identity, still paired, and its
    // persisted outbox resumes delivery without re-pairing.
    func testM7_OneSidedRelaunchResumesQueuedDelivery() throws {
        let key = "earnplay.pairing.test.relaunch"
        let childGateV1 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        let adminGate = SyncPairingGate(code: "111111", identity: admin1)
        _ = adminGate.markPaired(peer: childGateV1.localIdentity)
        _ = childGateV1.beginProvisional(peer: admin1)
        _ = childGateV1.recordRemoteVerified(peer: admin1)
        _ = childGateV1.recordPeerVerifiedLocal(peer: admin1)
        XCTAssertTrue(childGateV1.isPaired(to: admin1))
        // Child queues a log while offline (persisted outbox on disk).
        let queueDir = dir("cq"); let storeDir = dir("cs")
        let offlineQueue = SessionLogQueue(directory: queueDir)
        try offlineQueue.enqueue(log("s-relaunch"))
        // Child app relaunches: new gate + new service, same stores.
        let childGateV2 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        XCTAssertEqual(childGateV2.localIdentity, childGateV1.localIdentity)
        XCTAssertTrue(childGateV2.isPaired(to: admin1))
        let (at, ct, _) = InMemorySyncTransport.pair()
        let admin = AdminSyncService(policyQueue: PolicyUpdateQueue(directory: dir("aq")),
                                     sessionStore: SessionLogStore(directory: dir("as")),
                                     transport: at, pairing: adminGate)
        let child = ChildSyncService(policyStore: PolicyStore(directory: storeDir),
                                     sessionQueue: SessionLogQueue(directory: queueDir),
                                     transport: ct, pairing: childGateV2)
        admin.start(); child.start()
        child.flushPending()
        XCTAssertEqual(admin.sessionStore.allLogs.map(\.sessionId), ["s-relaunch"],
                       "queued delivery must resume after a one-sided relaunch")
        waitUntil { child.sessionQueue.pending().isEmpty }
    }
}
