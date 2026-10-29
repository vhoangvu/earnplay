import Foundation

/// Bounded ack-retry policy (finding 8): deadline + exponential backoff.
public struct SyncRetryConfiguration: Sendable {
    public var ackTimeout: TimeInterval
    public var maxRetries: Int
    public var backoffMultiplier: Double
    public var maxDelay: TimeInterval
    public init(ackTimeout: TimeInterval = 2, maxRetries: Int = 5,
                backoffMultiplier: Double = 2, maxDelay: TimeInterval = 30) {
        self.ackTimeout = ackTimeout; self.maxRetries = maxRetries
        self.backoffMultiplier = backoffMultiplier; self.maxDelay = maxDelay
    }
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        min(ackTimeout * pow(backoffMultiplier, Double(max(0, attempt))), maxDelay)
    }
}

/// Observable UI snapshots (findings 4-5), published on every mutation.
public struct ChildSyncSnapshot: Equatable, Sendable {
    public var policyVersion: Int; public var practiceMinutes: Int
    public var pendingUploads: Int; public var isPaired: Bool
    public init(policyVersion: Int, practiceMinutes: Int, pendingUploads: Int, isPaired: Bool) {
        self.policyVersion = policyVersion; self.practiceMinutes = practiceMinutes
        self.pendingUploads = pendingUploads; self.isPaired = isPaired
    }
}
public struct AdminSyncSnapshot: Equatable, Sendable {
    public var storedSessionCount: Int; public var sessionIDs: [String]
    public var pendingPolicies: Int; public var isPaired: Bool
    public init(storedSessionCount: Int, sessionIDs: [String], pendingPolicies: Int, isPaired: Bool) {
        self.storedSessionCount = storedSessionCount; self.sessionIDs = sessionIDs
        self.pendingPolicies = pendingPolicies; self.isPaired = isPaired
    }
}

/// Shared ack-retry engine: schedules bounded retries for unacked ids.
final class AckRetryEngine: @unchecked Sendable {
    private let config: SyncRetryConfiguration
    private let queue = DispatchQueue(label: "earnplay.sync.retry")
    private let lock = NSLock()
    private var work: [String: DispatchWorkItem] = [:]
    private var attempts: [String: Int] = [:]
    init(config: SyncRetryConfiguration) { self.config = config }
    func schedule(id: String, action: @escaping () -> Bool) {
        lock.lock()
        if work[id] != nil { lock.unlock(); return }
        let attempt = attempts[id] ?? 0
        guard attempt <= config.maxRetries else { lock.unlock(); return }
        lock.unlock()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.work[id] = nil; self.attempts[id] = attempt + 1; self.lock.unlock()
            if action() { self.schedule(id: id, action: action) }
        }
        lock.lock(); work[id] = item; lock.unlock()
        queue.asyncAfter(deadline: .now() + config.delay(forAttempt: attempt), execute: item)
    }
    func cancel(id: String) {
        lock.lock(); defer { lock.unlock() }
        work[id]?.cancel(); work[id] = nil; attempts[id] = nil
    }
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        work.values.forEach { $0.cancel() }; work.removeAll(); attempts.removeAll()
    }
}

