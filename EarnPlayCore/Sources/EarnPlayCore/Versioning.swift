import Foundation

/// Errors from version-bundle registration and selection (T5.3).
public enum VersioningError: Error, Equatable, Sendable {
    case unknownBundle(String)
    case emptyVersionField(bundleID: String, field: String)
    case noPreviousBundle
    /// Selection was rejected because the bundle's artifacts cannot
    /// be applied: its model file is missing/not usable or its prompt
    /// version has no bound prompt texts. The active bundle is left
    /// unchanged — rollback never becomes a label-only change.
    case artifactUnavailable(bundleID: String, artifact: String)
}

/// One selectable model + prompt pairing ("bundle" in the T5.3 card).
/// A bundle is bound to the artifacts inference actually uses: an
/// explicit GGUF file and/or explicit prompt texts. A nil artifact
/// means "this build's default for the version named here" and is
/// only selectable when that version matches the build default
/// (see `VersionRegistry.select`).
public struct VersionBundle: Equatable, Sendable, Codable {
    public let bundleID: String
    public let modelVersion: String
    public let promptVersion: String
    /// Path of the GGUF file inference must load for this bundle.
    public let modelFilePath: String?
    /// Prompt texts inference must run for this bundle.
    public let promptTexts: [String]?

    public init(bundleID: String, modelVersion: String, promptVersion: String,
                modelFilePath: String? = nil, promptTexts: [String]? = nil) {
        self.bundleID = bundleID
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
        self.modelFilePath = modelFilePath
        self.promptTexts = promptTexts
    }
}

/// Artifacts inference must actually use for the active bundle.
public struct InferenceArtifacts: Equatable, Sendable {
    public let modelVersion: String
    public let promptVersion: String
    /// Model file to load; nil means no model file is installed yet.
    public let modelURL: URL?
    public let prompts: [String]

    public init(modelVersion: String, promptVersion: String, modelURL: URL?, prompts: [String]) {
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
        self.modelURL = modelURL
        self.prompts = prompts
    }
}

private struct PersistedRegistryState: Codable {
    var bundles: [VersionBundle]
    var activeBundleID: String
}

/// Registry of version bundles and the one currently selected.
///
/// Thread safety (Copilot F1): every read/mutation of the bundle
/// table and active ID runs under `lock`, so the registry may be
/// shared across tasks (`@unchecked Sendable` is sound here only
/// because of that lock — all state is private and lock-guarded).
///
/// Persistence (Copilot F6): when built with a `storeURL`
/// (`production()` does), every register/select is written as
/// Codable JSON with an atomic write to Application Support —
/// the same on-device store pattern as the rest of the codebase —
/// and construction restores bundles + selection from that file,
/// so rollback survives an app update and restart.
public final class VersionRegistry: @unchecked Sendable {
    public static let previousKnownGoodBundleID = "previous-known-good"

    private let lock = NSLock()
    private var bundlesByID: [String: VersionBundle] = [:]
    private var orderedIDs: [String] = []
    private var _activeBundleID: String
    private let storeURL: URL?

    public var activeBundleID: String {
        lock.lock(); defer { lock.unlock() }
        return _activeBundleID
    }

    public init(bundles: [VersionBundle], activeBundleID: String, storeURL: URL? = nil) throws {
        for bundle in bundles { try Self.validate(bundle) }
        let ids = bundles.map(\.bundleID)
        guard Set(ids).count == ids.count, ids.contains(activeBundleID) else {
            throw VersioningError.unknownBundle(activeBundleID)
        }
        for bundle in bundles {
            bundlesByID[bundle.bundleID] = bundle
            orderedIDs.append(bundle.bundleID)
        }
        self._activeBundleID = activeBundleID
        self.storeURL = storeURL
        if storeURL != nil { try persistLocked() }
    }

