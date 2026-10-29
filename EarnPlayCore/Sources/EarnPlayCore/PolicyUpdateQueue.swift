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
///
/// ## Cross-instance safety
///
/// Like `PolicyStore.apply`, every reload–modify–persist operation
/// (`enqueue`, `removeDelivered`, intent recovery) runs under a
/// cross-instance file lock and re-reads the queue file first, so two
/// live instances over the same directory cannot clobber each other:
/// an instance that loaded `[v1]` before another instance enqueued
/// `v2` still sees `[v1, v2]` when it removes delivered `v1`, and
/// `v2` survives. Reads (`pendingUpdates`) serve the instance cache
/// without the file lock, mirroring `PolicyStore.currentPolicy`.
///
/// ## Save-intent journal (Finding 2 recovery)
///
/// `PolicyEditorSave.save` writes the update to the intent file
/// *before* advancing the admin `PolicyStore`, and deletes it after
/// the update is queued. If the app stops between the policy write
/// and the queue write, the next queue opened over the directory
/// re-merges the intent (recovery without another manual save), and
/// `PolicyEditorSave.recoverInterruptedSave` advances a store that
/// missed the policy write, then clears the intent. The merge is
/// idempotent (same-version entries replace in place), so a crash
/// between the merge and the intent delete safely re-merges.
public final class PolicyUpdateQueue: @unchecked Sendable {
    /// Pending-queue file name inside the queue directory.
    public static let queueFileName = "pending-policy-updates.json"
    /// Save-intent journal file name inside the queue directory.
    public static let saveIntentFileName = "policy-save-intent.json"
    /// Cross-instance lock file serializing reload–modify–persist.
    private static let lockFileName = "pending-policy-updates.lock"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var items: [PolicyUpdate]

    /// Opens the queue stored in `directory`, loading pending updates.
    ///
    /// Best-effort recovery runs here too: a save-intent journal left
    /// by an interrupted save is merged into the pending queue (under
    /// the cross-instance lock), so a version saved to the admin store
    /// but never queued is deliverable after relaunch. The intent file
    /// itself is left for `PolicyEditorSave.recoverInterruptedSave`,
    /// which clears it once the admin store is confirmed to hold it.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.items = Self.load(directory: directory, fileManager: fileManager) ?? []
        try? recoverSaveIntentLocked()
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
    /// Successive saves enqueue strictly increasing versions. A
    /// version already present is not duplicated: the stored entry is
    /// replaced in place. A version older than the queue head (only
    /// from intent recovery) is inserted in ascending version order,
    /// keeping creation order. The operation re-reads the queue file
    /// under the cross-instance lock first, so concurrent instances
    /// over the same directory cannot lose each other's updates.
    public func enqueue(_ update: PolicyUpdate) throws {
        lock.lock()
        defer { lock.unlock() }
        let lockFD = try acquireDirectoryLock()
        defer { releaseDirectoryLock(lockFD) }
        reloadLocked()
        insertLocked(update)
        try persistLocked()
    }

    /// Drops every pending update at or below `version` — the delivery
    /// confirmation hook for T4.6's SyncService.
    ///
    /// Like `enqueue`, this re-reads the queue file under the
    /// cross-instance lock first, so removing delivered versions never
    /// discards an update another instance enqueued meanwhile.
    public func removeDelivered(upToVersion version: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let lockFD = try acquireDirectoryLock()
        defer { releaseDirectoryLock(lockFD) }
        reloadLocked()
        items.removeAll(where: { $0.version <= version })
        try persistLocked()
    }

    // MARK: - Save-intent journal

    /// Durably records the update a save is about to persist to the
    /// admin store. Called before `PolicyStore.apply`; if the app
    /// stops after this point, the intent drives recovery.
    public func writeSaveIntent(_ update: PolicyUpdate) throws {
        let lockFD = try acquireDirectoryLock()
        defer { releaseDirectoryLock(lockFD) }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try PolicyUpdateCodec.encode(update)
        try data.write(
            to: directory.appendingPathComponent(Self.saveIntentFileName),
            options: [.atomic]
        )
    }

    /// Reads the save-intent journal, if any. A missing or corrupt
    /// file reads as no intent: a torn intent write means the save
    /// never reached the store, so there is nothing to recover.
    public func loadSaveIntent() -> PolicyUpdate? {
        let url = directory.appendingPathComponent(Self.saveIntentFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PolicyUpdateCodec.decode(data)
    }

    /// Deletes the save-intent journal, but only when its content
    /// still equals `expected`. A save that failed (stale or
    /// persistence) clears its own intent this way without risking a
    /// concurrent save's newer intent of the same version.
    public func clearSaveIntent(matching expected: PolicyUpdate) {
        guard let lockFD = try? acquireDirectoryLock() else { return }
        defer { releaseDirectoryLock(lockFD) }
        guard loadSaveIntent() == expected else { return }
        try? fileManager.removeItem(
            at: directory.appendingPathComponent(Self.saveIntentFileName)
        )
    }

    // MARK: - Internals (caller holds `lock` + file lock unless noted)

    /// Merges the save-intent journal into the pending queue (init and
    /// recovery path). Idempotent: re-merging replaces in place.
    private func recoverSaveIntentLocked() throws {
        let lockFD = try acquireDirectoryLock()
        defer { releaseDirectoryLock(lockFD) }
        reloadLocked()
        guard let intent = loadSaveIntent() else { return }
        let before = items
        insertLocked(intent)
        if items != before {
            try persistLocked()
        }
    }

    /// Inserts an update in ascending version order, replacing any
    /// entry with the same version in place.
    private func insertLocked(_ update: PolicyUpdate) {
        if let index = items.firstIndex(where: { $0.version == update.version }) {
            items[index] = update
            return
        }
        let at = items.firstIndex(where: { $0.version > update.version }) ?? items.endIndex
        items.insert(update, at: at)
    }

    /// Re-reads the cached queue from the persisted truth, so an
    /// instance created before another instance wrote still operates
    /// on current data. A missing or corrupt file reads as empty.
    private func reloadLocked() {
        items = Self.load(directory: directory, fileManager: fileManager) ?? []
    }

    // MARK: - Cross-instance lock (fail-closed; mirrors PolicyStore)

    private func acquireDirectoryLock() throws -> Int32 {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(Self.lockFileName)
        while true {
            do {
                let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard flock(fd, LOCK_EX) == 0 else {
                    let code = Int(errno)
                    close(fd)
                    throw NSError(domain: NSPOSIXErrorDomain, code: code)
                }
                return fd
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain
                    && Int32(error.code) == EINTR {
                continue
            }
        }
    }

    private func releaseDirectoryLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    // MARK: - Persistence (caller holds `lock` + file lock, except load)

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
