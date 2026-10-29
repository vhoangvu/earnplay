import Foundation

/// Admin side of T4.6 sync: PolicyUpdates DOWN (drained from the T4.1
/// PolicyUpdateQueue, removed only on ack), SessionLogs UP (stored
/// exactly once by sessionId, then acked — duplicates re-acked only).
public final class AdminSyncService: @unchecked Sendable {
    public let policyQueue: PolicyUpdateQueue
    public let sessionStore: SessionLogStore
    public let transport: any SyncTransport
    public init(policyQueue: PolicyUpdateQueue, sessionStore: SessionLogStore,
                transport: any SyncTransport) {
        self.policyQueue = policyQueue; self.sessionStore = sessionStore
        self.transport = transport
    }
    public func start() {
        transport.onReceive = { [weak self] in self?.handleReceived($0) }
        transport.onConnectionChange = { [weak self] up in if up { self?.flushPending() } }
        transport.start(); flushPending()
    }
    public func stop() { transport.stop() }
    /// (Re)send every queued PolicyUpdate. Safe anytime: the child
    /// discards stale versions and acks, so retry cannot duplicate.
    public func flushPending() {
        guard transport.isConnected else { return }
        for update in policyQueue.pendingUpdates() {
            guard let data = try? SyncMessageCodec.encode(.policyUpdate(update)),
                  (try? transport.send(data)) != nil else { return }
        }
    }
    public func handleReconnect() { flushPending() }
    public func handleReceived(_ data: Data) {
        guard let msg = try? SyncMessageCodec.decode(data) else { return }
        switch msg {
        case .sessionLog(let log):
            _ = sessionStore.store(log) // false on duplicate: still ack below
            if let ack = try? SyncMessageCodec.encode(.ackSession(sessionId: log.sessionId)) {
                try? transport.send(ack)
            }
        case .ackPolicy(let version):
            try? policyQueue.removeDelivered(upToVersion: version)
        case .policyUpdate, .ackSession: break // wrong direction; ignore
        }
    }
}

/// Child side of T4.6 sync: applies PolicyUpdates through PolicyStore
/// (newer wins; stale/replayed discarded but acked so admin dequeues;
/// persistence failure NOT acked so admin retries), and uploads
/// SessionLogs from the persistent outbox until acked.
public final class ChildSyncService: @unchecked Sendable {
    public let policyStore: PolicyStore
    public let sessionQueue: SessionLogQueue
    public let transport: any SyncTransport
    public init(policyStore: PolicyStore, sessionQueue: SessionLogQueue,
                transport: any SyncTransport) {
        self.policyStore = policyStore; self.sessionQueue = sessionQueue
        self.transport = transport
    }
    public func start() {
        transport.onReceive = { [weak self] in self?.handleReceived($0) }
        transport.onConnectionChange = { [weak self] up in if up { self?.flushPending() } }
        transport.start(); flushPending()
    }
    public func stop() { transport.stop() }
    /// Queue a finished session for upload and try to send now; if the
    /// transport is down it drains on reconnect with no re-run needed.
    public func sendSessionLog(_ log: SessionLog) throws {
        try sessionQueue.enqueue(log); flushPending()
    }
    public func flushPending() {
        guard transport.isConnected else { return }
        for log in sessionQueue.pending() {
            guard let data = try? SyncMessageCodec.encode(.sessionLog(log)),
                  (try? transport.send(data)) != nil else { return }
        }
    }
    public func handleReconnect() { flushPending() }
    public func handleReceived(_ data: Data) {
        guard let msg = try? SyncMessageCodec.decode(data) else { return }
        switch msg {
        case .policyUpdate(let policy):
            switch policyStore.apply(policy) {
            case .applied, .rejectedStaleVersion:
                if let ack = try? SyncMessageCodec.encode(.ackPolicy(version: policy.version)) {
                    try? transport.send(ack)
                }
            case .persistenceFailed: break // no ack: admin keeps it queued and retries
            }
        case .ackSession(let sessionId):
            try? sessionQueue.removeDelivered(sessionIds: [sessionId])
        case .sessionLog, .ackPolicy: break // wrong direction; ignore
        }
    }
}
