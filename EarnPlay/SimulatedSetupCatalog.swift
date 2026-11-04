import EarnPlayCore
import Foundation

/// One simulated app offered during forced-mode setup enumeration (issue
/// #87 fix round 1): a stable demo identity with a display name and a
/// KNOWN category. Stable ids (never random UUIDs) so a committed setup
/// restores its simulated picks from the persisted enumeration after a
/// relaunch, and so the installed shield panel presents the same demo
/// apps the parent picked.
public struct SimulatedSetupApp: Identifiable, Hashable, Sendable {
    public let ref: AppRef
    public let name: String
    public let category: SimulatedSetupCategory

    public var id: String { ref.id }

    public init(ref: AppRef, name: String, category: SimulatedSetupCategory) {
        self.ref = ref
        self.name = name
        self.category = category
    }
}

/// One simulated backstop category offered during forced-mode setup.
public struct SimulatedSetupCategory: Identifiable, Hashable, Sendable {
    public let ref: AppCategoryRef
    public let name: String

    public var id: String { ref.id }

    public init(ref: AppCategoryRef, name: String) {
        self.ref = ref
        self.name = name
    }
}

/// The forced-mode setup catalog: the demo apps/categories a tester picks
/// when the system picker cannot produce tokens (no FamilyControls
/// entitlement). Simulated approval never grants real authorization, so
/// without this catalog a fresh forced-mode setup stalls at enumeration.
/// The unforced flow never consults this catalog and keeps the real
/// picker exactly as-is.
public enum SimulatedSetupCatalog {
    public static let games = SimulatedSetupCategory(
        ref: AppCategoryRef(id: "earnplay.simulated.category.games"),
        name: "Games"
    )
    public static let entertainment = SimulatedSetupCategory(
        ref: AppCategoryRef(id: "earnplay.simulated.category.entertainment"),
        name: "Entertainment"
    )
    public static let social = SimulatedSetupCategory(
        ref: AppCategoryRef(id: "earnplay.simulated.category.social"),
        name: "Social"
    )

    public static let categories: [SimulatedSetupCategory] = [
        games, entertainment, social,
    ]

    public static let apps: [SimulatedSetupApp] = [
        SimulatedSetupApp(
            ref: AppRef(id: "earnplay.simulated.game"),
            name: "Demo Game",
            category: games
        ),
        SimulatedSetupApp(
            ref: AppRef(id: "earnplay.simulated.video"),
            name: "Demo Video",
            category: entertainment
        ),
        SimulatedSetupApp(
            ref: AppRef(id: "earnplay.simulated.chat"),
            name: "Demo Chat",
            category: social
        ),
    ]

    public static func app(id: String) -> SimulatedSetupApp? {
        apps.first { $0.id == id }
    }

    public static func category(id: String) -> SimulatedSetupCategory? {
        categories.first { $0.id == id }
    }
}
