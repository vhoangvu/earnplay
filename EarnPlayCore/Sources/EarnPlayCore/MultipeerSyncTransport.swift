import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Production T4.6 transport: MultipeerConnectivity only — local
/// peer-to-peer (Bluetooth / local Wi-Fi), no account, no server,
/// no internet. Pairing (F1): an invitation carries the browser's
/// pairing code; the advertiser accepts only on an exact match with
/// its own code and only after local confirmation via
/// `acceptPendingInvitation()`. Single-peer (F2): while a peer is
/// connected, invited, or paired, all other peers are refused.
public final class MultipeerSyncTransport: NSObject, SyncTransport, @unchecked Sendable {
    public enum Role: Sendable { case browser, advertiser }
    public static let serviceType = "earnplay-sync"
    private let role: Role
    private let peerID: MCPeerID
    public let pairing: SyncPairingGate
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingPeer: MCPeerID?
    private var pendingInvitationHandler: ((Bool, MCSession?) -> Void)?
    private var invitedPeerName: String?
    public var onReceive: ((Data) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    /// Advertiser side: a code-verified peer asked to pair; the UI
    /// shows the code and calls accept/reject after user confirmation.
    public var onPairingRequest: ((String) -> Void)?
    public init(role: Role, displayName: String, pairing: SyncPairingGate? = nil) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        self.pairing = pairing ?? SyncPairingGate()
        super.init()
    }
    public var pairingCode: String { pairing.localCode }
    public var isPaired: Bool { pairing.isPaired }
    public var hasPendingPairingRequest: Bool { pendingInvitationHandler != nil }
    @discardableResult
    public func acceptPendingInvitation() -> Bool {
        guard let handler = pendingInvitationHandler, let peer = pendingPeer else { return false }
        guard pairing.markPaired(peerID: peer.displayName) else { return false }
        handler(true, session)
        pendingInvitationHandler = nil; pendingPeer = nil
        return true
    }
    public func rejectPendingInvitation() {
        pendingInvitationHandler?(false, nil)
        pendingInvitationHandler = nil; pendingPeer = nil
    }
    public var isConnected: Bool { !(session?.connectedPeers.isEmpty ?? true) }
    public func start() {
        let s = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self; session = s
        switch role {
        case .advertiser:
            let a = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil,
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
        session?.disconnect(); session = nil; invitedPeerName = nil
    }
    public func send(_ data: Data) throws {
        guard pairing.isPaired else { throw SyncTransportError.notPaired }
        guard let session, !session.connectedPeers.isEmpty else {
            throw SyncTransportError.notConnected
        }
        // Single-peer: send only to the paired peer.
        let targets = session.connectedPeers.filter { $0.displayName == pairing.pairedPeerID }
        guard !targets.isEmpty else { throw SyncTransportError.notConnected }
        try session.send(data, toPeers: targets, with: .reliable)
    }
}

extension MultipeerSyncTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID,
                        didChange state: MCSessionState) {
        if state == .connected {
            if role == .browser {
                // Invitation accepted implies the advertiser verified
                // the code; complete pairing for the connected peer.
                _ = pairing.markPaired(peerID: peerID.displayName)
            }
            if let paired = pairing.pairedPeerID, paired != peerID.displayName {
                session.disconnect()
                return
            }
        }
        if state == .notConnected, pairing.pairedPeerID == peerID.displayName {
            invitedPeerName = nil
        }
        onConnectionChange?(state == .connected && pairing.isPaired)
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard pairing.isPaired(to: peerID.displayName) else { return }
        onReceive?(data)
    }
    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession,
                        didStartReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession,
                        didFinishReceivingResourceWithName resourceName: String,
                        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerSyncTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let active = session?.connectedPeers.first?.displayName
        guard PeerAdmission.shouldAccept(activePeerID: active ?? pairing.pairedPeerID,
                                         candidatePeerID: peerID.displayName),
              pendingInvitationHandler == nil else {
            invitationHandler(false, nil); return
        }
        let code = context.flatMap { String(data: $0, encoding: .utf8) }
        guard pairing.validateInvitationCode(code) else {
            invitationHandler(false, nil); return // unpaired/wrong code: rejected (F1)
        }
        pendingPeer = peerID; pendingInvitationHandler = invitationHandler
        if onPairingRequest != nil { onPairingRequest?(peerID.displayName) }
        else { _ = acceptPendingInvitation() } // no UI handler: code match is the confirmation
    }
}

extension MultipeerSyncTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        guard let session else { return }
        let active = session.connectedPeers.first?.displayName
        guard PeerAdmission.shouldInvite(activePeerID: active ?? pairing.pairedPeerID,
                                         pendingPeerID: invitedPeerName,
                                         candidatePeerID: peerID.displayName) else { return }
        invitedPeerName = peerID.displayName
        let code = pairing.expectedPeerCode ?? pairing.localCode
        browser.invitePeer(peerID, to: session, withContext: code.data(using: .utf8), timeout: 30)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if invitedPeerName == peerID.displayName { invitedPeerName = nil }
    }
}
#endif
