import Foundation
import EarnPlayCore

/// Demo tutor engine for Band B (grade 4). It owns every session
/// decision; `ChatConversationView` only renders its turn stream.
///
/// Questions come only from T1.2's verified path: fallback-bank
/// proposals re-verified through `SolverService` before presentation.
/// Answer checking is `SolverService.checkAnswer` against the verified
/// question. Hints come only from T1.3's `HintLadder` for the current
/// verified question. Encouragement and probe wording are canned
/// tutor lines chosen here, never in the view. Child text is treated
/// as an answer string (data) and compared by the solver only; it is
/// never used to build a prompt and never changes this engine's flow
/// beyond the solver verdict for the current question — except while
/// a probe is pending, when the next submission is treated as the
/// child's explanation of their step (acknowledged, not graded).
/// Finishing the last question reports an explicit session-complete
/// composer state; `startSession()` after that restarts the session.
///
/// Practice recording (issue #63): when constructed with `recording`
/// dependencies, every session is recorded into a `PracticeSessionRecorder`
/// (per-question detail + T1.4 effort) and, on completion, built via
/// `SessionLog.make` with the logger AND the detail and enqueued in the
/// T4.6 `SessionLogQueue` for the existing sync. Nil disables recording
/// (existing demo behavior, no filesystem writes).
struct PracticeRecordingDependencies {
    var makeSessionId: () -> String
    var logger: DecisionLogger
    var queue: SessionLogQueue
    var makeScorer: () -> EffortScorer
    var policyVersion: () -> Int
    var now: () -> Date
    /// Fired after a session log is durably enqueued (issue #63 fix 3).
    /// Production wires this to the shared sync service's
    /// `notifySessionEnqueued()` so delivery does not depend on any view;
    /// nil (tests, recording-only use) keeps enqueue-only behavior.
    var onSessionEnqueued: (() -> Void)? = nil
    /// Handoff for a finalized log whose enqueue failed (round 2 item 2).
    /// Production wires this to the app-scoped `ChildSyncController`, which
    /// retains the log and retries through the shared queue; nil (tests,
    /// recording-only use) keeps engine-memory-only retry.
    var onEnqueueFailed: ((SessionLog) -> Void)? = nil

    /// Production wiring: real on-device logger/queue/policy, one scorer
    /// draw per session, UUID session ids, live clock. Used only by the
    /// child app's practice screen; tests inject isolated fakes.
    static func productionDefault(
        logger: DecisionLogger = DecisionLogger(),
        queue: SessionLogQueue = SessionLogQueue(),
        policyVersion: @escaping () -> Int = { PolicyStore().storedVersion },
        makeScorer: @escaping () -> EffortScorer = { EffortScorer() },
        makeSessionId: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = Date.init,
        onSessionEnqueued: (() -> Void)? = nil,
        onEnqueueFailed: ((SessionLog) -> Void)? = nil
    ) -> Self {
        Self(makeSessionId: makeSessionId, logger: logger, queue: queue,
             makeScorer: makeScorer, policyVersion: policyVersion, now: now,
             onSessionEnqueued: onSessionEnqueued, onEnqueueFailed: onEnqueueFailed)
    }
}

final class DemoTutorEngine: ChatTutorEngine {
    private struct Item {
        let result: QuestionGenerationResult
        let ladder: HintLadder
    }

    private let solver = SolverService()
    private var items: [Item] = []
    private var index = 0
    private var attempted: Set<Int> = []
    private var lastAnswer: String?
    private var messageSequence = 0
    /// True while a probe ("show me one step") is waiting for the
    /// child's explanation. The next submission answers the probe:
    /// it is acknowledged, never graded as an answer, and never
    /// labelled a revision. Cleared when the explanation arrives,
    /// when the question is answered, or on session (re)start.
    private var awaitingProbeReply = false

