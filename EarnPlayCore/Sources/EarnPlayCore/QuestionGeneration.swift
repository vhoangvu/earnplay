import Foundation

/// Question generation + verification loop (T1.2, LLD Section 5 steps 5-6,
/// LLD Section 10.2 gates, SSOT Section 5).
///
/// The model proposes; the solver decides. `QuestionGenerator` asks a
/// `QuestionProposing` source for a structured problem (skill + form +
/// values), then verifies it with `SolverService` before anything may be
/// shown to the child. A proposal is presented only when the solver
/// verifies it. On any failure the loop asks for a new proposal, up to a
/// bounded attempt count; when the bound is exhausted it serves a safe,
/// pre-verified question from `FallbackQuestionBank` for the same skill.
/// No unverified question is ever returned: if no verified fallback exists
/// for the skill, the loop throws instead of presenting anything.
///
/// Interface for T1.1 / T1.8 (see `Docs/QuestionGeneration.md`):
/// - T1.1 (diagnostic) maps the profile's target skill to a
///   `QuestionGenerationRequest` (skill, difficulty, grade).
/// - T1.8 (chat UI) calls `QuestionGenerator.generate(_:)` and renders only
///   the returned `VerifiedQuestion`. It never sees a raw proposal.
/// - `QuestionGenerationResult` carries the retry/fallback counters the
///   task card requires to be logged (attempts used, per-attempt verify
///   status, and whether the fallback supplied the question).

/// Forms the generation loop may present. The LLD form list (Section 2.3)
/// deliberately excludes plain textbook form, so `.direct` proposals are
/// rejected by the loop even though the solver can compute them.
public enum QuestionForms {
    public static let presentable: [SolverForm] = [
        .story, .reverse, .estimation, .whichIsWrong, .irrelevantNumbers,
    ]

    public static func isPresentable(_ form: SolverForm) -> Bool {
        presentable.contains(form)
    }
}

/// One request for a verified question. T1.1 supplies the skill (and
/// difficulty/grade from the profile); T1.8 passes the request through.
public struct QuestionGenerationRequest: Equatable, Sendable {
    public let skill: SolverSkill
    public let difficulty: Int
    public let grade: String
    /// 1-based proposal attempt this request copy is for. Set by the loop.
    public private(set) var attemptNumber: Int
    /// Form the proposer is asked to use for this attempt. Set by the loop
    /// on a rotating basis so consecutive questions vary in surface form.
    public private(set) var formHint: SolverForm?

    public init(skill: SolverSkill, difficulty: Int = 1, grade: String = "4") {
        self.skill = skill
        self.difficulty = difficulty
        self.grade = grade
        self.attemptNumber = 1
        self.formHint = nil
    }

    func forAttempt(_ attemptNumber: Int, formHint: SolverForm?) -> QuestionGenerationRequest {
        var copy = self
        copy.attemptNumber = attemptNumber
        copy.formHint = formHint
        return copy
    }
}

/// A source of structured problem proposals. The production source is
/// `ModelQuestionProposer` (T0.2 `ModelRuntime`); tests inject stubs,
/// including fault-injected ones. Returning nil means the source produced
/// nothing parseable for this attempt; throwing means it failed outright.
/// Either counts as one failed attempt in the loop, never as a question.
public protocol QuestionProposing: Sendable {
    func propose(request: QuestionGenerationRequest) throws -> ProposedProblem?
}

/// Why one proposal attempt did not produce a presentable question.
public enum GenerationAttemptOutcome: Equatable, Sendable {
    /// Solver verified the proposal; it was presented.
    case verified
    /// Solver rejected the proposal (LLD Section 5 step 5).
    case solverRejected(SolverRejectionReason)
    /// Proposal practised a different skill than the one requested.
    case skillMismatch(proposed: String)
    /// Proposal used plain textbook form (`.direct`); never presented.
    case plainTextbookForm
    /// Proposal carried no question text to show the child.
    case emptyPromptText
    /// Proposer returned nothing parseable for this attempt.
    case noProposal
    /// Proposer threw. The string is the error description for the log.
    case proposerFailed(String)
}

/// Per-attempt verify status, logged for every proposal (acceptance:
/// any presented item without a solver pass in this log fails).
public struct GenerationAttemptLog: Equatable, Sendable {
    public let attemptNumber: Int
    public let outcome: GenerationAttemptOutcome

    public init(attemptNumber: Int, outcome: GenerationAttemptOutcome) {
        self.attemptNumber = attemptNumber
        self.outcome = outcome
    }
}

/// Whether the presented question came from a verified model proposal or
/// from the pre-verified fallback bank after retry exhaustion.
public enum GeneratedQuestionSource: Equatable, Sendable {
    case modelVerified
    case fallbackBank
}

/// The only output of the loop: a solver-verified question plus the
/// retry/fallback counters for the session log.
public struct QuestionGenerationResult: Equatable, Sendable {
    public let question: VerifiedQuestion
    public let source: GeneratedQuestionSource
    /// Proposal attempts consumed, including the successful one. Never
    /// exceeds the generator's `maxAttempts`. On fallback this equals
    /// `maxAttempts` (every attempt failed before the fallback served).
    public let attemptsUsed: Int
    public let attempts: [GenerationAttemptLog]

