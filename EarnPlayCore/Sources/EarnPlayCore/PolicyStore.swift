import Foundation

/// Outcome of handing a policy to `PolicyStore.apply(_:)`.
public enum PolicyApplyResult: Equatable, Sendable {
    /// The policy was newer than the cached one: stored and now enforced.
    case applied
    /// The policy's version was lower than or equal to the cached version
    /// and was discarded untouched (admin's newer version wins, LLD §8.2).
    case rejectedStaleVersion(currentVersion: Int)
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

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cached: Policy

    /// Creates a store over `directory`, loading any cached policy.
    ///
    /// Loading never throws and never crashes: a missing file yields
    /// `Policy.defaultPolicy`; a corrupt primary falls back to the backup;
    /// a corrupt backup too falls back to `Policy.defaultPolicy`.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
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
    /// (plus backup copy) before this returns `.applied`.
    @discardableResult
    public func apply(_ policy: Policy) -> PolicyApplyResult {
        lock.lock()
        defer { lock.unlock() }
        guard policy.version > cached.version else {
            return .rejectedStaleVersion(currentVersion: cached.version)
        }
        persist(policy)
        cached = policy
        return .applied
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

    private func persist(_ policy: Policy) {
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(policy)
            // Atomic replace: a crash mid-write leaves the old file intact.
            try data.write(
                to: directory.appendingPathComponent(Self.policyFileName),
                options: [.atomic]
            )
            // Last-good backup for the corrupt-primary fallback. Best
            // effort: the primary is already authoritative at this point.
            try? data.write(
                to: directory.appendingPathComponent(Self.backupFileName),
                options: [.atomic]
            )
        } catch {
            // Persistence failure must not crash enforcement: the accepted
            // policy still takes effect in memory for this process, and the
            // previous on-disk policy (or default) returns at next launch.
            // Deliberately no rethrow — `apply` has no throwing contract in
            // the LLD, and a disk error must never unlock anything by error.
        }
    }

    private static func load(directory: URL, fileManager: FileManager) -> Policy? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