    private let recording: PracticeRecordingDependencies?
    private var sessionRecorder: PracticeSessionRecorder?
    private var sessionScorer: EffortScorer?
    private var recordingEnded = false
    /// Finalized log awaiting a durable enqueue. Set on the first finish
    /// attempt and cleared only after the enqueue succeeds, so a retry
    /// enqueues THAT log (original records/effort/endedAt, no recompute).
    private var pendingFinishedLog: SessionLog?
    /// True once a resume-time persistence retry has failed (round 3 item
    /// 1): input stays blocked until the pending log drains. Set only
    /// alongside a retained `pendingFinishedLog`, cleared only by a
    /// successful enqueue in `finishRecordingSession` (the single drain
    /// funnel), so blocked always implies a pending log to retry.
    private var resumeBlockedOnPersistence = false

    /// Active recording session id, for tests. Nil when recording is
    /// disabled or no session has started.
    var recordingSessionId: String? { sessionRecorder?.sessionId }

    /// Whether input is blocked awaiting persistence (round 3 item 1).
    /// True after a resume-time pending-log retry fails; the view model
    /// renders the session-complete state (which refuses all submissions)
    /// until a later retry observes the drain.
    var isInputBlocked: Bool { resumeBlockedOnPersistence }

    init(maxQuestions: Int = 3, recording: PracticeRecordingDependencies? = nil) {
        self.recording = recording
        // Serve verified fallback questions deterministically. A
        // proposal that does not re-verify is dropped, never shown.
        var built: [Item] = []
        for proposal in FallbackQuestionBank.demo.entries {
            guard built.count < maxQuestions else { break }
            let questionId = "demo-q\(built.count + 1)"
            guard case .success(let question) = solver.verify(proposal, questionId: questionId) else { continue }
            let result = QuestionGenerationResult(
                question: question, source: .fallbackBank,
                attemptsUsed: 0, attempts: [], proposal: proposal,
                finalVerification: FinalVerificationRecord(
                    source: .fallbackBank, outcome: .verified,
                    attemptNumber: nil, questionId: questionId))
            built.append(Item(result: result, ladder: HintLadder(result: result)))
        }
        items = built
    }

    var totalQuestions: Int { items.count }

    func startSession() -> ChatEngineUpdate {
        // Restart after completion: reset the session state and
        // serve the first question again with fresh hint ladders.
        if current == nil && !items.isEmpty {
            // A new practice run starts here: finalize a prior
            // unfinished recording first. Normally already durable
            // (a no-op); otherwise this retries the failed completion
            // enqueue under Fix 4 semantics (retained log, original
            // endedAt). If it fails again the old session is kept and
            // stays retryable rather than orphaned.
            _ = finishRecordingSession()
            // Round 2 item 1: the retry failed too — stay in the
            // completed state and do NOT reset. Resetting here would
            // reuse the old recorder for the new run (it exists and is
            // not ended), and the next finish would short-circuit to
            // the retained old log, losing the new run's records. The
            // next start attempt retries again; on success the normal
            // reset below proceeds.
            if pendingFinishedLog != nil {
                return ChatEngineUpdate(composer: .sessionComplete)
            }
            index = 0
            attempted = []
            lastAnswer = nil
            awaitingProbeReply = false
            items = items.map { Item(result: $0.result, ladder: HintLadder(result: $0.result)) }
        }
        // Round 3 item 1: a mid-run start while a prior finalize is still
        // undrained (the blocked reappearance's "Start again") retries it
        // first — the same stay-complete-until-durable rule as the
        // completed restart above. Success falls through to a fresh
        // recorder below (`recordingEnded` is true after the drain);
        // failure stays blocked. No-op unless a log is pending.
        if pendingFinishedLog != nil {
            _ = finishRecordingSession()
            if pendingFinishedLog != nil {
                resumeBlockedOnPersistence = true
                return ChatEngineUpdate(composer: .sessionComplete)
            }
            // Round 4 item 2: the pending log drained, so this Start-again
            // falls through to a fresh recorder and a re-presented question
            // below — a probe left pending across the failed disappear must
            // not swallow the next submission as an unseen explanation. (The
            // completed-restart branch above clears it too; the still-blocked
            // path above keeps it, but input stays refused there.)
            awaitingProbeReply = false
        }
        guard let item = current else {
            return ChatEngineUpdate(turns: [.tutor(nextMessage(
                text: "Let's practise together. Take your time.",
                kind: .instruction))])
        }
        // Practice recording: one recorder/scorer per session, started on
        // first start and on restart after a finished session. A second
        // start without a finish keeps the active session.
        if let rec = recording, sessionRecorder == nil || recordingEnded {
            beginFreshRecordingSession(recording: rec, questionId: item.result.question.questionId,
                                        skill: item.result.question.skill)
        }
        return ChatEngineUpdate(
            turns: [questionTurn(item)],
            progress: ChatProgress(totalQuestions: items.count, attemptedQuestions: attempted.count),
            composer: composer(for: item))
    }

