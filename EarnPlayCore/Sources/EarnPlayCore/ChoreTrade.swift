import Foundation

/// Chore trade (T3.2) — deterministic single-offer state machine.
///
/// The AI offers exactly one chore from the parent-stocked pool
/// (`Policy.chorePool`) mid-session. The child accepts or declines and
/// taps done; the parent confirms completion in person and the unlock is
/// granted. The child never sees a chore menu or list: the session
/// surfaces at most one `currentOffer` at a time, never a list.
///
/// Flow (strict order, enforced by the mutating methods below):
/// `offer` -> `accept` -> `done` -> `parent confirm` -> `grant`.
/// `markDone` grants nothing: no unlock exists between Done and parent
/// confirmation. Only `parentConfirm` produces a `ChoreTradeRecord`
/// carrying `grantedUnlockMinutes`, and only from the
/// `doneAwaitingConfirm` phase, so a second confirm cannot double-grant.
///
/// Offer choice: `selectNextOffer` filters out expired entries
/// (`expiry <= now` is expired) and chores declined earlier in this
/// session, then picks the least-recently-offered chore (rotation over
/// `priorHistory + offeredHistory`), preferring a time-of-day fit and
/// breaking remaining ties deterministically. See `ChoreDaypart`.
///
/// Scope notes:
/// - T3.3 owns the offer-choice logic (when to offer, movement vs
///   chore, weekly caps in `TradeCaps`). This module offers on demand
///   (`makeOffer`) and enforces no caps; after one completed trade the
///   session is terminal (`makeOffer` returns nil once granted).
/// - T1.4 effort state is session context, not a gate here: the host
///   view injects its live `EffortSessionRecorder` so trade taps count
///   as interactions. T3.3 will own effort-gated offer choice.
/// - Verification is parent-confirm in person for the demo. Entries
///   marked `.photoAsync` are selectable (the pool is parent-stocked),
///   but no photo-proof pipeline is built here.

// MARK: - Daypart

/// Time-of-day bucket used for chore fit.
public enum ChoreDaypart: String, Equatable, Sendable {
    case morning
    case afternoon
    case evening
}

/// Maps a 0...23 hour to its daypart. Out-of-range hours clamp.
public func choreDaypart(hour: Int) -> ChoreDaypart {
    if hour < 12 { return .morning }
    if hour < 17 { return .afternoon }
    return .evening
}

// MARK: - Offer and record

/// One offered chore. A session holds at most one at a time.
public struct ChoreTradeOffer: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var entry: ChorePoolEntry
    public var offeredAt: Date

    public init(id: UUID = UUID(), entry: ChorePoolEntry, offeredAt: Date) {
        self.id = id
        self.entry = entry
        self.offeredAt = offeredAt
    }
}

/// Completed-trade record. Exists only after parent confirmation; its
/// `grantedUnlockMinutes` is the unlock the parent-confirm action grants.
public struct ChoreTradeRecord: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var chore: String
    public var unlockMinutes: Int
    public var offeredAt: Date
    public var acceptedAt: Date
    public var doneAt: Date
    public var confirmedAt: Date
    public var grantedUnlockMinutes: Int

    public init(
        sessionID: UUID,
        chore: String,
        unlockMinutes: Int,
        offeredAt: Date,
        acceptedAt: Date,
        doneAt: Date,
        confirmedAt: Date,
        grantedUnlockMinutes: Int
    ) {
        self.sessionID = sessionID
        self.chore = chore
        self.unlockMinutes = unlockMinutes
        self.offeredAt = offeredAt
        self.acceptedAt = acceptedAt
        self.doneAt = doneAt
        self.confirmedAt = confirmedAt
        self.grantedUnlockMinutes = grantedUnlockMinutes
    }
}

/// Session phase. Associated dates make the order auditable: an offer
/// must exist before an accept, an accept before Done, Done before
/// confirmation. Decline returns to `idle` (the chore stays excluded
/// via `declinedChores`); a grant is terminal.
public enum ChoreTradePhase: Equatable, Sendable {
    case idle
    case offered(ChoreTradeOffer)
    case accepted(ChoreTradeOffer, acceptedAt: Date)
    case doneAwaitingConfirm(ChoreTradeOffer, acceptedAt: Date, doneAt: Date)
    case granted(ChoreTradeRecord)
}

