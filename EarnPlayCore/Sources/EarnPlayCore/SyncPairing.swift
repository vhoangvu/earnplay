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
    /// Trusted-reconnect proof (round 4, H3): binds the per-session
    /// nonce and both stable identities to the pairing secret that
    /// was established during authenticated pairing. The secret is
    /// never the user-entered code and never the broadcast stableID.
    public static func trustedResponse(challenge: String, prover: PeerIdentity,
                                       verifier: PeerIdentity, secret: String) -> String {
        digest("trusted|\(challenge)|\(prover.stableID)|\(verifier.stableID)|\(secret)")
    }
    public static func verifyTrusted(response: String, challenge: String, prover: PeerIdentity,
                                     verifier: PeerIdentity, secret: String) -> Bool {
        response == trustedResponse(challenge: challenge, prover: prover, verifier: verifier, secret: secret)
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
        // Round 4 (H4): rediscovery revives the candidate — a peer
        // that failed or timed out before is invitable again.
        invited.remove(peer.stableID); failed.remove(peer.stableID)
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
/// Resolves transport peer handles to stable identities (round 4,
/// H2). MCPeerID equality is instance-based (verified empirically:
/// two instances with one displayName are unequal and do not share
/// a dictionary slot), so a handle names one live peer instance and
/// is bound to a stable identity learned from discovery info, the
/// invitation, or the handshake — never keyed by display name. On
/// rediscovery a new handle rebinds to the same stable identity and
/// becomes the handle used for sending. All access is serialized.
public final class PeerIdentityResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var identityByHandle: [String: PeerIdentity] = [:]
    private var handleByStableID: [String: String] = [:]
    public init() {}
    public func bind(_ identity: PeerIdentity, handle: String) {
        lock.lock(); defer { lock.unlock() }
        identityByHandle[handle] = identity
        handleByStableID[identity.stableID] = handle
    }
    public func identity(forHandle handle: String, fallbackDisplayName: String) -> PeerIdentity {
        lock.lock(); defer { lock.unlock() }
        // Unbound: an instance-scoped synthetic identity that can
        // never collide with another peer sharing the display name.
        return identityByHandle[handle] ?? PeerIdentity(stableID: "unbound:\(handle)", displayName: fallbackDisplayName)
    }
    public func identity(forStableID stableID: String) -> PeerIdentity? {
        lock.lock(); defer { lock.unlock() }
        guard let handle = handleByStableID[stableID] else { return nil }
        return identityByHandle[handle]
    }
    public func handle(forStableID stableID: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return handleByStableID[stableID]
    }
    public func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        identityByHandle.removeAll(); handleByStableID.removeAll()
    }
}

/// Delay schedule for trusted reconnect invitations (round 4, H4).
public struct ReconnectBackoff: Sendable {
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.baseDelay = baseDelay; self.maxDelay = maxDelay
    }
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        min(baseDelay * pow(2, Double(max(0, attempt))), maxDelay)
    }
}

/// Persisted pairing state (round 4, M7): installation identity,
/// its code, the authenticated paired peer, and the H3 secret.
public struct PersistedPairingState: Codable, Equatable, Sendable {
    public var localIdentity: PeerIdentity
    public var localCode: String
    public var pairedPeer: PeerIdentity?
    public var pairingSecrets: [String: String]
    public init(localIdentity: PeerIdentity, localCode: String,
                pairedPeer: PeerIdentity?, pairingSecrets: [String: String]) {
        self.localIdentity = localIdentity; self.localCode = localCode
        self.pairedPeer = pairedPeer; self.pairingSecrets = pairingSecrets
    }
}

/// UserDefaults-backed pairing store (round 4, M7). One consistent
/// store for identity, pairing, and secret across relaunch.
public final class SyncPairingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults; self.key = key
    }
    public func load() -> PersistedPairingState? {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPairingState.self, from: data)
    }
    public func save(_ state: PersistedPairingState) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
    /// Loads the persisted gate, or creates and persists a fresh
    /// identity on first launch. Later launches return the same
    /// identity, code, paired peer, and secret; every gate mutation
    /// is written back through `onStateChange`.
    public static func loadOrCreateGate(displayName: String, defaults: UserDefaults = .standard,
                                        key: String) -> SyncPairingGate {
        let store = SyncPairingStore(defaults: defaults, key: key)
        let gate: SyncPairingGate
        if let saved = store.load() {
            gate = SyncPairingGate(restoring: saved)
        } else {
            gate = SyncPairingGate(identity: PeerIdentity.generate(displayName: displayName))
            store.save(gate.persistedState())
        }
        gate.onStateChange = { [weak gate] in
            guard let gate else { return }
            store.save(gate.persistedState())
        }
        return gate
    }
}

