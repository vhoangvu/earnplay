import Foundation

/// Errors from version-bundle registration and selection (T5.3).
public enum VersioningError: Error, Equatable, Sendable {
    case unknownBundle(String)
    case emptyVersionField(bundleID: String, field: String)
    case noPreviousBundle
    case artifactUnavailable(bundleID: String, artifact: String)
}

public struct VersionBundle: Equatable, Sendable, Codable {
    public let bundleID: String
    public let modelVersion: String
    public let promptVersion: String
    public let modelFilePath: String?
    public let promptTexts: [String]?
    /// SHA-256 (hex) of the model file contents when bound.
    public let modelContentDigest: String?

    public init(bundleID: String, modelVersion: String, promptVersion: String,
                modelFilePath: String? = nil, promptTexts: [String]? = nil,
                modelContentDigest: String? = nil) {
        self.bundleID = bundleID
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
        self.modelFilePath = modelFilePath
        self.promptTexts = promptTexts
        self.modelContentDigest = modelContentDigest
    }
}

public struct InferenceArtifacts: Equatable, Sendable {
    public let modelVersion: String
    public let promptVersion: String
    public let modelURL: URL?
    public let prompts: [String]
    /// SHA-256 the loaded model file must still match at load time.
    public let modelContentDigest: String?
    public init(modelVersion: String, promptVersion: String, modelURL: URL?, prompts: [String],
                modelContentDigest: String? = nil) {
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
        self.modelURL = modelURL
        self.prompts = prompts
        self.modelContentDigest = modelContentDigest
    }
}

private struct PersistedRegistryState: Codable {
    var bundles: [VersionBundle]
    var activeBundleID: String
    /// Registry-owned snapshot paths (round 5 F4), stored relative
    /// to the registry directory like snapshot model paths (F8).
    var ownedSnapshotPaths: [String] = []
    /// Round 7 item 2: snapshots pending retirement, persisted so
    /// an interrupted cleanup survives process termination and is
    /// swept on recovery. Stored like `ownedSnapshotPaths` (F8).
    var pendingRetirementPaths: [String] = []

    private enum CodingKeys: String, CodingKey {
        case bundles, activeBundleID, ownedSnapshotPaths, pendingRetirementPaths
    }
    init(bundles: [VersionBundle], activeBundleID: String, ownedSnapshotPaths: [String] = [],
         pendingRetirementPaths: [String] = []) {
        self.bundles = bundles
        self.activeBundleID = activeBundleID
        self.ownedSnapshotPaths = ownedSnapshotPaths
        self.pendingRetirementPaths = pendingRetirementPaths
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundles = try c.decode([VersionBundle].self, forKey: .bundles)
        activeBundleID = try c.decode(String.self, forKey: .activeBundleID)
        ownedSnapshotPaths = try c.decodeIfPresent([String].self, forKey: .ownedSnapshotPaths) ?? []
        pendingRetirementPaths = try c.decodeIfPresent([String].self, forKey: .pendingRetirementPaths) ?? []
    }
}

/// Round 6 F1: child-app rollback controls are debug-only.
/// The child `SpikeView` compiles its rollback section only in
/// `DEBUG` builds and checks this policy; the production rollback
/// path is the separate EarnPlayAdmin operator app (see
/// Docs/VersioningAndRollback.md), not the child app.
public enum RollbackControlPolicy: Sendable {
    public static var allowsChildAppRollbackControls: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

public final class VersionRegistry: @unchecked Sendable {
    public static let previousKnownGoodBundleID = "previous-known-good"

    private static let storeLocksGuard = NSLock()
    private nonisolated(unsafe) static var storeLocks: [String: NSRecursiveLock] = [:]
    private static func sharedLock(for storeURL: URL?) -> NSRecursiveLock {
        guard let storeURL else { return NSRecursiveLock() }
        let key = storeURL.standardizedFileURL.path
        storeLocksGuard.lock(); defer { storeLocksGuard.unlock() }
        if let existing = storeLocks[key] { return existing }
        let created = NSRecursiveLock()
        storeLocks[key] = created
        return created
    }