/// Admin side: PolicyUpdates DOWN, SessionLogs UP. Ack a session only
/// after durable persistence or an already-persisted duplicate (F3).
public final class AdminSyncService: @unchecked Sendable {
    public let policyQueue: PolicyUpdateQueue
    public let sessionStore: SessionLogStore
    public let transport: any SyncTransport
    public let pairing: SyncPairingGate?
    private let retryEngine: AckRetryEngine
    private let snapLock = NSLock()
    private var _snapshot: AdminSyncSnapshot
    public var onSnapshotChange: ((AdminSyncSnapshot) -> Void)?
    public init(policyQueue: PolicyUpdateQueue, sessionStore: SessionLogStore,
                transport: any SyncTransport, pairing: SyncPairingGate? = nil,
                retry: SyncRetryConfiguration = SyncRetryConfiguration()) {
        self.policyQueue = policyQueue; self.sessionStore = sessionStore
        self.transport = transport; self.pairing = pairing
        self.retryEngine = AckRetryEngine(config: retry)
        self._snapshot = AdminSyncSnapshot(storedSessionCount: sessionStore.allLogs.count,
            sessionIDs: sessionStore.allLogs.map(\.sessionId),
            pendingPolicies: policyQueue.pendingUpdates().count, isPaired: pairing?.isPaired ?? true)
    }
    public var isPaired: Bool { pairing?.isPaired ?? true }
    public var snapshot: AdminSyncSnapshot { snapLock.lock(); defer { snapLock.unlock() }; return _snapshot }
    private func publishSnapshot() {
        let s = AdminSyncSnapshot(storedSessionCount: sessionStore.allLogs.count,
            sessionIDs: sessionStore.allLogs.map(\.sessionId),
            pendingPolicies: policyQueue.pendingUpdates().count, isPaired: isPaired)
        snapLock.lock(); _snapshot = s; snapLock.unlock()
        onSnapshotChange?(s)
    }
    @discardableResult
    public func confirmPairing(enteredCode: String, peerID: String) -> Bool {
        guard pairing?.confirmPairing(enteredCode: enteredCode, peerID: peerID) ?? false else { return false }
        publishSnapshot(); flushPending(); return true
    }
    public func start() {
        transport.onReceive = { [weak self] in self?.handleReceived($0) }
        transport.onConnectionChange = { [weak self] up in if up { self?.flushPending() } }
        transport.start(); flushPending(); publishSnapshot()
    }
    public func stop() { retryEngine.cancelAll(); transport.stop() }
    /// Called after a successful policy enqueue (finding 7).
    public func notifyPolicyEnqueued() { flushPending() }
    public func flushPending() {
        guard isPaired, transport.isConnected else { publishSnapshot(); return }
        for update in policyQueue.pendingUpdates() {
            guard let data = try? SyncMessageCodec.encode(.policyUpdate(update)),
                  (try? transport.send(data)) != nil else { return }
            let version = update.version
            retryEngine.schedule(id: "policy-\(version)") { [weak self] in
                guard let self, self.isPaired, self.transport.isConnected,
                      self.policyQueue.pendingUpdates().contains(where: { $0.version == version }),
                      let d = try? SyncMessageCodec.encode(.policyUpdate(update)) else { return false }
                return (try? self.transport.send(d)) != nil
            }
        }
        publishSnapshot()
    }
    public func handleReconnect() { flushPending() }
    public func handleReceived(_ data: Data) {
        guard let msg = try? SyncMessageCodec.decode(data) else { return }
        switch msg {
        case .sessionLog(let log):
            guard isPaired else { return }
            switch sessionStore.storeResult(log) {
            case .stored, .duplicate:
                publishSnapshot()
                if let ack = try? SyncMessageCodec.encode(.ackSession(sessionId: log.sessionId)) {
                    try? transport.send(ack)
                }
            case .failed: break // no ack: child retains outbox and retries (F3)
            }
        case .ackPolicy(let version):
            retryEngine.cancel(id: "policy-\(version)")
            try? policyQueue.removeDelivered(upToVersion: version)
            publishSnapshot()
        case .policyUpdate, .ackSession: break
        }
    }
}