    /// Ends the active session through the chat engine boundary (view
    /// disappearance): finalizes any unfinished recording session via the
    /// retryable finish below. Partially practised sessions keep the last
    /// solver verdict per question; sessions with no graded answers
    /// produce no records and nil effort. No-op when recording is
    /// disabled, no session is active, or the session already finished.
    func endSession() {
        _ = finishRecordingSession()
    }

    /// Resumes recording after the practice view reappears mid-run (round
    /// 2 item 3, round 3 item 1): resolves pending-log ownership BEFORE
    /// resuming. When the `endSession` finalize failed its enqueue, the
    /// pending log is retried first; only a drained prior log resumes into
    /// a fresh recorder/scorer for the current question (the continued run
    /// records under a new session id). A retry that still fails blocks
    /// input instead (`isInputBlocked`, no fresh recorder): resuming on
    /// top of an unresolved pending log would record continued answers
    /// into the old recorder, which the next finish short-circuits past —
    /// dropping them. No-op when recording is disabled, no session ever
    /// started, recording is still active, or the session is complete
    /// (restart owns that). Recording-only: question state (index,
    /// attempts, ladders) is untouched.
    func resumeSession() {
        guard let rec = recording, sessionRecorder != nil,
              let item = current else { return }
        if pendingFinishedLog != nil {
            // drainPendingAndResume blocks input itself on failure.
            _ = drainPendingAndResume(questionId: item.result.question.questionId,
                                       skill: item.result.question.skill)
            return
        }
        guard recordingEnded else { return }
        beginFreshRecordingSession(recording: rec, questionId: item.result.question.questionId,
                                    skill: item.result.question.skill)
    }

    /// Retries the pending log's enqueue and, on success, starts a fresh
    /// recorder/scorer for the current question (round 3 item 1). The queue
    /// dedupes by sessionId (`SessionLogQueue.enqueue` replaces in place),
    /// so a retry after the controller already drained its handed-off copy
    /// of the same log overwrites it instead of double-delivering.
    /// Returns false (and blocks input) when the retry still fails, in
    /// which case no recorder is started and nothing is recorded.
    private func drainPendingAndResume(questionId: String, skill: String) -> Bool {
        guard let rec = recording, finishRecordingSession() != nil else {
            resumeBlockedOnPersistence = true
            return false
        }
        beginFreshRecordingSession(recording: rec, questionId: questionId, skill: skill)
        return true
    }

    /// Starts a fresh recorder/scorer for one question: a new session id,
    /// open recording, and the question started. Shared by first/restart
    /// starts, resumes, and blocked-state retries that just drained.
    private func beginFreshRecordingSession(recording rec: PracticeRecordingDependencies,
                                             questionId: String, skill: String) {
        let startedAt = rec.now()
        sessionScorer = rec.makeScorer()
        let recorder = PracticeSessionRecorder(
            sessionId: rec.makeSessionId(), startedAt: startedAt, now: rec.now)
        sessionRecorder = recorder
        recordingEnded = false
        recorder.startQuestion(questionId: questionId, skill: skill, at: startedAt)
    }