    private let lock: NSRecursiveLock
    private var bundlesByID: [String: VersionBundle] = [:]
    private var orderedIDs: [String] = []
    private var _activeBundleID: String
    private let storeURL: URL?
    /// Absolute paths of snapshots this registry created (F4).
    private var ownedSnapshotPaths: Set<String> = []
    /// Round 7 item 2: standardized paths pending retirement for
    /// this store, mirrored into `PersistedRegistryState` so the
    /// cleanup survives termination (in-memory marker is static
    /// `pendingRetirements`; this set is its persisted form).
    private var pendingRetirementPaths: Set<String> = []
    /// Round 5 F9: optional load validation run against a
    /// candidate's artifacts before its selection is committed.
    /// The app layer installs a validator that loads the candidate
    /// with `ModelRuntime`; core tests install a stub. When the
    /// validator throws, the prior selection is left untouched.
    public var candidateLoadValidator: (@Sendable (InferenceArtifacts) throws -> Void)?

    // Round 6 F4: snapshots handed to a resolved session are
    // retained (process-wide, keyed by standardized path) until
    // that session releases them; retirement is deferred, not
    // performed solely from current registry entries.
    private static let retentionGuard = NSLock()
    private nonisolated(unsafe) static var retentionCounts: [String: Int] = [:]
    private nonisolated(unsafe) static var pendingRetirements: Set<String> = []

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Test-only (@testable, internal): simulate process
    /// termination by dropping all in-memory retention state.
    /// Persisted registry state on disk is left untouched.
    static func simulateProcessTerminationForTesting() {
        retentionGuard.lock(); defer { retentionGuard.unlock() }
        retentionCounts.removeAll()
        pendingRetirements.removeAll()
    }
    private static func retainSnapshot(atPath path: String) {
        let key = standardized(path)
        retentionGuard.lock(); defer { retentionGuard.unlock() }
        retentionCounts[key, default: 0] += 1
    }
    private static func retentionCount(forPath path: String) -> Int {
        retentionGuard.lock(); defer { retentionGuard.unlock() }
        return retentionCounts[standardized(path)] ?? 0
    }

    /// Retain the model file behind resolved artifacts when it is
    /// a registry-owned snapshot. Caller must hold `lock`.
    private func retainResolvedArtifacts(_ artifacts: InferenceArtifacts) {
        guard let url = artifacts.modelURL,
              isRegistryOwnedSnapshot(url.path) else { return }
        Self.retainSnapshot(atPath: url.path)
    }

    /// Release artifacts previously returned by
    /// `inferenceArtifacts()` / `inferenceSession(sessionId:)`.
    /// When the last resolved session releases a snapshot whose
    /// retirement was deferred, the file is retired then — and
    /// only if no registered bundle references it again.
    public func releaseInferenceArtifacts(_ artifacts: InferenceArtifacts) {
        guard let url = artifacts.modelURL else { return }
        let key = Self.standardized(url.path)
        Self.retentionGuard.lock()
        let count = Self.retentionCounts[key] ?? 0
        if count > 1 { Self.retentionCounts[key] = count - 1 }
        else { Self.retentionCounts.removeValue(forKey: key) }
        let isPending = Self.pendingRetirements.contains(key)
        Self.retentionGuard.unlock()
        guard count <= 1, isPending else { return }
        lock.lock(); defer { lock.unlock() }
        // Round 7 item 1: a failed reload must not proceed to
        // deletion or persist stale in-memory state over a corrupt
        // or unreadable registry. Leave the retirement pending
        // (in-memory + persisted) for a later successful reload.
        do { try reloadPersistedLocked() } catch { return }
        Self.retentionGuard.lock()
        if bundlesByID.values.contains(where: {
            $0.modelFilePath.map { Self.standardized($0) == key } ?? false
        }) {
            Self.pendingRetirements.remove(key)
            Self.retentionGuard.unlock()
            pendingRetirementPaths.remove(key)
            try? persistLocked()
            return
        }
        Self.pendingRetirements.remove(key)
        Self.retentionGuard.unlock()
        pendingRetirementPaths.remove(key)
        guard isRegistryOwnedSnapshot(key) else {
            try? persistLocked()
            return
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: key))
        ownedSnapshotPaths.remove(key)
        try? persistLocked()
    }

    private var registryDirectory: URL? { storeURL?.deletingLastPathComponent() }