/// Child side: applies PolicyUpdates (newer wins), uploads SessionLogs.
public final class ChildSyncService: @unchecked Sendable {
    public let policyStore: PolicyStore
    public let sessionQueue: SessionLogQueue
    public let transport: any SyncTransport
    public let pairing: SyncPairingGate?
    private let retryEngine: AckRetryEngine
    private let snapLock = NSLock()
    private var _snapshot: ChildSyncSnapshot
    public var onSnapshotChange: ((ChildSyncSnapshot) -> Void)?
    public init(policyStore: PolicyStore, sessionQueue: SessionLogQueue,
                transport: any SyncTransport, pairing: SyncPairingGate? = nil,
                retry: SyncRetryConfiguration = SyncRetryConfiguration()) {
        self.policyStore = policyStore; self.sessionQueue = sessionQueue
        self.transport = transport; self.pairing = pairing
        self.retryEngine = AckRetryEngine(config: retry)
        self._snapshot = ChildSyncSnapshot(policyVersion: policyStore.storedVersion,
            practiceMinutes: policyStore.currentPolicy.unlockDurations.practiceMinutes,
            pendingUploads: sessionQueue.pending().count, isPaired: pairing?.isPaired ?? true)
    }
    public var isPaired: Bool { pairing?.isPaired ?? true }
    public var snapshot: ChildSyncSnapshot { snapLock.lock(); defer { snapLock.unlock() }; return _snapshot }
    private func publishSnapshot() {
        let s = ChildSyncSnapshot(policyVersion: policyStore.storedVersion,
            practiceMinutes: policyStore.currentPolicy.unlockDurations.practiceMinutes,
            pendingUploads: sessionQueue.pending().count, isPaired: isPaired)
        snapLock.lock(); _snapshot = s; snapLock.unlock()
        onSnapshotChange?(s)
    }
    @discardableResult
    public func confirmPairing(enteredCode: String, peerID: String) -> Bool {
        guard pairing?.confirmPairing(enteredCode: enteredCode, peerID: peerID) ?? false else { return false }
        publishSnapshot(); flushPending(); return true
    }
    public func start() {
        transport.onReceive = { [weak self] in self?.handleReceived($0) }
        transport.onConnectionChange = { [weak self] up in if up { self?.flushPending() } }
        transport.start(); flushPending(); publishSnapshot()
    }
    public func stop() { retryEngine.cancelAll(); transport.stop() }
    public func sendSessionLog(_ log: SessionLog) throws {
        try sessionQueue.enqueue(log); publishSnapshot(); flushPending()
    }
    public func flushPending() {
        guard isPaired, transport.isConnected else { publishSnapshot(); return }
        for log in sessionQueue.pending() {
            guard let data = try? SyncMessageCodec.encode(.sessionLog(log)),
                  (try? transport.send(data)) != nil else { return }
            let sid = log.sessionId
            retryEngine.schedule(id: "session-\(sid)") { [weak self] in
                guard let self, self.isPaired, self.transport.isConnected,
                      self.sessionQueue.pending().contains(where: { $0.sessionId == sid }),
                      let d = try? SyncMessageCodec.encode(.sessionLog(log)) else { return false }
                return (try? self.transport.send(d)) != nil
            }
        }
        publishSnapshot()
    }
    public func handleReconnect() { flushPending() }
    public func handleReceived(_ data: Data) {
        guard let msg = try? SyncMessageCodec.decode(data) else { return }
        switch msg {
        case .policyUpdate(let policy):
            guard isPaired else { return }
            switch policyStore.apply(policy) {
            case .applied, .rejectedStaleVersion:
                publishSnapshot()
                if let ack = try? SyncMessageCodec.encode(.ackPolicy(version: policy.version)) {
                    try? transport.send(ack)
                }
            case .persistenceFailed: break
            }
        case .ackSession(let sessionId):
            retryEngine.cancel(id: "session-\(sessionId)")
            try? sessionQueue.removeDelivered(sessionIds: [sessionId])
            publishSnapshot()
        case .sessionLog, .ackPolicy: break
        }
    }
}

#if canImport(Combine)
import Combine

/// Observable UI snapshot holders (findings 4-5): views bind to these
/// so policy/queue/session mutations refresh the UI automatically
/// without a manual reload.
public final class ChildSyncUIState: ObservableObject {
    @Published public var snapshot: ChildSyncSnapshot
    public init(snapshot: ChildSyncSnapshot) { self.snapshot = snapshot }
}
public final class AdminSyncUIState: ObservableObject {
    @Published public var snapshot: AdminSyncSnapshot
    public init(snapshot: AdminSyncSnapshot) { self.snapshot = snapshot }
}
#endif
