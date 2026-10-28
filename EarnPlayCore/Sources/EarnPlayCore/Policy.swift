import Foundation

/// Policy model (LLD §2.1) — T2.1.
///
/// Authored in the admin app, versioned, and cached on the child device.
/// The child enforces the highest-version `Policy` it has received; see
/// `PolicyStore` for persistence and the conflict rule, and LLD §8.2 for
/// the sync-level statement ("admin policy wins; higher version wins;
/// lower or equal is discarded").
///
/// Scope note: this file is the data model only. It deliberately has no
/// FamilyControls / ManagedSettings dependency — app references are
/// opaque identifiers (the SSOT states FamilyControls tokens are opaque
/// and the app never learns installed apps beyond parent picks). T2.2's
/// ShieldManager maps these identifiers to real tokens at setup time.
public struct Policy: Codable, Equatable, Sendable {
    /// Monotonic version. Higher wins; lower or equal is ignored on receipt.
    public var version: Int
    /// Apps never blocked. Defaults include Phone, Messages, EarnPlay itself.
    public var alwaysAllowed: [AppRef]
    /// Apps locked by default that a completed challenge can open.
    public var unblockable: [AppRef]
    /// Apps that stay locked with no challenge offered, even if they would
    /// otherwise be unblockable. Overrides win over `unblockable`.
    public var neverUnlockableOverrides: [AppRef]
    /// Practice-earned and trade unlock durations.
    public var unlockDurations: UnlockDurations
    /// Floor-rule parameters read by EffortScorer.
    public var effortFloorSettings: EffortFloorSettings
    /// Trade offer caps.
    public var tradeCaps: TradeCaps
    /// Parent-stocked chores the AI may offer.
    public var chorePool: [ChorePoolEntry]
    /// Movement-trade settings.
    public var movementSettings: MovementSettings

    public init(
        version: Int,
        alwaysAllowed: [AppRef],
        unblockable: [AppRef],
        neverUnlockableOverrides: [AppRef],
        unlockDurations: UnlockDurations,
        effortFloorSettings: EffortFloorSettings,
        tradeCaps: TradeCaps,
        chorePool: [ChorePoolEntry],
        movementSettings: MovementSettings
    ) {
        self.version = version
        self.alwaysAllowed = alwaysAllowed
        self.unblockable = unblockable
        self.neverUnlockableOverrides = neverUnlockableOverrides
        self.unlockDurations = unlockDurations
        self.effortFloorSettings = effortFloorSettings
        self.tradeCaps = tradeCaps
        self.chorePool = chorePool
        self.movementSettings = movementSettings
    }

    /// Built-in policy enforced before the first sync arrives.
    ///
    /// Version 0, so the first admin-authored policy (version 1) always
    /// applies over it. Default-deny per the LLD new-install rule: only
    /// Phone, Messages, and EarnPlay itself are allowed; nothing is
    /// unblockable and the chore pool is empty until a policy syncs.
    public static let defaultPolicy = Policy(
        version: 0,
        alwaysAllowed: [.phone, .messages, .earnPlaySelf],
        unblockable: [],
        neverUnlockableOverrides: [],
        unlockDurations: .default,
        effortFloorSettings: .default,
        tradeCaps: .default,
        chorePool: [],
        movementSettings: .default
    )

    /// Copy with a different version. PolicyEditor (T4.1) saves with
    /// `current.version + 1`; the child never edits policy.
    public func withVersion(_ newVersion: Int) -> Policy {
        var copy = self
        copy.version = newVersion
        return copy
    }

    /// True when `app` stays locked with no challenge offered: either it is
    /// on the never-unlockable override list, or it is not unblockable at
    /// all. Overrides are checked regardless of `unblockable` membership.
    public func isNeverUnlockable(_ app: AppRef) -> Bool {
        neverUnlockableOverrides.contains(app) || !unblockable.contains(app)
    }

    /// True when a completed challenge may open `app`: unblockable and not
    /// overridden. This is the exact predicate T2.2/T3.x gate offers on.
    public func isChallengeUnlockable(_ app: AppRef) -> Bool {
        unblockable.contains(app) && !neverUnlockableOverrides.contains(app)
    }
}

/// Opaque reference to an app named in a policy.
///
/// The identifier is a stable opaque key chosen when the parent picks the
/// app. It is intentionally *not* a FamilyControls token type: tokens are
/// opaque blobs owned by the setup flow (T2.3), which persists the mapping
/// from token to `AppRef`. Keeping the policy free of framework types lets
/// the shared package (and its host tests) run without any entitlement.
public struct AppRef: Codable, Equatable, Hashable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    /// EarnPlay itself (bundle ID from `project.yml`; always allowed).
    public static let earnPlaySelf = AppRef(id: "com.vhoangvu.earnplay")
    /// Built-in default: Phone. Opaque key, not an asserted bundle ID.
    public static let phone = AppRef(id: "earnplay.default.phone")
    /// Built-in default: Messages. Opaque key, not an asserted bundle ID.
    public static let messages = AppRef(id: "earnplay.default.messages")
}

