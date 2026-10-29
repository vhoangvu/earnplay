import Foundation

/// Child-side persistent outbox for SessionLogs (T4.6). A log stays
/// queued until the admin acks its sessionId; dedupe by sessionId.
public final class SessionLogQueue: @unchecked Sendable {
    public static let fileName = "pending-session-logs.json"
    private let directory: URL; private let lock = NSLock()
    private var items: [SessionLog]
    public init(directory: URL) {
        self.directory = directory
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
        try SessionLogCodec.encode(items).write(
            to: directory.appendingPathComponent(Self.fileName), options: [.atomic])
    }
    private static func load(directory: URL) -> [SessionLog]? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return try? SessionLogCodec.decodeList(d)
    }
}

/// Admin-side persistent store for received SessionLogs (T4.6).
/// `store` is idempotent by sessionId — the exactly-once anchor:
/// a redelivered log (lost ack) returns false and adds nothing.
public final class SessionLogStore: @unchecked Sendable {
    public static let fileName = "received-session-logs.json"
    private let directory: URL; private let lock = NSLock()
    private var items: [SessionLog]
    public init(directory: URL) {
        self.directory = directory
        self.items = Self.load(directory: directory) ?? []
    }
    public convenience init() { self.init(directory: PolicyStore.defaultDirectory()) }
    @discardableResult
    public func store(_ log: SessionLog) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items
        guard !items.contains(where: { $0.sessionId == log.sessionId }) else { return false }
        items.append(log)
        do { try persist() } catch { items = Self.load(directory: directory) ?? items; return false }
        return true
    }
    public var allLogs: [SessionLog] {
        lock.lock(); defer { lock.unlock() }
        items = Self.load(directory: directory) ?? items; return items
    }
    public func contains(sessionId: String) -> Bool { allLogs.contains { $0.sessionId == sessionId } }
    private func persist() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SessionLogCodec.encode(items).write(
            to: directory.appendingPathComponent(Self.fileName), options: [.atomic])
    }
    private static func load(directory: URL) -> [SessionLog]? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return try? SessionLogCodec.decodeList(d)
    }
}
