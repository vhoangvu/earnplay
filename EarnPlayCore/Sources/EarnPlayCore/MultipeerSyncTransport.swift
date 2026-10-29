import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Production T4.6 transport: MultipeerConnectivity only — local
/// peer-to-peer (Bluetooth / local Wi-Fi), no account, no server,
/// no internet. Round 3: identity is a stable `PeerIdentity`, never
/// a bare display name (F1); invitations carry identity only, never
/// a secret, and pairing completes only after mutual challenge-
/// response plus explicit user confirmation on both sides (F2);
/// discovered peers are retained and invitations deferred until a
/// code is entered, with Pair retrying failed invitations (F5);
/// a trusted paired peer may reconnect without re-confirmation (F6).
public final class MultipeerSyncTransport: NSObject, SyncTransport, @unchecked Sendable {
    public enum Role: Sendable { case browser, advertiser }
    public static let serviceType = "earnplay-sync"
    private static let handshakePrefix = "EarnPlayPairing/1:"
    private let role: Role
    private let peerID: MCPeerID
    public let pairing: SyncPairingGate
    public var localIdentity: PeerIdentity { pairing.localIdentity }
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingPeerID: MCPeerID?
    private var pendingIdentity: PeerIdentity?
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    private var peerBook = DiscoveredPeerBook()
    private var mcPeersByStableID: [String: MCPeerID] = [:]
    private var identityByPeerName: [String: PeerIdentity] = [:]
    // Mutual-auth state for the current session attempt.
    private var issuedChallenge: String?
    private var remoteVerified = false
    private var verifiedPeer: PeerIdentity?
    public var onReceive: ((Data) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    /// Advertiser side: an identity-bearing invitation arrived; the UI
    /// shows its own code, the user enters the peer's code and confirms.
    public var onPairingRequest: ((PeerIdentity) -> Void)?
    public init(role: Role, displayName: String, pairing: SyncPairingGate? = nil) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        if let pairing {
            self.pairing = pairing
        } else {
            self.pairing = SyncPairingGate(identity: PeerIdentity.generate(displayName: displayName))
        }
        super.init()
    }
    public var pairingCode: String { pairing.localCode }
    public var isPaired: Bool { pairing.isPaired }
    public var hasPendingPairingRequest: Bool { pendingInvitationHandler != nil }

    private func identity(for mcPeer: MCPeerID) -> PeerIdentity {
        identityByPeerName[mcPeer.displayName] ?? PeerIdentity(stableID: "display:\(mcPeer.displayName)", displayName: mcPeer.displayName)
    }
    private func remember(_ identity: PeerIdentity, mcPeer: MCPeerID) {
        mcPeersByStableID[identity.stableID] = mcPeer
        identityByPeerName[mcPeer.displayName] = identity
    }

    /// Advertiser user confirmed out-of-band (entered the peer's code
    /// shown on the peer device) and accepted. Session acceptance
    /// alone proves nothing: mutual challenge-response follows and
    /// data flows only after both sides verify.
    @discardableResult
    public func acceptPendingInvitation() -> Bool {
        guard let handler = pendingInvitationHandler, let mcPeer = pendingPeerID,
              let candidate = pendingIdentity else { return false }
        guard PeerAdmission.shouldAccept(livePeer: session?.connectedPeers.first.map { identity(for: $0) },
                                         candidate: candidate,
                                         trustedPairedPeer: pairing.pairedPeer) else { return false }
        _ = mcPeer
        handler(true, session)
        pendingInvitationHandler = nil; pendingPeerID = nil; pendingIdentity = nil
        return true
    }
    public func rejectPendingInvitation() {
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil; pendingPeerID = nil; pendingIdentity = nil
    }
    public var isConnected: Bool {
        guard let session, !session.connectedPeers.isEmpty else { return false }
        // Data-plane connection counts only once paired to that peer.
        guard let paired = pairing.pairedPeer else { return false }
        return session.connectedPeers.contains { identity(for: $0) == paired }
    }
    public func start() {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self; session = s
        switch role {
        case .advertiser:
            let info = ["sid": pairing.localIdentity.stableID, "dn": pairing.localIdentity.displayName]
            let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: info,
                                              serviceType: Self.serviceType)
            a.delegate = self; advertiser = a; a.startAdvertisingPeer()
        case .browser:
            let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            b.delegate = self; browser = b; b.startBrowsingForPeers()
        }
    }
    public func stop() {
        rejectPendingInvitation()
        pairing.reset()
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        session?.disconnect(); session = nil
        peerBook = DiscoveredPeerBook(); mcPeersByStableID.removeAll()
    }
    /// Finding 5: Pair retry — clears failed/timed-out invitation
    /// state and re-invites retained discovered peers (or the trusted
    /// paired peer, finding 6).
    public func retryPairing() {
        _ = peerBook.retryCandidates()
        inviteEligiblePeers()
    }
    private func inviteEligiblePeers() {
        guard role == .browser, let session, let browser else { return }
        let live = session.connectedPeers.first.map { identity(for: $0) }
        for candidate in peerBook.invitationCandidates(hasPeerCode: pairing.hasEnteredPeerCode,
                                                       livePeer: live,
                                                       trustedPairedPeer: pairing.pairedPeer) {
            guard let mcPeer = mcPeersByStableID[candidate.stableID] else { continue }
            peerBook.markInvited(candidate)
            // Identity only — never the pairing code (finding 2).
            let context = try? PairingInvitation.encode(PairingInvitation(inviter: pairing.localIdentity))
            browser.invitePeer(mcPeer, to: session, withContext: context, timeout: 30)
        }
    }
    public func send(_ data: Data) throws {
        guard pairing.isPaired else { throw SyncTransportError.notPaired }
        guard let session, !session.connectedPeers.isEmpty else {
            throw SyncTransportError.notConnected
        }
        guard let paired = pairing.pairedPeer else { throw SyncTransportError.notPaired }
        let targets = session.connectedPeers.filter { identity(for: $0) == paired }
        guard !targets.isEmpty else { throw SyncTransportError.notConnected }
        try session.send(data, toPeers: targets, with: .reliable)
    }

    // MARK: - Mutual challenge-response handshake (finding 2)

    private enum HandshakeMessage: Codable {
        case challenge(nonce: String, from: PeerIdentity)
        case response(nonce: String, digest: String, from: PeerIdentity)
    }
    private func sendHandshake(_ msg: HandshakeMessage, to mcPeer: MCPeerID) {
        guard let session, let payload = try? JSONEncoder().encode(msg) else { return }
        var data = Data(Self.handshakePrefix.utf8); data.append(payload)
        try? session.send(data, toPeers: [mcPeer], with: .reliable)
    }
    private func beginHandshake(with mcPeer: MCPeerID, identity remote: PeerIdentity) {
        // Trusted reconnection (finding 6): pairing was already
        // verified; reuse it without another manual confirmation.
        if pairing.isPaired(to: remote) {
            verifiedPeer = remote; remoteVerified = true
            onConnectionChange?(true); return
        }
        let nonce = UUID().uuidString
        issuedChallenge = nonce; remoteVerified = false; verifiedPeer = remote
        sendHandshake(.challenge(nonce: nonce, from: pairing.localIdentity), to: mcPeer)
    }
    private func handleHandshake(_ data: Data, from mcPeer: MCPeerID) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(Self.handshakePrefix) else { return false }
        let payload = Data(text.dropFirst(Self.handshakePrefix.count).utf8)
        guard let msg = try? JSONDecoder().decode(HandshakeMessage.self, from: payload) else { return true }
        switch msg {
        case .challenge(let nonce, let from):
            remember(from, mcPeer: mcPeer)
            // No entered peer code -> no response: an advertiser that
            // skipped the out-of-band comparison gains nothing.
            if let digest = pairing.challengeResponse(toChallenge: nonce, verifier: from) {
                sendHandshake(.response(nonce: nonce, digest: digest, from: pairing.localIdentity), to: mcPeer)
            }
        case .response(let nonce, let digest, let from):
            remember(from, mcPeer: mcPeer)
            guard nonce == issuedChallenge,
                  pairing.verifyChallengeResponse(digest, toChallenge: nonce, prover: from) else {
                return true // unverified: no paired state, no data, no connection-up
            }
            remoteVerified = true
            if pairing.markPaired(peer: from) {
                onConnectionChange?(true)
            }
        }
        return true
    }
}

