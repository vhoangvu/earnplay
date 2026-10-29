import Foundation

/// Wire message for T4.6 sync. Acks are keyed by business identity
/// (policy version / sessionId), so a lost ack + redelivery is safe:
/// receivers deduplicate on that same identity.
public enum SyncMessage: Codable, Equatable, Sendable {
    case policyUpdate(Policy)
    case sessionLog(SessionLog)
    case ackPolicy(version: Int)
    case ackSession(sessionId: String)
}

public enum SyncMessageCodec {
    public static func encode(_ m: SyncMessage) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]; return try e.encode(m)
    }
    public static func decode(_ d: Data) throws -> SyncMessage {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .deferredToDate
        return try dec.decode(SyncMessage.self, from: d)
    }
}

public enum SyncTransportError: Error, Equatable, Sendable { case notConnected, notPaired }

/// Byte transport seam. Production is MultipeerConnectivity
/// (Bluetooth/local, no account/server/internet); tests use the
/// in-memory stub below. Implementations must call `onReceive`
/// for inbound bytes and `onConnectionChange` on peer connect.
public protocol SyncTransport: AnyObject {
    var isConnected: Bool { get }
    var onReceive: ((Data) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
    func send(_ data: Data) throws
}

/// Shared link state for a stub pair; set `isUp = false` to kill the
/// transport mid-send, back to `true` to restore it.
public final class InMemorySyncLink: @unchecked Sendable {
    private let lock = NSLock(); private var up = true
    public init() {}
    public var isUp: Bool { get { lock.lock(); defer { lock.unlock() }; return up }
        set { lock.lock(); up = newValue; lock.unlock() } }
}

/// Transport stub (explicitly allowed by issue #23 in place of two
/// devices). Delivery is synchronous and in-order while the link is up.
public final class InMemorySyncTransport: SyncTransport, @unchecked Sendable {
    public let link: InMemorySyncLink
    private weak var peer: InMemorySyncTransport?
    private var started = false
    public var onReceive: ((Data) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?
    private init(link: InMemorySyncLink) { self.link = link }
    public static func pair() -> (InMemorySyncTransport, InMemorySyncTransport, InMemorySyncLink) {
        let link = InMemorySyncLink()
        let a = InMemorySyncTransport(link: link); let b = InMemorySyncTransport(link: link)
        a.peer = b; b.peer = a; return (a, b, link)
    }
    public var isConnected: Bool { started && peer != nil && link.isUp }
    public func start() { started = true; onConnectionChange?(isConnected) }
    public func stop() { started = false }
    public func send(_ data: Data) throws {
        guard isConnected, let peer, peer.started else { throw SyncTransportError.notConnected }
        peer.onReceive?(data)
    }
}
