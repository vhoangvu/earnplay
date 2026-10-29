import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Production T4.6 transport: MultipeerConnectivity only — local
/// peer-to-peer (Bluetooth / local Wi-Fi), no account, no server,
/// no internet. Round 4: all mutable state is serialized (H1: a
/// lock held only around state access, never across `session.send`
/// or the reentrant `onReceive`/`onConnectionChange` callbacks);
/// peer instances resolve to stable identities, never display
/// names (H2); a retained pairing reconnects only after proving
/// possession of the pairing secret, else full manual re-pairing
/// (H3); trusted peers are re-invited on rediscovery and on a
/// dropped session with backoff (H4); pairing stays provisional
/// until mutual authentication completes on both sides (M6).
public final class MultipeerSyncTransport: NSObject, SyncTransport, @unchecked Sendable {
    public enum Role: Sendable { case browser, advertiser }
    public static let serviceType = "earnplay-sync"
    private static let handshakePrefix = "EarnPlayPairing/1:"
    private let role: Role
    private let peerID: MCPeerID
    public let pairing: SyncPairingGate
    public var localIdentity: PeerIdentity { pairing.localIdentity }

    private let stateLock = NSLock()
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingPeerID: MCPeerID?
    private var pendingIdentity: PeerIdentity?
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    private var pendingManualPeerID: MCPeerID?
    private var pendingManualIdentity: PeerIdentity?
    private var peerBook = DiscoveredPeerBook()
    private var mcPeersByStableID: [String: MCPeerID] = [:]
    private let resolver = PeerIdentityResolver()
    private var issuedChallenge: String?
    private var trustedNonce: String?
    private var trustedPending = false
    private var remoteVerified = false
    private var verifiedPeer: PeerIdentity?
    private var dataPlanePeer: PeerIdentity?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var reconnectGeneration = 0
    private let reconnectQueue = DispatchQueue(label: "earnplay.sync.reconnect")
    private let reconnectBackoff = ReconnectBackoff()

