import Foundation

/// Movement trade (T3.1) — AI-initiated physical-activity trade.
///
/// Flow: the AI (future TutorEngine / T3.3) detects low motivation after the
/// T1.4 floor is met and asks `MovementTradeManager.decide(_:policy:)` whether
/// a movement offer may be made. Caps and the taper rule are enforced in code
/// here — never by the model. An offer runs as a `MovementTradeSession`:
/// accept → verified reps counted by `VerifiedRepCounter` (live count shown
/// in the app) → completion grants the shorter trade unlock automatically
/// (no parent approval; LLD §7.1). Every terminal session produces a
/// self-contained `MovementTradeRecord` for T1.6/T4.x and a
/// `MovementTradeHistoryEntry` for caps and taper.
///
/// AI-initiated-only is structural: the only path to an offer is
/// `MovementTradeManager.decide` with `initiation == .aiLowMotivation`.
/// There is no child-request path, no menu, and no standing trigger.

// MARK: - Initiation

/// Who (or what) initiated the trade moment. Only `.aiLowMotivation` —
/// the AI judging patience exhausted while the child still wants the
/// unlock — can produce an offer.
public enum TradeInitiation: String, Equatable, Sendable {
    case aiLowMotivation
    case childRequest
    case none
}

// MARK: - Offer decision

/// Inputs to the offer decision. Session/weekly counts are read from
/// `MovementTradeHistory`; `sessionsSinceLastMovementOffer` comes from the
/// session owner (nil when no movement trade was ever offered).
public struct MovementOfferContext: Equatable, Sendable {
    public var initiation: TradeInitiation
    public var signals: EffortSignals
    /// Legacy, ignored by the offer gate: the floor is read from the
    /// supplied policy's `effortFloorSettings` (the parent's settings),
    /// so a movement trade cannot bypass stronger practice requirements.
    /// Kept so existing constructions keep compiling.
    public var floorSettings: EffortFloorSettings
    public var sessionOffersUsed: Int
    public var weeklyCompletions: Int
    /// Per-session completion flags, chronological oldest-first, up to 5 —
    /// over ALL recent sessions, with practice-only sessions as false (see
    /// `MovementTradeHistory.recentSessionCompletions(allSessionsInOrder:)`).
    public var recentSessionCompletions: [Bool]
    public var sessionsSinceLastMovementOffer: Int?

    public init(initiation: TradeInitiation, signals: EffortSignals,
                floorSettings: EffortFloorSettings = .default,
                sessionOffersUsed: Int = 0, weeklyCompletions: Int = 0,
                recentSessionCompletions: [Bool] = [],
                sessionsSinceLastMovementOffer: Int? = nil) {
        self.initiation = initiation
        self.signals = signals
        self.floorSettings = floorSettings
        self.sessionOffersUsed = sessionOffersUsed
        self.weeklyCompletions = weeklyCompletions
        self.recentSessionCompletions = recentSessionCompletions
        self.sessionsSinceLastMovementOffer = sessionsSinceLastMovementOffer
    }
}

/// Why no offer was made. Recorded in the session log; terminal refusals
/// (caps, floor, initiation) end the trade moment for this session.
public enum MovementOfferRefusal: String, Equatable, Sendable {
    case notAIInitiated
    case floorNotMet
    case sessionCapReached
    case weeklyCapReached
    case taperedCooldown
    case taperedPracticeRequired
    case noAllowedActivity
}

/// An offer the AI may present: one activity, one rep target, one grant.
public struct MovementTradeOffer: Equatable, Sendable {
    public var activity: MovementActivity
    public var targetReps: Int
    public var unlockMinutes: Int
    /// True when the offer was made under the taper rule.
    public var taperApplied: Bool

    public init(activity: MovementActivity, targetReps: Int,
                unlockMinutes: Int, taperApplied: Bool) {
        self.activity = activity
        self.targetReps = targetReps
        self.unlockMinutes = unlockMinutes
        self.taperApplied = taperApplied
    }
}

public enum MovementOfferDecision: Equatable, Sendable {
    case offer(MovementTradeOffer)
    case refuse(MovementOfferRefusal)
}

// MARK: - Taper rule