// MARK: - Session

/// One session's chore-trade state machine.
///
/// Identity is the chore text (`ChorePoolEntry` carries no id): a
/// declined chore excludes every pool entry with that text for the rest
/// of the session.
public struct ChoreTradeSession: Equatable, Sendable {
    public let sessionID: UUID
    public let pool: [ChorePoolEntry]
    /// Chore names offered in earlier sessions, oldest first, for
    /// cross-session rotation. Empty in the demo.
    public let priorHistory: [String]
    public private(set) var phase: ChoreTradePhase
    public private(set) var declinedChores: Set<String>
    public private(set) var offeredHistory: [String]

    public init(
        pool: [ChorePoolEntry],
        priorHistory: [String] = [],
        sessionID: UUID = UUID()
    ) {
        self.sessionID = sessionID
        self.pool = pool
        self.priorHistory = priorHistory
        self.phase = .idle
        self.declinedChores = []
        self.offeredHistory = []
    }

    /// The single current offer, or nil when idle or granted. This is
    /// the only offer surface: the session never vends a list.
    public var currentOffer: ChoreTradeOffer? {
        switch phase {
        case .idle, .granted: return nil
        case .offered(let offer): return offer
        case .accepted(let offer, _): return offer
        case .doneAwaitingConfirm(let offer, _, _): return offer
        }
    }

    /// True only after parent confirmation produced the record.
    public var hasGrantedUnlock: Bool {
        if case .granted = phase { return true }
        return false
    }

    /// Granted unlock minutes, or nil until parent confirmation.
    public var grantedMinutes: Int? {
        if case .granted(let record) = phase { return record.grantedUnlockMinutes }
        return nil
    }

    /// The completed-trade record, or nil until parent confirmation.
    public var grantedRecord: ChoreTradeRecord? {
        if case .granted(let record) = phase { return record }
        return nil
    }

    /// Offers one chore, or nil when no chore is eligible (all expired,
    /// all declined), when an offer is already active, or when this
    /// session already completed a trade (one trade per session).
    @discardableResult
    public mutating func makeOffer(at now: Date, calendar: Calendar = .current) -> ChoreTradeOffer? {
        guard case .idle = phase else { return nil }
        let hour = calendar.component(.hour, from: now)
        guard let entry = Self.selectNextOffer(
            pool: pool,
            declined: declinedChores,
            history: priorHistory + offeredHistory,
            now: now,
            hour: hour
        ) else { return nil }
        let offer = ChoreTradeOffer(entry: entry, offeredAt: now)
        offeredHistory.append(entry.chore)
        phase = .offered(offer)
        return offer
    }

    /// Accepts the current offer. True only from the offered phase with
    /// a live offer: an offer at or past its expiry (`expiry <= now` is
    /// expired, matching `eligibleChores`) returns the session to idle
    /// and false, so another eligible chore can be offered. The expired
    /// chore itself is never re-offered: `makeOffer` filters it.
    @discardableResult
    public mutating func acceptOffer(at now: Date) -> Bool {
        guard case .offered(let offer) = phase else { return false }
        if offer.entry.expiry <= now {
            phase = .idle
            return false
        }
        phase = .accepted(offer, acceptedAt: now)
        return true
    }

    /// Declines the current offer: practice resumes and the chore stays
    /// excluded for the rest of the session. True only from the offered
    /// phase; after accept there is no decline path in the demo.
    @discardableResult
    public mutating func declineOffer() -> Bool {
        guard case .offered(let offer) = phase else { return false }
        declinedChores.insert(offer.entry.chore)
        phase = .idle
        return true
    }

    /// Marks the accepted chore done. True only from the accepted phase.
    /// Grants nothing: no unlock exists until parent confirmation.
    @discardableResult
    public mutating func markDone(at now: Date) -> Bool {
        guard case .accepted(let offer, let acceptedAt) = phase else { return false }
        phase = .doneAwaitingConfirm(offer, acceptedAt: acceptedAt, doneAt: now)
        return true
    }

