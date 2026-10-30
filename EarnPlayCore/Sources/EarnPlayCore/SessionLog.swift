import Foundation

/// One practised question inside a synced session (T4.2 dashboard input).
///
/// The per-question facts the dashboard aggregates: which skill was
/// practised, whether the final answer was correct, idle-paused active
/// time on the question, how many hints were used, and — for incorrect
/// answers only — the recorded error type (e.g. "computation").
/// Counts clamp to zero and strings trim; a blank error type normalizes
/// to nil, and `errorType` on a correct answer is contradictory, so it
/// is dropped.
public struct SessionQuestionRecord: Codable, Equatable, Sendable {
    public var questionId: String
    public var skill: String
    public var correct: Bool
    /// Idle-paused active milliseconds on this question (>= 0).
    public var activeMs: Int
    /// Hints used on this question (>= 0).
    public var hintsUsed: Int
    /// Recorded only when `correct` is false; nil otherwise.
    public var errorType: String?

    public init(questionId: String, skill: String, correct: Bool,
                activeMs: Int, hintsUsed: Int, errorType: String? = nil) {
        self.questionId = questionId
        self.skill = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        self.correct = correct
        self.activeMs = max(0, activeMs)
        self.hintsUsed = max(0, hintsUsed)
        if correct {
            self.errorType = nil
        } else {
            let trimmed = (errorType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.errorType = trimmed.isEmpty ? nil : trimmed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case questionId, skill, correct, activeMs, hintsUsed, errorType
    }

    /// Decodes the unchanged wire format, then normalizes through the
    /// memberwise initializer so decoded records satisfy the same
    /// invariants as constructed ones (T4.2 fix round 2, item 4).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            questionId: try c.decode(String.self, forKey: .questionId),
            skill: try c.decode(String.self, forKey: .skill),
            correct: try c.decode(Bool.self, forKey: .correct),
            activeMs: try c.decode(Int.self, forKey: .activeMs),
            hintsUsed: try c.decode(Int.self, forKey: .hintsUsed),
            errorType: try c.decodeIfPresent(String.self, forKey: .errorType))
    }
}

/// Effort outcome snapshot for one session (T4.2 trend input).
///
/// The T1.4 score and the per-session threshold it was judged against,
/// recorded when the session's unlock decision was logged. The dashboard
/// trend reads these snapshots in chronological order; it never recomputes
/// or invents scores for sessions that carry none.
public struct SessionEffortRecord: Codable, Equatable, Sendable {
    public var score: Int
    public var threshold: Int

    public init(score: Int, threshold: Int) {
        self.score = score
        self.threshold = threshold
    }
}

