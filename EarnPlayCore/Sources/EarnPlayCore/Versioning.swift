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

    public var activeBundleID: String {
        lock.lock(); defer { lock.unlock() }
        try? reloadPersistedLocked()
        return _activeBundleID
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
            let bound = Self.enriched(bundle, bindDefaultModel: true)
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
            try registry.refreshCurrentBundle(current)
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
        if let verified = try? ModelRuntime.verifiedModelVersion(forModelAt: modelURL),
           let digest = try? ModelRuntime.contentSHA256(forFileAt: modelURL) {
            return VersionBundle(bundleID: "current", modelVersion: verified,
                                 promptVersion: SpikePrompts.version,
                                 modelFilePath: modelURL.path, promptTexts: SpikePrompts.all,
                                 modelContentDigest: digest)
        }
        return VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                             promptVersion: SpikePrompts.version,
                             modelFilePath: modelURL.path, promptTexts: SpikePrompts.all)
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
        lock.lock(); defer { lock.unlock() }
        try? reloadPersistedLocked()
        return bundlesByID[_activeBundleID]!
    }

    public var registeredBundles: [VersionBundle] {
        lock.lock(); defer { lock.unlock() }
        try? reloadPersistedLocked()
        return orderedIDs.compactMap { bundlesByID[$0] }
    }

    public func register(_ bundle: VersionBundle) throws {
        try Self.validate(bundle)
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let candidate = Self.enriched(bundle, bindDefaultModel: true)
        // F9: replacing the active bundle must validate first.
        if candidate.bundleID == _activeBundleID {
            try Self.validateArtifacts(candidate)
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
        let previous = _activeBundleID
        _activeBundleID = bundleID
        do { try persistLocked() } catch {
            _activeBundleID = previous; throw error
        }
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
        var stablePath: String? = active.modelFilePath
        var digest: String? = active.modelContentDigest
        let sourceURL = active.modelFilePath.map { URL(fileURLWithPath: $0) } ?? defaultModelURL
        if let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
            guard !isDir.boolValue, ModelRuntime.isGGUFFile(at: sourceURL) else {
                throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
            }
            let srcDigest = try ModelRuntime.contentSHA256(forFileAt: sourceURL)
            digest = srcDigest
            do {
                let dir = storeURL?.deletingLastPathComponent()
                    ?? Self.defaultStoreURL().deletingLastPathComponent()
                let stable = dir.appendingPathComponent("previous-known-good-model.gguf")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if sourceURL.standardizedFileURL.path != stable.standardizedFileURL.path {
                    let existingDigest = (try? ModelRuntime.contentSHA256(forFileAt: stable))
                    if existingDigest != srcDigest {
                        let tmp = dir.appendingPathComponent("previous-known-good-model.tmp.gguf")
                        try? FileManager.default.removeItem(at: tmp)
                        try FileManager.default.copyItem(at: sourceURL, to: tmp)
                        if FileManager.default.fileExists(atPath: stable.path) {
                            _ = try FileManager.default.replaceItemAt(stable, withItemAt: tmp)
                        } else {
                            try FileManager.default.moveItem(at: tmp, to: stable)
                        }
                    }
                }
                stablePath = stable.path
            }
        } else if active.modelFilePath != nil {
            throw VersioningError.artifactUnavailable(bundleID: active.bundleID, artifact: "modelFile")
        }
        try register(VersionBundle(
            bundleID: Self.previousKnownGoodBundleID,
            modelVersion: active.modelVersion,
            promptVersion: active.promptVersion,
            modelFilePath: stablePath,
            promptTexts: resolvedPrompts,
            modelContentDigest: digest
        ))
    }

    public func inferenceArtifacts(
        defaultModelURL: URL? = ModelRuntime.defaultModelURL()
    ) throws -> InferenceArtifacts {
        lock.lock(); defer { lock.unlock() }
        try reloadPersistedLocked()
        let bundle = bundlesByID[_activeBundleID]!
        try Self.validateArtifacts(bundle, defaultModelURL: defaultModelURL)
        let prompts = bundle.promptTexts ?? SpikePrompts.all
        let modelURL = bundle.modelFilePath.map { URL(fileURLWithPath: $0) } ?? defaultModelURL
        return InferenceArtifacts(modelVersion: bundle.modelVersion,
                                  promptVersion: bundle.promptVersion,
                                  modelURL: modelURL, prompts: prompts)
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
            guard bundle.modelContentDigest == nil, bundle.modelVersion == ModelRuntime.versionStamp else {
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
            byID[bundle.bundleID] = bundle; order.append(bundle.bundleID)
        }
        bundlesByID = byID; orderedIDs = order; _activeBundleID = state.activeBundleID
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
        let bundle = registry.activeBundle
        return try SessionRecord(
            sessionId: sessionId,
            startedAt: startedAt,
            modelVersion: bundle.modelVersion,
            promptVersion: bundle.promptVersion
        )
    }
}
