import Foundation

/// Errors from version-bundle registration and selection (T5.3).
public enum VersioningError: Error, Equatable, Sendable {
    /// No bundle is registered under this ID.
    case unknownBundle(String)
    /// A registered bundle (or the bundle being registered) has an
    /// empty or whitespace-only ID or version field.
    case emptyVersionField(bundleID: String, field: String)
    /// Rollback was requested but no previous known-good bundle is
    /// registered (production ships one bundle until an update
    /// registers its predecessor — see `Docs/VersioningAndRollback.md`).
    case noPreviousBundle
}

/// One selectable model + prompt pairing ("bundle" in the T5.3 card).
/// Selection changes only which bundle new sessions stamp; rollback
/// never downloads anything (re-downloads are out of scope).
public struct VersionBundle: Equatable, Sendable, Codable {
    public let bundleID: String
    public let modelVersion: String
    public let promptVersion: String

    public init(bundleID: String, modelVersion: String, promptVersion: String) {
        self.bundleID = bundleID
        self.modelVersion = modelVersion
        self.promptVersion = promptVersion
    }
}

/// Registry of version bundles and the one currently selected.
///
/// The production registry derives its single bundle from
/// `ModelRuntime.versionStamp` and `SpikePrompts.version`, so the
/// running version shown in the admin app and stamped on sessions is
/// always the build's real identity. Before a model or prompt update
/// ships, the outgoing bundle is registered under
/// `previousKnownGoodBundleID`; rollback is then one `select` call,
/// recorded on later sessions like any other version change (LLD 10.3).
public final class VersionRegistry: @unchecked Sendable {
    /// Bundle ID reserved for the previous known-good bundle.
    public static let previousKnownGoodBundleID = "previous-known-good"

    private var bundlesByID: [String: VersionBundle] = [:]
    private var orderedIDs: [String] = []
    public private(set) var activeBundleID: String

    /// Registers the initial bundle set. Every bundle must name a
    /// non-empty model and prompt version, and `activeBundleID` must
    /// identify one of them; anything else throws instead of starting
    /// in a state that would stamp a wrong or empty version.
    public init(bundles: [VersionBundle], activeBundleID: String) throws {
        for bundle in bundles {
            try Self.validate(bundle)
        }
        let ids = bundles.map(\.bundleID)
        guard Set(ids).count == ids.count, ids.contains(activeBundleID) else {
            throw VersioningError.unknownBundle(activeBundleID)
        }
        for bundle in bundles {
            bundlesByID[bundle.bundleID] = bundle
            orderedIDs.append(bundle.bundleID)
        }
        self.activeBundleID = activeBundleID
    }

    /// Production registry: exactly the bundle this build runs.
    public static func production() throws -> VersionRegistry {
        try VersionRegistry(
            bundles: [
                VersionBundle(
                    bundleID: "current",
                    modelVersion: ModelRuntime.versionStamp,
                    promptVersion: SpikePrompts.version
                )
            ],
            activeBundleID: "current"
        )
    }

    public var activeBundle: VersionBundle {
        // Force-unwrap is safe: init and select only admit known IDs.
        bundlesByID[activeBundleID]!
    }

    /// All registered bundles, in registration order.
    public var registeredBundles: [VersionBundle] {
        orderedIDs.compactMap { bundlesByID[$0] }
    }

    /// Keeps a bundle available for later selection — call with the
    /// outgoing bundle before selecting a new one, so rollback stays
    /// possible. Re-registering an existing ID replaces it in place.
    public func register(_ bundle: VersionBundle) throws {
        try Self.validate(bundle)
        if bundlesByID[bundle.bundleID] == nil {
            orderedIDs.append(bundle.bundleID)
        }
        bundlesByID[bundle.bundleID] = bundle
    }

    /// Selects the bundle new sessions will stamp. Throws and leaves
    /// the active bundle unchanged when the ID is unknown.
    public func select(bundleID: String) throws {
        guard bundlesByID[bundleID] != nil else {
            throw VersioningError.unknownBundle(bundleID)
        }
        activeBundleID = bundleID
    }

    /// Rolls back to the bundle registered as previous known-good.
    /// Throws `.noPreviousBundle` when none is registered.
    public func rollbackToPreviousKnownGood() throws {
        guard bundlesByID[Self.previousKnownGoodBundleID] != nil else {
            throw VersioningError.noPreviousBundle
        }
        try select(bundleID: Self.previousKnownGoodBundleID)
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
    }
}

/// Errors from creating a session record without its versions.
public enum SessionRecordError: Error, Equatable, Sendable {
    /// The named version field was empty or whitespace-only. A session
    /// recorded without both versions is a bug (T5.3), so construction
    /// throws instead of producing an unstamped record.
    case missingVersion(field: String)
}

/// Version-bearing session record — the subset of LLD section 2.2
/// that exists before the full session schema (T1.6): identity, start
/// time, and the model/prompt version that ran the session. Later
/// session code stamps through `start(sessionId:startedAt:registry:)`
/// so the active bundle is captured at session start, not read later.
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

    /// Starts a session stamped with the registry's active bundle.
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
