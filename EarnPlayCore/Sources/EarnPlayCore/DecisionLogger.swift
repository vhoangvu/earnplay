import Foundation

/// Decision record (LLD §2.6, T1.6) — one per consequential decision.
///
/// This is the auditability record: the admin app shows all questions,
/// answers, and these justifications together. Field names match the LLD
/// table exactly (`decisionId`, `sessionId`, `type`, `outcome`,
/// `evidenceSummary`, `reasoning`, `alternativeConsidered`, `confidence`,
/// `timestamp`) so T4.5 (auditor) and T4.6 (sync) can build on this schema
/// unchanged.
public struct Decision: Codable, Equatable, Sendable {
    /// Unique per decision (UUID by default).
    public var decisionId: String
    /// Session the decision belongs to.
    public var sessionId: String
    public var type: DecisionType
    /// What was decided, e.g. the app unlocked and for how long, or the trade offered.
    public var outcome: String
    /// Evidence observed: active time, attempts, hint use, revisions, explanations, signals relied on.
    public var evidenceSummary: String
    /// Why this outcome follows from the evidence.
    public var reasoning: String
    /// The main alternative and why it was not chosen.
    public var alternativeConsidered: String
    /// Confidence in the decision, 0...1 inclusive.
    public var confidence: Double
    /// When the decision was made.
    public var timestamp: Date

    public init(decisionId: String, sessionId: String, type: DecisionType,
                outcome: String, evidenceSummary: String, reasoning: String,
                alternativeConsidered: String, confidence: Double, timestamp: Date) {
        self.decisionId = decisionId
        self.sessionId = sessionId
        self.type = type
        self.outcome = outcome
        self.evidenceSummary = evidenceSummary
        self.reasoning = reasoning
        self.alternativeConsidered = alternativeConsidered
        self.confidence = confidence
        self.timestamp = timestamp
    }

    /// True when all five justification fields are populated: `outcome`,
    /// `evidenceSummary`, `reasoning`, `alternativeConsidered` are
    /// non-blank and `confidence` is finite within 0...1. IDs must also be
    /// non-blank. `type` and `timestamp` are always present by construction.
    public var isComplete: Bool { incompleteFields.isEmpty }

    /// Names of justification/identity fields that are blank or out of range.
    /// Empty means complete. Used by tests and the T4.5 justification check.
    public var incompleteFields: [String] {
        var missing: [String] = []
        if decisionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("decisionId")
        }
        if sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("sessionId")
        }
        if outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("outcome")
        }
        if evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("evidenceSummary")
        }
        if reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("reasoning")
        }
        if alternativeConsidered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("alternativeConsidered")
        }
        if !confidence.isFinite || confidence < 0 || confidence > 1 {
            missing.append("confidence")
        }
        return missing
    }
}

/// Decision type (LLD §2.6). Raw values match the LLD exactly.
public enum DecisionType: String, Codable, Equatable, Sendable, CaseIterable {
    case grantUnlock = "grant-unlock"
    case denyUnlock = "deny-unlock"
    case offerTrade = "offer-trade"
    case difficultyChange = "difficulty-change"
    case sessionJudgment = "session-judgment"
}

/// Failure to write a Decision. A throw means no log entry was made, so the
/// caller must not apply the decision's effect (LLD: the record is written
/// before the effect is applied; a decision without a log entry is a defect).
public enum DecisionLogError: Error, Equatable, Sendable {
    /// A justification or identity field was blank, or unlock context
    /// (`appId` / `durationMinutes`) was missing. Associated value names the field.
    case incompleteJustification(field: String)
    /// Confidence was NaN, infinite, or outside 0...1.
    case confidenceOutOfRange
    /// A record with this `decisionId` is already logged.
    case duplicateDecisionId
    /// The validated record could not be persisted. Nothing was appended,
    /// in memory or on disk, so the decision must not take effect.
    case persistenceFailed
}

