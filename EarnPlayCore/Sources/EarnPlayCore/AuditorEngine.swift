import Foundation

/// Auditor engine (T4.5, LLD §9). A second, separate check over synced
/// session logs, running on the parent device at sync time and on demand.
///
/// Deterministic logic only. The auditor flags and advises; it never
/// changes policy, never grants or revokes an unlock, and never contacts
/// the child app. Any change that follows a flag is a parent action in
/// the existing policy-editing path.
///
/// Inputs are the merged T1.6 `Decision` records carried verbatim in
/// T4.6 `SessionLog`s, plus the synced session excerpt for each session
/// (effort field values and question records). Full T4.3 transcripts and
/// T4.4 decision-log viewers are v1 and are not built here: the flag
/// detail shows the excerpt and justification carried with the flag.

// MARK: - Flag schema (LLD §2.7, exact)

/// One of the seven auditor checks (LLD §9.1).
public enum AuditCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case leniencyDrift = "leniency-drift"
    case falseNegative = "false-negative"
    case gamingPattern = "gaming-pattern"
    case difficultyMiscalibration = "difficulty-miscalibration"
    case behaviorShift = "behavior-shift"
    case inconsistency = "inconsistency"
    case justificationMismatch = "justification-mismatch"
}

/// Flag severity (LLD §2.7): info / watch / act.
public enum AuditSeverity: String, Codable, Equatable, Sendable, CaseIterable {
    case info
    case watch
    case act

    /// Ordering for listing: act first, then watch, then info.
    public var rank: Int {
        switch self {
        case .act: return 0
        case .watch: return 1
        case .info: return 2
        }
    }
}

/// Parent-driven flag lifecycle (LLD §2.7): open / dismissed / acted.
public enum AuditFlagStatus: String, Codable, Equatable, Sendable {
    case open
    case dismissed
    case acted
}

/// An auditor finding (LLD §2.7). Field names match the LLD table
/// exactly. `evidence` cites a concrete session and field value the
/// parent can open and verify; a flag without log evidence is never
/// emitted.
public struct AuditFlag: Codable, Equatable, Sendable, Identifiable {
    public var flagId: String
    public var sessionId: String
    public var category: AuditCategory
    public var severity: AuditSeverity
    public var evidence: String
    public var suggestedAction: String
    public var status: AuditFlagStatus

    public var id: String { flagId }

    public init(flagId: String, sessionId: String, category: AuditCategory,
                severity: AuditSeverity, evidence: String,
                suggestedAction: String, status: AuditFlagStatus = .open) {
        self.flagId = flagId
        self.sessionId = sessionId
        self.category = category
        self.severity = severity
        self.evidence = evidence
        self.suggestedAction = suggestedAction
        self.status = status
    }

    /// Every session this flag cites: its own session first, then any
    /// known session id named in the evidence or suggested action.
    public func citedSessionIds(knownSessionIds: [String]) -> [String] {
        var out = [sessionId]
        for id in knownSessionIds where id != sessionId && !out.contains(id)
            && (evidence.contains(id) || suggestedAction.contains(id)) {
            out.append(id)
        }
        return out
    }
}

