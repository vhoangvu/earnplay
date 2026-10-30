import Foundation

/// Child-side practice session recorder (code-repo issue #63, T4.7/Demo).
///
/// Records per-question practice detail and the session effort snapshot that
/// `SessionLog` carries to the admin (`questionRecords` + `effort`). The
/// child app's `DemoTutorEngine` owns one per practice session and feeds it
/// from the verified question path only: skill comes from the verified
/// question, correctness from the final solver verdict, hints from
/// `HintLadder` show events, and active time is idle-paused engaged time,
/// never wall-clock.
///
/// What is never invented:
/// - No record for a question that was not practised (no graded answer, no
///   record — presentation alone never creates one).
/// - No error type without a recorded source: `errorType` is carried only
///   when the caller supplies one for an incorrect answer, else nil.
/// - No zero-filled effort: when the session has no score (no scorer, or no
///   practised questions), `effort` stays nil.
/// - No decisions: this type never constructs `Decision` values. The log is
///   built via `SessionLog.make` with the caller's `DecisionLogger`, so the
///   decisions carried are exactly the ones logged through T1.6 during the
///   session (possibly none). The unlock convenience
///   `logUnlockAndMakeSessionLog` routes through the session-decision
///   boundary `EffortSessionRecorder.evaluateAndLog`, never around it.
///
/// Timing reuses T1.4's idle-pause rule: each question's `activeMs` caps
/// every gap between consecutive anchors (question start, each recorded
/// interaction on that question, question end) at `idlePauseSeconds`
/// (default 20, `ActiveTimeTracker.defaultIdlePauseSeconds`). Session-level
/// effort reuses the owned `EffortSessionRecorder` directly, so the snapshot
/// score/threshold always equals the T1.4 evaluation of the recorded
/// session.
public final class PracticeSessionRecorder: HintListenEventSink, @unchecked Sendable {
    public let sessionId: String
    public let startedAt: Date
    public let idlePauseSeconds: TimeInterval
    private let now: () -> Date
    /// Session-level T1.4 event stream. Every per-question child event
    /// (hint, graded answer, revision, probe reply, generic interaction)
    /// is also forwarded here, so `signals(at:)` and the effort snapshot
    /// always describe the same session the question records do.
    public let effortRecorder: EffortSessionRecorder

    private struct QuestionState {
        var questionId: String
        var skill: String
        var startedAt: Date
        var endedAt: Date?
        var interactionDates: [Date] = []
        var hintsUsed: Int = 0
        /// Final solver verdict, nil until the first graded answer.
        var lastCorrect: Bool?
        /// Recorded error source for the last answer, meaningful only
        /// when `lastCorrect` is false. Never invented here.
        var lastErrorType: String?
    }

    private let lock = NSLock()
    /// Question ids in first-start order.
    private var order: [String] = []
    private var states: [String: QuestionState] = [:]