/// Append-only persisted Decision log on the child device (LLD `DecisionLogger`, T1.6).
///
/// Writes an immutable record for every consequential decision —
/// grant-unlock, deny-unlock, offer-trade, difficulty-change,
/// session-judgment — including evidence summary, reasoning, alternative
/// considered, and confidence, before the decision's effect is applied.
/// Inputs: decision events from EffortScorer (live, via `logUnlock` /
/// `evaluateAndLog`) and, when they land, TutorEngine and the T3.x trade
/// managers (via the typed seams below). Outputs: persisted records,
/// included in the SessionLog at sync (T4.6 reads `decisions` /
/// `encodedForSync()`; this type does no networking itself).
///
/// ## Append-only and persisted
///
/// There is deliberately no update, delete, or clear API: records are only
/// appended, never mutated. Each append is validated (non-blank
/// justification, confidence 0...1, unique ID) and written atomically to
/// `decisions.json` in Application Support `EarnPlay/` (same directory as
/// `PolicyStore`, different file), with a best-effort backup copy for the
/// corrupt-primary fallback. Loading tries primary, then backup, then an
/// empty log — but an unreadable store (files exist yet neither decodes)
/// is not an empty log: appends fail closed with `persistenceFailed`
/// without overwriting, until history is recoverable again. Tests inject
/// an isolated temporary directory; production uses the default directory
/// and accumulates across launches.
///
/// ## Which paths are live at this stage
///
/// Only the T1.4 unlock path is live: `logUnlock(evaluation:...)` maps an
/// `EffortScore` to grant-unlock / deny-unlock with a deterministic
/// justification built from the actual signals, and `evaluateAndLog` scores
/// and logs atomically so the unlock path cannot complete without its log
/// write (if it throws, apply no effect). The session-decision boundary is
/// `EffortSessionRecorder.evaluateAndLog`, which routes the recorded
/// session through this log; the plain `evaluate` preview must never drive
/// an unlock effect. Difficulty-change has no live caller yet — no
/// TutorEngine exists on this branch, and none is invented here — so
/// `logDifficultyChange` is test-only until it lands. Offer-trade and
/// session-judgment are live through T3.3 (`TradeOfferDecider.decideAndLog`,
/// which logs every offer decision including no-offer).
///
/// ## Routine actions
///
/// Routine actions get a one-line reason via `routineReason(_:)`, not a
/// Decision record. That helper normalizes to a single line and is never
/// persisted in this log.
public final class DecisionLogger: @unchecked Sendable {
    /// Primary log file name inside the store directory.
    public static let decisionsFileName = "decisions.json"
    /// Last-good backup file name inside the store directory.
    public static let backupFileName = "decisions-backup.json"
    /// Cross-instance lock file serializing read/check/write in `log`.
    private static let lockFileName = "decisions.lock"

    private let directory: URL
    private let fileManager: FileManager
    private let dataWriter: (Data, URL) throws -> Void
    private let lockAcquirer: (URL) throws -> Int32
    private let lock = NSLock()
    private var cached: [Decision]

    /// Creates a logger over `directory`, loading any persisted records.
    ///
    /// Loading never throws: a missing store yields an empty log; an
    /// unreadable/corrupt primary falls back to the backup; an unreadable
    /// store (files exist yet neither decodes) also yields an empty
    /// in-memory log, but subsequent appends fail closed with
    /// `persistenceFailed` until history is recoverable again, so
    /// unreadable history is never overwritten.
    ///
    /// `dataWriter` is the persistence seam: it writes encoded log data to
    /// a file URL and must throw on failure. Production uses the default
    /// atomic `Data.write`; tests inject a throwing writer to prove a
    /// failed write appends nothing and the decision must not take effect.
    ///
    /// `lockAcquirer` is the lock-acquisition seam: given the lock-file
    /// URL it must return a locked file descriptor or throw an
    /// `NSPOSIXErrorDomain` error. Production uses the default
    /// `open` + `flock(LOCK_EX)` implementation; tests inject a failing
    /// acquirer to exercise that path deterministically.
    public init(directory: URL,
                fileManager: FileManager = .default,
                dataWriter: ((Data, URL) throws -> Void)? = nil,
                lockAcquirer: ((URL) throws -> Int32)? = nil) {
        self.directory = directory
        self.fileManager = fileManager
        self.dataWriter = dataWriter ?? { data, url in
            try data.write(to: url, options: [.atomic])
        }
        self.lockAcquirer = lockAcquirer ?? Self.acquireLockFile(at:)
        switch Self.loadOutcome(directory: directory, fileManager: fileManager) {
        case .loaded(let decisions):
            self.cached = decisions
        case .absent, .unreadable:
            // Unreadable starts empty in memory (init never throws), but
            // `log` re-checks under the directory lock and fails closed, so
            // the unreadable history is never overwritten.
            self.cached = []
        }
    }

    /// Creates a logger in the default on-device location:
    /// `Application Support/EarnPlay/` (same directory as `PolicyStore`).
    public convenience init(fileManager: FileManager = .default) {
        self.init(directory: PolicyStore.defaultDirectory(fileManager: fileManager),
                  fileManager: fileManager)
    }