    /// Parent confirms completion in person. Returns the completed-trade
    /// record — the unlock grant — only from the doneAwaitingConfirm
    /// phase; otherwise nil. A second confirm returns nil: one grant
    /// per trade, never a double-grant.
    @discardableResult
    public mutating func parentConfirm(at now: Date) -> ChoreTradeRecord? {
        guard case .doneAwaitingConfirm(let offer, let acceptedAt, let doneAt) = phase else {
            return nil
        }
        let record = ChoreTradeRecord(
            sessionID: sessionID,
            chore: offer.entry.chore,
            unlockMinutes: offer.entry.unlockMinutes,
            offeredAt: offer.offeredAt,
            acceptedAt: acceptedAt,
            doneAt: doneAt,
            confirmedAt: now,
            grantedUnlockMinutes: offer.entry.unlockMinutes
        )
        phase = .granted(record)
        return record
    }

    /// Parent confirms completion, committing the terminal granted phase
    /// only when `grant` reports success.
    ///
    /// Confirms a copy of the session and runs `grant` with the resulting
    /// record; the copy replaces the session only when `grant` returns
    /// true. A failed grant (e.g. persisting the unlock window fails)
    /// leaves the session in `doneAwaitingConfirm`, so confirmation stays
    /// retryable instead of losing the reward. Returns nil — without
    /// calling `grant` — from any other phase, preserving the strict
    /// order and the one-grant-per-trade guarantee.
    @discardableResult
    public mutating func parentConfirmWithGrant(
        at now: Date,
        grant: (ChoreTradeRecord) -> Bool
    ) -> ChoreTradeRecord? {
        var confirmed = self
        guard let record = confirmed.parentConfirm(at: now) else { return nil }
        guard grant(record) else { return nil }
        self = confirmed
        return record
    }

    // MARK: - Selection

    /// Pool entries that may be offered at `now`: unexpired and not
    /// declined this session. `expiry <= now` counts as expired.
    public static func eligibleChores(
        pool: [ChorePoolEntry],
        declined: Set<String>,
        now: Date
    ) -> [ChorePoolEntry] {
        pool.filter { $0.expiry > now && !declined.contains($0.chore) }
    }

    /// Picks the one chore to offer: eligible entries ordered by
    /// time-of-day fit (a chore whose text names the current daypart
    /// wins), then rotation (never-offered first, then
    /// least-recently-offered over `history`, oldest first), then a
    /// deterministic daypart-varying tiebreak, then chore text so the
    /// result is total and stable. Nil when nothing is eligible.
    public static func selectNextOffer(
        pool: [ChorePoolEntry],
        declined: Set<String>,
        history: [String],
        now: Date,
        hour: Int
    ) -> ChorePoolEntry? {
        let daypart = choreDaypart(hour: hour)
        let eligible = eligibleChores(pool: pool, declined: declined, now: now)
        guard !eligible.isEmpty else { return nil }
        var lastIndex: [String: Int] = [:]
        for (index, chore) in history.enumerated() { lastIndex[chore] = index }
        return eligible.sorted { lhs, rhs in
            let lhsFit = daypartFitScore(chore: lhs.chore, daypart: daypart)
            let rhsFit = daypartFitScore(chore: rhs.chore, daypart: daypart)
            if lhsFit != rhsFit { return lhsFit > rhsFit }
            let lhsRecency = lastIndex[lhs.chore] ?? -1
            let rhsRecency = lastIndex[rhs.chore] ?? -1
            if lhsRecency != rhsRecency { return lhsRecency < rhsRecency }
            let lhsTie = stableTiebreak(chore: lhs.chore, daypart: daypart)
            let rhsTie = stableTiebreak(chore: rhs.chore, daypart: daypart)
            if lhsTie != rhsTie { return lhsTie < rhsTie }
            return lhs.chore < rhs.chore
        }.first
    }

    /// 1 when the chore text names the current daypart, else 0.
    /// Keyword matching is the demo fit: the pool schema carries no
    /// time-of-day field, so fit reads the parent-written text.
    static func daypartFitScore(chore: String, daypart: ChoreDaypart) -> Int {
        let text = chore.lowercased()
        let keywords: [String]
        switch daypart {
        case .morning:
            keywords = ["morning", "breakfast", "make the bed", "make your bed",
                        "brush teeth", "brush your teeth", "get dressed"]
        case .afternoon:
            keywords = ["homework", "desk", "trash", "recycle", "yard", "garden",
                        "sweep", "vacuum", "mop", "dust"]
        case .evening:
            keywords = ["dinner", "dish", "laundry", "bath", "shower", "bedtime",
                        "evening", "set the table", "kitchen"]
        }
        return keywords.contains(where: { text.contains($0) }) ? 1 : 0
    }

