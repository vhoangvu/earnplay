import Foundation

/// Outcome of handing a policy to `PolicyStore.apply(_:)`.
public enum PolicyApplyResult: Equatable, Sendable {
    /// The policy was newer than the cached one: stored and now enforced.
    case applied
    /// The policy's version was lower than or equal to the cached version
    /// and was discarded untouched (admin's newer version wins, LLD §8.2).
    case rejectedStaleVersion(currentVersion: Int)
    /// The policy was newer but could not be persisted. The cached policy
    /// and version are unchanged, so the caller may retry the same update
    /// once writing works — it is not rejected as stale.
    case persistenceFailed(currentVersion: Int)
}

/// Versioned policy store on the child device (LLD `PolicyStore`, T2.1).
///
/// Persists the last-known `Policy` and is the single source the other
/// child modules read policy from. It accepts a policy only when its
/// version is higher than the stored version, so on any conflict the
/// admin's newer version wins and stale or replayed updates are discarded
/// — including without touching the on-disk cache.
///
/// ## Persistence choice
///
/// The codebase has no on-device store today: no SwiftData, Core Data, or
/// `UserDefaults` persistence exists anywhere in the repo, and the only
/// storage precedent is `ModelRuntime` resolving files with `FileManager`
/// directory URLs. This store follows that precedent: the policy is a
/// `Codable` JSON file in Application Support, written atomically, with a
/// second copy kept as the last-good backup. A single-file JSON record is
/// the right size for one versioned policy — it needs no schema migration
/// machinery, survives inspection in tests, and (unlike `UserDefaults`)
/// supports the atomic-replace + corrupt-file fallback the T2.1
/// acceptance criteria require. Introducing SwiftData/Core Data for one
/// record would add a model stack neither app currently carries.
///
/// Corruption handling: if the primary file fails to decode (truncated
/// write, partial sync artifact), loading falls back to the backup copy;
/// if both are unreadable, the store vends `Policy.defaultPolicy`
/// (safe default-deny). It never crashes and never unlocks everything.
///
/// ## T2.2 enforcement integration point
///
/// T2.2's ShieldManager (and the trade managers / EffortScorer) read only
/// from here — they never parse the file or talk to sync directly:
///
/// - `currentPolicy.alwaysAllowed` — never shield these apps.
/// - `currentPolicy.unblockable` minus `neverUnlockableOverrides`
///   (see `Policy.isChallengeUnlockable`) — shielded, challenge may open.
/// - Everything else enumerated at setup — shielded, no challenge.
/// - `currentPolicy.unlockDurations` / `movementSettings` — unlock timers.
/// - `currentPolicy.tradeCaps`, `chorePool`, `effortFloorSettings` —
///   offer caps, chore selection, and the effort floor.
/// - `storedVersion` — reported to SyncService for version comparison.
///
/// The store does no shielding itself: no FamilyControls, ManagedSettings,
/// or Shield API is used here (enforcement is T2.2, behind its entitlement).
public final class PolicyStore: @unchecked Sendable {
    /// Primary cache file name inside the store directory.
    public static let policyFileName = "policy.json"
    /// Last-good backup file name inside the store directory.
    public static let backupFileName = "policy-backup.json"
    /// Cross-instance lock file serializing compare-and-write in `apply`.
    private static let lockFileName = "policy.lock"

    private let directory: URL
    private let fileManager: FileManager
    private let dataWriter: (Data, URL) throws -> Void
    private let lock = NSLock()
    private var cached: Policy

    /// Creates a store over `directory`, loading any cached policy.
    ///
    /// Loading never throws and never crashes: a missing file yields
    /// `Policy.defaultPolicy`; a corrupt primary falls back to the backup;
    /// a corrupt backup too falls back to `Policy.defaultPolicy`.
    ///
    /// `dataWriter` is the persistence seam: it writes encoded policy data
    /// to a file URL and must throw on failure. Production uses the default
    /// atomic `Data.write`; tests inject a throwing writer to exercise the
    /// persistence-failure path deterministically. It has no other effect.
    public init(
        directory: URL,
        fileManager: FileManager = .default,
        dataWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.dataWriter = dataWriter ?? { data, url in
            try data.write(to: url, options: [.atomic])
        }
        self.cached = Self.load(directory: directory, fileManager: fileManager)
            ?? .defaultPolicy
    }