/// Taper rule (LLD §7.1): when movement trades become the pattern, offer
/// less often and require a short practice attempt first; the pattern is
/// flagged for the parent via `MovementTradeRecord.taperPatternFlagged`.
public enum TaperRule {
    /// Sessions of history examined.
    public static let windowSessions = 5
    /// Completions within the window that constitute a pattern.
    public static let patternThreshold = 4
    /// History entries needed before the rule can trigger (4-of-4 counts).
    public static let minHistoryEntries = 4
    /// Tapered sessions between offers ("offer less often").
    public static let minSessionsBetweenOffers = 2
    /// Genuine attempts required when tapered: the floor's attempt plus a
    /// short practice burst first.
    public static let taperedMinGenuineAttempts = 3

    /// True when the last `windowSessions` sessions (or fewer, when little
    /// history exists) contain at least `patternThreshold` completions.
    public static func isPattern(_ recentSessionCompletions: [Bool]) -> Bool {
        let window = Array(recentSessionCompletions.suffix(windowSessions))
        return window.count >= minHistoryEntries
            && window.filter({ $0 }).count >= patternThreshold
    }
}

// MARK: - Offer manager

/// Decides whether a movement trade may be offered. Deterministic; the AI
/// proposes the moment, this gate disposes.
public enum MovementTradeManager {
    /// Demo rep target. The LLD fixes only `maxReps`; 10 is the chosen
    /// default within `1...maxReps`.
    public static let defaultTargetReps = 10
    /// Canonical preference order for picking one offered activity.
    public static let canonicalActivityOrder: [MovementActivity] = [
        .jumpingJacks, .runningInPlace, .squats, .marchingInPlace,
    ]

    public static func targetReps(maxReps: Int) -> Int {
        min(max(1, defaultTargetReps), max(1, maxReps))
    }

    /// The single activity to offer: the first canonical activity the
    /// policy allows. Nil when the policy allows nothing.
    public static func selectActivity(allowed: [MovementActivity]) -> MovementActivity? {
        canonicalActivityOrder.first(where: { allowed.contains($0) })
    }

    /// Gate order: initiation → floor → session cap → weekly cap → taper →
    /// activity availability. Caps fail closed on degenerate policy values.
    public static func decide(context: MovementOfferContext, policy: Policy) -> MovementOfferDecision {
        guard context.initiation == .aiLowMotivation else {
            return .refuse(.notAIInitiated)
        }
        // Threshold is irrelevant here; only the T1.4 floor rule is read,
        // with the POLICY's floor settings — never the context's.
        let floor = EffortScorer(threshold: 8, floorSettings: policy.effortFloorSettings)
        guard floor.floorMet(for: context.signals) else {
            return .refuse(.floorNotMet)
        }
        guard context.sessionOffersUsed < max(0, policy.tradeCaps.maxTradesPerSession) else {
            return .refuse(.sessionCapReached)
        }
        guard context.weeklyCompletions < max(0, policy.tradeCaps.weeklyMaxMovementTrades) else {
            return .refuse(.weeklyCapReached)
        }
        let tapered = TaperRule.isPattern(context.recentSessionCompletions)
        if tapered {
            if let since = context.sessionsSinceLastMovementOffer,
               since < TaperRule.minSessionsBetweenOffers {
                return .refuse(.taperedCooldown)
            }
            if context.signals.genuineAttempts < TaperRule.taperedMinGenuineAttempts {
                return .refuse(.taperedPracticeRequired)
            }
        }
        guard let activity = selectActivity(allowed: policy.movementSettings.allowedActivities) else {
            return .refuse(.noAllowedActivity)
        }
        return .offer(MovementTradeOffer(
            activity: activity,
            targetReps: targetReps(maxReps: policy.movementSettings.maxReps),
            unlockMinutes: policy.movementSettings.tradeUnlockDurationMinutes,
            taperApplied: tapered))
    }
}

// MARK: - Outcome and history

/// Outcome of a movement trade. Movement unlocks are automatic on
/// verified completion (no parent approval; LLD §7.1), so completion and
/// grant are one outcome.
public enum MovementTradeOutcome: String, Codable, Equatable, Sendable {
    /// Reservation: the offer was presented and counts toward caps, but no
    /// terminal outcome is recorded yet. The store replaces it with the
    /// terminal outcome when the trade completes.
    case offered
    case granted
    case declined
    case abandoned
}

