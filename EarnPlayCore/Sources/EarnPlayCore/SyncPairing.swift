import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Authenticated peer identity (T4.6 fix round 3, finding 1).
/// A display name is NOT an identity: every admin instance uses
/// "EarnPlay-Admin". Each device owns a stable identifier generated
/// once and never derived from the display name; admission, pairing,
/// and routing compare this value. Two peers that share a display
/// name but differ in `stableID` are different peers.
public struct PeerIdentity: Hashable, Codable, Sendable {
    public let stableID: String
    public let displayName: String
    public init(stableID: String, displayName: String) {
        self.stableID = stableID; self.displayName = displayName
    }
    public static func generate(displayName: String) -> PeerIdentity {
        PeerIdentity(stableID: UUID().uuidString, displayName: displayName)
    }
}

/// Invitation payload (finding 2): identity only. It NEVER carries a
/// pairing code or any secret, so a nearby advertiser that receives
/// an invitation learns nothing it could replay as proof.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public var version: Int = 1
    public let inviter: PeerIdentity
    public init(inviter: PeerIdentity) { self.inviter = inviter }
    public static func encode(_ v: PairingInvitation) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(v)
    }
    public static func decode(_ d: Data) throws -> PairingInvitation {
        try JSONDecoder().decode(PairingInvitation.self, from: d)
    }
}

/// Challenge-response primitives (finding 2). The response binds the
/// per-session challenge, both stable identities, and the peer code
/// the responder's user entered after seeing it on the verifier's
/// screen. The code itself is never transmitted: only this digest
/// crosses the (already MPC-encrypted) session, and only after the
/// advertiser's user explicitly accepted the invitation.
public enum PairingAuthenticator {
    public static func response(challenge: String, prover: PeerIdentity,
                                verifier: PeerIdentity, peerCode: String) -> String {
        digest("\(challenge)|\(prover.stableID)|\(verifier.stableID)|\(peerCode)")
    }
    public static func verify(response: String, challenge: String, prover: PeerIdentity,
                              verifier: PeerIdentity, localCode: String) -> Bool {
        response == digest("\(challenge)|\(prover.stableID)|\(verifier.stableID)|\(localCode)")
    }
    static func digest(_ s: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // FNV-1a fallback only where CryptoKit is unavailable (never on Apple SDKs).
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
        return String(h, radix: 16)
        #endif
    }
}

/// Single-peer admission (fix round 2 findings 1-2, corrected by
/// round 3 findings 1/5/6). A live connection blocks everyone else;
/// a trusted pairing (retained after a drop) blocks everyone except
/// that exact peer, which may reconnect without another manual
/// confirmation; an invitation is sent only once a code has been
/// entered, unless the candidate is the trusted paired peer.
public enum PeerAdmission: Sendable {
    public static func shouldInvite(livePeer: PeerIdentity?, pendingPeer: PeerIdentity?,
                                    candidate: PeerIdentity, trustedPairedPeer: PeerIdentity?) -> Bool {
        if let livePeer { return livePeer == candidate }
        if let pendingPeer { return pendingPeer == candidate }
        if let trustedPairedPeer { return trustedPairedPeer == candidate }
        return true
    }
    public static func shouldInviteNow(hasPeerCode: Bool, livePeer: PeerIdentity?, pendingPeer: PeerIdentity?,
                                       candidate: PeerIdentity, trustedPairedPeer: PeerIdentity?) -> Bool {
        guard hasPeerCode || trustedPairedPeer == candidate else { return false }
        return shouldInvite(livePeer: livePeer, pendingPeer: pendingPeer,
                            candidate: candidate, trustedPairedPeer: trustedPairedPeer)
    }
    public static func shouldAccept(livePeer: PeerIdentity?, candidate: PeerIdentity,
                                    trustedPairedPeer: PeerIdentity?) -> Bool {
        if let livePeer { return livePeer == candidate }
        if let trustedPairedPeer { return trustedPairedPeer == candidate }
        return true
    }
}