    /// The CURRENT session's hint-listen sink (round 2 item 5, round 3 item
    /// 2): the live session recorder while actively recording — one listen
    /// event records both the question timing anchor and the effort event
    /// — nil once the session finishes, while input is blocked awaiting
    /// persistence (no active session exists to anchor to), or when
    /// recording is disabled, so the production chat's forwarding sink
    /// never delivers to a stale recorder.
    var currentHintListenSink: (any HintListenEventSink)? {
        guard !recordingEnded, !resumeBlockedOnPersistence,
              let recorder = sessionRecorder else { return nil }
        return recorder
    }

    /// Composer activity (typing, number-pad taps, draft edits): a timing
    /// anchor on the current question via `recordInteraction` — question
    /// timing plus session active time, never attempt/hint counts.
    /// No-op when recording is disabled, no session is active, no
    /// question is current, the session already finished, or input is
    /// blocked awaiting persistence (no active session exists to anchor
    /// to; anchoring the dead recorder would be dropped). Unthrottled:
    /// one `Date` per keystroke is trivially bounded, and any throttle
    /// would cost timing accuracy.
    func recordComposerActivity() {
        guard let rec = recording, let recorder = sessionRecorder,
              !recordingEnded, !resumeBlockedOnPersistence,
              let item = current else { return }
        recorder.recordInteraction(questionId: item.result.question.questionId, at: rec.now())
    }

    /// Finishes the active recording session (if any) and enqueues its
    /// `SessionLog` in the T4.6 queue. Called automatically when the last
    /// question is answered correctly, when the session ends early
    /// (`endSession`), and when a new run starts over an unfinished
    /// session; tests call it directly to finish incomplete sessions
    /// (e.g. with a final incorrect answer). Returns
    /// the enqueued log, or nil when recording is disabled, no session is
    /// active, or the session already finished. A failed enqueue also
    /// returns nil, but the finalized log is retained and the session stays
    /// retryable: a later finish enqueues THAT log (original
    /// records/effort/endedAt, no recompute). Never invents detail:
    /// unanswered questions produce no records and unscored sessions carry
    /// nil effort.
    @discardableResult
    func finishRecordingSession(at date: Date? = nil) -> SessionLog? {
        guard let rec = recording, let recorder = sessionRecorder,
              let scorer = sessionScorer, !recordingEnded else { return nil }
        // Finalize once: a retry reuses the retained log instead of
        // recomputing it (a recompute would shift endedAt and re-end
        // questions at the later date).
        let log: SessionLog
        if let pending = pendingFinishedLog {
            log = pending
        } else {
            log = recorder.makeSessionLog(
                endedAt: date ?? rec.now(), logger: rec.logger,
                policyVersion: rec.policyVersion(), scorer: scorer)
            pendingFinishedLog = log
        }
        do {
            try rec.queue.enqueue(log)
        } catch {
            // Hand the finalized log to the app-scoped owner (round 2
            // item 2) so discarding this engine does not lose it. The
            // engine also retains it for its own retry (dedupe by
            // sessionId makes a double enqueue safe).
            rec.onEnqueueFailed?(log)
            return nil
        }
        recordingEnded = true
        pendingFinishedLog = nil
        // Persistence observed succeeding: lift any resume block (round 3
        // item 1). Retry-on-touch unblocks from here — no controller→engine
        // signal exists, so the next resume, submission, hint, or start
        // observes the drain and proceeds.
        resumeBlockedOnPersistence = false
        // Durable now: kick delivery (the service does not poll).
        rec.onSessionEnqueued?()
        return log
    }