    /// All logged decisions in append order. Sync-ready (T4.6): `Decision`
    /// is `Codable` with LLD-exact keys; see also `encodedForSync()`.
    public var decisions: [Decision] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Decisions for one session, in append order.
    public func decisions(for sessionId: String) -> [Decision] {
        lock.lock()
        defer { lock.unlock() }
        return cached.filter { $0.sessionId == sessionId }
    }

    // MARK: - Generic append (validates; persists before returning)

    /// Appends one fully-justified Decision and persists it.
    ///
    /// All string fields are stored trimmed and must be non-blank;
    /// `confidence` must be finite within 0...1; `decisionId` must be
    /// unique. On any failure nothing is appended and the caller must not
    /// apply the decision's effect.
    @discardableResult
    public func log(type: DecisionType, sessionId: String, outcome: String,
                    evidenceSummary: String, reasoning: String,
                    alternativeConsidered: String, confidence: Double,
                    timestamp: Date = Date(),
                    decisionId: String = UUID().uuidString) throws -> Decision {
        let trimmedId = decisionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "decisionId")
        }
        let trimmedSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "sessionId")
        }
        let trimmedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutcome.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "outcome")
        }
        let trimmedEvidence = evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEvidence.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "evidenceSummary")
        }
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReasoning.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "reasoning")
        }
        let trimmedAlternative = alternativeConsidered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlternative.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "alternativeConsidered")
        }
        guard confidence.isFinite, confidence >= 0, confidence <= 1 else {
            throw DecisionLogError.confidenceOutOfRange
        }
        let record = Decision(decisionId: trimmedId, sessionId: trimmedSession, type: type,
                              outcome: trimmedOutcome, evidenceSummary: trimmedEvidence,
                              reasoning: trimmedReasoning, alternativeConsidered: trimmedAlternative,
                              confidence: confidence, timestamp: timestamp)
        lock.lock()
        defer { lock.unlock() }
        // Serialize read/check/write across live instances over the same
        // directory (the instance lock alone cannot), then reload the
        // persisted history under that lock before checking IDs and
        // appending — following PolicyStore.apply. Without the reload, a
        // stale instance would overwrite records another instance wrote.
        let lockFD: Int32
        do {
            lockFD = try acquireDirectoryLock()
        } catch {
            // Never proceed unlocked: fail before reading or writing.
            throw DecisionLogError.persistenceFailed
        }
        defer { releaseDirectoryLock(lockFD) }
        switch Self.loadOutcome(directory: directory, fileManager: fileManager) {
        case .loaded(let persisted):
            var seen = Set(persisted.map(\.decisionId))
            var merged = persisted
            for held in cached where !seen.contains(held.decisionId) {
                merged.append(held)
                seen.insert(held.decisionId)
            }
            cached = merged
        case .absent:
            break
        case .unreadable:
            // History exists but cannot be recovered (both files present
            // yet neither decodes): fail without writing, so the append
            // never replaces audit history with only the new record.
            throw DecisionLogError.persistenceFailed
        }
        if cached.contains(where: { $0.decisionId == record.decisionId }) {
            throw DecisionLogError.duplicateDecisionId
        }
        let appended: [Decision]
        do {
            appended = cached + [record]
            try persist(appended)
        } catch {
            throw DecisionLogError.persistenceFailed
        }
        cached = appended
        return record
    }

    // MARK: - Typed seams (one per LLD decision type)

    /// Logs a grant-unlock Decision. T3.x / ShieldManager call sites use the
    /// unlock mapping (`logUnlock`) when the grant comes from effort; this
    /// seam covers grants whose justification is built by the caller.
    @discardableResult
    public func logUnlockGrant(sessionId: String, outcome: String, evidenceSummary: String,
                               reasoning: String, alternativeConsidered: String,
                               confidence: Double, timestamp: Date = Date(),
                               decisionId: String = UUID().uuidString) throws -> Decision {
        try log(type: .grantUnlock, sessionId: sessionId, outcome: outcome,
                evidenceSummary: evidenceSummary, reasoning: reasoning,
                alternativeConsidered: alternativeConsidered, confidence: confidence,
                timestamp: timestamp, decisionId: decisionId)
    }

    /// Logs a deny-unlock Decision. See `logUnlockGrant` for the seam note.
    @discardableResult
    public func logUnlockDeny(sessionId: String, outcome: String, evidenceSummary: String,
                              reasoning: String, alternativeConsidered: String,
                              confidence: Double, timestamp: Date = Date(),
                              decisionId: String = UUID().uuidString) throws -> Decision {
        try log(type: .denyUnlock, sessionId: sessionId, outcome: outcome,
                evidenceSummary: evidenceSummary, reasoning: reasoning,
                alternativeConsidered: alternativeConsidered, confidence: confidence,
                timestamp: timestamp, decisionId: decisionId)
    }

    /// Call-site seam for T3.x: logs an offer-trade Decision. Live caller:
    /// T3.3 `TradeOfferDecider.decideAndLog` (one record per offered trade).
    @discardableResult
    public func logTradeOffer(sessionId: String, outcome: String, evidenceSummary: String,
                              reasoning: String, alternativeConsidered: String,
                              confidence: Double, timestamp: Date = Date(),
                              decisionId: String = UUID().uuidString) throws -> Decision {
        try log(type: .offerTrade, sessionId: sessionId, outcome: outcome,
                evidenceSummary: evidenceSummary, reasoning: reasoning,
                alternativeConsidered: alternativeConsidered, confidence: confidence,
                timestamp: timestamp, decisionId: decisionId)
    }

    /// Call-site seam for TutorEngine: logs a difficulty-change Decision. No
    /// live caller exists yet (no TutorEngine on this branch), so this is
    /// test-only until the difficulty engine lands.
    @discardableResult
    public func logDifficultyChange(sessionId: String, outcome: String, evidenceSummary: String,
                                    reasoning: String, alternativeConsidered: String,
                                    confidence: Double, timestamp: Date = Date(),
                                    decisionId: String = UUID().uuidString) throws -> Decision {
        try log(type: .difficultyChange, sessionId: sessionId, outcome: outcome,
                evidenceSummary: evidenceSummary, reasoning: reasoning,
                alternativeConsidered: alternativeConsidered, confidence: confidence,
                timestamp: timestamp, decisionId: decisionId)
    }

    /// Logs a session-judgment Decision (e.g. the patience-exhausted offer
    /// condition, LLD §7). Live caller: T3.3 `TradeOfferDecider.decideAndLog`
    /// (one record per no-offer decision).
    @discardableResult
    public func logSessionJudgment(sessionId: String, outcome: String, evidenceSummary: String,
                                   reasoning: String, alternativeConsidered: String,
                                   confidence: Double, timestamp: Date = Date(),
                                   decisionId: String = UUID().uuidString) throws -> Decision {
        try log(type: .sessionJudgment, sessionId: sessionId, outcome: outcome,
                evidenceSummary: evidenceSummary, reasoning: reasoning,
                alternativeConsidered: alternativeConsidered, confidence: confidence,
                timestamp: timestamp, decisionId: decisionId)
    }

    // MARK: - Live unlock wiring (T1.4 EffortScore -> grant/deny Decision)

    /// Deterministic justification for an unlock decision from its evaluation.
    ///
    /// Pure and total over valid unlock context: the same `evaluation` always
    /// yields the same type, outcome, evidence, reasoning, alternative, and
    /// confidence. Evidence names what the child actually did (active time,
    /// attempts, hint/follow-up use, revisions, explanations, score vs
    /// threshold, floor state); grant and deny reasoning are distinct texts,
    /// never copies. Throws `incompleteJustification` when `appId` is blank
    /// or `durationMinutes` is not positive.
    public static func unlockJustification(for evaluation: EffortScore,
                                           floorSettings: EffortFloorSettings = .default,
                                           appId: String,
                                           durationMinutes: Int)
    throws -> (type: DecisionType, outcome: String, evidenceSummary: String,
               reasoning: String, alternativeConsidered: String, confidence: Double) {
        let app = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else {
            throw DecisionLogError.incompleteJustification(field: "appId")
        }
        guard durationMinutes > 0 else {
            throw DecisionLogError.incompleteJustification(field: "durationMinutes")
        }
        let signals = evaluation.signals
        let score = evaluation.score
        let threshold = evaluation.threshold
        let floorMet = evaluation.floorMet
        let granted = evaluation.unlockGranted
        let type: DecisionType = granted ? .grantUnlock : .denyUnlock

        let evidence = "Evidence: \(count(signals.activeMinutes, singular: "active minute"))"
            + " (\(signals.activeSeconds)s active time),"
            + " \(count(signals.genuineAttempts, singular: "genuine attempt")),"
            + " \(count(signals.hintInteractions, singular: "hint interaction")),"
            + " \(count(signals.followUpInteractions, singular: "follow-up interaction")),"
            + " \(count(signals.answerRevisions, singular: "answer revision")),"
            + " \(count(signals.explanations, singular: "explanation"));"
            + " score \(score) vs threshold \(threshold);"
            + " floor \(floorMet ? "met" : "not met")."

        let reasoning: String
        let alternative: String
        let outcome: String
        let confidence: Double
        if granted {
            reasoning = "Score \(score) meets threshold \(threshold) and floor met"
                + " (\(signals.genuineAttempts) genuine attempts and"
                + " \(signals.hintOrFollowUpInteractions) hint/follow-up interactions),"
                + " so unlock follows."
            alternative = "Alternative was to deny and require more practice; rejected"
                + " because both gates hold and denial would be a false negative."
            outcome = "Granted unlock of \(app) for \(durationMinutes) minutes"
                + " (score \(score) vs threshold \(threshold), floor met)."
            let margin = Double(score - threshold)
            confidence = 0.8 + min(0.15, margin * 0.02)
        } else if !floorMet {
            let needAttempts = max(1, floorSettings.minGenuineAttempts)
            let needHint = max(1, floorSettings.minHintOrFollowUpInteractions)
            reasoning = "Floor not met (\(signals.genuineAttempts) genuine attempts,"
                + " \(signals.hintOrFollowUpInteractions) hint/follow-up interactions;"
                + " need at least \(needAttempts) and \(needHint)): no amount of time"
                + " unlocks without genuine attempt-plus-hint evidence, so deny."
            alternative = "Alternative was to grant despite missing floor; rejected because"
                + " the floor is mandatory and granting would unlock without genuine"
                + " attempt-plus-hint evidence."
            outcome = "Denied unlock for \(app): floor not met"
                + " (score \(score) vs threshold \(threshold))."
            confidence = 0.9
        } else {
            reasoning = "Floor met but score \(score) below threshold \(threshold),"
                + " so deny; more genuine effort required."
            alternative = "Alternative was to grant despite shortfall; rejected because"
                + " threshold not met and granting would reward insufficient effort."
            outcome = "Denied unlock for \(app): score \(score) below threshold"
                + " \(threshold) (floor met)."
            let deficit = Double(threshold - score)
            confidence = 0.65 + min(0.25, deficit * 0.05)
        }
        return (type, outcome, evidence, reasoning, alternative, confidence)
    }

    /// Logs the unlock decision for a T1.4 evaluation.
    ///
    /// Maps `evaluation.decision` to grant-unlock / deny-unlock and builds
    /// the full justification from the actual signals via
    /// `unlockJustification(for:floorSettings:appId:durationMinutes:)`.
    /// Call this before applying the unlock effect; if it throws, apply no
    /// effect. `floorSettings` should be the scorer's settings so deny
    /// reasoning names the enforced minima (defaults to the 1+1 floor).
    @discardableResult
    public func logUnlock(evaluation: EffortScore,
                          floorSettings: EffortFloorSettings = .default,
                          sessionId: String, appId: String, durationMinutes: Int,
                          timestamp: Date = Date(),
                          decisionId: String = UUID().uuidString) throws -> Decision {
        let justification = try Self.unlockJustification(for: evaluation,
                                                         floorSettings: floorSettings,
                                                         appId: appId,
                                                         durationMinutes: durationMinutes)
        return try log(type: justification.type, sessionId: sessionId,
                       outcome: justification.outcome,
                       evidenceSummary: justification.evidenceSummary,
                       reasoning: justification.reasoning,
                       alternativeConsidered: justification.alternativeConsidered,
                       confidence: justification.confidence,
                       timestamp: timestamp, decisionId: decisionId)
    }

    /// Scores the signals and logs the resulting unlock decision atomically.
    ///
    /// This is the enforcement point for "no unlock path completes without
    /// its log write": one call evaluates and appends, and the caller applies
    /// the unlock effect only when this returns. If logging throws (invalid
    /// context, duplicate ID, or persistence failure), nothing returns and
    /// no record exists, so the caller cannot mistake an unlogged
    /// evaluation for a decided one. On success returns both the score and
    /// its persisted Decision.
    public func evaluateAndLog(signals: EffortSignals, scorer: EffortScorer,
                               sessionId: String, appId: String, durationMinutes: Int,
                               timestamp: Date = Date(),
                               decisionId: String = UUID().uuidString)
    throws -> (score: EffortScore, decision: Decision) {
        let score = scorer.evaluate(signals)
        let decision = try logUnlock(evaluation: score, floorSettings: scorer.floorSettings,
                                     sessionId: sessionId, appId: appId,
                                     durationMinutes: durationMinutes,
                                     timestamp: timestamp, decisionId: decisionId)
        return (score, decision)
    }

    // MARK: - Routine one-line reasons (not Decisions, not persisted)

    /// One-line reason for a routine (non-consequential) action.
    ///
    /// Normalizes to a single line: leading/trailing whitespace trimmed and
    /// all internal whitespace runs (including newlines) collapsed to single
    /// spaces. Routine reasons are never Decision records and never touch
    /// this log; consequential decisions must use `log` / the typed seams.
    public static func routineReason(_ reason: String) -> String {
        reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Instance alias for `routineReason(_:)`.
    public func routineReason(_ reason: String) -> String {
        Self.routineReason(reason)
    }

    // MARK: - Reload and sync payload

    /// Re-reads the log from disk — the relaunch-equivalent reload.
    ///
    /// Uses the same fallback chain as initialization (primary, backup,
    /// empty) and merges the loaded snapshot with held records missing
    /// from it — the same union `log` performs — because the snapshot can
    /// be stale: the backup write is best-effort, so a missed backup write
    /// followed by a corrupt primary loads OLDER history, and a wholesale
    /// replace would drop successfully logged decisions still held in
    /// memory (the next append would then persist that incomplete
    /// history). An unreadable store preserves the in-memory log and
    /// returns it, so a transient read failure never wipes held history.
    @discardableResult
    public func reloadFromDisk() -> [Decision] {
        lock.lock()
        defer { lock.unlock() }
        switch Self.loadOutcome(directory: directory, fileManager: fileManager) {
        case .loaded(let loaded):
            var seen = Set(loaded.map(\.decisionId))
            var merged = loaded
            for held in cached where !seen.contains(held.decisionId) {
                merged.append(held)
                seen.insert(held.decisionId)
            }
            cached = merged
            return merged
        case .absent:
            cached = []
            return []
        case .unreadable:
            return cached
        }
    }

    /// JSON payload of the full log for T4.6 sync (child → admin).
    ///
    /// Same `Codable` schema as the on-disk file (sorted keys, fractional
    /// seconds preserved). T4.6 copies these bytes into the SessionLog;
    /// this type does no networking itself.
    public func encodedForSync() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try Self.encode(cached)
    }

    // MARK: - Cross-instance lock (fail-closed; reload above is the guard)

    private func acquireDirectoryLock() throws -> Int32 {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let lockURL = directory.appendingPathComponent(Self.lockFileName)
        while true {
            do {
                return try lockAcquirer(lockURL)
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

    // MARK: - Persistence (caller holds `lock`, except loadOutcome at init)

    private func persist(_ decisions: [Decision]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encode(decisions)
        try dataWriter(data, directory.appendingPathComponent(Self.decisionsFileName))
        try? dataWriter(data, directory.appendingPathComponent(Self.backupFileName))
    }

    private static func encode(_ decisions: [Decision]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(decisions)
    }

    /// Outcome of attempting to read persisted history.
    private enum LoadOutcome {
        /// Neither file exists: no history to recover.
        case absent
        /// At least one file decoded.
        case loaded([Decision])
        /// At least one file exists but neither decoded (unreadable or
        /// corrupt): history cannot be recovered.
        case unreadable
    }

    private static func loadOutcome(directory: URL, fileManager: FileManager) -> LoadOutcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var sawExisting = false
        for name in [decisionsFileName, backupFileName] {
            let url = directory.appendingPathComponent(name)
            do {
                let data = try Data(contentsOf: url)
                if let decisions = try? decoder.decode([Decision].self, from: data) {
                    return .loaded(decisions)
                }
                sawExisting = true
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
                continue
            } catch {
                // Missing files are handled above; any other failure means
                // history exists but cannot be recovered — unless the path
                // is now gone (error-code variance), which counts as missing.
                if !fileManager.fileExists(atPath: url.path) {
                    continue
                }
                sawExisting = true
            }
        }
        return sawExisting ? .unreadable : .absent
    }

    private static func count(_ value: Int, singular: String) -> String {
        value == 1 ? "1 \(singular)" : "\(value) \(singular)s"
    }
}