extension MultipeerSyncTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer mcPeer: MCPeerID,
                        didChange state: MCSessionState) {
        let remote = identity(for: mcPeer)
        if state == .connected {
            if let paired = pairing.pairedPeer, paired != remote {
                session.disconnect(); return
            }
            beginHandshake(with: mcPeer, identity: remote)
            return
        }
        if state == .notConnected {
            peerBook.markFailed(remote)
            if pairing.pairedPeer == remote { verifiedPeer = nil; remoteVerified = false }
        }
        onConnectionChange?(false)
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer mcPeer: MCPeerID) {
        if handleHandshake(data, from: mcPeer) { return }
        guard pairing.isPaired(to: identity(for: mcPeer)) else { return }
        onReceive?(data)
    }
    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer mcPeer: MCPeerID) {}
    public func session(_ session: MCSession,
                        didStartReceivingResourceWithName resourceName: String,
                        fromPeer mcPeer: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession,
                        didFinishReceivingResourceWithName resourceName: String,
                        fromPeer mcPeer: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerSyncTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer mcPeer: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // The invitation authenticates nobody by itself: it carries
        // only the inviter's stable identity, never a secret (F2).
        guard let context, let invitation = try? PairingInvitation.decode(context) else {
            invitationHandler(false, nil); return
        }
        let candidate = invitation.inviter
        remember(candidate, mcPeer: mcPeer)
        let live = session?.connectedPeers.first.map { identity(for: $0) }
        guard PeerAdmission.shouldAccept(livePeer: live, candidate: candidate,
                                         trustedPairedPeer: pairing.pairedPeer),
              pendingInvitationHandler == nil else {
            invitationHandler(false, nil); return
        }
        if pairing.isPaired(to: candidate) {
            invitationHandler(true, session); return // trusted reconnect (F6)
        }
        pendingPeerID = mcPeer; pendingIdentity = candidate
        pendingInvitationHandler = invitationHandler
        if onPairingRequest != nil { onPairingRequest?(candidate) }
        else { invitationHandler(false, nil) } // no UI confirmation -> no trust
    }
}

extension MultipeerSyncTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer mcPeer: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        let candidate: PeerIdentity
        if let sid = info?["sid"], !sid.isEmpty {
            candidate = PeerIdentity(stableID: sid, displayName: info?["dn"] ?? mcPeer.displayName)
        } else {
            candidate = PeerIdentity(stableID: "display:\(mcPeer.displayName)", displayName: mcPeer.displayName)
        }
        remember(candidate, mcPeer: mcPeer)
        peerBook.retain(candidate) // retained even before a code is entered (F5)
        inviteEligiblePeers() // defers until a code is supplied (F5)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer mcPeer: MCPeerID) {
        // Retain the discovered peer for Pair retry (F5).
        peerBook.markFailed(identity(for: mcPeer))
    }
}
#endif
