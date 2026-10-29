import Foundation
import EarnPlayCore
import FamilyControls
import ManagedSettings

/// The persisted link between picked picker tokens and the opaque
/// `AppRef` / `AppCategoryRef` identifiers the policy and the enumeration
/// use.
///
/// Tokens are opaque to the app, so the view model assigns each picked
/// token a stable identifier at enumeration time and persists the pairing
/// here (parallel arrays, paired by index). Reloading reproduces the exact
/// mapping, which the completion screen uses to render the picked apps'
/// names/icons (via `Label(token)`) after a relaunch and which the v1
/// ManagedSettings backend will use to resolve each `AppRef` back to its
/// token.
public struct SetupTokenMapping: Codable, Equatable, Sendable {
    public var applicationTokens: [ApplicationToken]
    public var applicationRefIDs: [String]
    public var categoryTokens: [ActivityCategoryToken]
    public var categoryRefIDs: [String]

    public init(
        applicationTokens: [ApplicationToken] = [],
        applicationRefIDs: [String] = [],
        categoryTokens: [ActivityCategoryToken] = [],
        categoryRefIDs: [String] = []
    ) {
        self.applicationTokens = applicationTokens
        self.applicationRefIDs = applicationRefIDs
        self.categoryTokens = categoryTokens
        self.categoryRefIDs = categoryRefIDs
    }

    /// True when every token has exactly one identifier.
    public var isWellFormed: Bool {
        applicationTokens.count == applicationRefIDs.count
            && categoryTokens.count == categoryRefIDs.count
    }
}

/// Persists the `SetupTokenMapping` captured at T2.3 setup, as JSON next
/// to the policy cache. A missing, corrupt, or malformed file loads as no
/// mapping — counts and shields never depend on it (they come from the
/// policy and the enumeration), only the token-backed app labels do.
public struct SetupTokenStore: Sendable {
    public static let mappingFileName = "setup-token-mapping.json"

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default store directory, shared with `PolicyStore`.
    public init(fileManager: FileManager = .default) {
        self.init(directory: PolicyStore.defaultDirectory(fileManager: fileManager),
                  fileManager: fileManager)
    }

    public func loadMapping() -> SetupTokenMapping? {
        let url = directory.appendingPathComponent(Self.mappingFileName)
        guard let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode(SetupTokenMapping.self, from: data),
              mapping.isWellFormed
        else { return nil }
        return mapping
    }

    public func saveMapping(_ mapping: SetupTokenMapping) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mapping)
        try data.write(to: directory.appendingPathComponent(Self.mappingFileName),
                       options: [.atomic])
    }
}
