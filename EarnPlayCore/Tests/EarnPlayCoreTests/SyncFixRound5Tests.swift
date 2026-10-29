import Foundation
import XCTest
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif
@testable import EarnPlayCore

/// T4.6 fix round 5 (issue #23): regression tests, one per item.
final class SyncFixRound5Tests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFixRound5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "SyncFixRound5-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        defaults?.removePersistentDomain(forName: suiteName)
        directory = nil; defaults = nil; suiteName = nil
    }
    private func dir(_ n: String) -> URL { directory.appendingPathComponent(n, isDirectory: true) }
    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; Thread.sleep(forTimeInterval: 0.01) }
        XCTFail("condition not met within \(timeout)s")
    }

    // Stable IDs chosen so the claimant sorts before the victim: a
    // converged-secret tiebreak must never let an unauthenticated
    // claimant displace an established secret.
    private let victim = PeerIdentity(stableID: "victim-z", displayName: "EarnPlay-Child")
    private let claimant = PeerIdentity(stableID: "peer-a", displayName: "EarnPlay-Admin")

    // Item 1: pairing already established + persisted (trusted state,
    // no fresh pairing on this connection). A replacement secret
    // arriving now must be rejected; the original secret must still
    // answer trusted challenges.
    func testR5_1_SecretReplacementDuringUnauthenticatedReconnectRejected() {
        let original = String(repeating: "ab", count: 32)
        let restored = SyncPairingGate(restoring: PersistedPairingState(
            localIdentity: victim, localCode: "654321",
            pairedPeer: claimant, pairingSecrets: [claimant.stableID: original]))
        XCTAssertTrue(restored.isPaired(to: claimant))
        XCTAssertEqual(restored.pairingSecret(for: claimant), original)
        // Unauthenticated claimant sends a replacement secret.
        restored.adoptSharedSecret(String(repeating: "cd", count: 32), from: claimant)
        XCTAssertEqual(restored.pairingSecret(for: claimant), original,
                       "unauthenticated reconnection must not replace the retained secret")
        let nonce = "reconnect-nonce"
        let proof = PairingAuthenticator.trustedResponse(challenge: nonce, prover: claimant,
                                                         verifier: victim, secret: original)
        XCTAssertTrue(restored.verifyTrustedResponse(proof, toChallenge: nonce, prover: claimant),
                      "the original secret must still answer challenges")
    }

    // Item 1 (fresh pairing still works): after a fresh mutual
    // promotion on this connection, the shared secret is adopted
    // and both sides converge on one secret.
    func testR5_1_FreshMutualPairingStillEstablishesSecret() {
        let a = SyncPairingGate(code: "111111", identity: PeerIdentity(stableID: "a-side", displayName: "A"))
        let b = SyncPairingGate(code: "222222", identity: PeerIdentity(stableID: "b-side", displayName: "B"))
        let aPeer = b.localIdentity, bPeer = a.localIdentity
        _ = a.beginProvisional(peer: aPeer); _ = b.beginProvisional(peer: bPeer)
        _ = a.recordRemoteVerified(peer: aPeer); XCTAssertTrue(a.recordPeerVerifiedLocal(peer: aPeer))
        _ = b.recordRemoteVerified(peer: bPeer); XCTAssertTrue(b.recordPeerVerifiedLocal(peer: bPeer))
        let shared = try! XCTUnwrap(a.takeSecretToShare(for: aPeer))
        b.adoptSharedSecret(shared, from: bPeer)
        XCTAssertEqual(b.pairingSecret(for: bPeer), shared)
    }

