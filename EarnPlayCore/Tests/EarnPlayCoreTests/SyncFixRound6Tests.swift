import Foundation
import XCTest
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif
@testable import EarnPlayCore

/// T4.6 fix round 6 (issue #23): regression tests for confirmed items
/// 1 (provisional verification survives disconnect), 5 (peer handles by
/// MCPeerID equality), 6 (durable pairing lost on transport restart),
/// 7 (duplicate disconnect clears genuine state). Items 9-12 were
/// refuted by construction trace (see fix-round-6 log entry); items 2
/// and 3 are covered by the Docs/Sync.md limitation note and the built
/// Info.plist check respectively.
final class SyncFixRound6Tests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    override func setUpWithError() throws {
        suiteName = "SyncFixRound6-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
    }

    private let victim = PeerIdentity(stableID: "victim-z", displayName: "EarnPlay-Child")
    private let claimant = PeerIdentity(stableID: "peer-a", displayName: "EarnPlay-Admin")

#if canImport(MultipeerConnectivity)
    private func handshakeData(_ json: String) -> Data {
        var d = Data("EarnPlayPairing/1:".utf8)
        d.append(Data(json.utf8))
        return d
    }
    private func peerJSON(_ p: PeerIdentity) -> String {
        "{\"stableID\":\"\(p.stableID)\",\"displayName\":\"\(p.displayName)\"}"
    }
    private func makeSession() -> MCSession {
        MCSession(peer: MCPeerID(displayName: "probe"), securityIdentity: nil, encryptionPreference: .required)
    }
    /// An equal-but-distinct instance of `peer`, as the framework may
    /// vend for the same remote peer in a later callback.
    private func twin(of peer: MCPeerID) throws -> MCPeerID {
        let data = try NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true)
        return try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data))
    }

    // Item 1: a peer whose response was verified, then disconnected
    // before mutual promotion, must NOT be promoted later by sending
    // only pairingConfirmed on a new connection.
    func testR6_1_VerifiedThenDisconnectedMustNotPromoteOnPairingConfirmedAlone() throws {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var connections: [Bool] = []
        transport.onConnectionChange = { connections.append($0) }
        transport.onPairingRequest = { _ in }
        let session = makeSession()
        let genuine = MCPeerID(displayName: claimant.displayName)
        // Invitation binds the genuine handle to the claimant identity.
        let advertiser = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "EarnPlay-Child"),
                                                   discoveryInfo: nil, serviceType: MultipeerSyncTransport.serviceType)
        let context = try! PairingInvitation.encode(PairingInvitation(inviter: claimant))
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: genuine, withContext: context) { _, _ in }
        transport.session(session, peer: genuine, didChange: .connected)
        // This side verified the peer's challenge response; the peer
        // disconnects before confirming this side in return.
        _ = gate.recordRemoteVerified(peer: claimant)
        transport.session(session, peer: genuine, didChange: .notConnected)
        // A new connection claiming the same identity sends only
        // pairingConfirmed, without answering the new challenge.
        let impostor = MCPeerID(displayName: claimant.displayName)
        transport.session(session, peer: impostor, didChange: .connected)
        let json = "{\"pairingConfirmed\":{\"from\":\(peerJSON(claimant))}}"
        transport.session(session, didReceive: handshakeData(json), fromPeer: impostor)
        XCTAssertFalse(gate.isPaired(to: claimant),
                       "verified-then-disconnected peer must not promote on pairingConfirmed alone")
        XCTAssertFalse(connections.contains(true), "no data plane may open without a fresh challenge answer")
    }

    // Item 5: an equal-but-distinct MCPeerID instance for the same
    // peer (archived round-trip, == true but a different object) must
    // resolve to the same handle/identity as the original instance.
    func testR6_5_EqualPeerInstanceSharesHandleAndIdentity() throws {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var connections: [Bool] = []
        transport.onConnectionChange = { connections.append($0) }
        transport.onPairingRequest = { _ in }
        let session = makeSession()
        let genuine = MCPeerID(displayName: claimant.displayName)
        let advertiser = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "EarnPlay-Child"),
                                                   discoveryInfo: nil, serviceType: MultipeerSyncTransport.serviceType)
        let context = try! PairingInvitation.encode(PairingInvitation(inviter: claimant))
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: genuine, withContext: context) { _, _ in }
        transport.session(session, peer: genuine, didChange: .connected)
        _ = gate.recordRemoteVerified(peer: claimant)
        // The framework vends a fresh, equal object for the same peer.
        let twinPeer = try twin(of: genuine)
        XCTAssertTrue(twinPeer == genuine)
        XCTAssertFalse(twinPeer === genuine)
        let json = "{\"pairingConfirmed\":{\"from\":\(peerJSON(claimant))}}"
        transport.session(session, didReceive: handshakeData(json), fromPeer: twinPeer)
        XCTAssertTrue(gate.isPaired(to: claimant),
                      "an equal peer instance must continue the same handshake, not start as an unbound identity")
        XCTAssertTrue(connections.contains(true))
    }

    // Item 7: an unauthenticated second handle claiming the paired
    // identity disconnecting must not clear the genuine data plane.
    func testR6_7_DuplicateDisconnectDoesNotClearGenuineDataPlane() throws {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        var received: [Data] = []
        transport.onReceive = { received.append($0) }
        transport.onPairingRequest = { _ in }
        let session = makeSession()
        let genuine = MCPeerID(displayName: claimant.displayName)
        let advertiser = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "EarnPlay-Child"),
                                                   discoveryInfo: nil, serviceType: MultipeerSyncTransport.serviceType)
        let context = try! PairingInvitation.encode(PairingInvitation(inviter: claimant))
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: genuine, withContext: context) { _, _ in }
        _ = gate.beginProvisional(peer: claimant)
        _ = gate.recordRemoteVerified(peer: claimant)
        let confirmed = "{\"pairingConfirmed\":{\"from\":\(peerJSON(claimant))}}"
        transport.session(session, didReceive: handshakeData(confirmed), fromPeer: genuine)
        XCTAssertTrue(gate.isPaired(to: claimant))
        // A duplicate claimant (distinct peer instance, same claimed
        // identity) is refused while bound, then disconnects.
        let duplicate = MCPeerID(displayName: claimant.displayName)
        var duplicateAccepted: [Bool] = []
        transport.advertiser(advertiser, didReceiveInvitationFromPeer: duplicate, withContext: context) { ok, _ in
            duplicateAccepted.append(ok)
        }
        XCTAssertEqual(duplicateAccepted, [false])
        transport.session(session, peer: duplicate, didChange: .notConnected)
        // Genuine peer traffic must still flow.
        transport.session(session, didReceive: Data("genuine-payload".utf8), fromPeer: genuine)
        XCTAssertEqual(received, [Data("genuine-payload".utf8)],
                       "duplicate disconnect must not clear the genuine peer's data plane")
    }
