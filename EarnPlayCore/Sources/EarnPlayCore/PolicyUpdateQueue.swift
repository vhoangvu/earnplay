import Foundation

/// Pending `PolicyUpdate` queue on the admin app (T4.1; drained by T4.6).
///
/// Every `PolicyEditorSave.save` appends the new versioned policy here
/// in creation order (LLD §8.2: queued and sent at the next sync
/// opportunity, in creation order; no payload dropped for being old).
/// T4.6's SyncService reads `pendingUpdates()` and calls
/// `removeDelivered(upToVersion:)` once the child confirms receipt.
///
/// Persistence follows the `PolicyStore` precedent: one JSON file in a
/// directory, written atomically. A missing or corrupt file reads as an
/// empty queue — the admin's authored policy itself lives in the
/// admin-local `PolicyStore`, so queue corruption loses at most
/// redelivery of already-saved versions, which the parent can re-save.
public final class PolicyUpdateQueue: @unchecked Sendable {
    /// Pending-queue file name inside the queue directory.
    public static let queueFileName = "pending-policy-updates.json"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var items: [PolicyUpdate]

    /// Opens the queue stored in `directory`, loading pending updates.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.items = Self.load(directory: directory, fileManager: fileManager) ?? []
    }

    /// Opens the queue in the default on-device location:
    /// `Application Support/EarnPlay/` inside the app's container
    /// (shared with the admin-local `PolicyStore`).
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            directory: PolicyStore.defaultDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// Pending updates in creation order (oldest first).
    public func pendingUpdates() -> [PolicyUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// True when no update is waiting for delivery.
    public var isEmpty: Bool { pendingUpdates().isEmpty }

    /// Highest version waiting for delivery, if any.
    public var latestPendingVersion: Int? { pendingUpdates().last?.version }

    /// Appends an update to the pending queue and persists it.
    ///
    /// Versions are stamped `baseVersion + 1` by the save pipeline, so
    /// successive saves enqueue strictly increasing versions. A version
    /// already present is not duplicated: the stored entry is replaced
    /// in place, keeping creation order.
    public func enqueue(_ update: PolicyUpdate) throws {
        lock.lock()
        defer { lock.unlock() }
        if let index = items.firstIndex(where: { $0.version == update.version }) {
            items[index] = update
        } else {
            items.append(update)
        }
        try persistLocked()
    }

    /// Drops every pending update at or below `version` — the delivery
    /// confirmation hook for T4.6's SyncService.
    public func removeDelivered(upToVersion version: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll(where: { $0.version <= version })
        try persistLocked()
    }

    // MARK: - Persistence (caller holds `lock`, except load at init)

    private func persistLocked() throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try PolicyUpdateCodec.encode(items)
        try data.write(
            to: directory.appendingPathComponent(Self.queueFileName),
            options: [.atomic]
        )
    }

    private static func load(directory: URL, fileManager: FileManager) -> [PolicyUpdate]? {
        let url = directory.appendingPathComponent(queueFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode([PolicyUpdate].self, from: data)
    }
}