    public init(sessionId: String, startedAt: Date,
                idlePauseSeconds: TimeInterval = ActiveTimeTracker.defaultIdlePauseSeconds,
                now: @escaping () -> Date = Date.init,
                effortRecorder: EffortSessionRecorder? = nil) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.idlePauseSeconds = idlePauseSeconds
        self.now = now
        self.effortRecorder = effortRecorder
            ?? EffortSessionRecorder(startedAt: startedAt,
                                     idlePauseSeconds: idlePauseSeconds, now: now)
    }

    // MARK: - Question lifecycle

    /// Marks a question presented. A second start for the same id keeps the
    /// first start time; presentation alone never creates a record (only a
    /// graded answer does).
    public func startQuestion(questionId: String, skill: String, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard states[questionId] == nil else { return }
        let at = date ?? now()
        states[questionId] = QuestionState(questionId: questionId, skill: skill,
                                           startedAt: at)
        order.append(questionId)
    }

    /// Records one shown hint for the question. Call only when
    /// `HintLadder.requestHint()` returns a hint (exhausted taps record
    /// nothing). Unknown questions are ignored, never created.
    public func recordHint(questionId: String, at date: Date? = nil) {
        let at = date ?? now()
        lock.lock()
        guard var state = states[questionId] else { lock.unlock(); return }
        state.hintsUsed += 1
        state.interactionDates.append(at)
        states[questionId] = state
        lock.unlock()
        effortRecorder.recordHintInteraction(at: at)
    }

    /// Records one graded answer for the question: `correct` is the final
    /// solver verdict for this submission (`true` only for `.correct`),
    /// `errorType` a recorded classification source for incorrect answers
    /// only (nil when none exists — never invented). Unknown questions are
    /// ignored, never created.
    public func recordAnswer(questionId: String, correct: Bool, errorType: String? = nil,
                             isRevision: Bool = false, isGenuine: Bool = true,
                             at date: Date? = nil) {
        let at = date ?? now()
        lock.lock()
        guard var state = states[questionId] else { lock.unlock(); return }
        state.interactionDates.append(at)
        state.lastCorrect = correct
        state.lastErrorType = correct ? nil : errorType
        states[questionId] = state
        lock.unlock()
        effortRecorder.recordAttempt(isGenuine: isGenuine, at: at)
        if isRevision {
            effortRecorder.recordAnswerRevision(at: at)
        }
    }

    /// Records the child's reply to the tutor's probe ("show me one step")
    /// on the question: one follow-up interaction plus one explanation on
    /// the T1.4 stream (the `StallProbeSession` substantive-reply shape),
    /// plus question timing. The reply is never graded and never changes
    /// the question's correctness.
    public func recordProbeReply(questionId: String, at date: Date? = nil) {
        let at = date ?? now()
        lock.lock()
        if var state = states[questionId] {
            state.interactionDates.append(at)
            states[questionId] = state
        }
        lock.unlock()
        effortRecorder.recordFollowUpInteraction(at: at)
        effortRecorder.recordExplanation(at: at)
    }

    /// `HintListenEventSink` (round 3 item 2): one listen event does BOTH
    /// the question timing anchor for the current question AND the session
    /// effort event. The event carries no question id, so the anchor goes
    /// to the recorder's current question — the most recently started one
    /// (`order.last`, which is the unfinished question while a session is
    /// actively recording). `hintsUsed` is untouched: it stays tied to
    /// ladder-show events (`recordHint` is its only writer). Out-of-window
    /// anchors are filtered by `activeMs`, so a late listen after its
    /// question ended contributes no time.
    public func recordHintListen(_ event: HintListenEvent) {
        let at = event.emittedAt
        lock.lock()
        if let currentId = order.last, var state = states[currentId] {
            state.interactionDates.append(at)
            states[currentId] = state
        }
        lock.unlock()
        effortRecorder.recordHintListen(event)
    }

    /// Generic interaction (typing, non-substantive reply): question timing
    /// plus session active time, never effort counts. When `questionId` is
    /// nil or unknown, only the session stream records.
    public func recordInteraction(questionId: String? = nil, at date: Date? = nil) {
        let at = date ?? now()
        if let questionId {
            lock.lock()
            if var state = states[questionId] {
                state.interactionDates.append(at)
                states[questionId] = state
            }
            lock.unlock()
        }
        effortRecorder.recordInteraction(at: at)
    }

    /// Marks a question ended (e.g. answered correctly and the next one
    /// presented). A second finish keeps the first end time. Questions left
    /// unfinished end at the session end in `finishSession`.
    public func finishQuestion(questionId: String, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard var state = states[questionId], state.endedAt == nil else { return }
        state.endedAt = date ?? now()
        states[questionId] = state
    }

    // MARK: - Finish

    /// Finished detail for one session: practised questions in
    /// first-start order, the effort snapshot (nil when the session
    /// produced no score), and the session end time.
    public struct FinishedSession: Equatable, Sendable {
        public var questionRecords: [SessionQuestionRecord]
        public var effort: SessionEffortRecord?
        public var endedAt: Date
        public init(questionRecords: [SessionQuestionRecord],
                    effort: SessionEffortRecord?, endedAt: Date) {
            self.questionRecords = questionRecords
            self.effort = effort
            self.endedAt = endedAt
        }
    }

    /// Finishes the session: ends unfinished questions at `date`, builds
    /// one `SessionQuestionRecord` per question with a graded answer (in
    /// first-start order; unanswered questions produce no record), and
    /// snapshots the T1.4 score/threshold when `scorer` is provided AND at
    /// least one question was practised. Otherwise `effort` is nil — never
    /// zero-filled. Preview only: logs nothing.
    public func finishSession(at date: Date? = nil, scorer: EffortScorer? = nil) -> FinishedSession {
        let end = date ?? now()
        lock.lock()
        for id in order where states[id]?.endedAt == nil {
            states[id]?.endedAt = end
        }
        let snapshot = order.compactMap { states[$0] }
        let pause = idlePauseSeconds
        lock.unlock()
        var records: [SessionQuestionRecord] = []
        for state in snapshot {
            guard let correct = state.lastCorrect else { continue }
            let activeMs = Self.activeMs(interactionDates: state.interactionDates,
                                         startedAt: state.startedAt,
                                         endedAt: state.endedAt ?? end,
                                         idlePauseSeconds: pause)
            records.append(SessionQuestionRecord(
                questionId: state.questionId, skill: state.skill, correct: correct,
                activeMs: activeMs, hintsUsed: state.hintsUsed,
                errorType: correct ? nil : state.lastErrorType))
        }
        let effort: SessionEffortRecord?
        if let scorer, !records.isEmpty {
            let score = scorer.evaluate(effortRecorder.signals(at: end))
            effort = SessionEffortRecord(score: score.score, threshold: score.threshold)
        } else {
            effort = nil
        }
        return FinishedSession(questionRecords: records, effort: effort, endedAt: end)
    }

    /// Builds the session's `SessionLog` via `SessionLog.make` with the
    /// caller's logger AND this recorder's finished detail. Decisions are
    /// whatever `logger` holds for `sessionId` (possibly none); this call
    /// logs nothing itself.
    public func makeSessionLog(endedAt: Date? = nil, logger: DecisionLogger,
                               policyVersion: Int,
                               scorer: EffortScorer? = nil) -> SessionLog {
        let finished = finishSession(at: endedAt, scorer: scorer)
        return SessionLog.make(sessionId: sessionId, startedAt: startedAt,
                               endedAt: finished.endedAt, logger: logger,
                               policyVersion: policyVersion,
                               questionRecords: finished.questionRecords,
                               effort: finished.effort)
    }

    /// Unlock path: scores the recorded session through the
    /// session-decision boundary (`EffortSessionRecorder.evaluateAndLog`,
    /// which persists the grant/deny `Decision` before returning) and
    /// builds the `SessionLog` carrying that decision plus this recorder's
    /// detail. When no question was practised, nothing is logged and the
    /// returned score/decision are nil with `effort` nil: an empty session
    /// never produces an unlock decision. Throws exactly when the log
    /// write fails, in which case no decision exists and the caller must
    /// apply no effect.
    public func logUnlockAndMakeSessionLog(endedAt: Date? = nil, scorer: EffortScorer,
                                           logger: DecisionLogger, policyVersion: Int,
                                           appId: String, durationMinutes: Int,
                                           timestamp: Date? = nil,
                                           decisionId: String = UUID().uuidString)
    throws -> (log: SessionLog, score: EffortScore?, decision: Decision?) {
        let preview = finishSession(at: endedAt, scorer: scorer)
        guard !preview.questionRecords.isEmpty else {
            let log = SessionLog.make(sessionId: sessionId, startedAt: startedAt,
                                      endedAt: preview.endedAt, logger: logger,
                                      policyVersion: policyVersion,
                                      questionRecords: [], effort: nil)
            return (log, nil, nil)
        }
        let logged = try logger.evaluateAndLog(
            signals: effortRecorder.signals(at: preview.endedAt), scorer: scorer,
            sessionId: sessionId, appId: appId, durationMinutes: durationMinutes,
            timestamp: timestamp ?? preview.endedAt, decisionId: decisionId)
        let effort = SessionEffortRecord(score: logged.score.score,
                                         threshold: logged.score.threshold)
        let log = SessionLog.make(sessionId: sessionId, startedAt: startedAt,
                                  endedAt: preview.endedAt, logger: logger,
                                  policyVersion: policyVersion,
                                  questionRecords: preview.questionRecords,
                                  effort: effort)
        return (log, logged.score, logged.decision)
    }

    // MARK: - Per-question active time

    /// Idle-paused active milliseconds for one question: anchors are the
    /// question start, each interaction on that question within
    /// `startedAt...endedAt`, and the question end. Each positive gap
    /// contributes at most `idlePauseSeconds` (the T1.4 rule); time beyond
    /// the pause with no interaction never counts.
    public static func activeMs(interactionDates: [Date], startedAt: Date,
                                endedAt: Date,
                                idlePauseSeconds: TimeInterval = ActiveTimeTracker.defaultIdlePauseSeconds) -> Int {
        let pause = max(0, idlePauseSeconds)
        let end = max(startedAt, endedAt)
        var anchors = [startedAt]
        anchors += interactionDates.filter { $0 >= startedAt && $0 <= end }
        anchors.sort()
        anchors.append(end)
        var total: TimeInterval = 0
        for index in 1..<anchors.count {
            let gap = anchors[index].timeIntervalSince(anchors[index - 1])
            if gap > 0 { total += min(gap, pause) }
        }
        return Int((total * 1000).rounded())
    }
}