/// One completed child session, synced child → admin (T4.6, LLD sync).
/// Built on the merged T1.6 `Decision` schema unchanged: the session's
/// decisions are carried verbatim, never re-shaped.
///
/// T4.5 adds optional auditor fields — independently recorded question
/// detail and raw effort signals — that the auditor checks read. T4.2
/// adds two optional dashboard detail fields — per-question records and
/// the session effort snapshot — that the dashboard aggregates. All
/// default to empty and decode as empty when absent, so logs written
/// before either feature (decisions only) still decode and sync
/// unchanged. The dashboard detail was renamed `questionRecords` at the
/// T4.2/T4.5 merge: `questions` carries the auditor records.
public struct SessionLog: Codable, Equatable, Sendable {
    public var sessionId: String
    public var startedAt: Date
    public var endedAt: Date
    public var decisions: [Decision]
    /// Child's policy version in force for this session.
    public var policyVersion: Int
    /// Optional question detail carried with the log, where the child
    /// recorded it (T4.5 item 7). Nil when absent; old logs decode nil.
    public var questions: [AuditorQuestionRecord]?
    /// Independently recorded raw effort signals, where they exist
    /// (T4.5 item 6). Never derived from a decision's evidence text.
    public var rawSignals: EffortSignals?
    public var rawEffortTotal: Int?
    public var rawEffortBar: Int?
    public var rawFloorMet: Bool?
    /// Per-question practice detail (T4.2). Empty for sessions recorded
    /// before the detail exists (e.g. decisions-only sessions).
    public var questionRecords: [SessionQuestionRecord]
    /// Effort outcome snapshot (T4.2). Nil when the session recorded none.
    public var effort: SessionEffortRecord?
    public init(sessionId: String, startedAt: Date, endedAt: Date,
                decisions: [Decision], policyVersion: Int,
                questions: [AuditorQuestionRecord]? = nil,
                rawSignals: EffortSignals? = nil, rawEffortTotal: Int? = nil,
                rawEffortBar: Int? = nil, rawFloorMet: Bool? = nil,
                questionRecords: [SessionQuestionRecord] = [],
                effort: SessionEffortRecord? = nil) {
        self.sessionId = sessionId; self.startedAt = startedAt
        self.endedAt = endedAt; self.decisions = decisions
        self.policyVersion = policyVersion
        self.questions = questions; self.rawSignals = rawSignals
        self.rawEffortTotal = rawEffortTotal; self.rawEffortBar = rawEffortBar
        self.rawFloorMet = rawFloorMet
        self.questionRecords = questionRecords; self.effort = effort
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, startedAt, endedAt, decisions, policyVersion
        case questions, rawSignals, rawEffortTotal, rawEffortBar, rawFloorMet
        case questionRecords, effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        decisions = try c.decode([Decision].self, forKey: .decisions)
        policyVersion = try c.decode(Int.self, forKey: .policyVersion)
        // Pre-T4.5 logs carry no auditor keys; pre-T4.2 logs carry no
        // dashboard keys; all decode as nil/empty (decisions only).
        questions = try c.decodeIfPresent([AuditorQuestionRecord].self, forKey: .questions)
        rawSignals = try c.decodeIfPresent(EffortSignals.self, forKey: .rawSignals)
        rawEffortTotal = try c.decodeIfPresent(Int.self, forKey: .rawEffortTotal)
        rawEffortBar = try c.decodeIfPresent(Int.self, forKey: .rawEffortBar)
        rawFloorMet = try c.decodeIfPresent(Bool.self, forKey: .rawFloorMet)
        questionRecords = try c.decodeIfPresent([SessionQuestionRecord].self, forKey: .questionRecords) ?? []
        effort = try c.decodeIfPresent(SessionEffortRecord.self, forKey: .effort)
    }

    /// Builds a log from the T1.6 DecisionLogger for one session.
    /// `questions`/raw-effort carry the auditor's independently recorded
    /// detail (T4.5) and `questionRecords`/`effort` the dashboard practice
    /// detail (T4.2) when the caller has them; all default to empty
    /// (decisions only).
    public static func make(sessionId: String, startedAt: Date, endedAt: Date,
                            logger: DecisionLogger, policyVersion: Int,
                            questions: [AuditorQuestionRecord]? = nil,
                            rawSignals: EffortSignals? = nil, rawEffortTotal: Int? = nil,
                            rawEffortBar: Int? = nil, rawFloorMet: Bool? = nil,
                            questionRecords: [SessionQuestionRecord] = [],
                            effort: SessionEffortRecord? = nil) -> SessionLog {
        SessionLog(sessionId: sessionId, startedAt: startedAt, endedAt: endedAt,
                   decisions: logger.decisions(for: sessionId), policyVersion: policyVersion,
                   questions: questions, rawSignals: rawSignals,
                   rawEffortTotal: rawEffortTotal, rawEffortBar: rawEffortBar,
                   rawFloorMet: rawFloorMet,
                   questionRecords: questionRecords, effort: effort)
    }
}

public enum SessionLogCodec {
    public static func encode(_ log: SessionLog) throws -> Data { try encodeValue(log) }
    public static func encode(_ logs: [SessionLog]) throws -> Data { try encodeValue(logs) }
    private static func encodeValue(_ v: some Encodable) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]; return try e.encode(v)
    }
    public static func decode(_ data: Data) throws -> SessionLog {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate
        return try d.decode(SessionLog.self, from: data)
    }
    public static func decodeList(_ data: Data) throws -> [SessionLog] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate
        return try d.decode([SessionLog].self, from: data)
    }
}