    func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
        guard let item = current else {
            // Explicit session-complete state, never a silent empty
            // update behind an editable composer.
            return ChatEngineUpdate(composer: items.isEmpty ? nil : .sessionComplete)
        }
        // Round 3 item 1: while blocked on persistence, a submission
        // retries the pending enqueue instead of recording into the dead
        // recorder. Success drains the old log and starts a fresh recorder
        // for the current question then processes below; failure refuses
        // with the session-complete state — no state advance, nothing
        // recorded. (The view model already refuses submissions behind a
        // complete composer; this is the engine boundary's own guarantee.)
        if resumeBlockedOnPersistence {
            guard drainPendingAndResume(questionId: item.result.question.questionId,
                                        skill: item.result.question.skill) else {
                return ChatEngineUpdate(composer: .sessionComplete)
            }
        }
        // A pending probe takes this submission as the child's
        // explanation: acknowledge the thinking, do not grade it
        // against the answer, do not record it as an answer
        // submission, and do not label it a revision. The child is
        // then back to answering the same question.
        if awaitingProbeReply {
            awaitingProbeReply = false
            if let rec = recording, let recorder = sessionRecorder, !recordingEnded {
                // Only a substantive explanation scores follow-up +
                // explanation effort; anything else is a timing anchor.
                if StallingDetector().isSubstantiveReply(plainText) {
                    recorder.recordProbeReply(questionId: item.result.question.questionId,
                                              at: rec.now())
                } else {
                    recorder.recordInteraction(questionId: item.result.question.questionId,
                                               at: rec.now())
                }
            }
            let progress = ChatProgress(totalQuestions: items.count,
                                        attemptedQuestions: attempted.count)
            return ChatEngineUpdate(
                turns: [.tutor(nextMessage(
                    text: "Thanks for showing your thinking. Try the question again when you are ready.",
                    kind: .encouragement))],
                progress: progress,
                composer: composer(for: item),
                submittedTurnIsRevision: false)
        }
        let isRevision = lastAnswer.map { $0 != plainText } ?? false
        _ = item.ladder.recordAnswerSubmission(plainText)
        let firstAttempt = !attempted.contains(index)
        attempted.insert(index)
        let progress = ChatProgress(totalQuestions: items.count, attemptedQuestions: attempted.count)
        lastAnswer = plainText

