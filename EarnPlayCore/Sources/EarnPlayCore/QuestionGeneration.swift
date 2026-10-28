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
    /// Monotonic per-question variation index (F4). Set by the loop once
    /// per `generate` call so repeated skill/form requests never reuse
    /// identical prompt or sampling-seed inputs.
    public private(set) var variationIndex: Int

    public init(skill: SolverSkill, difficulty: Int = 1, grade: String = "4") {
        self.skill = skill
        self.difficulty = difficulty
        self.grade = grade
        self.attemptNumber = 1
        self.formHint = nil
        self.variationIndex = 0
    }

    func forAttempt(_ attemptNumber: Int, formHint: SolverForm?,
                    variationIndex: Int? = nil) -> QuestionGenerationRequest {
        var copy = self
        copy.attemptNumber = attemptNumber
        copy.formHint = formHint
        if let variationIndex { copy.variationIndex = variationIndex }
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
    /// Reading text did not contain its supporting passage (F1 contract).
    case promptTextMismatch
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

/// Successful verification of the final delivered question (F5),
/// recorded separately from the bounded model-attempt log. Every
/// delivered result carries one with outcome `.verified`.
public struct FinalVerificationRecord: Equatable, Sendable {
    public let source: GeneratedQuestionSource
    public let outcome: GenerationAttemptOutcome
    /// Model attempt that verified, or nil when the fallback served.
    public let attemptNumber: Int?
    public let questionId: String

    public init(source: GeneratedQuestionSource, outcome: GenerationAttemptOutcome,
                attemptNumber: Int?, questionId: String) {
        self.source = source
        self.outcome = outcome
        self.attemptNumber = attemptNumber
        self.questionId = questionId
    }
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
    /// Structured proposal the delivered question was verified from
    /// (rendered text included), for independent re-solving (F6).
    public let proposal: ProposedProblem
    /// Solver pass for the delivered question itself (F5).
    public let finalVerification: FinalVerificationRecord

    public var usedFallback: Bool { source == .fallbackBank }

    public init(question: VerifiedQuestion, source: GeneratedQuestionSource,
                attemptsUsed: Int, attempts: [GenerationAttemptLog],
                proposal: ProposedProblem, finalVerification: FinalVerificationRecord) {
        self.question = question
        self.source = source
        self.attemptsUsed = attemptsUsed
        self.attempts = attempts
        self.proposal = proposal
        self.finalVerification = finalVerification
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
    private var questionCounter = 0
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
        let variationIndex = nextVariationIndex()

        for attempt in 1...maxAttempts {
            let attemptRequest = request.forAttempt(
                attempt, formHint: nextFormHint(), variationIndex: variationIndex)
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
            // F1: displayed text is rendered from the structured values
            // (or, for reading, checked against its passage), never the
            // proposer's unverified wording for a computed skill.
            let checked: ProposedProblem
            switch Self.checkedForPresentation(proposal) {
            case .ready(let ready): checked = ready
            case .mismatch:
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .promptTextMismatch))
                continue
            case .rejected(let reason):
                log.append(GenerationAttemptLog(
                    attemptNumber: attempt, outcome: .solverRejected(reason)))
                continue
            }
            // Solver gate (LLD Section 5 steps 2-4). The model's own
            // stated answer is never consulted; the solver computes it.
            switch solver.verify(checked, questionId: makeQuestionID()) {
            case .success(let question):
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .verified))
                return QuestionGenerationResult(
                    question: question, source: .modelVerified,
                    attemptsUsed: attempt, attempts: log, proposal: checked,
                    finalVerification: FinalVerificationRecord(
                        source: .modelVerified, outcome: .verified,
                        attemptNumber: attempt, questionId: question.questionId))
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
        guard case .ready(let checkedFallback) = Self.checkedForPresentation(fallback) else {
            throw QuestionGenerationError.noVerifiedFallback(skill: request.skill.rawValue)
        }
        switch solver.verify(checkedFallback, questionId: makeQuestionID()) {
        case .success(let question):
            // F5: fallback solver pass is recorded separately; `attempts`
            // stays the bounded model-attempt log (all failures here).
            return QuestionGenerationResult(
                question: question, source: .fallbackBank,
                attemptsUsed: maxAttempts, attempts: log, proposal: checkedFallback,
                finalVerification: FinalVerificationRecord(
                    source: .fallbackBank, outcome: .verified,
                    attemptNumber: nil, questionId: question.questionId))
        case .failure:
            // A bank entry that no longer verifies must never be served.
            throw QuestionGenerationError.noVerifiedFallback(skill: request.skill.rawValue)
        }
    }

    private enum PresentationCheck {
        case ready(ProposedProblem)
        case mismatch
        case rejected(SolverRejectionReason)
    }

    /// Structured values are solver-validated BEFORE any rendering, so
    /// an invalid proposal (e.g. a subtraction that would go negative)
    /// never reaches distractor construction, whose arguments Swift
    /// evaluates eagerly for every form. The loop still verifies the
    /// final rendered proposal afterwards. Computed skills: replace
    /// free-form text with rendered text. Reading: require the text to
    /// contain its passage verbatim and the question/answer pair to
    /// satisfy a deterministically checkable relationship (see
    /// `ReadingPresentationVerifier`); containment alone is not enough.
    private static func checkedForPresentation(_ proposal: ProposedProblem) -> PresentationCheck {
        if case .rejected(let reason) = SolverService().solve(proposal) {
            return .rejected(reason)
        }
        if proposal.skill == .readingComprehension {
            guard let passage = proposal.passage,
                  !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .mismatch
            }
            let trimmedPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard proposal.promptText.contains(trimmedPassage) else { return .mismatch }
            guard ReadingPresentationVerifier.isVerified(proposal) else { return .mismatch }
            return .ready(proposal)
        }
        guard let rendered = QuestionPromptRenderer.render(proposal) else {
            return .mismatch
        }
        var copy = proposal
        copy.promptText = rendered
        return .ready(copy)
    }

    private func nextVariationIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { questionCounter += 1 }
        return questionCounter
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

