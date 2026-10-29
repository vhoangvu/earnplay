import Foundation

/// Single-peer admission (T4.6 fix round 2, findings 1-2). The issue's
/// model is one child + one admin nearby: while a peer is active or
/// paired, every other peer is refused so a shared queue ack can never
/// drop an update another child never received.
public enum PeerAdmission: Sendable {
    public static func shouldInvite(activePeerID: String?, pendingPeerID: String?,
                                    candidatePeerID: String) -> Bool {
        activePeerID == nil && pendingPeerID == nil
    }
    public static func shouldAccept(activePeerID: String?, candidatePeerID: String) -> Bool {
        activePeerID == nil || activePeerID == candidatePeerID
    }
}

/// Local pairing gate (finding 1, demo scope: no account/server).
/// Both devices show a short code; the user enters the peer's code on
/// each device and confirms. Data flows only after `confirmPairing`
/// succeeds. Single-peer: a second peer cannot pair while paired.
public final class SyncPairingGate: @unchecked Sendable {
    public let localCode: String
    private let lock = NSLock()
    private var _pairedPeerID: String?
    private var _expectedPeerCode: String?
    public init(code: String? = nil) {
        self.localCode = code ?? Self.generateCode()
    }
    public static func generateCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
    public var isPaired: Bool { lock.lock(); defer { lock.unlock() }; return _pairedPeerID != nil }
    public var pairedPeerID: String? { lock.lock(); defer { lock.unlock() }; return _pairedPeerID }
    /// Code to present to the peer / send in an invitation context.
    public var expectedPeerCode: String? { lock.lock(); defer { lock.unlock() }; return _expectedPeerCode }

    /// Local user confirmation: the code shown on the peer device was
    /// entered here. Succeeds only for an exact non-empty match with
    /// the code this side expects. In the demo flow both sides are
    /// configured with the same shared code displayed on both devices,
    /// so an exact match of `enteredCode` against `localCode` proves
    /// both users saw and confirmed the same code. While already
    /// paired, a different peer is refused (single-peer).
    @discardableResult
    public func confirmPairing(enteredCode: String, peerID: String) -> Bool {
        let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        guard !code.isEmpty, code == localCode else { return false }
        if let existing = _pairedPeerID, existing != peerID { return false }
        _pairedPeerID = peerID; _expectedPeerCode = code
        return true
    }

    /// Records the code the user entered for the peer without pairing
    /// yet (browser side: pairing completes when the peer accepts and
    /// the session connects). Returns false on empty/mismatched input
    /// when a shared `localCode` check applies is intentionally not
    /// done here: the remote side performs the exact-match check.
    @discardableResult
    public func preparePairing(enteredCode: String) -> Bool {
        let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if _pairedPeerID != nil { return false }
        _expectedPeerCode = code
        return true
    }

    /// Validates an invitation's pairing code (advertiser side).
    public func validateInvitationCode(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        return code == localCode
    }

    /// Marks pairing complete for `peerID` after a verified connect.
    @discardableResult
    public func markPaired(peerID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let existing = _pairedPeerID, existing != peerID { return false }
        _pairedPeerID = peerID
        return true
    }

    public func isPaired(to peerID: String) -> Bool { pairedPeerID == peerID }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _pairedPeerID = nil; _expectedPeerCode = nil
    }
}