        let verdict = solver.checkAnswer(item.result.question, proposedAnswer: plainText)
        // Practice recording: one event date for the answer, the question
        // end, and the next question start, so per-question timing has no
        // invented gap. No error classification source exists on this
        // branch, so errorType stays nil (never invented).
        let eventDate: Date? = recording?.now()
        if let rec = recording, let recorder = sessionRecorder,
           !recordingEnded, let at = eventDate {
            let genuine = !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            recorder.recordAnswer(questionId: item.result.question.questionId,
                                  correct: verdict == .correct, errorType: nil,
                                  isRevision: isRevision, isGenuine: genuine, at: at)
        }
        switch verdict {
        case .correct:
            awaitingProbeReply = false
            if let recorder = sessionRecorder, !recordingEnded, let at = eventDate,
               recording != nil {
                recorder.finishQuestion(questionId: item.result.question.questionId, at: at)
            }
            index += 1
            lastAnswer = nil
            var turns: [ChatTurn] = [.tutor(nextMessage(
                text: "Nice work. Let's try another one.", kind: .encouragement))]
            if let next = current {
                if let recorder = sessionRecorder, !recordingEnded, let at = eventDate,
                   recording != nil {
                    recorder.startQuestion(questionId: next.result.question.questionId,
                                           skill: next.result.question.skill, at: at)
                }
                turns.append(questionTurn(next))
                return ChatEngineUpdate(turns: turns, progress: progress,
                                        composer: composer(for: next),
                                        submittedTurnIsRevision: isRevision)
            }
            if recording != nil, let at = eventDate {
                _ = finishRecordingSession(at: at)
            }
            turns = [.tutor(nextMessage(
                text: "Nice work. That was a good practice session.", kind: .encouragement))]
            return ChatEngineUpdate(turns: turns, progress: progress,
                                    composer: .sessionComplete, submittedTurnIsRevision: isRevision)
        case .incorrect, .invalid:
            // No failure state: encouragement, then a probe asking the
            // child to show a step. A hint stays one tap away.
            var turns: [ChatTurn] = [
                .tutor(nextMessage(text: firstAttempt
                    ? "Good trying. Let's look at it another way."
                    : "Thanks for trying again. Let's look at it another way.",
                    kind: .encouragement)),
                .tutor(nextMessage(text: "Show me one step: what did you try first?",
                                   kind: .probe)),
            ]
            if !firstAttempt { turns.removeLast() }
            // A probe was just appended: the next submission is the
            // child's explanation, handled at the top of this method.
            awaitingProbeReply = firstAttempt
            // While awaiting the probe explanation the child needs
            // free text, not the question's number pad / choices.
            return ChatEngineUpdate(turns: turns, progress: progress,
                                    composer: firstAttempt ? .text : composer(for: item),
                                    submittedTurnIsRevision: isRevision)
        }
    }

    func requestHint() -> ChatEngineUpdate {
        guard let item = current else {
            // Finished session: restate the explicit complete state
            // instead of silently returning nothing.
            return ChatEngineUpdate(composer: items.isEmpty ? nil : .sessionComplete)
        }
        // Round 3 item 1: while blocked on persistence, a hint request
        // retries the pending enqueue instead of consuming a ladder hint
        // that could not be recorded. Success drains and starts a fresh
        // recorder, then the request processes below; failure refuses with
        // the session-complete state.
        if resumeBlockedOnPersistence {
            guard drainPendingAndResume(questionId: item.result.question.questionId,
                                        skill: item.result.question.skill) else {
                return ChatEngineUpdate(composer: .sessionComplete)
            }
        }
        guard let hint = item.ladder.requestHint() else {
            return ChatEngineUpdate()
        }
        if let rec = recording, let recorder = sessionRecorder, !recordingEnded {
            // Round 4 item 3: feed the delivered hint message's id so a
            // later replay of THIS hint anchors this question, never
            // whatever is current when replayed.
            recorder.recordHint(questionId: item.result.question.questionId, at: rec.now(),
                                hintMessageID: hint.tutorMessage.id)
        }
        return ChatEngineUpdate(turns: [.tutor(hint.tutorMessage)])
    }

    // MARK: Helpers (engine-side presentation choices)

    private var current: Item? { items.indices.contains(index) ? items[index] : nil }

    private func questionTurn(_ item: Item) -> ChatTurn {
        let question = item.result.question
        // Fallback reading prompts already embed their passage
        // verbatim (FallbackQuestionBank + QuestionGeneration both
        // require promptText to contain it, and SolverService.verify
        // preserves both). Prepending the passage again would render
        // and speak it twice, so only prepend when it is absent.
        let text: String
        if let passage = question.passage,
           !question.promptText.contains(passage.trimmingCharacters(in: .whitespacesAndNewlines)) {
            text = "\(passage)\n\n\(question.promptText)"
        } else {
            text = question.promptText
        }
        return .tutor(TutorMessage(id: question.questionId, text: text, kind: .question))
    }

    private func composer(for item: Item) -> ChatComposerSpec {
        let question = item.result.question
        if question.skill == SolverSkill.fractionComparison.rawValue {
            return .choices(["<", ">", "="])
        }
        if question.skill == SolverSkill.readingComprehension.rawValue {
            return .text
        }
        // Numeric and fraction answers use the number pad (digits and
        // the fraction bar); free text remains available beside it.
        return .numberPad
    }

    private func nextMessage(text: String, kind: TutorMessageKind) -> TutorMessage {
        messageSequence += 1
        return TutorMessage(id: "demo-m\(messageSequence)", text: text, kind: kind)
    }
}
