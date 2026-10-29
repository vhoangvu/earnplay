import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Production T4.6 transport: MultipeerConnectivity only — local
/// peer-to-peer (Bluetooth / local Wi-Fi), no account, no server,
/// no internet. Admin browses and invites; child advertises and
/// accepts. Encrypted session, one peer at a time.
public final class MultipeerSyncTransport: NSObject, SyncTransport, @unchecked Sendable {
    public enum Role: Sendable { case browser, advertiser }
    public static let serviceType = "earnplay-sync"
    private let role: Role
    private let peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    public var onReceive: ((Data) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    public init(role: Role, displayName: String) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        super.init()
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
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        session?.disconnect(); session = nil
    }
    public func send(_ data: Data) throws {
        guard let session, !session.connectedPeers.isEmpty else {
            throw SyncTransportError.notConnected
        }
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension MultipeerSyncTransport: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID,
                        didChange state: MCSessionState) {
        onConnectionChange?(state == .connected)
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
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
        invitationHandler(true, session)
    }
}

extension MultipeerSyncTransport: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        guard let session else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
#endif