    /// F8: persist paths inside the registry directory relative to
    /// it, so a restored container resolves them locally.
    private func storedPath(forAbsolute path: String) -> String {
        guard let dir = registryDirectory else { return path }
        let dirPath = dir.standardizedFileURL.path
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        guard std.hasPrefix(dirPath + "/") else { return path }
        return String(std.dropFirst(dirPath.count + 1))
    }

    /// Resolve a stored path against the current registry
    /// directory. Legacy absolute paths from an old container are
    /// migrated when the file now lives beside the registry (F8).
    private func resolvedPath(forStored path: String) -> String {
        guard let dir = registryDirectory else { return path }
        if !path.hasPrefix("/") {
            return dir.appendingPathComponent(path).path
        }
        if !FileManager.default.fileExists(atPath: path) {
            let migrated = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            if FileManager.default.fileExists(atPath: migrated.path) {
                return migrated.path
            }
        }
        return path
    }

    private func resolvedBundle(_ bundle: VersionBundle) -> VersionBundle {
        guard let path = bundle.modelFilePath else { return bundle }
        let resolved = resolvedPath(forStored: path)
        guard resolved != path else { return bundle }
        return VersionBundle(bundleID: bundle.bundleID, modelVersion: bundle.modelVersion,
                             promptVersion: bundle.promptVersion, modelFilePath: resolved,
                             promptTexts: bundle.promptTexts,
                             modelContentDigest: bundle.modelContentDigest)
    }

    private func isRegistryOwnedSnapshot(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if ownedSnapshotPaths.contains(std) { return true }
        // Legacy snapshots created before ownership tracking used
        // this naming scheme inside the registry directory.
        guard let dir = registryDirectory else { return false }
        let url = URL(fileURLWithPath: std)
        return url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path
            && url.lastPathComponent.hasPrefix("previous-known-good-model-")
    }

    public var activeBundleID: String {
        get throws {
            lock.lock(); defer { lock.unlock() }
            try reloadPersistedLocked()
            return _activeBundleID
        }
    }

    public init(bundles: [VersionBundle], activeBundleID: String, storeURL: URL? = nil) throws {
        for bundle in bundles { try Self.validate(bundle) }
        let ids = bundles.map(\.bundleID)
        guard Set(ids).count == ids.count, ids.contains(activeBundleID) else {
            throw VersioningError.unknownBundle(activeBundleID)
        }
        self.lock = Self.sharedLock(for: storeURL)
        self.storeURL = storeURL
        self._activeBundleID = activeBundleID
        for bundle in bundles {
            let bound = Self.enriched(resolvedBundle(bundle), bindDefaultModel: true)
            bundlesByID[bound.bundleID] = bound
            orderedIDs.append(bound.bundleID)
        }
        if storeURL != nil {
            lock.lock(); defer { lock.unlock() }
            try persistLocked()
        }
    }

