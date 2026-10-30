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

    /// Production wiring: real on-device logger/queue/policy, one scorer
    /// draw per session, UUID session ids, live clock. Used only by the
    /// child app's practice screen; tests inject isolated fakes.
    static func productionDefault(
        logger: DecisionLogger = DecisionLogger(),
        queue: SessionLogQueue = SessionLogQueue(),
        policyVersion: @escaping () -> Int = { PolicyStore().storedVersion },
        makeScorer: @escaping () -> EffortScorer = { EffortScorer() },
        makeSessionId: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = Date.init
    ) -> Self {
        Self(makeSessionId: makeSessionId, logger: logger, queue: queue,
             makeScorer: makeScorer, policyVersion: policyVersion, now: now)
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

    /// Active recording session id, for tests. Nil when recording is
    /// disabled or no session has started.
    var recordingSessionId: String? { sessionRecorder?.sessionId }

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
            index = 0
            attempted = []
            lastAnswer = nil
            awaitingProbeReply = false
            items = items.map { Item(result: $0.result, ladder: HintLadder(result: $0.result)) }
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
            let startedAt = rec.now()
            sessionScorer = rec.makeScorer()
            let recorder = PracticeSessionRecorder(
                sessionId: rec.makeSessionId(), startedAt: startedAt, now: rec.now)
            sessionRecorder = recorder
            recordingEnded = false
            recorder.startQuestion(questionId: item.result.question.questionId,
                                   skill: item.result.question.skill, at: startedAt)
        }
        return ChatEngineUpdate(
            turns: [questionTurn(item)],
            progress: ChatProgress(totalQuestions: items.count, attemptedQuestions: 0),
            composer: composer(for: item))
    }

    /// Finishes the active recording session (if any) and enqueues its
    /// `SessionLog` in the T4.6 queue. Called automatically when the last
    /// question is answered correctly; tests call it directly to finish
    /// incomplete sessions (e.g. with a final incorrect answer). Returns
    /// the enqueued log, or nil when recording is disabled, no session is
    /// active, or the session already finished. Never invents detail:
    /// unanswered questions produce no records and unscored sessions carry
    /// nil effort.
    @discardableResult
    func finishRecordingSession(at date: Date? = nil) -> SessionLog? {
        guard let rec = recording, let recorder = sessionRecorder,
              let scorer = sessionScorer, !recordingEnded else { return nil }
        recordingEnded = true
        let log = recorder.makeSessionLog(
            endedAt: date ?? rec.now(), logger: rec.logger,
            policyVersion: rec.policyVersion(), scorer: scorer)
        try? rec.queue.enqueue(log)
        return log
    }

    func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
        guard let item = current else {
            // Explicit session-complete state, never a silent empty
            // update behind an editable composer.
            return ChatEngineUpdate(composer: items.isEmpty ? nil : .sessionComplete)
        }
        // A pending probe takes this submission as the child's
        // explanation: acknowledge the thinking, do not grade it
        // against the answer, do not record it as an answer
        // submission, and do not label it a revision. The child is
        // then back to answering the same question.
        if awaitingProbeReply {
            awaitingProbeReply = false
            if let rec = recording, let recorder = sessionRecorder, !recordingEnded {
                recorder.recordProbeReply(questionId: item.result.question.questionId,
                                          at: rec.now())
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
        guard let hint = item.ladder.requestHint() else {
            return ChatEngineUpdate()
        }
        if let rec = recording, let recorder = sessionRecorder, !recordingEnded {
            recorder.recordHint(questionId: item.result.question.questionId, at: rec.now())
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