/// Score-free presentation for auditor surfaces (item 3): strips
/// score/threshold tokens and numeric score/bar values while retaining
/// concrete attempts, hint interactions, and other permitted evidence.
/// Stored records are unchanged; only presented text passes here.
public enum AuditorScoreFreeText {
    public static func make(_ text: String) -> String {
        var out = text
        out = replace(#"(?i)score\s+\d+\s+vs\s+threshold\s+\d+"#, in: out, with: "recorded effort compared with the recorded bar")
        out = replace(#"(?i)effortTotal:?\s*(?:is\s+)?\d+"#, in: out, with: "effortTotal (recorded)")
        out = replace(#"(?i)effortBar:?\s*(?:is\s+)?\d+"#, in: out, with: "effortBar (recorded)")
        out = replace(#"(?i)score\s+\d+"#, in: out, with: "recorded effort")
        out = replace(#"(?i)threshold\s+\d+"#, in: out, with: "recorded bar")
        return out
    }
    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Serializes auditor runs (round 2, item 1; round 3, item 3): a run
/// requested while another is in flight coalesces into one rerun
/// instead of overlapping or being dropped.
public final class AuditRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var dirty = false
    public init() {}
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    /// True when a request arrived mid-run and one rerun is owed.
    public var hasPendingRerun: Bool { lock.lock(); defer { lock.unlock() }; return dirty }
    /// Marks a run in flight and returns true, or returns false when
    /// a run is already in flight.
    public func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }
    public func end() { lock.lock(); running = false; dirty = false; lock.unlock() }
    /// Starts a run and returns true, or, when a run is already in
    /// flight, marks it dirty and returns false so the caller coalesces
    /// into one rerun instead of dropping the request (round 3, item 3).
    public func beginOrMarkDirty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { dirty = true; return false }
        running = true
        return true
    }
    /// Ends the current pass. Returns true when a coalesced request is
    /// pending: the caller reruns once and the run stays in flight.
    /// Returns false when the run is fully finished.
    @discardableResult
    public func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dirty { dirty = false; return true }
        running = false
        return false
    }
}

/// Runs audit work off the main queue and hops to the main queue only
/// to publish results (round 3, items 1-2). Requests arriving while a
/// run is in flight coalesce into exactly one rerun, so a session
/// stored mid-audit is still audited (round 3, item 3). Each pass
/// captures its work/publish pair together under one lock when the
/// pass starts, and a newer request's pair is used only for the
/// coalesced rerun: an earlier pass never invokes a later request's
/// publish callback, and no pass's callback is dropped (round 4,
/// item 2).
public final class AuditRunPerformer: @unchecked Sendable {
    private typealias Pair = (work: @Sendable () -> Void, publish: @Sendable () -> Void)
    private let gate = AuditRunGate()
    private let workQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingPair: Pair?
    private var pendingSettled: (@Sendable () -> Void)?

    public init(workQueue: DispatchQueue = DispatchQueue(label: "earnplay.auditor-work", qos: .userInitiated)) {
        self.workQueue = workQueue
    }

    public var isRunning: Bool { gate.isRunning }

    /// `work` runs on the work queue; `publish` then runs on the main
    /// queue. `settled` runs on the main queue once no rerun is owed.
    public func request(work: @escaping @Sendable () -> Void,
                        publish: @escaping @Sendable () -> Void,
                        settled: (@Sendable () -> Void)? = nil) {
        lock.lock()
        pendingPair = (work: work, publish: publish)
        if let settled { pendingSettled = settled }
        // Capture the starting pass's pair together, under the same
        // lock that records the newest pair, so a request arriving
        // before this pass runs cannot substitute its own pair.
        let startPair = gate.beginOrMarkDirty() ? pendingPair : nil
        lock.unlock()
        if let startPair { schedule(startPair) }
    }

    private func schedule(_ pair: Pair) {
        workQueue.async { [self] in
            pair.work()
            DispatchQueue.main.async { [self] in
                pair.publish()
                if gate.finish() {
                    // Use the newer pair only now, for the rerun.
                    lock.lock(); let next = pendingPair; lock.unlock()
                    if let next {
                        schedule(next)
                    } else {
                        drainSettled()
                    }
                } else {
                    drainSettled()
                }
            }
        }
    }

    private func drainSettled() {
        lock.lock(); let settled = pendingSettled; pendingSettled = nil; lock.unlock()
        settled?()
    }
}

/// Completion text for an auditor run (round 2, item 2): success is
/// reported only when the findings write persisted; a persistence
/// failure is reported with a retry prompt instead.
public enum AuditorRunStatus {
    public static func completionMessage(openCount: Int, persistenceError: String?) -> String {
        if let persistenceError, !persistenceError.isEmpty {
            return "Could not save the findings (\(persistenceError)). The previous findings are still shown — run the auditor again to retry."
        }
        return "Auditor run complete. \(openCount) open finding(s)."
    }
}

// MARK: - Synced session excerpt (auditor input)

/// One question as carried in the synced excerpt, for the
/// question-quality / difficulty check.
public struct AuditorQuestionRecord: Codable, Equatable, Sendable {
    public var questionId: String
    /// Form label, e.g. "story", "reverse", "estimation".
    public var form: String
    /// Difficulty level recorded for the question.
    public var difficulty: Int
    /// Whether the recorded answer agreed with the verified answer,
    /// when the excerpt carries it.
    public var answerMatched: Bool?

    public init(questionId: String, form: String, difficulty: Int,
                answerMatched: Bool? = nil) {
        self.questionId = questionId
        self.form = form
        self.difficulty = difficulty
        self.answerMatched = answerMatched
    }
}

/// The synced excerpt for one session: the raw field values the seven
/// checks read, beside the session's T1.6 decisions. This is the Demo
/// excerpt attached to a staged flag, not the v1 full transcript.
public struct AuditorSessionExcerpt: Codable, Equatable, Sendable {
    public var sessionId: String
    public var startedAt: Date
    public var endedAt: Date
    /// T1.6 decisions for this session, carried verbatim.
    public var decisions: [Decision]
    /// Raw effort field values from the session log.
    public var effortTotal: Int?
    public var effortBar: Int?
    public var floorMet: Bool?
    public var signals: EffortSignals?
    public var questions: [AuditorQuestionRecord]
    /// True only when effort/signals came from an independently
    /// recorded snapshot, not parsed from a decision's own text.
    public var hasIndependentSnapshot: Bool

    public init(sessionId: String, startedAt: Date, endedAt: Date,
                decisions: [Decision], effortTotal: Int? = nil,
                effortBar: Int? = nil, floorMet: Bool? = nil,
                signals: EffortSignals? = nil,
                questions: [AuditorQuestionRecord] = [],
                hasIndependentSnapshot: Bool = true) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.decisions = decisions
        self.effortTotal = effortTotal
        self.effortBar = effortBar
        self.floorMet = floorMet
        self.signals = signals
        self.questions = questions
        self.hasIndependentSnapshot = hasIndependentSnapshot
    }

    /// Builds the excerpt from a synced T4.6 `SessionLog`. Where the
    /// log carries independently recorded raw signals/questions, they
    /// are used; otherwise values parsed from the unlock decision's
    /// own evidence text are marked non-independent, so the mismatch
    /// value check does not compare a claim against itself (item 6).
    public init(sessionLog: SessionLog) {
        let parsed = Self.parsedUnlockEvidence(in: sessionLog.decisions)
        let independent = sessionLog.rawSignals != nil || sessionLog.rawEffortTotal != nil
            || sessionLog.rawEffortBar != nil || sessionLog.rawFloorMet != nil
        self.init(sessionId: sessionLog.sessionId,
                  startedAt: sessionLog.startedAt,
                  endedAt: sessionLog.endedAt,
                  decisions: sessionLog.decisions,
                  effortTotal: sessionLog.rawEffortTotal ?? parsed?.total,
                  effortBar: sessionLog.rawEffortBar ?? parsed?.bar,
                  floorMet: sessionLog.rawFloorMet ?? parsed?.floorMet,
                  signals: sessionLog.rawSignals ?? parsed?.signals,
                  questions: sessionLog.questions ?? [],
                  hasIndependentSnapshot: independent)
    }

    /// The session's unlock decision (grant or deny), when present.
    public var unlockDecision: Decision? {
        decisions.last { $0.type == .grantUnlock || $0.type == .denyUnlock }
    }

    public var wasGranted: Bool { unlockDecision?.type == .grantUnlock }

    /// True only when an unlock decision (grant or deny) was recorded.
    /// A session without one has no outcome: it is neither granted nor
    /// denied (round 3, item 5).
    public var hasUnlockDecision: Bool { unlockDecision != nil }

    /// Values parsed from one decision's evidence text.
    public struct ParsedEvidence: Equatable, Sendable {
        public var total: Int
        public var bar: Int
        public var floorMet: Bool
        public var signals: EffortSignals
    }

    /// Parses the field values T1.6 `unlockJustification` records in
    /// `evidenceSummary` ("N active minutes (Ss active time), A genuine
    /// attempts, ...; score T vs threshold B; floor met/not met").
    /// Returns nil when the text carries no such values.
    public static func parsedEvidence(_ text: String) -> ParsedEvidence? {
        guard let total = firstInt(#"score (\d+) vs threshold"#, in: text),
              let bar = firstInt(#"vs threshold (\d+)"#, in: text) else { return nil }
        let floorMet: Bool
        if text.contains("floor not met") { floorMet = false }
        else if text.contains("floor met") { floorMet = true }
        else { return nil }
        let signals = EffortSignals(
            activeSeconds: firstInt(#"\((\d+)s active time\)"#, in: text) ?? 0,
            genuineAttempts: firstInt(#"(\d+) genuine attempt"#, in: text) ?? 0,
            hintInteractions: firstInt(#"(\d+) hint interaction"#, in: text) ?? 0,
            followUpInteractions: firstInt(#"(\d+) follow-up interaction"#, in: text) ?? 0,
            answerRevisions: firstInt(#"(\d+) answer revision"#, in: text) ?? 0,
            explanations: firstInt(#"(\d+) explanation"#, in: text) ?? 0)
        return ParsedEvidence(total: total, bar: bar, floorMet: floorMet, signals: signals)
    }

    public static func parsedUnlockEvidence(in decisions: [Decision]) -> ParsedEvidence? {
        for decision in decisions.reversed()
        where decision.type == .grantUnlock || decision.type == .denyUnlock {
            if let parsed = parsedEvidence(decision.evidenceSummary) { return parsed }
        }
        return nil
    }

    private static func firstInt(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

// MARK: - Auditor runtime seam (admin-app instance, distinct from tutor)

/// Candidate findings from the auditor runtime. The deterministic
/// engine below is the source of truth for emitted flags; candidates
/// alone never become flags without an engine check behind them.
public struct AuditorCandidate: Equatable, Sendable {
    public var sessionId: String
    public var category: AuditCategory
    public var evidence: String

    public init(sessionId: String, category: AuditCategory, evidence: String) {
        self.sessionId = sessionId
        self.category = category
        self.evidence = evidence
    }
}

/// The admin-app auditor runtime: a separate model instance from the
/// child-app tutor runtime (T0.2), used only for log analysis. The
/// deterministic provider ships in the Demo; a model-backed provider
/// can be injected without changing the engine's checks.
public protocol AuditorCandidateProviding: Sendable {
    func candidateFindings(for sessions: [AuditorSessionExcerpt]) -> [AuditorCandidate]
}

/// Deterministic candidate provider: proposes nothing on its own, so
/// every emitted flag comes from the seven checks below.
public struct DeterministicAuditorCandidates: AuditorCandidateProviding, Sendable {
    public init() {}
    public func candidateFindings(for sessions: [AuditorSessionExcerpt]) -> [AuditorCandidate] { [] }
}

/// Owns the admin-app auditor runtime instance. Distinct from any
/// tutor `ModelRuntime`: when a model file is available the admin app
/// constructs its own `ModelRuntime` for this role and never shares
/// the child app's instance or context.
public final class AuditorRuntime: @unchecked Sendable {
    /// Role marker separating this instance from the tutor runtime.
    public static let roleIdentifier = "earnplay-auditor (admin app)"
    public let candidateProvider: any AuditorCandidateProviding
    /// The separate on-device model instance for this role, when the
    /// admin app has one. Nil in the deterministic Demo configuration.
    public let modelRuntime: ModelRuntime?

    public init(candidateProvider: any AuditorCandidateProviding = DeterministicAuditorCandidates(),
                modelRuntime: ModelRuntime? = nil) {
        self.candidateProvider = candidateProvider
        self.modelRuntime = modelRuntime
    }

    /// The admin-app instance used by the Demo: deterministic, with no
    /// shared tutor context.
    public static func adminDefault() -> AuditorRuntime { AuditorRuntime() }
}

// MARK: - Engine

/// Runs the seven checks over synced excerpts and produces flags.
///
/// Pure and deterministic: the same input always yields the same
/// flags, in the same order (session start, then check number). It
/// holds no policy reference and exposes no policy-writing API.
public struct AuditorEngine: Sendable {
    public let runtime: AuditorRuntime

    public init(runtime: AuditorRuntime = .adminDefault()) {
        self.runtime = runtime
    }

    /// Audits the sessions and returns open flags. Sessions are read
    /// in start-time order regardless of input order.
    public func audit(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        let ordered = sessions.sorted {
            ($0.startedAt, $0.sessionId) < ($1.startedAt, $1.sessionId)
        }
        var flags: [AuditFlag] = []
        flags += checkJustificationMismatch(ordered)
        flags += checkFalseNegatives(ordered)
        flags += checkLeniencyDrift(ordered)
        flags += checkGamingPatterns(ordered)
        flags += checkDifficultyMiscalibration(ordered)
        flags += checkBehaviorShifts(ordered)
        flags += checkInconsistency(ordered)
        // Runtime candidates never emit flags by themselves; they are
        // only kept when a deterministic check already supports them.
        _ = runtime.candidateProvider.candidateFindings(for: ordered)
        let order = Dictionary(uniqueKeysWithValues:
            ordered.enumerated().map { ($0.element.sessionId, $0.offset) })
        return flags.sorted {
            (order[$0.sessionId] ?? 0, $0.category.rawValue)
                < (order[$1.sessionId] ?? 0, $1.category.rawValue)
        }
    }

    private func flag(_ category: AuditCategory, _ severity: AuditSeverity,
                      session: AuditorSessionExcerpt, evidence: String,
                      action: String, discriminator: String? = nil) -> AuditFlag {
        let suffix = discriminator.map { "-\($0)" } ?? ""
        return AuditFlag(flagId: "audit-\(category.rawValue)-\(session.sessionId)\(suffix)",
                  sessionId: session.sessionId, category: category,
                  severity: severity, evidence: evidence, suggestedAction: action)
    }

    // Check 7: justification mismatch (severity act, LLD §9.2).
    // Value comparison runs only for the session-final unlock decision
    // against an independently recorded snapshot (items 6, 8), and
    // compares all six signal fields (item 9).
    private func checkJustificationMismatch(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        var out: [AuditFlag] = []
        for session in sessions {
            for decision in session.decisions where !decision.isComplete {
                out.append(flag(.justificationMismatch, .act, session: session,
                    evidence: "Session \(session.sessionId), decision \(decision.decisionId): justification field(s) \(decision.incompleteFields.joined(separator: ", ")) are blank or out of range in the synced record.",
                    action: "Open the session excerpt and read this decision beside the raw log values, then decide whether any setting needs attention.",
                    discriminator: decision.decisionId))
            }
            guard session.hasIndependentSnapshot, let decision = session.unlockDecision, decision.isComplete,
                  let claimed = AuditorSessionExcerpt.parsedEvidence(decision.evidenceSummary),
                  let total = session.effortTotal, let bar = session.effortBar,
                  let floor = session.floorMet else { continue }
            var differing: [String] = []
            if claimed.total != total { differing.append("evidence text says effortTotal \(claimed.total); raw log field effortTotal is \(total)") }
            if claimed.bar != bar { differing.append("evidence text says effortBar \(claimed.bar); raw log field effortBar is \(bar)") }
            if claimed.floorMet != floor { differing.append("evidence text says floorMet \(claimed.floorMet); raw log field floorMet is \(floor)") }
            if let raw = session.signals {
                let c = claimed.signals
                if c.genuineAttempts != raw.genuineAttempts { differing.append("evidence text says genuineAttempts \(c.genuineAttempts); raw log field genuineAttempts is \(raw.genuineAttempts)") }
                if c.activeSeconds != raw.activeSeconds { differing.append("evidence text says activeSeconds \(c.activeSeconds); raw log field activeSeconds is \(raw.activeSeconds)") }
                if c.hintInteractions != raw.hintInteractions { differing.append("evidence text says hintInteractions \(c.hintInteractions); raw log field hintInteractions is \(raw.hintInteractions)") }
                if c.followUpInteractions != raw.followUpInteractions { differing.append("evidence text says followUpInteractions \(c.followUpInteractions); raw log field followUpInteractions is \(raw.followUpInteractions)") }
                if c.answerRevisions != raw.answerRevisions { differing.append("evidence text says answerRevisions \(c.answerRevisions); raw log field answerRevisions is \(raw.answerRevisions)") }
                if c.explanations != raw.explanations { differing.append("evidence text says explanations \(c.explanations); raw log field explanations is \(raw.explanations)") }
            }
            if !differing.isEmpty {
                out.append(flag(.justificationMismatch, .act, session: session,
                    evidence: "Session \(session.sessionId), decision \(decision.decisionId): " + differing.joined(separator: "; ") + ".",
                    action: "Open the session excerpt and compare the justification with the raw log values shown with this flag.",
                    discriminator: decision.decisionId))
            }
        }
        return out
    }

    // Check 2: false negatives — strong trying evidence, denied.
    private func checkFalseNegatives(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        sessions.compactMap { session in
            guard session.unlockDecision?.type == .denyUnlock,
                  let total = session.effortTotal, let bar = session.effortBar,
                  let floor = session.floorMet, floor, total >= bar else { return nil }
            return flag(.falseNegative, .watch, session: session,
                evidence: "Session \(session.sessionId): unlock denied while raw log fields show effortTotal \(total), effortBar \(bar), floorMet true, genuineAttempts \(session.signals?.genuineAttempts ?? 0), activeSeconds \(session.signals?.activeSeconds ?? 0).",
                action: "Open the session excerpt to see the trying evidence, then review the unlock settings in Policy if a change looks right.")
        }
    }

    // Check 1: leniency drift — grants on progressively weaker evidence.
    // Each maximal non-increasing streak is evaluated independently
    // (round 2, item 4): a later drift flags even when an earlier
    // grant breaks the global sequence.
    private func checkLeniencyDrift(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        let grants = sessions.filter { $0.wasGranted && $0.effortTotal != nil }
        guard grants.count >= 3 else { return [] }
        var runs: [[AuditorSessionExcerpt]] = []
        for grant in grants {
            if let prev = runs.last?.last, let prevTotal = prev.effortTotal,
               let total = grant.effortTotal, total > prevTotal {
                runs.append([grant])
            } else if runs.isEmpty {
                runs.append([grant])
            } else {
                runs[runs.count - 1].append(grant)
            }
        }
        var out: [AuditFlag] = []
        for run in runs where run.count >= 3 {
            guard let first = run.first, let last = run.last,
                  let firstTotal = first.effortTotal, let lastTotal = last.effortTotal,
                  lastTotal <= firstTotal - 4 else { continue }
            out.append(flag(.leniencyDrift, .watch, session: last,
                evidence: "Granted sessions in order: " + run.map { "\($0.sessionId) effortTotal \($0.effortTotal ?? 0)" }.joined(separator: ", ") + ". The latest grant rests on weaker evidence than the first.",
                action: "Open the latest session excerpt and review whether the unlock settings still reflect the effort you want to see."))
        }
        return out
    }

    // Check 3: gaming patterns — repeated minimal-work grants (act when repeated).
    private func checkGamingPatterns(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        let minimal = sessions.filter { session in
            guard session.wasGranted, let signals = session.signals else { return false }
            return signals.activeSeconds <= 180 && signals.genuineAttempts <= 2
                && session.endedAt.timeIntervalSince(session.startedAt) <= 300
        }
        guard minimal.count >= 3, let last = minimal.last else { return [] }
        return [flag(.gamingPattern, .act, session: last,
            evidence: "Repeated granted sessions with minimal recorded work: " + minimal.map { "\($0.sessionId) activeSeconds \($0.signals?.activeSeconds ?? 0), genuineAttempts \($0.signals?.genuineAttempts ?? 0)" }.joined(separator: "; ") + ".",
            action: "Open one of these session excerpts to see the pattern, then review practice expectations in Policy if a change looks right.")]
    }

    // Check 4: question quality / difficulty miscalibration.
    private func checkDifficultyMiscalibration(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        sessions.compactMap { session in
            let questions = session.questions
            guard questions.count >= 4 else { return nil }
            let forms = Dictionary(grouping: questions, by: \.form).mapValues(\.count)
            let dominant = forms.max(by: { $0.value < $1.value })
            let dominantShare = Double(dominant?.value ?? 0) / Double(questions.count)
            let answered = questions.filter { $0.answerMatched != nil }
            let matchedShare = answered.isEmpty ? nil
                : Double(answered.filter { $0.answerMatched == true }.count) / Double(answered.count)
            let meanDifficulty = Double(questions.map(\.difficulty).reduce(0, +)) / Double(questions.count)
            var reasons: [String] = []
            if dominantShare >= 0.8, let dominant {
                reasons.append("\(dominant.value) of \(questions.count) questions share form \"\(dominant.key)\"")
            }
            if let matchedShare, matchedShare >= 0.9, meanDifficulty <= 1.5 {
                reasons.append("recorded answers matched on \(answered.filter { $0.answerMatched == true }.count) of \(answered.count) questions at difficulty values \(questions.map(\.difficulty))")
            }
            if let matchedShare, matchedShare <= 0.1, meanDifficulty >= 3.5 {
                reasons.append("recorded answers matched on \(answered.filter { $0.answerMatched == true }.count) of \(answered.count) questions at difficulty values \(questions.map(\.difficulty))")
            }
            guard !reasons.isEmpty else { return nil }
            return flag(.difficultyMiscalibration, .watch, session: session,
                evidence: "Session \(session.sessionId): " + reasons.joined(separator: "; ") + ".",
                action: "Open the session excerpt to see the questions recorded, then review question settings if a change looks right.")
        }
    }

    // Check 5: behavior shifts versus the child's own history. Every
    // session from the fourth onward is evaluated against its own
    // preceding history (round 2, item 5), not only the last session.
    private func checkBehaviorShifts(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        guard sessions.count >= 4 else { return [] }
        var out: [AuditFlag] = []
        for index in 3..<sessions.count {
            let latest = sessions[index]
            // Round 3, item 4: sessions without effort signals are
            // skipped, not treated as a baseline of zero — one missing
            // observation must not disable the whole check. At least
            // three usable baseline sessions are still required.
            let usable = sessions[..<index].filter { $0.signals != nil }
            guard let latestSignals = latest.signals, usable.count >= 3 else { continue }
            let priorAttempts = usable.map { Double($0.signals?.genuineAttempts ?? 0) }
            let meanAttempts = priorAttempts.reduce(0, +) / Double(priorAttempts.count)
            guard meanAttempts >= 3,
                  Double(latestSignals.genuineAttempts) <= meanAttempts * 0.25 else { continue }
            out.append(flag(.behaviorShift, .info, session: latest,
                evidence: "Session \(latest.sessionId): genuineAttempts \(latestSignals.genuineAttempts), activeSeconds \(latestSignals.activeSeconds). Prior sessions \(usable.map(\.sessionId).joined(separator: ", ")) recorded genuineAttempts \(usable.map { String($0.signals?.genuineAttempts ?? 0) }.joined(separator: ", ")).",
                action: "Open the latest session excerpt to see what changed, and talk with your child about how practice is going."))
        }
        return out
    }

    // Check 6: inconsistency — similar evidence, different decisions.
    private func checkInconsistency(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        var out: [AuditFlag] = []
        for (index, session) in sessions.enumerated() {
            // Round 3, item 5: only sessions with a recorded unlock
            // decision have an outcome to compare. A session without
            // one is not a denial and is never compared as one.
            guard session.hasUnlockDecision,
                  let total = session.effortTotal, let floor = session.floorMet else { continue }
            for prior in sessions[..<index] {
                guard prior.hasUnlockDecision,
                      let priorTotal = prior.effortTotal, let priorFloor = prior.floorMet,
                      prior.wasGranted != session.wasGranted,
                      abs(priorTotal - total) <= 2, priorFloor == floor else { continue }
                // Item 10: exclude pairs where both outcomes follow
                // their own recorded eligibility (total vs own bar).
                if Self.followsEligibility(session) && Self.followsEligibility(prior) { continue }
                out.append(flag(.inconsistency, .watch, session: session,
                    evidence: "Session \(session.sessionId): effortTotal \(total), floorMet \(floor), outcome \(session.wasGranted ? "granted" : "denied"). Earlier session \(prior.sessionId): effortTotal \(priorTotal), floorMet \(priorFloor), outcome \(prior.wasGranted ? "granted" : "denied"). The recorded evidence is close and the outcomes differ.",
                    action: "Open both session excerpts and compare the justifications shown with this flag."))
                break
            }
        }
        return out
    }

    private static func followsEligibility(_ s: AuditorSessionExcerpt) -> Bool {
        guard let total = s.effortTotal, let bar = s.effortBar, let floor = s.floorMet else { return false }
        return s.wasGranted ? (total >= bar && floor) : (total < bar || !floor)
    }
}

// MARK: - Flag manager (parent actions; never edits policy)

/// Where an "act" action routes the parent. The auditor itself applies
/// nothing: acting opens the existing parent surfaces.
public enum AuditActionRoute: Equatable, Sendable {
    /// Open the flagged session excerpt and justification.
    case openSession(sessionId: String)
    /// Open the existing policy-editing surface. Saving there is a
    /// parent action delivered as a normal policy update.
    case openPolicyEditor
}

/// Owns the AuditFlag lifecycle (LLD FlagManager): listing open flags
/// by severity, and recording the parent's dismiss / acted choice.
/// Persisted on the parent device; holds no policy-writing API.
public final class AuditFlagManager: @unchecked Sendable {
    public static let fileName = "audit-flags.json"
    private let directory: URL
    private let lock = NSLock()
    private let dataWriter: (Data, URL) throws -> Void
    private var flags: [AuditFlag]
    /// Last persistence failure, if any (item 11). Success is reported
    /// only after a durable write; failures restore prior cached state.
    public private(set) var lastPersistenceError: String?

    public init(directory: URL, dataWriter: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.dataWriter = dataWriter ?? { data, url in try data.write(to: url, options: [.atomic]) }
        self.flags = Self.deduped(Self.load(directory: directory) ?? [])
    }

    public convenience init() {
        self.init(directory: PolicyStore.defaultDirectory())
    }

    static func deduped(_ input: [AuditFlag]) -> [AuditFlag] {
        var byId: [String: AuditFlag] = [:]; var order: [String] = []
        for f in input {
            if let existing = byId[f.flagId] {
                // Resolved status wins over open for duplicate ids.
                if existing.status == .open && f.status != .open { byId[f.flagId] = f }
            } else { byId[f.flagId] = f; order.append(f.flagId) }
        }
        return order.compactMap { byId[$0] }
    }

    /// Records a fresh audit run. Returns true only after durable write.
    @discardableResult
    public func recordRun(_ newFlags: [AuditFlag]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previous = flags
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        let resolved = flags.filter { $0.status != .open }
        let resolvedIds = Set(resolved.map(\.flagId))
        // Round 2, item 6: previously open findings are preserved
        // alongside resolved and new flags. A finding leaves the open
        // list only by parent dismiss/act, never by silent omission
        // from a later run.
        let previouslyOpen = flags.filter { $0.status == .open }
        flags = Self.deduped(resolved + previouslyOpen
            + Self.deduped(newFlags).filter { !resolvedIds.contains($0.flagId) })
        do { try persistLocked(); lastPersistenceError = nil; return true }
        catch { flags = previous; lastPersistenceError = String(describing: error); return false }
    }

    /// Open flags, act first, then watch, then info.
    public var openFlags: [AuditFlag] {
        lock.lock(); defer { lock.unlock() }
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        return flags.filter { $0.status == .open }
            .sorted { ($0.severity.rank, $0.flagId) < ($1.severity.rank, $1.flagId) }
    }

    public var allFlags: [AuditFlag] {
        lock.lock(); defer { lock.unlock() }
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        return flags
    }

    /// Parent dismisses a flag. Returns true only after durable write.
    @discardableResult
    public func dismiss(flagId: String) -> Bool { update(flagId: flagId, status: .dismissed) }

    /// Parent chooses to act. Returns route only after durable write;
    /// nil on failure (previous cached state restored).
    @discardableResult
    public func markActed(flagId: String) -> AuditActionRoute? {
        lock.lock(); defer { lock.unlock() }
        let previous = flags
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        guard let index = flags.firstIndex(where: { $0.flagId == flagId }) else { return nil }
        flags[index].status = .acted
        do { try persistLocked(); lastPersistenceError = nil; return .openPolicyEditor }
        catch { flags = previous; lastPersistenceError = String(describing: error); return nil }
    }

    /// Route for opening a flag's staged detail.
    public func detailRoute(flagId: String) -> AuditActionRoute? {
        lock.lock(); defer { lock.unlock() }
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        guard let flag = flags.first(where: { $0.flagId == flagId }) else { return nil }
        return .openSession(sessionId: flag.sessionId)
    }

    @discardableResult
    private func update(flagId: String, status: AuditFlagStatus) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let previous = flags
        flags = Self.deduped(Self.load(directory: directory) ?? flags)
        // Update every duplicate sharing this id, not only the first.
        var found = false
        for i in flags.indices where flags[i].flagId == flagId { flags[i].status = status; found = true }
        guard found else { return false }
        do { try persistLocked(); lastPersistenceError = nil; return true }
        catch { flags = previous; lastPersistenceError = String(describing: error); return false }
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(flags)
        try dataWriter(data, directory.appendingPathComponent(Self.fileName))
    }

    private static func load(directory: URL) -> [AuditFlag]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode([AuditFlag].self, from: data)
    }
}