    /// Creates a store in the default on-device location:
    /// `Application Support/EarnPlay/` inside the app's container.
    public convenience init(fileManager: FileManager = .default) {
        self.init(directory: Self.defaultDirectory(fileManager: fileManager),
                  fileManager: fileManager)
    }

    /// Default store directory (Application Support, created on demand).
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("EarnPlay", isDirectory: true)
    }

    /// The last-known policy; the enforcement source of truth on device.
    public var currentPolicy: Policy {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Stored version, for sync comparison (LLD `PolicyStore` outputs).
    public var storedVersion: Int { currentPolicy.version }

    /// Applies a policy received from SyncService (a `PolicyUpdate`).
    ///
    /// Only a strictly higher version is stored; a lower or equal version
    /// is rejected without changing memory or disk, so the admin's newer
    /// version always wins. An accepted policy is persisted atomically
    /// (plus backup copy) before the cache advances and this returns
    /// `.applied`. If persistence fails, the cache is left unchanged and
    /// `.persistenceFailed` is returned, so the same version can be
    /// retried once writing works — it is not rejected as stale.
    @discardableResult
    public func apply(_ policy: Policy) -> PolicyApplyResult {
        lock.lock()
        defer { lock.unlock() }
        // Serialize compare-and-write across live instances over the same
        // directory (the instance lock alone cannot), then compare against
        // the persisted truth — not just this instance's cache — so a store
        // created before another store wrote v2 still rejects v1.
        let lockFD = acquireDirectoryLock()
        defer { releaseDirectoryLock(lockFD) }
        if let persisted = Self.load(directory: directory, fileManager: fileManager),
           persisted.version > cached.version {
            cached = persisted
        }
        guard policy.version > cached.version else {
            return .rejectedStaleVersion(currentVersion: cached.version)
        }
        do {
            try persist(policy)
        } catch {
            return .persistenceFailed(currentVersion: cached.version)
        }
        cached = policy
        return .applied
    }

    // MARK: - Cross-instance lock (best effort; re-read above is the guard)

    private func acquireDirectoryLock() -> Int32 {
        try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(Self.lockFileName)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return -1 }
        flock(fd, LOCK_EX)
        return fd
    }

    private func releaseDirectoryLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// Re-reads the cache from disk — the relaunch-equivalent reload.
    ///
    /// Uses the same fallback chain as initialization (primary, backup,
    /// default-deny) and replaces the in-memory policy with the result.
    @discardableResult
    public func reloadFromDisk() -> Policy {
        lock.lock()
        defer { lock.unlock() }
        let loaded = Self.load(directory: directory, fileManager: fileManager)
            ?? .defaultPolicy
        cached = loaded
        return loaded
    }

    // MARK: - Persistence (caller holds `lock`, except load at init)

    private func persist(_ policy: Policy) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        // `.deferredToDate` preserves fractional seconds (e.g. a chore
        // expiry of 1_800_000_000.125); `.iso8601` would truncate them.
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(policy)
        // Atomic replace: a crash mid-write leaves the old file intact.
        // A failure here propagates: `apply` reports it and does not
        // advance the cached version.
        try dataWriter(data, directory.appendingPathComponent(Self.policyFileName))
        // Last-good backup for the corrupt-primary fallback. Best
        // effort: the primary is already authoritative at this point.
        try? dataWriter(data, directory.appendingPathComponent(Self.backupFileName))
    }

    private static func load(directory: URL, fileManager: FileManager) -> Policy? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        for name in [policyFileName, backupFileName] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let policy = try? decoder.decode(Policy.self, from: data)
            else { continue }
            return policy
        }
        return nil
    }
}