/// Deterministic reading question/answer check (round-2 F2). Passage
/// containment plus a passage span is NOT support for an answer: the
/// question must ask for the kind of thing the candidate is, in a way
/// checkable from the passage text alone. Accepted shapes, all
/// fail-closed (anything else is a mismatch and falls back):
/// - a vetted fallback-bank (passage, question, answer) tuple, matched
///   on normalized passage, question, and candidate;
/// - a color question, whose candidate is a color word used as the
///   adjective of the questioned noun in the passage ("blue box");
/// - a how-many/much question, whose candidate begins with a number;
/// - a who question, whose candidate is a capitalized name span;
/// - a what-did question, whose candidate starts at most two tokens
///   after a passage verb sharing a stem with a question verb.
enum ReadingPresentationVerifier {
    private static let colors: Set<String> = [
        "red", "orange", "yellow", "green", "blue", "purple", "pink",
        "brown", "black", "white", "gray", "grey", "gold", "silver",
    ]
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]
    private static let stopwords: Set<String> = [
        "what", "did", "do", "does", "the", "a", "an", "in", "on", "at",
        "to", "of", "was", "were", "is", "are", "was", "for", "with",
    ]
    private static let vettedReading = FallbackQuestionBank.demo.entries(for: .readingComprehension)

    static func isVerified(_ proposal: ProposedProblem) -> Bool {
        guard let passage = proposal.passage,
              let candidate = proposal.candidateAnswer else { return false }
        let trimmedPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassage.isEmpty,
              let question = questionText(in: proposal.promptText, passage: trimmedPassage)
        else { return false }
        let candidateTokens = tokens(candidate)
        guard !candidateTokens.isEmpty else { return false }
        if isVetted(passage: trimmedPassage, question: question, candidate: candidate) {
            return true
        }
        let qTokens = tokens(question)
        let qLower = question.lowercased()
        if qLower.contains("what color") || qLower.contains("what colour") {
            return isColorAnswer(candidateTokens: candidateTokens, questionTokens: qTokens,
                                 passage: passage)
        }
        if qLower.contains("how many") || qLower.contains("how much") {
            guard let first = candidateTokens.first else { return false }
            return numberWords.contains(first) || (!first.isEmpty && first.allSatisfy(\.isNumber))
        }
        if qTokens.first == "who" {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedCandidate.first?.isUppercase == true && passage.contains(trimmedCandidate)
        }
        if qTokens.first == "what", qTokens.count > 1,
           ["did", "do", "does"].contains(qTokens[1]) {
            return isVerbObjectAnswer(candidateTokens: candidateTokens,
                                      questionTokens: qTokens, passage: passage)
        }
        return false
    }

    private static func questionText(in promptText: String, passage: String) -> String? {
        guard let range = promptText.range(of: passage) else { return nil }
        let rest = promptText[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    private static func isVetted(passage: String, question: String, candidate: String) -> Bool {
        vettedReading.contains { entry in
            guard let entryPassage = entry.passage,
                  let entryCandidate = entry.candidateAnswer,
                  let entryQuestion = questionText(
                    in: entry.promptText,
                    passage: entryPassage.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return false }
            return SolverService.normalizeForSupport(entryPassage) == SolverService.normalizeForSupport(passage)
                && SolverService.normalizeForSupport(entryQuestion) == SolverService.normalizeForSupport(question)
                && SolverService.normalizeForSupport(entryCandidate) == SolverService.normalizeForSupport(candidate)
        }
    }

    private static func isColorAnswer(candidateTokens: [String], questionTokens: [String],
                                      passage: String) -> Bool {
        guard candidateTokens.count == 1, colors.contains(candidateTokens[0]) else { return false }
        guard let colorIndex = questionTokens.firstIndex(where: { $0 == "color" || $0 == "colour" }),
              let theIndex = questionTokens[colorIndex...].firstIndex(of: "the"),
              theIndex + 1 < questionTokens.count else { return false }
        let noun = questionTokens[theIndex + 1]
        let passageTokens = tokens(passage)
        for index in passageTokens.indices.dropLast()
        where passageTokens[index] == candidateTokens[0] && passageTokens[index + 1] == noun {
            return true
        }
        return false
    }

    private static func isVerbObjectAnswer(candidateTokens: [String], questionTokens: [String],
                                           passage: String) -> Bool {
        let verbCandidates = questionTokens.dropFirst(2).filter { !stopwords.contains($0) && $0.count >= 3 }
        for sentence in SolverService.passageSentences(passage) {
            let sentenceTokens = tokens(sentence)
            guard let candidateStart = firstIndex(of: candidateTokens, in: sentenceTokens) else { continue }
            for verb in verbCandidates {
                for index in sentenceTokens.indices
                where sharesStem(sentenceTokens[index], verb) {
                    if candidateStart > index, candidateStart - index <= 2 { return true }
                }
            }
        }
        return false
    }

    private static func sharesStem(_ a: String, _ b: String) -> Bool {
        let stem = min(a.count, b.count)
        guard stem >= 3 else { return a == b }
        return a.prefix(stem) == b.prefix(stem) && (a.count <= b.count + 3)
    }

    private static func firstIndex(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    private static func tokens(_ text: String) -> [String] {
        SolverService.normalizeForSupport(text).split(separator: " ").map(String.init)
    }
}
