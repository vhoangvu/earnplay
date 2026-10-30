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

    public init(sessionId: String, startedAt: Date, endedAt: Date,
                decisions: [Decision], effortTotal: Int? = nil,
                effortBar: Int? = nil, floorMet: Bool? = nil,
                signals: EffortSignals? = nil,
                questions: [AuditorQuestionRecord] = []) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.decisions = decisions
        self.effortTotal = effortTotal
        self.effortBar = effortBar
        self.floorMet = floorMet
        self.signals = signals
        self.questions = questions
    }

    /// Builds the excerpt from a synced T4.6 `SessionLog`. Raw effort
    /// values are read from the unlock decision's evidence text (the
    /// concrete field values T1.6 recorded), so a synced log can be
    /// audited without any new child-side schema.
    public init(sessionLog: SessionLog) {
        let parsed = Self.parsedUnlockEvidence(in: sessionLog.decisions)
        self.init(sessionId: sessionLog.sessionId,
                  startedAt: sessionLog.startedAt,
                  endedAt: sessionLog.endedAt,
                  decisions: sessionLog.decisions,
                  effortTotal: parsed?.total,
                  effortBar: parsed?.bar,
                  floorMet: parsed?.floorMet,
                  signals: parsed?.signals,
                  questions: [])
    }

    /// The session's unlock decision (grant or deny), when present.
    public var unlockDecision: Decision? {
        decisions.last { $0.type == .grantUnlock || $0.type == .denyUnlock }
    }

    public var wasGranted: Bool { unlockDecision?.type == .grantUnlock }

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
                      action: String) -> AuditFlag {
        AuditFlag(flagId: "audit-\(category.rawValue)-\(session.sessionId)",
                  sessionId: session.sessionId, category: category,
                  severity: severity, evidence: evidence, suggestedAction: action)
    }

    // Check 7: justification mismatch (severity act, LLD §9.2).
    private func checkJustificationMismatch(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        var out: [AuditFlag] = []
        for session in sessions {
            for decision in session.decisions {
                if !decision.isComplete {
                    out.append(flag(.justificationMismatch, .act, session: session,
                        evidence: "Session \(session.sessionId), decision \(decision.decisionId): justification field(s) \(decision.incompleteFields.joined(separator: ", ")) are blank or out of range in the synced record.",
                        action: "Open the session excerpt and read this decision beside the raw log values, then decide whether any setting needs attention."))
                    continue
                }
                guard let claimed = AuditorSessionExcerpt.parsedEvidence(decision.evidenceSummary),
                      let total = session.effortTotal, let bar = session.effortBar,
                      let floor = session.floorMet else { continue }
                var differing: [String] = []
                if claimed.total != total {
                    differing.append("evidence text says effortTotal \(claimed.total); raw log field effortTotal is \(total)")
                }
                if claimed.bar != bar {
                    differing.append("evidence text says effortBar \(claimed.bar); raw log field effortBar is \(bar)")
                }
                if claimed.floorMet != floor {
                    differing.append("evidence text says floorMet \(claimed.floorMet); raw log field floorMet is \(floor)")
                }
                if let raw = session.signals {
                    let c = claimed.signals
                    if c.genuineAttempts != raw.genuineAttempts {
                        differing.append("evidence text says genuineAttempts \(c.genuineAttempts); raw log field genuineAttempts is \(raw.genuineAttempts)")
                    }
                    if c.activeSeconds != raw.activeSeconds {
                        differing.append("evidence text says activeSeconds \(c.activeSeconds); raw log field activeSeconds is \(raw.activeSeconds)")
                    }
                }
                if !differing.isEmpty {
                    out.append(flag(.justificationMismatch, .act, session: session,
                        evidence: "Session \(session.sessionId), decision \(decision.decisionId): " + differing.joined(separator: "; ") + ".",
                        action: "Open the session excerpt and compare the justification with the raw log values shown with this flag."))
                }
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
    private func checkLeniencyDrift(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        let grants = sessions.filter { $0.wasGranted && $0.effortTotal != nil }
        guard grants.count >= 3, let first = grants.first, let last = grants.last,
              let firstTotal = first.effortTotal, let lastTotal = last.effortTotal,
              lastTotal <= firstTotal - 4 else { return [] }
        let totals = grants.compactMap { $0.effortTotal }
        let falling = zip(totals, totals.dropFirst()).allSatisfy { $0.1 <= $0.0 }
        guard falling else { return [] }
        return [flag(.leniencyDrift, .watch, session: last,
            evidence: "Granted sessions in order: " + grants.map { "\($0.sessionId) effortTotal \($0.effortTotal ?? 0)" }.joined(separator: ", ") + ". The latest grant rests on weaker evidence than the first.",
            action: "Open the latest session excerpt and review whether the unlock settings still reflect the effort you want to see.")]
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

    // Check 5: behavior shifts versus the child's own history.
    private func checkBehaviorShifts(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        guard sessions.count >= 4, let latest = sessions.last else { return [] }
        let prior = sessions.dropLast()
        guard let latestSignals = latest.signals,
              prior.allSatisfy({ $0.signals != nil }) else { return [] }
        let priorAttempts = prior.map { Double($0.signals?.genuineAttempts ?? 0) }
        let meanAttempts = priorAttempts.reduce(0, +) / Double(priorAttempts.count)
        guard meanAttempts >= 3,
              Double(latestSignals.genuineAttempts) <= meanAttempts * 0.25 else { return [] }
        return [flag(.behaviorShift, .info, session: latest,
            evidence: "Session \(latest.sessionId): genuineAttempts \(latestSignals.genuineAttempts), activeSeconds \(latestSignals.activeSeconds). Prior sessions \(prior.map(\.sessionId).joined(separator: ", ")) recorded genuineAttempts \(prior.map { String($0.signals?.genuineAttempts ?? 0) }.joined(separator: ", ")).",
            action: "Open the latest session excerpt to see what changed, and talk with your child about how practice is going.")]
    }

    // Check 6: inconsistency — similar evidence, different decisions.
    private func checkInconsistency(_ sessions: [AuditorSessionExcerpt]) -> [AuditFlag] {
        var out: [AuditFlag] = []
        for (index, session) in sessions.enumerated() {
            guard let total = session.effortTotal, let floor = session.floorMet else { continue }
            for prior in sessions[..<index] {
                guard let priorTotal = prior.effortTotal, let priorFloor = prior.floorMet,
                      prior.wasGranted != session.wasGranted,
                      abs(priorTotal - total) <= 2, priorFloor == floor else { continue }
                out.append(flag(.inconsistency, .watch, session: session,
                    evidence: "Session \(session.sessionId): effortTotal \(total), floorMet \(floor), outcome \(session.wasGranted ? "granted" : "denied"). Earlier session \(prior.sessionId): effortTotal \(priorTotal), floorMet \(priorFloor), outcome \(prior.wasGranted ? "granted" : "denied"). The recorded evidence is close and the outcomes differ.",
                    action: "Open both session excerpts and compare the justifications shown with this flag."))
                break
            }
        }
        return out
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

    public init(directory: URL, dataWriter: ((Data, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.dataWriter = dataWriter ?? { data, url in try data.write(to: url, options: [.atomic]) }
        self.flags = Self.load(directory: directory) ?? []
    }

    public convenience init() {
        self.init(directory: PolicyStore.defaultDirectory())
    }

    /// Records a fresh audit run. Flags the parent already dismissed
    /// or acted on keep their recorded status across runs.
    public func recordRun(_ newFlags: [AuditFlag]) {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        var byId = Dictionary(uniqueKeysWithValues: flags.map { ($0.flagId, $0) })
        for flag in newFlags where byId[flag.flagId]?.status != .dismissed
            && byId[flag.flagId]?.status != .acted {
            byId[flag.flagId] = flag
        }
        // Keep resolved flags the parent already handled, drop stale opens.
        let resolved = flags.filter { $0.status != .open }
        let resolvedIds = Set(resolved.map(\.flagId))
        flags = resolved + newFlags.filter { !resolvedIds.contains($0.flagId) }
        persistLocked()
    }

    /// Open flags, act first, then watch, then info.
    public var openFlags: [AuditFlag] {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        return flags.filter { $0.status == .open }
            .sorted { ($0.severity.rank, $0.flagId) < ($1.severity.rank, $1.flagId) }
    }

    public var allFlags: [AuditFlag] {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        return flags
    }

    /// Parent dismisses a flag. Clears it from the open list and
    /// changes nothing else — policy is untouched by design.
    public func dismiss(flagId: String) {
        update(flagId: flagId, status: .dismissed)
    }

    /// Parent chooses to act. Records the choice and returns where to
    /// route the parent; it applies no policy change itself.
    @discardableResult
    public func markActed(flagId: String) -> AuditActionRoute? {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        guard let index = flags.firstIndex(where: { $0.flagId == flagId }) else { return nil }
        flags[index].status = .acted
        persistLocked()
        return .openPolicyEditor
    }

    /// Route for opening a flag's staged detail.
    public func detailRoute(flagId: String) -> AuditActionRoute? {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        guard let flag = flags.first(where: { $0.flagId == flagId }) else { return nil }
        return .openSession(sessionId: flag.sessionId)
    }

    private func update(flagId: String, status: AuditFlagStatus) {
        lock.lock(); defer { lock.unlock() }
        flags = Self.load(directory: directory) ?? flags
        guard let index = flags.firstIndex(where: { $0.flagId == flagId }) else { return }
        flags[index].status = status
        persistLocked()
    }

    private func persistLocked() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(flags) {
            try? dataWriter(data, directory.appendingPathComponent(Self.fileName))
        }
    }

    private static func load(directory: URL) -> [AuditFlag]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode([AuditFlag].self, from: data)
    }
}