public final class SyncPairingGate: @unchecked Sendable {
    public let localCode: String
    public let localIdentity: PeerIdentity
    private let lock = NSLock()
    private var _pairedPeer: PeerIdentity?
    private var _expectedPeerCode: String?
    // Round 4 (M6): pairing is provisional until BOTH directions
    // verify; round 4 (H3): per-peer secret from that pairing.
    private var _provisionalPeer: PeerIdentity?
    private var _verifiedRemote = false
    private var _verifiedByPeer = false
    private var _pairingSecrets: [String: String] = [:]
    private var _secretToShare: [String: String] = [:]
    /// Set once before the gate is shared; called after mutations
    /// that must persist (pairing, secret, unpair).
    public var onStateChange: (() -> Void)?
    public init(code: String? = nil, identity: PeerIdentity? = nil) {
        self.localCode = code ?? Self.generateCode()
        self.localIdentity = identity ?? PeerIdentity.generate(displayName: "EarnPlay")
    }
    public init(restoring state: PersistedPairingState) {
        self.localCode = state.localCode
        self.localIdentity = state.localIdentity
        self._pairedPeer = state.pairedPeer
        self._pairingSecrets = state.pairingSecrets
    }
    public func persistedState() -> PersistedPairingState {
        lock.lock(); defer { lock.unlock() }
        return PersistedPairingState(localIdentity: localIdentity, localCode: localCode,
                                     pairedPeer: _pairedPeer, pairingSecrets: _pairingSecrets)
    }
    private func notifyChanged() { onStateChange?() }
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
        lock.lock()
        guard !code.isEmpty, code == localCode else { lock.unlock(); return false }
        if let existing = _pairedPeer, existing != peer { lock.unlock(); return false }
        _pairedPeer = peer; _expectedPeerCode = code
        lock.unlock()
        notifyChanged()
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
        lock.lock()
        if let existing = _pairedPeer, existing != peer { lock.unlock(); return false }
        _pairedPeer = peer
        if _provisionalPeer == peer { _provisionalPeer = nil; _verifiedRemote = false; _verifiedByPeer = false }
        lock.unlock()
        notifyChanged()
        return true
    }

    public func isPaired(to peer: PeerIdentity) -> Bool { pairedPeer == peer }

    // MARK: - Provisional mutual pairing (round 4, M6)

    public var provisionalPeer: PeerIdentity? { lock.lock(); defer { lock.unlock() }; return _provisionalPeer }

    @discardableResult
    public func beginProvisional(peer: PeerIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let existing = _pairedPeer { return existing == peer }
        if let current = _provisionalPeer, current != peer { return false }
        _provisionalPeer = peer
        return true
    }

    /// This side verified the peer's challenge response. Returns
    /// true only once mutual confirmation has also arrived.
    @discardableResult
    public func recordRemoteVerified(peer: PeerIdentity) -> Bool {
        lock.lock()
        guard _provisionalPeer == peer || _pairedPeer == peer else { lock.unlock(); return false }
        if _provisionalPeer == nil { _provisionalPeer = peer }
        _verifiedRemote = true
        let promoted = promoteIfMutualLocked()
        lock.unlock()
        if promoted { notifyChanged() }
        return promoted
    }

    /// The peer confirmed it verified this side's response.
    @discardableResult
    public func recordPeerVerifiedLocal(peer: PeerIdentity) -> Bool {
        lock.lock()
        guard _provisionalPeer == peer || _pairedPeer == peer else { lock.unlock(); return false }
        if _provisionalPeer == nil { _provisionalPeer = peer }
        _verifiedByPeer = true
        let promoted = promoteIfMutualLocked()
        lock.unlock()
        if promoted { notifyChanged() }
        return promoted
    }

    private func promoteIfMutualLocked() -> Bool {
        guard let peer = _provisionalPeer, _verifiedRemote, _verifiedByPeer else { return false }
        if let existing = _pairedPeer, existing != peer { return false }
        _pairedPeer = peer
        _provisionalPeer = nil; _verifiedRemote = false; _verifiedByPeer = false
        return true
    }

    /// Verification failed: BOTH sides reset the attempt (the peer
    /// is told via the transport), entered codes are cleared so a
    /// corrected code is accepted, and no paired state remains.
    public func failProvisionalAttempt(peer: PeerIdentity) {
        lock.lock(); defer { lock.unlock() }
        guard _pairedPeer == nil else { return }
        if let current = _provisionalPeer, current != peer { return }
        _provisionalPeer = nil; _verifiedRemote = false; _verifiedByPeer = false
        _expectedPeerCode = nil
    }

    // MARK: - Pairing secret + trusted proof (round 4, H3)

    public func pairingSecret(for peer: PeerIdentity) -> String? {
        lock.lock(); defer { lock.unlock() }; return _pairingSecrets[peer.stableID]
    }

    /// After promotion, returns the secret to share with the peer
    /// over the encrypted session (generating it on first use).
    public func takeSecretToShare(for peer: PeerIdentity) -> String? {
        lock.lock()
        guard _pairedPeer == peer else { lock.unlock(); return nil }
        if let pending = _secretToShare[peer.stableID] { lock.unlock(); return pending }
        if let existing = _pairingSecrets[peer.stableID] { lock.unlock(); return existing }
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        _pairingSecrets[peer.stableID] = secret
        _secretToShare[peer.stableID] = secret
        lock.unlock()
        notifyChanged()
        return secret
    }

    /// Adopts a secret shared by the peer during pairing. When both
    /// sides generated one, the smaller stableID's secret wins on
    /// both sides so they converge on a single secret.
    public func adoptSharedSecret(_ secret: String, from peer: PeerIdentity) {
        lock.lock()
        guard _pairedPeer == peer || _provisionalPeer == peer else { lock.unlock(); return }
        if let existing = _pairingSecrets[peer.stableID], existing != secret {
            guard peer.stableID < localIdentity.stableID else { lock.unlock(); return }
        }
        _pairingSecrets[peer.stableID] = secret
        lock.unlock()
        notifyChanged()
    }

    public func trustedResponse(toChallenge challenge: String, peer: PeerIdentity) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let secret = _pairingSecrets[peer.stableID] else { return nil }
        return PairingAuthenticator.trustedResponse(challenge: challenge, prover: localIdentity,
                                                    verifier: peer, secret: secret)
    }

    public func verifyTrustedResponse(_ response: String, toChallenge challenge: String,
                                      prover: PeerIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let secret = _pairingSecrets[prover.stableID] else { return false }
        return PairingAuthenticator.verifyTrusted(response: response, challenge: challenge,
                                                  prover: prover, verifier: localIdentity, secret: secret)
    }

    /// Trusted proof is impossible or failed: drop the retained
    /// pairing so the peer falls back to full manual re-pairing.
    public func downgradeTrustedPairing(for peer: PeerIdentity) {
        lock.lock()
        guard _pairedPeer == peer else { lock.unlock(); return }
        _pairedPeer = nil; _provisionalPeer = nil
        _verifiedRemote = false; _verifiedByPeer = false
        _pairingSecrets.removeValue(forKey: peer.stableID)
        _secretToShare.removeValue(forKey: peer.stableID)
        _expectedPeerCode = nil
        lock.unlock()
        notifyChanged()
    }

    /// Reset/Unpair control (round 4, M7): clears the paired peer,
    /// provisional attempt, entered code, and secrets. The
    /// installation identity and its code are kept.
    public func unpair() {
        lock.lock()
        _pairedPeer = nil; _provisionalPeer = nil
        _verifiedRemote = false; _verifiedByPeer = false
        _expectedPeerCode = nil; _pairingSecrets.removeAll(); _secretToShare.removeAll()
        lock.unlock()
        notifyChanged()
    }

    public func reset() {
        lock.lock()
        _pairedPeer = nil; _expectedPeerCode = nil
        _provisionalPeer = nil; _verifiedRemote = false; _verifiedByPeer = false
        lock.unlock()
        notifyChanged()
    }
}