#if canImport(MultipeerConnectivity)
    private func handshakeData(_ json: String) -> Data {
        var d = Data("EarnPlayPairing/1:".utf8)
        d.append(Data(json.utf8))
        return d
    }
    private func peerJSON(_ p: PeerIdentity) -> String {
        "{\"stableID\":\"\(p.stableID)\",\"displayName\":\"\(p.displayName)\"}"
    }

    // Probe: hand-crafted handshake JSON must decode (guards the two
    // transport-driven tests below against a wrong wire shape).
    func testR5_ProbeHandshakeJSONDecodes() {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var failures: [PeerIdentity] = []
        transport.onPairingFailure = { failures.append($0) }
        let session = MCSession(peer: MCPeerID(displayName: "probe"), securityIdentity: nil, encryptionPreference: .required)
        let mcPeer = MCPeerID(displayName: claimant.displayName)
        let json = "{\"pairingFailed\":{\"from\":\(peerJSON(claimant))}}"
        transport.session(session, didReceive: handshakeData(json), fromPeer: mcPeer)
        XCTAssertEqual(failures, [claimant], "crafted handshake JSON must reach the pairingFailed handler")
    }

    // Item 4: unpair must reject and clear a pending invitation so the
    // next invitation is accepted without an app restart.
    func testR5_4_UnpairClearsPendingInvitation() {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var requested: [PeerIdentity] = []
        transport.onPairingRequest = { requested.append($0) }
        let advertiser = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "EarnPlay-Child"),
                                                   discoveryInfo: nil, serviceType: MultipeerSyncTransport.serviceType)
        let mcPeer = MCPeerID(displayName: claimant.displayName)
        let context = try! PairingInvitation.encode(PairingInvitation(inviter: claimant))
        var handlerResults: [Bool] = []
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: mcPeer, withContext: context) { ok, _ in
            handlerResults.append(ok)
        }
        XCTAssertEqual(requested, [claimant])
        XCTAssertTrue(transport.hasPendingPairingRequest)
        transport.unpair()
        XCTAssertEqual(handlerResults, [false], "unpair must reject the pending invitation")
        XCTAssertFalse(transport.hasPendingPairingRequest, "unpair must clear the pending invitation")
        // Next invitation is accepted for user confirmation (no restart).
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: mcPeer, withContext: context) { ok, _ in
            handlerResults.append(ok)
        }
        XCTAssertEqual(requested, [claimant, claimant], "a later invitation must surface after unpair")
        XCTAssertTrue(transport.hasPendingPairingRequest)
    }

    // Item 6: a challenge arrives while no code is entered (the state
    // a code mismatch leaves the child in). The transport must
    // restore a manual pairing request so the user can enter a
    // corrected code and accept.
    func testR5_6_ChallengeWithoutCodeRestoresManualRequest() {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var requested: [PeerIdentity] = []
        transport.onPairingRequest = { requested.append($0) }
        let session = MCSession(peer: MCPeerID(displayName: "probe"), securityIdentity: nil, encryptionPreference: .required)
        let mcPeer = MCPeerID(displayName: claimant.displayName)
        let json = "{\"challenge\":{\"nonce\":\"retry-nonce\",\"from\":\(peerJSON(claimant))}}"
        transport.session(session, didReceive: handshakeData(json), fromPeer: mcPeer)
        XCTAssertEqual(requested, [claimant],
                       "a challenge the child cannot answer yet must restore its manual request")
        XCTAssertTrue(transport.hasPendingPairingRequest)
    }