    /// Deterministic daypart-varying tiebreak (djb2 over chore + daypart;
    /// `String.hashValue` is per-run seeded and must not be used).
    static func stableTiebreak(chore: String, daypart: ChoreDaypart) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in (chore + "\u{0}" + daypart.rawValue).utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return hash
    }
}

// MARK: - Demo seed

/// Seeded chore pool for the demo, used only when the policy pool is
/// empty (no sync in the demo). All entries are parent-confirm,
/// in-person: no photo-proof pipeline is built in T3.2.
public enum DemoChorePool {
    public static func seeded(
        expiry: Date = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> [ChorePoolEntry] {
        [
            ChorePoolEntry(
                chore: "Tidy your room",
                unlockMinutes: 10,
                expiry: expiry,
                weeklyCap: 3,
                verificationMode: .parentConfirm
            ),
            ChorePoolEntry(
                chore: "Take out the trash",
                unlockMinutes: 15,
                expiry: expiry,
                weeklyCap: 3,
                verificationMode: .parentConfirm
            ),
            ChorePoolEntry(
                chore: "Help set the dinner table",
                unlockMinutes: 10,
                expiry: expiry,
                weeklyCap: 3,
                verificationMode: .parentConfirm
            ),
        ]
    }
}

// MARK: - Demo shield fixture (fix round 2)

/// Configured policy/enumeration pairs behind the chore-trade demo UI.
///
/// `grantUnlockForAllChallengeUnlockable` grants only over enumerated
/// challenge-unlockable apps, so a manager built with `.empty`
/// enumeration can never grant — the confirm flow needs a configured
/// pair. The demo has no FamilyControls picker (T2.3), so the view takes
/// its pair from here instead. Neither builder touches
/// `Policy.defaultPolicy`: the default-deny policy keeps its empty
/// unblockable list, and the demo policy lives only in the view's
/// isolated store, never in the real on-disk cache.
public enum ChoreTradeDemoShield {
    /// The demo fixture's unblockable app (opaque demo key, not a real
    /// bundle ID — nothing is enforced outside the simulated backend).
    public static let demoApp = AppRef(id: "com.example.earnplay.demo-play")
    /// The demo fixture's category.
    public static let demoCategory = AppCategoryRef(id: "earnplay.demo")

    /// Demo policy: default-deny shape (the default allowlist, no
    /// overrides) plus the demo unblockable app and the given chore
    /// pool. Version 1 so it applies over a fresh isolated store.
    public static func demoPolicy(chorePool: [ChorePoolEntry]) -> Policy {
        Policy(
            version: 1,
            alwaysAllowed: Policy.defaultPolicy.alwaysAllowed,
            unblockable: [demoApp],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: chorePool,
            movementSettings: .default
        )
    }

    /// Enumeration matching the demo policy: the demo app under the
    /// demo category, so a confirm-flow grant creates the simulated
    /// unlock.
    public static func demoEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [EnumeratedApp(app: demoApp, category: demoCategory)],
            categories: [demoCategory]
        )
    }

    /// Enumeration derived from a synced policy's own app lists (the
    /// demo stand-in for picker enumeration): every allowlisted and
    /// unblockable app, deterministically ordered, with no category
    /// metadata. Grants still gate on `isChallengeUnlockable`, so a
    /// policy with no unblockable apps grants nothing.
    public static func enumeration(for policy: Policy) -> ShieldEnumeration {
        let apps = Set(policy.alwaysAllowed + policy.unblockable)
            .sorted { $0.id < $1.id }
            .map { EnumeratedApp(app: $0) }
        return ShieldEnumeration(apps: apps)
    }
}

// MARK: - Unlock grant

extension ShieldManager {
    /// Grants a parent-confirmed chore-trade unlock for every
    /// challenge-unlockable app, for the chore's stated minutes.
    /// Returns false for non-positive minutes or when no app qualifies
    /// (mirroring `grantUnlockForAllChallengeUnlockable`).
    @discardableResult
    public func grantChoreTradeUnlock(minutes: Int) -> Bool {
        guard minutes > 0 else { return false }
        return grantUnlockForAllChallengeUnlockable(duration: TimeInterval(minutes) * 60)
    }
}