#endif

#if canImport(MultipeerConnectivity)
    // Item 5 (allocator): handles follow MCPeerID equality within a
    // session generation and never carry across generations.
    func testR6_5_HandleAllocatorEqualityAndGenerationScoping() throws {
        let allocator = PeerHandleAllocator()
        let peer = MCPeerID(displayName: "EarnPlay-Admin")
        let twinPeer = try twin(of: peer)
        let other = MCPeerID(displayName: "EarnPlay-Admin")
        let first = allocator.handle(for: peer)
        XCTAssertEqual(allocator.handle(for: twinPeer), first,
                       "equal peer instances share one handle in a generation")
        XCTAssertNotEqual(allocator.handle(for: other), first,
                          "a separately created peer instance is a different peer")
        allocator.reset()
        XCTAssertNotEqual(allocator.handle(for: peer), first,
                          "a new session generation must not reuse a stale handle")
    }
#endif

    // Item 6: ordinary stop()/start teardown must preserve the durable
    // pairing and secret; only explicit unpair() clears them.
    func testR6_6_StopPreservesDurablePairingAndSecret() {
        let key = "earnplay.pairing.test.r6"
        let gate = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        _ = gate.beginProvisional(peer: claimant)
        _ = gate.recordRemoteVerified(peer: claimant)
        XCTAssertTrue(gate.recordPeerVerifiedLocal(peer: claimant))
        let secret = gate.takeSecretToShare(for: claimant)
        XCTAssertNotNil(secret)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        transport.stop()
        XCTAssertTrue(gate.isPaired(to: claimant), "stop() must not clear the durable pairing")
        XCTAssertEqual(gate.pairingSecret(for: claimant), secret, "stop() must not clear the pairing secret")
        let relaunched = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child", defaults: defaults, key: key)
        XCTAssertTrue(relaunched.isPaired(to: claimant), "pairing must survive stop + relaunch")
        XCTAssertEqual(relaunched.pairingSecret(for: claimant), secret)
        // Explicit unpair still clears.
        transport.unpair()
        XCTAssertFalse(gate.isPaired(to: claimant), "unpair() must clear the pairing")
        XCTAssertNil(gate.pairingSecret(for: claimant), "unpair() must clear the secret")
    }

    // Item 6 (transient side): stop() clears a provisional attempt.
    func testR6_6_StopClearsProvisionalAttempt() {
        let gate = SyncPairingGate(code: "654321", identity: victim)
        _ = gate.beginProvisional(peer: claimant)
        _ = gate.recordRemoteVerified(peer: claimant)
        let transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: gate)
        transport.stop()
        XCTAssertNil(gate.provisionalPeer, "stop() must clear the provisional attempt")
        XCTAssertFalse(gate.isPaired(to: claimant))
    }
}