/// Unlock durations in minutes (LLD §2.1).
public struct UnlockDurations: Codable, Equatable, Sendable {
    /// Unlock earned by completing a practice challenge. Default 30.
    public var practiceMinutes: Int
    /// Unlock granted by a completed trade. Default 15 (shorter than practice).
    public var tradeMinutes: Int

    public init(practiceMinutes: Int, tradeMinutes: Int) {
        self.practiceMinutes = practiceMinutes
        self.tradeMinutes = tradeMinutes
    }

    public static let `default` = UnlockDurations(practiceMinutes: 30, tradeMinutes: 15)
}

/// Floor-rule parameters (LLD §2.1), read by EffortScorer.
public struct EffortFloorSettings: Codable, Equatable, Sendable {
    /// Minimum genuine attempts required before an unlock. Default 1.
    public var minGenuineAttempts: Int
    /// Minimum real hint or follow-up interactions required. Default 1.
    public var minHintOrFollowUpInteractions: Int

    public init(minGenuineAttempts: Int, minHintOrFollowUpInteractions: Int) {
        self.minGenuineAttempts = minGenuineAttempts
        self.minHintOrFollowUpInteractions = minHintOrFollowUpInteractions
    }

    public static let `default` = EffortFloorSettings(
        minGenuineAttempts: 1, minHintOrFollowUpInteractions: 1
    )
}

/// Trade offer caps (LLD §2.1 `tradeCaps`).
public struct TradeCaps: Codable, Equatable, Sendable {
    /// Maximum trade offers in one session across both trade types.
    public var maxTradesPerSession: Int
    /// Parent-set weekly cap for movement trades; suggested range 2–3.
    public var weeklyMaxMovementTrades: Int
    /// Parent-set weekly cap for chore trades.
    public var weeklyMaxChoreTrades: Int

    public init(
        maxTradesPerSession: Int,
        weeklyMaxMovementTrades: Int,
        weeklyMaxChoreTrades: Int
    ) {
        self.maxTradesPerSession = maxTradesPerSession
        self.weeklyMaxMovementTrades = weeklyMaxMovementTrades
        self.weeklyMaxChoreTrades = weeklyMaxChoreTrades
    }

    public static let `default` = TradeCaps(
        maxTradesPerSession: 1, weeklyMaxMovementTrades: 3, weeklyMaxChoreTrades: 3
    )
}

/// How completion of a chore is verified (LLD §2.1).
public enum ChoreVerificationMode: String, Codable, Equatable, Sendable {
    /// Parent confirms completion; only the parent can judge.
    case parentConfirm = "parent-confirm"
    /// Photo proof: unlock granted, parent reviews later and can revoke.
    case photoAsync = "photo-async"
}

/// One parent-stocked chore in the pool (LLD §2.1 `ChorePoolEntry`).
public struct ChorePoolEntry: Codable, Equatable, Sendable {
    /// Chore description written by the parent.
    public var chore: String
    /// Unlock minutes earned when the chore is completed and confirmed.
    public var unlockMinutes: Int
    /// Offer is not usable after this time.
    public var expiry: Date
    /// Parent-set weekly cap for this chore (per-entry cap).
    public var weeklyCap: Int
    public var verificationMode: ChoreVerificationMode

    public init(
        chore: String,
        unlockMinutes: Int,
        expiry: Date,
        weeklyCap: Int,
        verificationMode: ChoreVerificationMode
    ) {
        self.chore = chore
        self.unlockMinutes = unlockMinutes
        self.expiry = expiry
        self.weeklyCap = weeklyCap
        self.verificationMode = verificationMode
    }
}

/// Physical activities the AI may offer in a movement trade.
public enum MovementActivity: String, Codable, Equatable, Sendable, CaseIterable {
    case jumpingJacks = "jumping-jacks"
    case runningInPlace = "running-in-place"
    case squats = "squats"
    case marchingInPlace = "marching-in-place"
}

/// Movement-trade settings (LLD §2.1 `MovementSettings`).
public struct MovementSettings: Codable, Equatable, Sendable {
    /// Activities the AI may offer, e.g. jumping jacks, running in place.
    public var allowedActivities: [MovementActivity]
    /// Maximum repetitions the AI may ask for in one movement trade.
    public var maxReps: Int
    /// Unlock (minutes) granted by a completed movement trade; shorter
    /// than a practice-earned unlock (15 min vs 30 min).
    public var tradeUnlockDurationMinutes: Int

    public init(
        allowedActivities: [MovementActivity],
        maxReps: Int,
        tradeUnlockDurationMinutes: Int
    ) {
        self.allowedActivities = allowedActivities
        self.maxReps = maxReps
        self.tradeUnlockDurationMinutes = tradeUnlockDurationMinutes
    }

    public static let `default` = MovementSettings(
        allowedActivities: [.jumpingJacks, .runningInPlace],
        maxReps: 20,
        tradeUnlockDurationMinutes: 15
    )
}