/// Retained discovered peers (finding 5): discovery before a code is
/// entered must not lose the peer, and Pair-retry returns failed or
/// timed-out peers to the invitation candidates.
public struct DiscoveredPeerBook: Sendable {
    private var peers: [PeerIdentity] = []
    private var invited: Set<String> = []
    private var failed: Set<String> = []
    public init() {}
    public mutating func retain(_ peer: PeerIdentity) {
        if !peers.contains(peer) { peers.append(peer) }
    }
    public mutating func markInvited(_ peer: PeerIdentity) { invited.insert(peer.stableID); failed.remove(peer.stableID) }
    public mutating func markFailed(_ peer: PeerIdentity) { invited.remove(peer.stableID); failed.insert(peer.stableID) }
    public mutating func clearInvitationState(_ peer: PeerIdentity) {
        invited.remove(peer.stableID); failed.remove(peer.stableID)
    }
    public func invitationCandidates(hasPeerCode: Bool, livePeer: PeerIdentity?,
                                     trustedPairedPeer: PeerIdentity?) -> [PeerIdentity] {
        peers.filter {
            !invited.contains($0.stableID) && !failed.contains($0.stableID)
                && PeerAdmission.shouldInviteNow(hasPeerCode: hasPeerCode, livePeer: livePeer,
                                                 pendingPeer: nil, candidate: $0,
                                                 trustedPairedPeer: trustedPairedPeer)
        }
    }
    @discardableResult
    public mutating func retryCandidates() -> [PeerIdentity] {
        let retry = peers.filter { failed.contains($0.stableID) }
        failed.removeAll(); invited.removeAll()
        return retry
    }
}

/// Local pairing gate (demo scope: no account/server). Each device
/// shows its own 6-digit code; each user enters the peer's code on
/// their own device. Pairing completes only after MUTUAL
/// challenge-response over the connected session: each side proves
/// knowledge of the other's code, which was never sent in the
/// invitation. Single-peer by stable identity.
public final class SyncPairingGate: @unchecked Sendable {
    public let localCode: String
    public let localIdentity: PeerIdentity
    private let lock = NSLock()
    private var _pairedPeer: PeerIdentity?
    private var _expectedPeerCode: String?
    public init(code: String? = nil, identity: PeerIdentity? = nil) {
        self.localCode = code ?? Self.generateCode()
        self.localIdentity = identity ?? PeerIdentity.generate(displayName: "EarnPlay")
    }
    public static func generateCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
    public var isPaired: Bool { lock.lock(); defer { lock.unlock() }; return _pairedPeer != nil }
    public var pairedPeer: PeerIdentity? { lock.lock(); defer { lock.unlock() }; return _pairedPeer }
    /// The peer code this side's user entered (never transmitted).
    public var expectedPeerCode: String? { lock.lock(); defer { lock.unlock() }; return _expectedPeerCode }
    public var hasEnteredPeerCode: Bool { expectedPeerCode != nil }

    /// Records the code the user entered for the peer. Pairing does
    /// NOT complete here: it completes after mutual verification.
    @discardableResult
    public func preparePairing(enteredCode: String) -> Bool {
        let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if _pairedPeer != nil { return false }
        _expectedPeerCode = code
        return true
    }

    /// Legacy local-confirmation path kept for the in-memory service
    /// tests: exact match against this device's own code, bound to a
    /// stable peer identity. While paired, a different peer (even
    /// with the same display name) is refused.
    @discardableResult
    public func confirmPairing(enteredCode: String, peer: PeerIdentity) -> Bool {
        let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        guard !code.isEmpty, code == localCode else { return false }
        if let existing = _pairedPeer, existing != peer { return false }
        _pairedPeer = peer; _expectedPeerCode = code
        return true
    }

    /// Builds this side's challenge response for `verifier`, proving
    /// knowledge of the code entered for that peer. Nil until a code
    /// has been entered: an advertiser that never went through the
    /// out-of-band comparison cannot answer.
    public func challengeResponse(toChallenge challenge: String, verifier: PeerIdentity) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let code = _expectedPeerCode, !code.isEmpty else { return nil }
        return PairingAuthenticator.response(challenge: challenge, prover: localIdentity,
                                             verifier: verifier, peerCode: code)
    }

    /// Verifies a peer's response against this device's own code.
    public func verifyChallengeResponse(_ response: String, toChallenge challenge: String,
                                        prover: PeerIdentity) -> Bool {
        PairingAuthenticator.verify(response: response, challenge: challenge, prover: prover,
                                    verifier: localIdentity, localCode: localCode)
    }

    /// Marks pairing complete for a stable peer identity after
    /// verified mutual authentication (or for the trusted peer on
    /// reconnection). A different identity is refused while paired.
    @discardableResult
    public func markPaired(peer: PeerIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let existing = _pairedPeer, existing != peer { return false }
        _pairedPeer = peer
        return true
    }

    public func isPaired(to peer: PeerIdentity) -> Bool { pairedPeer == peer }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _pairedPeer = nil; _expectedPeerCode = nil
    }
}