/// One offered trade for caps and taper. Append-only, chronological;
/// a reservation entry (`.offered`) is updated in place to its terminal
/// outcome on completion.
public struct MovementTradeHistoryEntry: Codable, Equatable, Sendable {
    /// Identifies the trade across its reservation and its terminal
    /// update, including across store instances (the view model reserves
    /// at presentation and finalizes at completion).
    public var tradeId: String
    public var sessionId: String
    public var activity: MovementActivity
    public var offeredAt: Date
    public var outcome: MovementTradeOutcome
    /// Set when granted; defines the weekly-cap window.
    public var completedAt: Date?
    public var verifiedReps: Int
    public var targetReps: Int

    public init(tradeId: String = UUID().uuidString, sessionId: String,
                activity: MovementActivity, offeredAt: Date,
                outcome: MovementTradeOutcome, completedAt: Date? = nil,
                verifiedReps: Int, targetReps: Int) {
        self.tradeId = tradeId
        self.sessionId = sessionId
        self.activity = activity
        self.offeredAt = offeredAt
        self.outcome = outcome
        self.completedAt = completedAt
        self.verifiedReps = verifiedReps
        self.targetReps = targetReps
    }

    private enum CodingKeys: String, CodingKey {
        case tradeId
        case sessionId
        case activity
        case offeredAt
        case outcome
        case completedAt
        case verifiedReps
        case targetReps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Pre-reservation files have no trade ID; mint one so the entry
        // still decodes and compares by value after a round-trip.
        tradeId = try container.decodeIfPresent(String.self, forKey: .tradeId)
            ?? UUID().uuidString
        sessionId = try container.decode(String.self, forKey: .sessionId)
        activity = try container.decode(MovementActivity.self, forKey: .activity)
        offeredAt = try container.decode(Date.self, forKey: .offeredAt)
        outcome = try container.decode(MovementTradeOutcome.self, forKey: .outcome)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        verifiedReps = try container.decode(Int.self, forKey: .verifiedReps)
        targetReps = try container.decode(Int.self, forKey: .targetReps)
    }
}

/// Append-only movement-trade history backing caps and taper.
public struct MovementTradeHistory: Codable, Equatable, Sendable {
    /// Chronological, oldest first.
    public var entries: [MovementTradeHistoryEntry]

    public init(entries: [MovementTradeHistoryEntry] = []) {
        self.entries = entries
    }

    /// Trailing-window length for the weekly cap (7 × 24h from now).
    public static let weekSeconds: TimeInterval = 7 * 24 * 3600

    public func completions(since date: Date) -> Int {
        entries.filter {
            $0.outcome == .granted && ($0.completedAt ?? $0.offeredAt) >= date
        }.count
    }

    public func completionsInTrailingWeek(now: Date = Date()) -> Int {
        completions(since: now.addingTimeInterval(-Self.weekSeconds))
    }

    /// Offers already made in `sessionId` (session-cap numerator).
    public func offersInSession(_ sessionId: String) -> Int {
        entries.filter { $0.sessionId == sessionId }.count
    }

    /// Per-session completion flags, chronological oldest-first, for the
    /// last `limit` sessions that had offers. Feeds `TaperRule.isPattern`
    /// only when the session owner cannot supply the full session order;
    /// prefer `recentSessionCompletions(allSessionsInOrder:)` otherwise,
    /// because this trade-only window cannot see practice-only sessions.
    public func recentSessionCompletions(limit: Int = TaperRule.windowSessions) -> [Bool] {
        var order: [String] = []
        var completed: [String: Bool] = [:]
        for entry in entries {
            if completed[entry.sessionId] == nil {
                order.append(entry.sessionId)
                completed[entry.sessionId] = false
            }
            if entry.outcome == .granted {
                completed[entry.sessionId] = true
            }
        }
        return order.suffix(max(0, limit)).map { completed[$0] ?? false }
    }

    /// Per-session completion flags over the FULL ordered session list
    /// (trade sessions and practice-only sessions alike), chronological
    /// oldest-first, for the last `limit` sessions. Feeds
    /// `TaperRule.isPattern`, which interprets its input as the last five
    /// sessions overall: every listed session without a granted trade —
    /// declined/abandoned offers and practice-only sessions — reads as
    /// false, so practice between grants dilutes the pattern and practice
    /// after a pattern clears it.
    ///
    /// - Parameter allSessionsInOrder: unique session IDs, chronological
    ///   oldest-first, supplied by the session owner. The history only
    ///   records sessions that had offers and cannot enumerate the rest.
    public func recentSessionCompletions(allSessionsInOrder: [String],
                                         limit: Int = TaperRule.windowSessions) -> [Bool] {
        var seen: Set<String> = []
        var ordered: [String] = []
        ordered.reserveCapacity(allSessionsInOrder.count)
        for id in allSessionsInOrder where seen.insert(id).inserted {
            ordered.append(id)
        }
        var granted: Set<String> = []
        for entry in entries where entry.outcome == .granted {
            granted.insert(entry.sessionId)
        }
        return Array(ordered.suffix(max(0, limit))).map { granted.contains($0) }
    }
}

