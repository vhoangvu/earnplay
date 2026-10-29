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
/// beyond the solver verdict for the current question.
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

    init(maxQuestions: Int = 3) {
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
        guard let item = current else {
            return ChatEngineUpdate(turns: [.tutor(nextMessage(
                text: "Let's practise together. Take your time.",
                kind: .instruction))])
        }
        return ChatEngineUpdate(
            turns: [questionTurn(item)],
            progress: ChatProgress(totalQuestions: items.count, attemptedQuestions: 0),
            composer: composer(for: item))
    }

    func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
        guard let item = current else { return ChatEngineUpdate() }
        let isRevision = lastAnswer.map { $0 != plainText } ?? false
        _ = item.ladder.recordAnswerSubmission(plainText)
        let firstAttempt = !attempted.contains(index)
        attempted.insert(index)
        let progress = ChatProgress(totalQuestions: items.count, attemptedQuestions: attempted.count)
        lastAnswer = plainText

        switch solver.checkAnswer(item.result.question, proposedAnswer: plainText) {
        case .correct:
            index += 1
            lastAnswer = nil
            var turns: [ChatTurn] = [.tutor(nextMessage(
                text: "Nice work. Let's try another one.", kind: .encouragement))]
            if let next = current {
                turns.append(questionTurn(next))
                return ChatEngineUpdate(turns: turns, progress: progress,
                                        composer: composer(for: next),
                                        submittedTurnIsRevision: isRevision)
            }
            turns = [.tutor(nextMessage(
                text: "Nice work. That was a good practice session.", kind: .encouragement))]
            return ChatEngineUpdate(turns: turns, progress: progress,
                                    composer: .text, submittedTurnIsRevision: isRevision)
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
            return ChatEngineUpdate(turns: turns, progress: progress,
                                    composer: composer(for: item),
                                    submittedTurnIsRevision: isRevision)
        }
    }

    func requestHint() -> ChatEngineUpdate {
        guard let item = current, let hint = item.ladder.requestHint() else {
            return ChatEngineUpdate()
        }
        return ChatEngineUpdate(turns: [.tutor(hint.tutorMessage)])
    }

    // MARK: Helpers (engine-side presentation choices)

    private var current: Item? { items.indices.contains(index) ? items[index] : nil }

    private func questionTurn(_ item: Item) -> ChatTurn {
        let question = item.result.question
        let text = question.passage.map { "\($0)\n\n\(question.promptText)" } ?? question.promptText
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