#endif

    // Item 2: authorization is bound to the authenticated session
    // instance in both directions. A second instance claiming the
    // connected identity is authorized for nothing: no policy/ack
    // acceptance (receive) and no session-log upload inclusion (send).
    func testR5_2_DuplicateIdentityGetsNoDataPlaneAuthorization() {
        let paired = PeerIdentity(stableID: "admin-stable-1", displayName: "EarnPlay-Admin")
        var binding = DataPlaneBinding()
        XCTAssertFalse(binding.authorizes(peer: paired, sessionHandle: "handle-genuine"))
        binding.bind(peer: paired, sessionHandle: "handle-genuine", viaFreshPairing: false)
        XCTAssertTrue(binding.authorizes(peer: paired, sessionHandle: "handle-genuine"))
        XCTAssertFalse(binding.authorizes(peer: paired, sessionHandle: "handle-duplicate"),
                       "duplicate claimant must not be authorized by identity alone")
        // Both filters, as the transport applies them:
        let connected = ["handle-genuine", "handle-duplicate"]
        XCTAssertEqual(connected.filter { binding.authorizes(peer: paired, sessionHandle: $0) },
                       ["handle-genuine"], "send path excludes the duplicate")
        XCTAssertFalse(binding.authorizesSecretEstablishment(peer: paired, sessionHandle: "handle-genuine"),
                       "a trusted reconnect never authorizes secret establishment")
        binding.unbind(sessionHandle: "handle-duplicate")
        XCTAssertTrue(binding.authorizes(peer: paired, sessionHandle: "handle-genuine"),
                      "unbinding a different instance must not drop the genuine one")
        binding.unbind(sessionHandle: "handle-genuine")
        XCTAssertFalse(binding.authorizes(peer: paired, sessionHandle: "handle-genuine"))
        // Fresh pairing authorizes establishment only on its own instance.
        binding.bind(peer: paired, sessionHandle: "handle-fresh", viaFreshPairing: true)
        XCTAssertTrue(binding.authorizesSecretEstablishment(peer: paired, sessionHandle: "handle-fresh"))
        XCTAssertFalse(binding.authorizesSecretEstablishment(peer: paired, sessionHandle: "handle-duplicate"))
    }

    // Item 3: after unpair, the flush the child view now performs
    // republishes an unpaired snapshot immediately.
    func testR5_3_UnpairThenFlushRepublishesUnpairedSnapshot() throws {
        let admin = PeerIdentity(stableID: "admin-stable-1", displayName: "EarnPlay-Admin")
        let gate = SyncPairingGate(code: "654321", identity: victim)
        XCTAssertTrue(gate.markPaired(peer: admin))
        let (at, ct, _) = InMemorySyncTransport.pair()
        _ = at
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("cs")),
                                     sessionQueue: SessionLogQueue(directory: dir("cq")),
                                     transport: ct, pairing: gate)
        var published: [ChildSyncSnapshot] = []
        child.onSnapshotChange = { published.append($0) }
        child.start()
        XCTAssertTrue(child.snapshot.isPaired)
        gate.unpair()          // what transport.unpair() does to the gate
        child.flushPending()   // the call the fixed child view now makes
        XCTAssertFalse(child.snapshot.isPaired, "snapshot must show unpaired immediately after unpair")
        XCTAssertEqual(published.last?.isPaired, false)
    }

    // Item 6 (gate evidence): a mismatch clears the entered code, so
    // the child cannot answer a retried challenge until it re-enters
    // a corrected code — then a fresh handshake in both directions
    // completes pairing.
    func testR5_6_CorrectedCodeAnswersRetriedChallenge() throws {
        let adminGate = SyncPairingGate(code: "111111", identity: claimant)
        let childGate = SyncPairingGate(code: "654321", identity: victim)
        _ = adminGate.preparePairing(enteredCode: "000000") // mistyped
        _ = childGate.preparePairing(enteredCode: "111111")
        _ = adminGate.beginProvisional(peer: victim)
        _ = childGate.beginProvisional(peer: claimant)
        let bad = try XCTUnwrap(adminGate.challengeResponse(toChallenge: "c1", verifier: victim))
        XCTAssertFalse(childGate.verifyChallengeResponse(bad, toChallenge: "c1", prover: claimant))
        childGate.failProvisionalAttempt(peer: claimant)
        adminGate.failProvisionalAttempt(peer: victim)
        XCTAssertNil(childGate.challengeResponse(toChallenge: "c2", verifier: claimant),
                     "after a mismatch the child has no code and cannot answer yet")
        // Corrected entry + fresh handshake, both directions.
        XCTAssertTrue(adminGate.preparePairing(enteredCode: "654321"))
        XCTAssertTrue(childGate.preparePairing(enteredCode: "111111"))
        XCTAssertTrue(adminGate.beginProvisional(peer: victim))
        XCTAssertTrue(childGate.beginProvisional(peer: claimant))
        let r1 = try XCTUnwrap(childGate.challengeResponse(toChallenge: "c3", verifier: claimant))
        XCTAssertTrue(adminGate.verifyChallengeResponse(r1, toChallenge: "c3", prover: victim))
        _ = adminGate.recordRemoteVerified(peer: victim)
        XCTAssertTrue(adminGate.recordPeerVerifiedLocal(peer: victim))
        let r2 = try XCTUnwrap(adminGate.challengeResponse(toChallenge: "c4", verifier: victim))
        XCTAssertTrue(childGate.verifyChallengeResponse(r2, toChallenge: "c4", prover: claimant))
        _ = childGate.recordRemoteVerified(peer: claimant)
        XCTAssertTrue(childGate.recordPeerVerifiedLocal(peer: claimant))
        XCTAssertTrue(adminGate.isPaired(to: victim))
        XCTAssertTrue(childGate.isPaired(to: claimant))
    }

    // Item 7 (refuted — evidence): the child app's only sync path is
    // SyncDebugView (embedded by EarnPlayApp.ContentView), wired with
    // the production store key below. A relaunch on that wiring keeps
    // the identity, pairing, and secret.
    func testR5_7_ChildProductionWiringPersistsAcrossRelaunch() {
        let key = "earnplay.pairing.child.v1" // SyncDebugView's production key
        let gate1 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child",
                                                      defaults: defaults, key: key)
        let identity1 = gate1.localIdentity
        _ = gate1.beginProvisional(peer: claimant)
        _ = gate1.recordRemoteVerified(peer: claimant)
        XCTAssertTrue(gate1.recordPeerVerifiedLocal(peer: claimant))
        let secret = gate1.takeSecretToShare(for: claimant)
        XCTAssertNotNil(secret)
        let gate2 = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child",
                                                      defaults: defaults, key: key)
        XCTAssertEqual(gate2.localIdentity, identity1, "child relaunch must keep its identity")
        XCTAssertTrue(gate2.isPaired(to: claimant), "child relaunch must retain the pairing")
        XCTAssertEqual(gate2.pairingSecret(for: claimant), secret,
                       "child relaunch must retain the pairing secret")
    }

    // Item 5: with two discovered children, only one invitation may be
    // outstanding; the second waits until the first resolves.
    func testR5_5_OnlyOneInvitationOutstanding() {
        let childA = PeerIdentity(stableID: "child-a", displayName: "EarnPlay-Child")
        let childB = PeerIdentity(stableID: "child-b", displayName: "EarnPlay-Child")
        var book = DiscoveredPeerBook()
        book.retain(childA); book.retain(childB)
        let first = book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil)
        XCTAssertEqual(first.count, 1, "only one invitation may be outstanding at a time")
        book.markInvited(first[0])
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil), [],
                       "the second child waits while the first invitation is outstanding")
        book.markFailed(first[0])
        XCTAssertEqual(book.invitationCandidates(hasPeerCode: true, livePeer: nil, trustedPairedPeer: nil),
                       [first[0] == childA ? childB : childA],
                       "after the first fails, the second child becomes invitable")
    }
}