/// File-backed `MovementTradeHistory` on the child device, following the
/// `PolicyStore` precedent (JSON file in Application Support, atomic
/// writes). A missing or corrupt file yields empty history — caps then
/// fail open to "no usage yet", which is correct for a fresh install and
/// safe because the session cap still bounds any single session.
public final class MovementTradeHistoryStore: @unchecked Sendable {
    public static let fileName = "movement-trades.json"
    /// Cross-instance lock file serializing read-modify-write in
    /// `record`/`update` (the `PolicyStore.apply` precedent).
    private static let lockFileName = "movement-trades.lock"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cached: MovementTradeHistory

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        self.cached = Self.load(directory: directory, fileManager: fileManager)
            ?? MovementTradeHistory()
    }

    public convenience init(fileManager: FileManager = .default) {
        self.init(directory: PolicyStore.defaultDirectory(fileManager: fileManager),
                  fileManager: fileManager)
    }

    public var history: MovementTradeHistory {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Appends one entry (a reservation or a terminal trade) and persists.
    public func record(_ entry: MovementTradeHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        mutate { $0.entries.append(entry) }
    }

    /// Replaces the entry with the same `tradeId` (finalizing a
    /// reservation to its terminal outcome) and persists. Appends when no
    /// reservation with that ID is on disk, so a terminal trade is never
    /// lost when its reservation write was missed.
    public func update(_ entry: MovementTradeHistoryEntry) {
        lock.lock()
        defer { lock.unlock() }
        mutate {
            if let index = $0.entries.firstIndex(where: { $0.tradeId == entry.tradeId }) {
                $0.entries[index] = entry
            } else {
                $0.entries.append(entry)
            }
        }
    }

    @discardableResult
    public func reloadFromDisk() -> MovementTradeHistory {
        lock.lock()
        defer { lock.unlock() }
        cached = Self.load(directory: directory, fileManager: fileManager)
            ?? MovementTradeHistory()
        return cached
    }

    /// Runs `change` against the persisted truth inside a cross-instance
    /// file lock, then persists: two stores over one directory can no
    /// longer erase each other's entries (or undercount the weekly cap).
    /// When the lock file itself cannot be acquired, falls back to a
    /// best-effort unsynchronized write; caps fail open by design.
    private func mutate(_ change: (inout MovementTradeHistory) -> Void) {
        guard let fd = try? acquireDirectoryLock() else {
            change(&cached)
            try? persist(cached)
            return
        }
        defer { releaseDirectoryLock(fd) }
        if let persisted = Self.load(directory: directory, fileManager: fileManager) {
            cached = persisted
        }
        change(&cached)
        try? persist(cached)
    }

    private func acquireDirectoryLock() throws -> Int32 {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(Self.lockFileName)
        while true {
            do {
                return try Self.acquireLockFile(at: lockURL)
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain
                    && Int32(error.code) == EINTR {
                continue
            }
        }
    }

    private static func acquireLockFile(at lockURL: URL) throws -> Int32 {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(fd, LOCK_EX) == 0 else {
            let code = Int(errno)
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        return fd
    }

    private func releaseDirectoryLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func persist(_ history: MovementTradeHistory) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(history)
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: [.atomic])
    }

    private static func load(directory: URL, fileManager: FileManager) -> MovementTradeHistory? {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(MovementTradeHistory.self, from: data)
    }
}

// MARK: - Live session

/// Session phase. `offered → active → granted`, with `declined` and
/// `abandoned` exits; `granted` applies the unlock immediately.
public enum MovementTradePhase: String, Equatable, Sendable {
    case offered
    case active
    case declined
    case granted
    case abandoned
}

