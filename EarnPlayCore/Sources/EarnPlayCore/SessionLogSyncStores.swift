import Foundation

/// Child-side persistent outbox for SessionLogs (T4.6). A log stays
/// queued until the admin acks its sessionId; dedupe by sessionId.
public final class SessionLogQueue: @unchecked Sendable {
    public static let fileName = "pending-session-logs.json"
    private let directory: URL; private let lock = NSLock()
    private let dataWriter: (Data, URL) throws -> Void
    private var items: [SessionLog]
    public init(directory: URL, dataWriter: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.dataWriter = dataWriter ?? { data, url in try data.write(to: url, options: [.atomic]) }
        self.items = Self.load(directory: directory) ?? []
    }
    public convenience init() { self.init(directory: PolicyStore.defaultDirectory()) }
    public func enqueue(_ log: SessionLog) throws {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items
        if let i = items.firstIndex(where: { $0.sessionId == log.sessionId }) { items[i] = log }
        else { items.append(log) }
        do { try persist() } catch { items = Self.load(directory: directory) ?? []; throw error }
    }
    public func pending() -> [SessionLog] {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items; return items
    }
    public var isEmpty: Bool { pending().isEmpty }
    public func removeDelivered(sessionIds: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items
        items.removeAll { sessionIds.contains($0.sessionId) }
        do { try persist() } catch { items = Self.load(directory: directory) ?? []; throw error }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try dataWriter(SessionLogCodec.encode(items),
                       directory.appendingPathComponent(Self.fileName))
    }
    private static func load(directory: URL) -> [SessionLog]? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return try? SessionLogCodec.decodeList(d)
    }
}

/// Result of `SessionLogStore.storeResult` (finding 3): a durable
/// duplicate must be acked, a failed write must NOT be acked.
public enum SessionLogStoreResult: Equatable, Sendable { case stored, duplicate, failed }

/// Admin-side persistent store for received SessionLogs (T4.6).
/// Idempotent by sessionId — the exactly-once anchor.
public final class SessionLogStore: @unchecked Sendable {
    public static let fileName = "received-session-logs.json"
    /// Posted (object: the store) after a new log persists via `storeResult`.
    /// Duplicates and failures post nothing. The admin Progress view observes
    /// this to refresh its aggregates when a sync lands while open (T4.2 fix
    /// round 2, item 3); posted after the lock releases so observers can read.
    public static let didChangeNotification = Notification.Name("earnplay.SessionLogStore.didChange")
    private let directory: URL; private let lock = NSLock()
    private let dataWriter: (Data, URL) throws -> Void
    private var items: [SessionLog]
    public init(directory: URL, dataWriter: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.dataWriter = dataWriter ?? { data, url in try data.write(to: url, options: [.atomic]) }
        self.items = Self.load(directory: directory) ?? []
    }
    public convenience init() { self.init(directory: PolicyStore.defaultDirectory()) }
    public func storeResult(_ log: SessionLog) -> SessionLogStoreResult {
        let result: SessionLogStoreResult
        lock.lock()
        items = Self.load(directory: directory) ?? items
        if items.contains(where: { $0.sessionId == log.sessionId }) {
            result = .duplicate
        } else {
            items.append(log)
            do {
                try persist()
                result = .stored
            } catch {
                // Roll back any unpersisted cache change (finding 3).
                if let reloaded = Self.load(directory: directory) { items = reloaded }
                else { items.removeAll { $0.sessionId == log.sessionId } }
                result = .failed
            }
        }
        lock.unlock()
        if result == .stored {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return result
    }
    @discardableResult
    public func store(_ log: SessionLog) -> Bool { storeResult(log) == .stored }
    public var allLogs: [SessionLog] {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items; return items
    }
    public func contains(sessionId: String) -> Bool { allLogs.contains { $0.sessionId == sessionId } }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try dataWriter(SessionLogCodec.encode(items),
                       directory.appendingPathComponent(Self.fileName))
    }
    private static func load(directory: URL) -> [SessionLog]? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return try? SessionLogCodec.decodeList(d)
    }
}