    private var _onReceive: ((Data) -> Void)?
    private var _onConnectionChange: ((Bool) -> Void)?
    private var _onPairingRequest: ((PeerIdentity) -> Void)?
    private var _onPairingFailure: ((PeerIdentity) -> Void)?
    public var onReceive: ((Data) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onReceive }
        set { stateLock.lock(); _onReceive = newValue; stateLock.unlock() }
    }
    public var onConnectionChange: ((Bool) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onConnectionChange }
        set { stateLock.lock(); _onConnectionChange = newValue; stateLock.unlock() }
    }
    /// Advertiser side: an identity-bearing invitation arrived; the UI
    /// shows its own code, the user enters the peer's code and confirms.
    public var onPairingRequest: ((PeerIdentity) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onPairingRequest }
        set { stateLock.lock(); _onPairingRequest = newValue; stateLock.unlock() }
    }
    /// Pairing verification failed (round 4, M6): both sides reset
    /// the attempt; the UI surfaces a retryable status.
    public var onPairingFailure: ((PeerIdentity) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onPairingFailure }
        set { stateLock.lock(); _onPairingFailure = newValue; stateLock.unlock() }
    }

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
    public var hasPendingPairingRequest: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendingInvitationHandler != nil || pendingManualPeerID != nil
    }

    // MARK: - Serialized state helpers (H1, H2)

    private func handle(for mcPeer: MCPeerID) -> String { "\(ObjectIdentifier(mcPeer))" }
    private func identity(for mcPeer: MCPeerID) -> PeerIdentity {
        resolver.identity(forHandle: handle(for: mcPeer), fallbackDisplayName: mcPeer.displayName)
    }
    /// Called on every discovery/invitation/handshake event so the
    /// stable identity always maps to the latest live peer instance.
    private func remember(_ identity: PeerIdentity, mcPeer: MCPeerID) {
        resolver.bind(identity, handle: handle(for: mcPeer))
        stateLock.lock(); mcPeersByStableID[identity.stableID] = mcPeer; stateLock.unlock()
    }
    private func mcPeer(for identity: PeerIdentity) -> MCPeerID? {
        stateLock.lock(); defer { stateLock.unlock() }; return mcPeersByStableID[identity.stableID]
    }

    /// Advertiser user confirmed out-of-band (entered the peer's code
    /// shown on the peer device) and accepted. Session acceptance
    /// alone proves nothing: mutual challenge-response follows and
    /// data flows only after both sides verify.
    @discardableResult
    public func acceptPendingInvitation() -> Bool {
        stateLock.lock()
        if let handler = pendingInvitationHandler, let candidate = pendingIdentity {
            let live = session?.connectedPeers.first.map { identity(for: $0) }
            guard PeerAdmission.shouldAccept(livePeer: live, candidate: candidate,
                                             trustedPairedPeer: pairing.pairedPeer) else {
                stateLock.unlock(); return false
            }
            let currentSession = session
            pendingInvitationHandler = nil; pendingPeerID = nil; pendingIdentity = nil
            stateLock.unlock()
            handler(true, currentSession)
            return true
        }
        if let mcPeer = pendingManualPeerID, let candidate = pendingManualIdentity {
            pendingManualPeerID = nil; pendingManualIdentity = nil
            stateLock.unlock()
            // Session already exists; the user's fresh code entry is
            // the manual re-confirmation — run a fresh handshake.
            beginHandshake(with: mcPeer, identity: candidate)
            return true
        }
        stateLock.unlock()
        return false
    }
    public func rejectPendingInvitation() {
        stateLock.lock()
        let handler = pendingInvitationHandler
        pendingInvitationHandler = nil; pendingPeerID = nil; pendingIdentity = nil
        pendingManualPeerID = nil; pendingManualIdentity = nil
        stateLock.unlock()
        handler?(false, nil)
    }
    public var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let session, !session.connectedPeers.isEmpty else { return false }
        guard let paired = pairing.pairedPeer, dataPlanePeer == paired else { return false }
        return session.connectedPeers.contains { identity(for: $0) == paired }
    }
    public func start() {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        var newAdvertiser: MCNearbyServiceAdvertiser?
        var newBrowser: MCNearbyServiceBrowser?
        switch role {
        case .advertiser:
            let info = ["sid": pairing.localIdentity.stableID, "dn": pairing.localIdentity.displayName]
            let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: info,
                                              serviceType: Self.serviceType)
            a.delegate = self; newAdvertiser = a
        case .browser:
            let b = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            b.delegate = self; newBrowser = b
        }
        stateLock.lock()
        session = s; advertiser = newAdvertiser; browser = newBrowser
        stateLock.unlock()
        newAdvertiser?.startAdvertisingPeer()
        newBrowser?.startBrowsingForPeers()
    }
    public func stop() {
        cancelReconnect()
        rejectPendingInvitation()
        stateLock.lock()
        let oldAdvertiser = advertiser; let oldBrowser = browser; let oldSession = session
        advertiser = nil; browser = nil; session = nil
        peerBook = DiscoveredPeerBook(); mcPeersByStableID.removeAll()
        issuedChallenge = nil; trustedNonce = nil; trustedPending = false
        remoteVerified = false; verifiedPeer = nil; dataPlanePeer = nil
        stateLock.unlock()
        resolver.forgetAll()
        pairing.reset()
        oldAdvertiser?.stopAdvertisingPeer(); oldBrowser?.stopBrowsingForPeers()
        oldSession?.disconnect()
    }
    /// Reset/Unpair (round 4, M7): drops the session and the
    /// retained pairing; the installation identity is kept.
    public func unpair() {
        cancelReconnect()
        stateLock.lock()
        let oldSession = session
        dataPlanePeer = nil; remoteVerified = false; verifiedPeer = nil
        trustedNonce = nil; trustedPending = false; issuedChallenge = nil
        pendingManualPeerID = nil; pendingManualIdentity = nil
        stateLock.unlock()
        pairing.unpair()
        oldSession?.disconnect()
    }
    /// Pair retry: clears failed/timed-out invitation state and
    /// re-invites retained peers; also restarts the handshake for a
    /// connected peer whose pairing is not yet established (M6).
    public func retryPairing() {
        stateLock.lock()
        _ = peerBook.retryCandidates()
        let unverified = session?.connectedPeers.first(where: { dataPlanePeer != identity(for: $0) })
        let unverifiedIdentity = unverified.map { identity(for: $0) }
        stateLock.unlock()
        inviteEligiblePeers()
        if let unverified, let unverifiedIdentity { beginHandshake(with: unverified, identity: unverifiedIdentity) }
    }
    private func inviteEligiblePeers() {
        stateLock.lock()
        guard role == .browser, let currentSession = session, let currentBrowser = browser else {
            stateLock.unlock(); return
        }
        let live = currentSession.connectedPeers.first.map { identity(for: $0) }
        let candidates = peerBook.invitationCandidates(hasPeerCode: pairing.hasEnteredPeerCode,
                                                       livePeer: live,
                                                       trustedPairedPeer: pairing.pairedPeer)
        var targets: [(PeerIdentity, MCPeerID)] = []
        for candidate in candidates {
            guard let mcPeer = mcPeersByStableID[candidate.stableID] else { continue }
            peerBook.markInvited(candidate)
            targets.append((candidate, mcPeer))
        }
        stateLock.unlock()
        for (_, mcPeer) in targets {
            // Identity only — never the pairing code.
            let context = try? PairingInvitation.encode(PairingInvitation(inviter: pairing.localIdentity))
            currentBrowser.invitePeer(mcPeer, to: currentSession, withContext: context, timeout: 30)
        }
    }
    public func send(_ data: Data) throws {
        guard pairing.isPaired else { throw SyncTransportError.notPaired }
        guard let paired = pairing.pairedPeer else { throw SyncTransportError.notPaired }
        stateLock.lock()
        guard let currentSession = session, dataPlanePeer == paired else {
            stateLock.unlock(); throw SyncTransportError.notConnected
        }
        let targets = currentSession.connectedPeers.filter { identity(for: $0) == paired }
        stateLock.unlock()
        guard !targets.isEmpty else { throw SyncTransportError.notConnected }
        // session.send runs outside the lock: it must never be able
        // to re-enter transport state while the lock is held (H1).
        try currentSession.send(data, toPeers: targets, with: .reliable)
    }

    // MARK: - Handshake: mutual pairing (M6) + trusted proof (H3)

    private enum HandshakeMessage: Codable {
        case challenge(nonce: String, from: PeerIdentity)
        case response(nonce: String, digest: String, from: PeerIdentity)
        case pairingConfirmed(from: PeerIdentity)
        case pairingFailed(from: PeerIdentity)
        case pairingSecret(secret: String, from: PeerIdentity)
        case trustedChallenge(nonce: String, from: PeerIdentity)
        case trustedResponse(nonce: String, digest: String, from: PeerIdentity)
    }
    private func sendHandshake(_ msg: HandshakeMessage, to mcPeer: MCPeerID) {
        stateLock.lock(); let currentSession = session; stateLock.unlock()
        guard let currentSession, let payload = try? JSONEncoder().encode(msg) else { return }
        var data = Data(Self.handshakePrefix.utf8); data.append(payload)
        try? currentSession.send(data, toPeers: [mcPeer], with: .reliable)
    }
    private func openDataPlane(for remote: PeerIdentity, mcPeer: MCPeerID) {
        stateLock.lock(); dataPlanePeer = remote; remoteVerified = true; verifiedPeer = remote
        trustedPending = false; trustedNonce = nil; stateLock.unlock()
        cancelReconnect()
        if let secret = pairing.takeSecretToShare(for: remote) {
            sendHandshake(.pairingSecret(secret: secret, from: pairing.localIdentity), to: mcPeer)
        }
        // Outside the lock: the service callback can re-enter send().
        onConnectionChange?(true)
    }
    private func beginHandshake(with mcPeer: MCPeerID, identity remote: PeerIdentity) {
        var fellBackFromTrusted = false
        if pairing.isPaired(to: remote) {
            if pairing.pairingSecret(for: remote) != nil {
                let nonce = UUID().uuidString
                stateLock.lock()
                trustedNonce = nonce; trustedPending = true; verifiedPeer = remote; remoteVerified = false
                stateLock.unlock()
                sendHandshake(.trustedChallenge(nonce: nonce, from: pairing.localIdentity), to: mcPeer)
                return
            }
            // Retained pairing but no secret (H3): never silent
            // trust — drop it and fall back to manual re-pairing.
            pairing.downgradeTrustedPairing(for: remote)
            fellBackFromTrusted = true
        }
        _ = pairing.beginProvisional(peer: remote)
        let nonce = UUID().uuidString
        var surfaceManual = false
        stateLock.lock()
        issuedChallenge = nonce; remoteVerified = false; verifiedPeer = remote; trustedPending = false
        if role == .advertiser, fellBackFromTrusted {
            pendingManualPeerID = mcPeer; pendingManualIdentity = remote; surfaceManual = true
        }
        stateLock.unlock()
        if surfaceManual { onPairingRequest?(remote) }
        sendHandshake(.challenge(nonce: nonce, from: pairing.localIdentity), to: mcPeer)
    }
    /// Shared failure path (M6/H3): both sides reset the attempt and
    /// the local user gets a retryable failure signal.
    private func failHandshake(with mcPeer: MCPeerID, identity remote: PeerIdentity, notifyPeer: Bool) {
        let wasTrusted: Bool = {
            stateLock.lock(); defer { stateLock.unlock() }; return trustedPending
        }()
        stateLock.lock()
        issuedChallenge = nil; trustedNonce = nil; trustedPending = false
        remoteVerified = false; dataPlanePeer = nil
        stateLock.unlock()
        if wasTrusted { pairing.downgradeTrustedPairing(for: remote) }
        pairing.failProvisionalAttempt(peer: remote)
        if notifyPeer {
            sendHandshake(.pairingFailed(from: pairing.localIdentity), to: mcPeer)
        }
        onPairingFailure?(remote)
    }
    private func handleHandshake(_ data: Data, from mcPeer: MCPeerID) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix(Self.handshakePrefix) else { return false }
        let payload = Data(text.dropFirst(Self.handshakePrefix.count).utf8)
        guard let msg = try? JSONDecoder().decode(HandshakeMessage.self, from: payload) else { return true }
        switch msg {
        case .challenge(let nonce, let from):
            remember(from, mcPeer: mcPeer)
            if pairing.isPaired(to: from) {
                // Peer fell back to manual pairing: match it.
                pairing.downgradeTrustedPairing(for: from)
            }
            _ = pairing.beginProvisional(peer: from)
            if let digest = pairing.challengeResponse(toChallenge: nonce, verifier: from) {
                sendHandshake(.response(nonce: nonce, digest: digest, from: pairing.localIdentity), to: mcPeer)
            }
        case .response(let nonce, let digest, let from):
            remember(from, mcPeer: mcPeer)
            stateLock.lock(); let expected = issuedChallenge; stateLock.unlock()
            guard nonce == expected,
                  pairing.verifyChallengeResponse(digest, toChallenge: nonce, prover: from) else {
                failHandshake(with: mcPeer, identity: from, notifyPeer: true)
                return true
            }
            sendHandshake(.pairingConfirmed(from: pairing.localIdentity), to: mcPeer)
            if pairing.recordRemoteVerified(peer: from) {
                openDataPlane(for: from, mcPeer: mcPeer)
            }
        case .pairingConfirmed(let from):
            remember(from, mcPeer: mcPeer)
            if pairing.recordPeerVerifiedLocal(peer: from) {
                openDataPlane(for: from, mcPeer: mcPeer)
            }
        case .pairingFailed(let from):
            remember(from, mcPeer: mcPeer)
            stateLock.lock(); let wasTrusted = trustedPending; stateLock.unlock()
            if wasTrusted || pairing.isPaired(to: from) {
                // Peer cannot prove the secret: both sides drop the
                // retained pairing and re-pair manually (H3).
                pairing.downgradeTrustedPairing(for: from)
                onPairingFailure?(from)
                beginHandshake(with: mcPeer, identity: from)
            } else {
                pairing.failProvisionalAttempt(peer: from)
                stateLock.lock()
                issuedChallenge = nil; remoteVerified = false; dataPlanePeer = nil
                stateLock.unlock()
                onPairingFailure?(from)
            }
        case .pairingSecret(let secret, let from):
            remember(from, mcPeer: mcPeer)
            if pairing.isPaired(to: from) || pairing.provisionalPeer == from {
                pairing.adoptSharedSecret(secret, from: from)
            }
        case .trustedChallenge(let nonce, let from):
            remember(from, mcPeer: mcPeer)
            if pairing.isPaired(to: from),
               let proof = pairing.trustedResponse(toChallenge: nonce, peer: from) {
                sendHandshake(.trustedResponse(nonce: nonce, digest: proof, from: pairing.localIdentity), to: mcPeer)
            } else {
                sendHandshake(.pairingFailed(from: pairing.localIdentity), to: mcPeer)
                if role == .advertiser {
                    stateLock.lock()
                    pendingManualPeerID = mcPeer; pendingManualIdentity = from
                    stateLock.unlock()
                    onPairingRequest?(from)
                }
            }
        case .trustedResponse(let nonce, let digest, let from):
            remember(from, mcPeer: mcPeer)
            stateLock.lock(); let expected = trustedNonce; stateLock.unlock()
            guard nonce == expected,
                  pairing.verifyTrustedResponse(digest, toChallenge: nonce, prover: from) else {
                failHandshake(with: mcPeer, identity: from, notifyPeer: true)
                return true
            }
            openDataPlane(for: from, mcPeer: mcPeer)
        }
        return true
    }

    // MARK: - Trusted reconnect scheduling (H4)

    private func cancelReconnect() {
        stateLock.lock()
        reconnectWork?.cancel(); reconnectWork = nil
        reconnectGeneration += 1; reconnectAttempt = 0
        stateLock.unlock()
    }
    private func scheduleTrustedReconnect() {
        guard role == .browser else { return }
        stateLock.lock()
        guard pairing.pairedPeer != nil, dataPlanePeer == nil else { stateLock.unlock(); return }
        reconnectWork?.cancel()
        reconnectGeneration += 1; reconnectAttempt = 0
        let generation = reconnectGeneration
        stateLock.unlock()
        scheduleReconnectAttempt(generation: generation)
    }
    private func scheduleReconnectAttempt(generation: Int) {
        stateLock.lock()
        guard generation == reconnectGeneration, pairing.pairedPeer != nil else { stateLock.unlock(); return }
        let attempt = reconnectAttempt
        guard attempt <= 12 else { stateLock.unlock(); return }
        stateLock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stillWaiting = generation == self.reconnectGeneration
                && self.pairing.pairedPeer != nil && self.dataPlanePeer == nil
            if stillWaiting, let paired = self.pairing.pairedPeer {
                self.peerBook.clearInvitationState(paired)
                self.reconnectAttempt += 1
            }
            self.stateLock.unlock()
            guard stillWaiting else { return }
            self.inviteEligiblePeers()
            self.scheduleReconnectAttempt(generation: generation)
        }
        stateLock.lock()
        guard generation == reconnectGeneration else { stateLock.unlock(); return }
        reconnectWork = work
        stateLock.unlock()
        reconnectQueue.asyncAfter(deadline: .now() + reconnectBackoff.delay(forAttempt: attempt), execute: work)
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
            cancelReconnect()
            beginHandshake(with: mcPeer, identity: remote)
            return
        }
        if state == .notConnected {
            var shouldReconnect = false
            stateLock.lock()
            peerBook.markFailed(remote)
            if pairing.pairedPeer == remote {
                verifiedPeer = nil; remoteVerified = false; dataPlanePeer = nil
                trustedNonce = nil; trustedPending = false
                shouldReconnect = (role == .browser)
            }
            stateLock.unlock()
            if shouldReconnect { scheduleTrustedReconnect() }
        }
        onConnectionChange?(false)
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer mcPeer: MCPeerID) {
        if handleHandshake(data, from: mcPeer) { return }
        let remote = identity(for: mcPeer)
        stateLock.lock(); let plane = dataPlanePeer; stateLock.unlock()
        guard plane == remote, pairing.isPaired(to: remote) else { return }
        // Outside the lock: the service can re-enter send() (acks).
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
        // only the inviter's stable identity, never a secret.
        guard let context, let invitation = try? PairingInvitation.decode(context) else {
            invitationHandler(false, nil); return
        }
        let candidate = invitation.inviter
        remember(candidate, mcPeer: mcPeer)
        stateLock.lock()
        let live = session?.connectedPeers.first.map { identity(for: $0) }
        let hasPending = pendingInvitationHandler != nil
        let currentSession = session
        stateLock.unlock()
        guard PeerAdmission.shouldAccept(livePeer: live, candidate: candidate,
                                         trustedPairedPeer: pairing.pairedPeer),
              !hasPending else {
            invitationHandler(false, nil); return
        }
        if pairing.isPaired(to: candidate) {
            // Session may establish, but no data flows until the
            // trusted secret proof completes in the handshake (H3).
            invitationHandler(true, currentSession); return
        }
        stateLock.lock()
        pendingPeerID = mcPeer; pendingIdentity = candidate
        pendingInvitationHandler = invitationHandler
        stateLock.unlock()
        if onPairingRequest != nil { onPairingRequest?(candidate) }
        else {
            stateLock.lock()
            pendingInvitationHandler = nil; pendingPeerID = nil; pendingIdentity = nil
            stateLock.unlock()
            invitationHandler(false, nil) // no UI confirmation -> no trust
        }
    }
}

extension MultipeerSyncTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer mcPeer: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        let candidate: PeerIdentity
        if let sid = info?["sid"], !sid.isEmpty {
            candidate = PeerIdentity(stableID: sid, displayName: info?["dn"] ?? mcPeer.displayName)
        } else {
            candidate = PeerIdentity(stableID: "unbound:\(handle(for: mcPeer))", displayName: mcPeer.displayName)
        }
        remember(candidate, mcPeer: mcPeer)
        stateLock.lock(); peerBook.retain(candidate); stateLock.unlock()
        inviteEligiblePeers()
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer mcPeer: MCPeerID) {
        let remote = identity(for: mcPeer)
        var shouldReconnect = false
        stateLock.lock()
        peerBook.markFailed(remote)
        if pairing.pairedPeer == remote { shouldReconnect = true }
        stateLock.unlock()
        if shouldReconnect { scheduleTrustedReconnect() }
    }
}
#endif