/// One offered movement trade: the offer state machine plus its live rep
/// counter. UI-agnostic — the app feeds provider samples into `ingest` and
/// reads `verifiedCount` for the live counter.
public struct MovementTradeSession: Equatable, Sendable {
    public let tradeId: String
    public let sessionId: String
    public let offer: MovementTradeOffer
    public let offeredAt: Date
    public private(set) var phase: MovementTradePhase = .offered
    public private(set) var acceptedAt: Date?
    public private(set) var endedAt: Date?
    private var counter: VerifiedRepCounter

    public init(tradeId: String = UUID().uuidString, sessionId: String,
                offer: MovementTradeOffer, offeredAt: Date = Date()) {
        self.tradeId = tradeId
        self.sessionId = sessionId
        self.offer = offer
        self.offeredAt = offeredAt
        self.counter = VerifiedRepCounter(targetReps: offer.targetReps)
    }

    public var verifiedCount: Int { counter.verifiedCount }
    public var targetReps: Int { offer.targetReps }
    public var rejectedNoiseEvents: Int { counter.rejectedNoiseEvents }
    public var isTerminal: Bool {
        phase == .declined || phase == .granted || phase == .abandoned
    }

    /// Accept the offer and begin counting. False unless currently offered.
    @discardableResult
    public mutating func accept(at date: Date = Date()) -> Bool {
        guard phase == .offered else { return false }
        phase = .active
        acceptedAt = date
        return true
    }

    /// Decline the offer. False unless currently offered.
    @discardableResult
    public mutating func decline(at date: Date = Date()) -> Bool {
        guard phase == .offered else { return false }
        phase = .declined
        endedAt = date
        return true
    }

    /// Ingest one motion sample while active; returns the live verified
    /// count. Reaching the target grants immediately. Samples outside the
    /// active phase are ignored.
    @discardableResult
    public mutating func ingest(_ sample: MotionSample, at date: Date = Date()) -> Int {
        guard phase == .active else { return counter.verifiedCount }
        let count = counter.ingest(sample)
        if counter.isComplete {
            phase = .granted
            endedAt = date
        }
        return count
    }

    /// Ingest a stream (fixtures, catch-up); returns the live count.
    @discardableResult
    public mutating func ingest(_ samples: [MotionSample], at date: Date = Date()) -> Int {
        for sample in samples {
            ingest(sample, at: date)
            if phase == .granted { break }
        }
        return counter.verifiedCount
    }

    /// Abandon an accepted trade with no grant. False unless active.
    @discardableResult
    public mutating func abandon(at date: Date = Date()) -> Bool {
        guard phase == .active else { return false }
        phase = .abandoned
        endedAt = date
        return true
    }

    public var outcome: MovementTradeOutcome? {
        switch phase {
        case .granted: return .granted
        case .declined: return .declined
        case .abandoned: return .abandoned
        case .offered, .active: return nil
        }
    }

    /// History entry for caps/taper. Nil until terminal. Carries the
    /// session's trade ID so the store finalizes the presentation-time
    /// reservation instead of appending a second entry.
    public func makeHistoryEntry() -> MovementTradeHistoryEntry? {
        guard let outcome else { return nil }
        return MovementTradeHistoryEntry(
            tradeId: tradeId, sessionId: sessionId, activity: offer.activity,
            offeredAt: offeredAt, outcome: outcome,
            completedAt: outcome == .granted ? endedAt : nil,
            verifiedReps: counter.verifiedCount, targetReps: offer.targetReps)
    }

    /// Self-contained trade record for T1.6/T4.x. Nil until terminal.
    public func makeRecord(verificationConfidence: MovementVerificationConfidence = .full)
        -> MovementTradeRecord? {
        guard let outcome else { return nil }
        let activityName = Self.activityName(offer.activity)
        let evidence: String
        let reasoning: String
        switch outcome {
        case .offered:
            // Unreachable through a session (its outcome is nil until
            // terminal); history reservations never produce records.
            evidence = "Offer presented; outcome not yet recorded."
            reasoning = "Reservation entry; the terminal outcome is still pending."
        case .granted:
            evidence = "Verified \(counter.verifiedCount)/\(offer.targetReps) \(activityName) reps "
                + "by motion (\(counter.rejectedNoiseEvents) unverified motion events rejected)."
            reasoning = "AI-initiated trade after the effort floor was met; verified completion "
                + "grants the shorter \(offer.unlockMinutes)-minute trade unlock."
        case .declined:
            evidence = "Child declined the \(activityName) trade; no reps recorded."
            reasoning = "Declined offer ends with no penalty and no re-offer this session."
        case .abandoned:
            evidence = "Trade accepted but abandoned at \(counter.verifiedCount)/\(offer.targetReps) "
                + "verified \(activityName) reps; no unlock."
            reasoning = "Unverified completion grants nothing; practice remains available."
        }
        return MovementTradeRecord(
            tradeId: tradeId, sessionId: sessionId, activity: offer.activity,
            targetReps: offer.targetReps, verifiedReps: counter.verifiedCount,
            outcome: outcome,
            unlockMinutesGranted: outcome == .granted ? offer.unlockMinutes : nil,
            offeredAt: offeredAt, acceptedAt: acceptedAt, endedAt: endedAt,
            taperApplied: offer.taperApplied, taperPatternFlagged: offer.taperApplied,
            verificationConfidence: verificationConfidence,
            evidenceSummary: evidence, reasoning: reasoning,
            alternativeConsidered: "Continued practice toward the practice-earned unlock.",
            confidence: verificationConfidence == .full
                ? "high — every counted rep matched the activity cadence"
                : "reduced — no pocket carry (iPad); motion evidence is weaker")
    }