    public var usedFallback: Bool { source == .fallbackBank }

    public init(question: VerifiedQuestion, source: GeneratedQuestionSource,
                attemptsUsed: Int, attempts: [GenerationAttemptLog]) {
        self.question = question
        self.source = source
        self.attemptsUsed = attemptsUsed
        self.attempts = attempts
    }
}

public enum QuestionGenerationError: Error, Equatable, Sendable {
    /// Retry bound exhausted and the fallback bank holds no verified
    /// question for this skill. Thrown rather than presenting anything
    /// unverified; the session surfaces an error instead of a question.
    case noVerifiedFallback(skill: String)
}

/// The generation + verification loop. See the file header for the
/// contract. Bounds: at most `maxAttempts` proposals per question
/// (default 3, the "fixed small retry count" of LLD Section 5 step 5;
/// the LLD pins no number, so this choice is recorded in
/// `Docs/QuestionGeneration.md`), then one fallback question.
public final class QuestionGenerator: @unchecked Sendable {
    public static let defaultMaxAttempts = 3

    private let proposer: any QuestionProposing
    private let solver: SolverService
    private let fallbackBank: FallbackQuestionBank
    public let maxAttempts: Int
    private let makeQuestionID: @Sendable () -> String

    private let lock = NSLock()
    private var formRotation = 0
    private var fallbackRotation: [SolverSkill: Int] = [:]

    public init(proposer: any QuestionProposing,
                solver: SolverService = SolverService(),
                fallbackBank: FallbackQuestionBank = .demo,
                maxAttempts: Int = QuestionGenerator.defaultMaxAttempts,
                makeQuestionID: @escaping @Sendable () -> String = { "q-\(UUID().uuidString)" }) {
        self.proposer = proposer
        self.solver = solver
        self.fallbackBank = fallbackBank
        self.maxAttempts = max(1, maxAttempts)
        self.makeQuestionID = makeQuestionID
    }

    /// Returns a solver-verified question for `request`. Throws only
    /// `QuestionGenerationError.noVerifiedFallback`, when every proposal
    /// failed and the bank has nothing verified for the skill.
    public func generate(_ request: QuestionGenerationRequest) throws -> QuestionGenerationResult {
        var log: [GenerationAttemptLog] = []
        log.reserveCapacity(maxAttempts)

        for attempt in 1...maxAttempts {
            let attemptRequest = request.forAttempt(attempt, formHint: nextFormHint())
            let proposal: ProposedProblem?
            do {
                proposal = try proposer.propose(request: attemptRequest)
            } catch {
                log.append(GenerationAttemptLog(
                    attemptNumber: attempt,
                    outcome: .proposerFailed(String(describing: error))))
                continue
            }
            guard let proposal else {
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .noProposal))
                continue
            }
            // Loop-level gates (LLD 10.2 schema/safety gates, SSOT form
            // rule). These run before the solver so a proposal that could
            // never be presented does not consume solver trust by accident.
            guard proposal.skill == request.skill else {
                log.append(GenerationAttemptLog(
                    attemptNumber: attempt,
                    outcome: .skillMismatch(proposed: proposal.skill.rawValue)))
                continue
            }
            guard QuestionForms.isPresentable(proposal.form) else {
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .plainTextbookForm))
                continue
            }
            guard !proposal.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .emptyPromptText))
                continue
            }
            // Solver gate (LLD Section 5 steps 2-4). The model's own
            // stated answer is never consulted; the solver computes it.
            switch solver.verify(proposal, questionId: makeQuestionID()) {
            case .success(let question):
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .verified))
                return QuestionGenerationResult(
                    question: question, source: .modelVerified,
                    attemptsUsed: attempt, attempts: log)
            case .failure(let reason):
                log.append(GenerationAttemptLog(
                    attemptNumber: attempt, outcome: .solverRejected(reason)))
                continue
            }
        }

        // Retry bound exhausted: safe pre-verified fallback for the same
        // skill (LLD Section 5 step 6). The bank only holds proposals the
        // solver verified when the bank was built, and the serve below
        // re-verifies with this question's own id, so the fallback path
        // is verified by construction, not by trust.
        guard let fallback = nextFallback(for: request.skill) else {
            throw QuestionGenerationError.noVerifiedFallback(skill: request.skill.rawValue)
        }
        switch solver.verify(fallback, questionId: makeQuestionID()) {
        case .success(let question):
            return QuestionGenerationResult(
                question: question, source: .fallbackBank,
                attemptsUsed: maxAttempts, attempts: log)
        case .failure:
            // A bank entry that no longer verifies must never be served.
            throw QuestionGenerationError.noVerifiedFallback(skill: request.skill.rawValue)
        }
    }

    private func nextFormHint() -> SolverForm {
        lock.lock()
        defer { lock.unlock() }
        let form = QuestionForms.presentable[formRotation % QuestionForms.presentable.count]
        formRotation += 1
        return form
    }

    private func nextFallback(for skill: SolverSkill) -> ProposedProblem? {
        lock.lock()
        defer { lock.unlock() }
        guard let proposal = fallbackBank.proposal(for: skill, rotationIndex: fallbackRotation[skill, default: 0]) else {
            return nil
        }
        fallbackRotation[skill, default: 0] += 1
        return proposal
    }
}