    /// On-disk location of the production registry state.
    public static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("EarnPlay/version-registry.json")
    }

    /// Production registry: the bundle this build runs, restored
    /// from (and persisted to) `storeURL` when one applies.
    /// If a model file is installed at `modelURL`, the current
    /// bundle's model version is that file's verified identity
    /// (Copilot F5) — never the fixed spike identifier. With no
    /// installed file it falls back to the build's configured stamp.
    public static func production(
        storeURL: URL? = nil,
        modelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> VersionRegistry {
        let url = storeURL ?? defaultStoreURL()
        let currentModelVersion: String
        if let modelURL, FileManager.default.fileExists(atPath: modelURL.path) {
            currentModelVersion = try ModelRuntime.verifiedModelVersion(forModelAt: modelURL)
        } else {
            currentModelVersion = ModelRuntime.versionStamp
        }
        let current = VersionBundle(
            bundleID: "current",
            modelVersion: currentModelVersion,
            promptVersion: SpikePrompts.version
        )
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(PersistedRegistryState.self, from: data),
           !state.bundles.isEmpty {
            // Restore persisted bundles + selection (validating via
            // init); refresh the "current" bundle to this build's
            // identity so an app update cannot leave it stale, while
            // keeping the persisted selection untouched.
            let registry = try VersionRegistry(
                bundles: state.bundles, activeBundleID: state.activeBundleID, storeURL: url
            )
            if registry.registeredBundles.first(where: { $0.bundleID == "current" }) != current {
                try registry.register(current)
            }
            return registry
        }
        return try VersionRegistry(bundles: [current], activeBundleID: "current", storeURL: url)
    }

    public var activeBundle: VersionBundle {
        lock.lock(); defer { lock.unlock() }
        return bundlesByID[_activeBundleID]!
    }

    public var registeredBundles: [VersionBundle] {
        lock.lock(); defer { lock.unlock() }
        return orderedIDs.compactMap { bundlesByID[$0] }
    }

    public func register(_ bundle: VersionBundle) throws {
        try Self.validate(bundle)
        lock.lock(); defer { lock.unlock() }
        if bundlesByID[bundle.bundleID] == nil { orderedIDs.append(bundle.bundleID) }
        bundlesByID[bundle.bundleID] = bundle
        try persistLocked()
    }

    /// Selects the bundle new sessions stamp AND inference uses.
    /// Throws `.artifactUnavailable` (active bundle unchanged) when
    /// the bundle's artifacts cannot be applied (Copilot F2).
    public func select(bundleID: String) throws {
        let bundle: VersionBundle = try {
            lock.lock(); defer { lock.unlock() }
            guard let found = bundlesByID[bundleID] else {
                throw VersioningError.unknownBundle(bundleID)
            }
            return found
        }()
        try Self.validateArtifacts(bundle)
        lock.lock(); defer { lock.unlock() }
        guard bundlesByID[bundleID] != nil else {
            throw VersioningError.unknownBundle(bundleID)
        }
        _activeBundleID = bundleID
        try persistLocked()
    }

    public func rollbackToPreviousKnownGood() throws {
        let exists: Bool = {
            lock.lock(); defer { lock.unlock() }
            return bundlesByID[Self.previousKnownGoodBundleID] != nil
        }()
        guard exists else { throw VersioningError.noPreviousBundle }
        try select(bundleID: Self.previousKnownGoodBundleID)
    }

    /// Arms rollback: copies the active bundle (with its artifacts)
    /// under `previous-known-good`. The operator entry point in the
    /// admin app calls this before an update ships.
    public func registerActiveAsPreviousKnownGood() throws {
        let active = activeBundle
        try register(VersionBundle(
            bundleID: Self.previousKnownGoodBundleID,
            modelVersion: active.modelVersion,
            promptVersion: active.promptVersion,
            modelFilePath: active.modelFilePath,
            promptTexts: active.promptTexts
        ))
    }

    /// Artifacts inference must load/run for the active bundle.
    /// Throws `.artifactUnavailable` rather than silently falling
    /// back to the current model/prompts under an old label.
    public func inferenceArtifacts(
        defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> InferenceArtifacts {
        let bundle = activeBundle
        try Self.validateArtifacts(bundle, defaultModelURL: defaultModelURL)
        let prompts = bundle.promptTexts ?? SpikePrompts.all
        let modelURL = bundle.modelFilePath.map { URL(fileURLWithPath: $0) } ?? defaultModelURL
        return InferenceArtifacts(
            modelVersion: bundle.modelVersion,
            promptVersion: bundle.promptVersion,
            modelURL: modelURL,
            prompts: prompts
        )
    }

    private static func validateArtifacts(
        _ bundle: VersionBundle, defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws {
        if let path = bundle.modelFilePath {
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
            }
        } else if bundle.modelVersion != ModelRuntime.versionStamp {
            // No explicit file: only the build-default model may be
            // claimed. A verified installed file also qualifies.
            var verifiedMatches = false
            if let defaultModelURL,
               let verified = try? ModelRuntime.verifiedModelVersion(forModelAt: defaultModelURL) {
                verifiedMatches = (verified == bundle.modelVersion)
            }
            guard verifiedMatches else {
                throw VersioningError.artifactUnavailable(bundleID: bundle.bundleID, artifact: "modelFile")
            }
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

    private func persistLocked() throws {
        guard let storeURL else { return }
        let state = PersistedRegistryState(
            bundles: orderedIDs.compactMap { bundlesByID[$0] },
            activeBundleID: _activeBundleID
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

/// Errors from creating a session record without its versions.
public enum SessionRecordError: Error, Equatable, Sendable {
    case missingVersion(field: String)
}

/// Version-bearing session record (LLD 2.2 subset, pre-T1.6).
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

    // Copilot F7: decode through the validating initializer so a
    // restored/synced record cannot bypass the non-empty invariant.
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
        let bundle = registry.activeBundle
        return try SessionRecord(
            sessionId: sessionId,
            startedAt: startedAt,
            modelVersion: bundle.modelVersion,
            promptVersion: bundle.promptVersion
        )
    }
}