    private static func activityName(_ activity: MovementActivity) -> String {
        switch activity {
        case .jumpingJacks: return "jumping-jack"
        case .runningInPlace: return "running-in-place"
        case .squats: return "squat"
        case .marchingInPlace: return "marching-in-place"
        }
    }
}

// MARK: - Trade record (T1.6/T4.x handoff)

/// Verification strength. Phone-in-pocket is full evidence; LLD §7.1 notes
/// iPad verification is weaker (no pocket carry) and must be recorded.
public enum MovementVerificationConfidence: String, Codable, Equatable, Sendable {
    case full
    case reduced

    /// Device carry mapping: iPhone trades verify with the phone in the
    /// pocket (full evidence); iPad has no pocket carry, so its motion
    /// evidence is weaker (reduced, LLD §7.1). The app passes the result
    /// into `MovementTradeViewModel`.
    public static func forDevice(isPad: Bool) -> MovementVerificationConfidence {
        isPad ? .reduced : .full
    }
}

/// Self-contained record of one terminal movement trade.
///
/// T1.6 mapping (no dependency on the decision logger existing yet): this
/// becomes an `offer-trade` / `grant-unlock` Decision whose evidence
/// summary, reasoning, alternative considered, and confidence are the four
/// fields below. T4.x reads `taperPatternFlagged` for the admin pattern
/// flag and `verificationConfidence` for the iPad caveat.
public struct MovementTradeRecord: Codable, Equatable, Sendable {
    public var tradeId: String
    public var sessionId: String
    public var activity: MovementActivity
    public var targetReps: Int
    public var verifiedReps: Int
    public var outcome: MovementTradeOutcome
    /// Set only when granted; always the shorter trade duration.
    public var unlockMinutesGranted: Int?
    public var offeredAt: Date
    public var acceptedAt: Date?
    public var endedAt: Date?
    /// True when the taper rule gated this offer.
    public var taperApplied: Bool
    /// True when the taper pattern held; the admin app surfaces this.
    public var taperPatternFlagged: Bool
    public var verificationConfidence: MovementVerificationConfidence
    // Decision-logger fields:
    public var evidenceSummary: String
    public var reasoning: String
    public var alternativeConsidered: String
    public var confidence: String

    public init(tradeId: String, sessionId: String, activity: MovementActivity,
                targetReps: Int, verifiedReps: Int, outcome: MovementTradeOutcome,
                unlockMinutesGranted: Int?, offeredAt: Date, acceptedAt: Date? = nil,
                endedAt: Date? = nil, taperApplied: Bool, taperPatternFlagged: Bool,
                verificationConfidence: MovementVerificationConfidence,
                evidenceSummary: String, reasoning: String,
                alternativeConsidered: String, confidence: String) {
        self.tradeId = tradeId
        self.sessionId = sessionId
        self.activity = activity
        self.targetReps = targetReps
        self.verifiedReps = verifiedReps
        self.outcome = outcome
        self.unlockMinutesGranted = unlockMinutesGranted
        self.offeredAt = offeredAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.taperApplied = taperApplied
        self.taperPatternFlagged = taperPatternFlagged
        self.verificationConfidence = verificationConfidence
        self.evidenceSummary = evidenceSummary
        self.reasoning = reasoning
        self.alternativeConsidered = alternativeConsidered
        self.confidence = confidence
    }
}