    public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("EarnPlay/version-registry.json")
    }

    public static func production(
        storeURL: URL? = nil,
        modelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> VersionRegistry {
        let url = storeURL ?? defaultStoreURL()
        // Round 4 F3: hold the shared per-store lock across the
        // entire existence check, restore/create, and refresh
        // transaction so a concurrent instance cannot be overwritten.
        let shared = sharedLock(for: url)
        shared.lock(); defer { shared.unlock() }
        let current = makeCurrentBundle(modelURL: modelURL)
        // F1/F2: restore persisted registry independently of current
        // artifact validity; propagate corrupt-store errors.
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(PersistedRegistryState.self, from: data)
            guard !state.bundles.isEmpty else {
                throw VersioningError.unknownBundle(state.activeBundleID)
            }
            let registry = try VersionRegistry(
                bundles: state.bundles, activeBundleID: state.activeBundleID, storeURL: url
            )
            registry.restoreOwnedSnapshotPaths(state.ownedSnapshotPaths)
            registry.restorePendingRetirements(state.pendingRetirementPaths)
            try registry.refreshCurrentBundle(current)
            registry.restoreOwnedSnapshotPaths(state.ownedSnapshotPaths)
            registry.restorePendingRetirements(state.pendingRetirementPaths)
            registry.sweepOrphanedOwnedSnapshotsOnRecovery()
            return registry
        }
        return try VersionRegistry(bundles: [current], activeBundleID: "current", storeURL: url)
    }

    private static func makeCurrentBundle(modelURL: URL?) -> VersionBundle {
        guard let modelURL else {
            return VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                                 promptVersion: SpikePrompts.version, promptTexts: SpikePrompts.all)
        }
        // F8: bind supplied path to the bundle regardless of validity;
        // validation is deferred to select/inference (F1).
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                                 promptVersion: SpikePrompts.version,
                                 modelFilePath: modelURL.path, promptTexts: SpikePrompts.all)
        }
        // Round 5 F2: one single-pass read derives both fields.
        if let identity = try? ModelRuntime.verifiedModelIdentity(forModelAt: modelURL) {
            return VersionBundle(bundleID: "current", modelVersion: identity.modelVersion,
                                 promptVersion: SpikePrompts.version,
                                 modelFilePath: modelURL.path, promptTexts: SpikePrompts.all,
                                 modelContentDigest: identity.contentDigest)
        }
        return VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                             promptVersion: SpikePrompts.version,
                             modelFilePath: modelURL.path, promptTexts: SpikePrompts.all)
    }

    /// Restore ownership records decoded outside the registry
    /// (used by `production`, whose init persist precedes this).
    func restoreOwnedSnapshotPaths(_ stored: [String]) {
        guard !stored.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for path in stored {
            ownedSnapshotPaths.insert(
                URL(fileURLWithPath: resolvedPath(forStored: path)).standardizedFileURL.path)
        }
        try? persistLocked()
    }

    /// Restore persisted pending retirements (round 7 item 2,
    /// used by `production`), then sweep any whose cleanup was
    /// interrupted by termination.
    func restorePendingRetirements(_ stored: [String]) {
        guard !stored.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for path in stored {
            let key = URL(fileURLWithPath: resolvedPath(forStored: path)).standardizedFileURL.path
            pendingRetirementPaths.insert(key)
            Self.retentionGuard.lock()
            Self.pendingRetirements.insert(key)
            Self.retentionGuard.unlock()
        }
        try? persistLocked()
        sweepPendingRetirementsLocked()
    }

    /// Round 7 item 2 recovery sweep. Caller must hold `lock`.
    /// Deletes ONLY persisted-pending snapshots that are no
    /// longer retained by a resolved session, not referenced by
    /// any registered bundle, and registry-owned. A referenced
    /// or retained snapshot is never swept.
    private func sweepPendingRetirementsLocked() {
        guard !pendingRetirementPaths.isEmpty else { return }
        var changed = false
        for key in pendingRetirementPaths.sorted() {
            if Self.retentionCount(forPath: key) > 0 { continue }
            let referenced = bundlesByID.values.contains(where: {
                $0.modelFilePath.map { Self.standardized($0) == key } ?? false
            })
            if referenced || !isRegistryOwnedSnapshot(key) {
                pendingRetirementPaths.remove(key)
                Self.retentionGuard.lock()
                Self.pendingRetirements.remove(key)
                Self.retentionGuard.unlock()
                changed = true
                continue
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: key))
            ownedSnapshotPaths.remove(key)
            pendingRetirementPaths.remove(key)
            Self.retentionGuard.lock()
            Self.pendingRetirements.remove(key)
            Self.retentionGuard.unlock()
            changed = true
        }
        if changed { try? persistLocked() }
    }

    /// Recovery-only (production restore): also reclaim owned
    /// snapshots no bundle references — e.g. orphans written by
    /// a version whose pending marker was never persisted. Same
    /// guards as the pending sweep: retained or referenced
    /// snapshots are never touched.
    func sweepOrphanedOwnedSnapshotsOnRecovery() {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for key in ownedSnapshotPaths.sorted() {
            if Self.retentionCount(forPath: key) > 0 { continue }
            let referenced = bundlesByID.values.contains(where: {
                $0.modelFilePath.map { Self.standardized($0) == key } ?? false
            })
            if referenced { continue }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: key))
            ownedSnapshotPaths.remove(key)
            pendingRetirementPaths.remove(key)
            Self.retentionGuard.lock()
            Self.pendingRetirements.remove(key)
            Self.retentionGuard.unlock()
            changed = true
        }
        if changed { try? persistLocked() }
    }

    /// Lenient refresh of "current" without artifact validation, so a
    /// corrupt current model cannot block recovery (F1).
    private func refreshCurrentBundle(_ current: VersionBundle) throws {
        lock.lock(); defer { lock.unlock() }
        let savedByID = bundlesByID; let savedOrder = orderedIDs; let savedActive = _activeBundleID
        let boundCurrent = Self.enriched(current, bindDefaultModel: true)
        if bundlesByID[boundCurrent.bundleID] == nil { orderedIDs.append(boundCurrent.bundleID) }
        bundlesByID[boundCurrent.bundleID] = boundCurrent
        do { try persistLocked() } catch {
            bundlesByID = savedByID; orderedIDs = savedOrder; _activeBundleID = savedActive; throw error
        }
    }

    public var activeBundle: VersionBundle {
        get throws {
            lock.lock(); defer { lock.unlock() }
            try reloadPersistedLocked()
            return bundlesByID[_activeBundleID]!
        }
    }

    public var registeredBundles: [VersionBundle] {
        get throws {
            lock.lock(); defer { lock.unlock() }
            try reloadPersistedLocked()
            return orderedIDs.compactMap { bundlesByID[$0] }
        }
    }

    public func register(_ bundle: VersionBundle) throws {
        try Self.validate(bundle)
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let candidate = Self.enriched(bundle, bindDefaultModel: true)
        // F9: replacing the active bundle must validate first.
        // Round 6 F5: this active-register commit path previously
        // bypassed `candidateLoadValidator` (only GGUF/digest
        // checks), so a truncated/unloadable model could become
        // the persisted active bundle. Run the load validator
        // before any mutation, exactly as `selectLocked` does;
        // a failure leaves the prior selection untouched.
        if candidate.bundleID == _activeBundleID {
            try Self.validateArtifacts(candidate)
            if let candidateLoadValidator {
                try candidateLoadValidator(artifacts(for: candidate))
            }
        }
        let savedByID = bundlesByID; let savedOrder = orderedIDs; let savedActive = _activeBundleID
        if bundlesByID[candidate.bundleID] == nil { orderedIDs.append(candidate.bundleID) }
        bundlesByID[candidate.bundleID] = candidate
        do { try persistLocked() } catch {
            bundlesByID = savedByID; orderedIDs = savedOrder; _activeBundleID = savedActive; throw error
        }
    }

    public func select(bundleID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        try selectLocked(bundleID: bundleID)
    }

    private func selectLocked(bundleID: String) throws {
        guard let bundle = bundlesByID[bundleID] else {
            throw VersioningError.unknownBundle(bundleID)
        }
        // F11: lookup, validation and selection under the same lock.
        try Self.validateArtifacts(bundle)
        // Round 5 F9: when a load validator is installed, the
        // candidate must actually load before selection commits;
        // a failure leaves the prior selection untouched.
        if let candidateLoadValidator {
            try candidateLoadValidator(artifacts(for: bundle))
        }
        let previous = _activeBundleID
        _activeBundleID = bundleID
        do { try persistLocked() } catch {
            _activeBundleID = previous; throw error
        }
    }

    private func artifacts(for bundle: VersionBundle,
                           defaultModelURL: URL? = ModelRuntime.defaultModelURL()) -> InferenceArtifacts {
        let prompts = bundle.promptTexts ?? SpikePrompts.all
        let modelURL = bundle.modelFilePath.map { URL(fileURLWithPath: $0) } ?? defaultModelURL
        let digest = bundle.modelContentDigest
            ?? (modelURL.flatMap { try? ModelRuntime.contentSHA256(forFileAt: $0) })
        return InferenceArtifacts(
            modelVersion: ModelRuntime.reportedModelVersion(storedModelVersion: bundle.modelVersion),
            promptVersion: bundle.promptVersion,
            modelURL: modelURL, prompts: prompts,
            modelContentDigest: digest)
    }

    /// Round 5 F10: resolve artifacts and stamp the session from
    /// that one immutable snapshot, under one lock acquisition.
    public func inferenceSession(
        sessionId: String, startedAt: Date = Date(),
        defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> (artifacts: InferenceArtifacts, record: SessionRecord) {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let bundle = bundlesByID[_activeBundleID]!
        try Self.validateArtifacts(bundle, defaultModelURL: defaultModelURL)
        let resolved = artifacts(for: bundle, defaultModelURL: defaultModelURL)
        retainResolvedArtifacts(resolved)
        let record = try SessionRecord(sessionId: sessionId, startedAt: startedAt,
                                       modelVersion: resolved.modelVersion,
                                       promptVersion: resolved.promptVersion)
        return (resolved, record)
    }

    public func rollbackToPreviousKnownGood() throws {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        guard bundlesByID[Self.previousKnownGoodBundleID] != nil else {
            throw VersioningError.noPreviousBundle
        }
        try selectLocked(bundleID: Self.previousKnownGoodBundleID)
    }

    public func registerActiveAsPreviousKnownGood(
        defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let active = bundlesByID[_activeBundleID]!
        let resolvedPrompts = active.promptTexts ?? SpikePrompts.all
        let previousSnapshotPath = bundlesByID[Self.previousKnownGoodBundleID]?.modelFilePath
        // F12: a snapshot with no model file is not a success.
        guard let sourceURL = active.modelFilePath.map({ URL(fileURLWithPath: $0) }) ?? defaultModelURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
        }
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        guard !isDir.boolValue, ModelRuntime.isGGUFFile(at: sourceURL) else {
            throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
        }
        let srcDigest = try ModelRuntime.contentSHA256(forFileAt: sourceURL)
        // F5: reject a source that no longer matches the active bundle.
        if let expected = active.modelContentDigest, expected != srcDigest {
            throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
        }
        if active.modelContentDigest == nil, active.modelFilePath == nil,
           let verified = try? ModelRuntime.verifiedModelVersion(forModelAt: sourceURL),
           ModelRuntime.reportedModelVersion(storedModelVersion: verified)
               != ModelRuntime.reportedModelVersion(storedModelVersion: active.modelVersion),
           verified != active.modelVersion {
            throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
        }
        // F6: distinct immutable path per content digest. Never
        // overwrite an existing snapshot file in place.
        let dir = storeURL?.deletingLastPathComponent()
            ?? Self.defaultStoreURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stable = dir.appendingPathComponent(
            "previous-known-good-model-\(String(srcDigest.prefix(16))).gguf")
        var createdSnapshot = false
        if sourceURL.standardizedFileURL.path != stable.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: stable.path) {
                guard (try? ModelRuntime.contentSHA256(forFileAt: stable)) == srcDigest else {
                    throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
                }
            } else {
                let tmp = dir.appendingPathComponent("previous-known-good-model-\(UUID().uuidString).tmp.gguf")
                try FileManager.default.copyItem(at: sourceURL, to: tmp)
                // Round 5 F3: verify the copied bytes before
                // publishing; on mismatch preserve the old entry.
                guard (try? ModelRuntime.contentSHA256(forFileAt: tmp)) == srcDigest else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
                }
                do { try FileManager.default.moveItem(at: tmp, to: stable) }
                catch { try? FileManager.default.removeItem(at: tmp); throw error }
                createdSnapshot = true
            }
        }
        do {
            try register(VersionBundle(
                bundleID: Self.previousKnownGoodBundleID,
                modelVersion: active.modelVersion,
                promptVersion: active.promptVersion,
                modelFilePath: stable.path,
                promptTexts: resolvedPrompts,
                modelContentDigest: srcDigest
            ))
        } catch {
            if createdSnapshot { try? FileManager.default.removeItem(at: stable) }
            throw error
        }
        // Track ownership of the snapshot just published (F4).
        let stableKey = stable.standardizedFileURL.path
        ownedSnapshotPaths.insert(stableKey)
        // A snapshot referenced again is no longer pending.
        pendingRetirementPaths.remove(stableKey)
        Self.retentionGuard.lock()
        Self.pendingRetirements.remove(stableKey)
        Self.retentionGuard.unlock()
        try? persistLocked()
        // Only after the new entry is persisted, retire a snapshot
        // no remaining bundle references — and only a file this
        // registry owns, never an externally registered artifact.
        // Round 6 F4: defer retirement while a resolved session
        // still retains the snapshot; it is retired on release.
        if let previousSnapshotPath,
           previousSnapshotPath != stable.path,
           isRegistryOwnedSnapshot(previousSnapshotPath),
           !bundlesByID.values.contains(where: { $0.modelFilePath == previousSnapshotPath }) {
            let key = Self.standardized(previousSnapshotPath)
            // Round 7 item 3: check the retention count and insert
            // the pending retirement in ONE critical section. A
            // release arriving after the check must still see the
            // pending marker; splitting these let it slip between.
            Self.retentionGuard.lock()
            let isRetained = (Self.retentionCounts[key] ?? 0) > 0
            if isRetained { Self.pendingRetirements.insert(key) }
            Self.retentionGuard.unlock()
            if isRetained {
                // Round 7 item 2: persist the pending marker so
                // it survives termination.
                pendingRetirementPaths.insert(key)
                try? persistLocked()
            } else {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: key))
                ownedSnapshotPaths.remove(key)
                pendingRetirementPaths.remove(key)
                Self.retentionGuard.lock()
                Self.pendingRetirements.remove(key)
                Self.retentionGuard.unlock()
                try? persistLocked()
            }
        }
    }

    public func inferenceArtifacts(
        defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> InferenceArtifacts {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let bundle = bundlesByID[_activeBundleID]!
        try Self.validateArtifacts(bundle, defaultModelURL: defaultModelURL)
        // F13/F1 via artifacts(for:): composed version + digest.
        let resolved = artifacts(for: bundle, defaultModelURL: defaultModelURL)
        retainResolvedArtifacts(resolved)
        return resolved
    }

    private static func enriched(_ bundle: VersionBundle, bindDefaultModel: Bool = false) -> VersionBundle {
        guard bundle.modelContentDigest == nil else { return bundle }
        if let path = bundle.modelFilePath {
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return bundle }
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  ModelRuntime.isGGUFFile(at: url),
                  let digest = try? ModelRuntime.contentSHA256(forFileAt: url) else { return bundle }
            return VersionBundle(bundleID: bundle.bundleID, modelVersion: bundle.modelVersion,
                                 promptVersion: bundle.promptVersion, modelFilePath: path,
                                 promptTexts: bundle.promptTexts, modelContentDigest: digest)
        }
        guard bindDefaultModel, bundle.modelVersion == ModelRuntime.versionStamp, let url = ModelRuntime.defaultModelURL() else { return bundle }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              ModelRuntime.isGGUFFile(at: url),
              let digest = try? ModelRuntime.contentSHA256(forFileAt: url) else { return bundle }
        return VersionBundle(bundleID: bundle.bundleID, modelVersion: bundle.modelVersion,
                             promptVersion: bundle.promptVersion, modelFilePath: nil,
                             promptTexts: bundle.promptTexts, modelContentDigest: digest)
    }

    private static func validateArtifacts(
        _ bundle: VersionBundle, defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws {
        if let path = bundle.modelFilePath {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue, ModelRuntime.isGGUFFile(at: url) else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
            }
            if let expected = bundle.modelContentDigest {
                guard let actual = try? ModelRuntime.contentSHA256(forFileAt: url), actual == expected else {
                    throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
                }
            }
        } else if let resolved = defaultModelURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
                  !isDir.boolValue, ModelRuntime.isGGUFFile(at: resolved) else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
            }
            if let expected = bundle.modelContentDigest {
                guard let actual = try? ModelRuntime.contentSHA256(forFileAt: resolved), actual == expected else {
                    throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
                }
            } else if let verified = try? ModelRuntime.verifiedModelVersion(forModelAt: resolved) {
                // F5: configured stamp alone does not bind this file.
                guard verified == bundle.modelVersion else {
                    throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
                }
            } else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
            }
        } else {
            // F12: no explicit or default model file means no model
            // can run — never accept it as a selectable bundle.
            throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
        }
        if let texts = bundle.promptTexts {
            guard !texts.isEmpty,
                  texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "prompts")
            }
        } else {
            guard bundle.promptVersion == SpikePrompts.version else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "prompts")
            }
        }
    }

    private func reloadPersistedLocked() throws {
        guard let storeURL else { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data = try Data(contentsOf: storeURL)
        let state = try JSONDecoder().decode(PersistedRegistryState.self, from: data)
        guard !state.bundles.isEmpty, state.bundles.contains(where: { $0.bundleID == state.activeBundleID }) else {
            throw VersioningError.unknownBundle(state.activeBundleID)
        }
        for bundle in state.bundles { try Self.validate(bundle) }
        var byID: [String: VersionBundle] = [:]
        var order: [String] = []
        for bundle in state.bundles {
            let resolved = resolvedBundle(bundle)
            byID[resolved.bundleID] = resolved; order.append(resolved.bundleID)
        }
        bundlesByID = byID; orderedIDs = order; _activeBundleID = state.activeBundleID
        ownedSnapshotPaths = Set(state.ownedSnapshotPaths.map { resolvedPath(forStored: $0) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        pendingRetirementPaths = Set(state.pendingRetirementPaths.map { resolvedPath(forStored: $0) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if !pendingRetirementPaths.isEmpty {
            Self.retentionGuard.lock()
            Self.pendingRetirements.formUnion(pendingRetirementPaths)
            Self.retentionGuard.unlock()
            // Round 7 items 1+2: a successful reload retries any
            // pending retirement interrupted earlier (the failed-
            // reload path returns before ever reaching this).
            sweepPendingRetirementsLocked()
        }
    }

    private func persistLocked() throws {
        guard let storeURL else { return }
        let storedBundles = orderedIDs.compactMap { bundlesByID[$0] }.map { bundle -> VersionBundle in
            guard let path = bundle.modelFilePath else { return bundle }
            return VersionBundle(bundleID: bundle.bundleID, modelVersion: bundle.modelVersion,
                                 promptVersion: bundle.promptVersion,
                                 modelFilePath: storedPath(forAbsolute: path),
                                 promptTexts: bundle.promptTexts,
                                 modelContentDigest: bundle.modelContentDigest)
        }
        let state = PersistedRegistryState(
            bundles: storedBundles,
            activeBundleID: _activeBundleID,
            ownedSnapshotPaths: ownedSnapshotPaths.sorted().map { storedPath(forAbsolute: $0) },
            pendingRetirementPaths: pendingRetirementPaths.sorted().map { storedPath(forAbsolute: $0) }
        )
        let data = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: [.atomic])
    }

    private static func validate(_ bundle: VersionBundle) throws {
        func field(_ name: String, _ value: String) throws {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw VersioningError.emptyVersionField(bundleID: bundle.bundleID, field: name)
            }
        }
        try field("bundleID", bundle.bundleID)
        try field("modelVersion", bundle.modelVersion)
        try field("promptVersion", bundle.promptVersion)
        if let path = bundle.modelFilePath { try field("modelFilePath", path) }
    }
}

public enum SessionRecordError: Error, Equatable, Sendable {
    case missingVersion(field: String)
}

public struct SessionRecord: Equatable, Sendable, Codable {
    public let sessionId: String
    public let startedAt: Date
    public let modelVersion: String
    public let promptVersion: String

    public init(sessionId: String, startedAt: Date, modelVersion: String, promptVersion: String) throws {
        if modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SessionRecordError.missingVersion(field: "modelVersion")
        }
        if promptVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SessionRecordError.missingVersion(field: "promptVersion")
        }
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, startedAt, modelVersion, promptVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: values.decode(String.self, forKey: .sessionId),
            startedAt: values.decode(Date.self, forKey: .startedAt),
            modelVersion: values.decode(String.self, forKey: .modelVersion),
            promptVersion: values.decode(String.self, forKey: .promptVersion)
        )
    }

    public static func start(
        sessionId: String,
        startedAt: Date = Date(),
        registry: VersionRegistry
    ) throws -> SessionRecord {
        // F4: throwing read — a reload failure propagates instead
        // of stamping stale cached versions. F13: stamp the
        // retained model identity with the runtime actually running.
        let bundle = try registry.activeBundle
        return try SessionRecord(
            sessionId: sessionId,
            startedAt: startedAt,
            modelVersion: ModelRuntime.reportedModelVersion(storedModelVersion: bundle.modelVersion),
            promptVersion: bundle.promptVersion
        )
    }

    /// Round 5 F10: stamp from the same immutable artifacts
    /// snapshot used to start inference — no second registry read.
    public static func start(
        sessionId: String,
        startedAt: Date = Date(),
        artifacts: InferenceArtifacts
    ) throws -> SessionRecord {
        try SessionRecord(
            sessionId: sessionId,
            startedAt: startedAt,
            modelVersion: artifacts.modelVersion,
            promptVersion: artifacts.promptVersion
        )
    }
}
