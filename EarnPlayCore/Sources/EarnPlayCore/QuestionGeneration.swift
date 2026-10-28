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
    /// Serializes fallback selection, verification, and rotation
    /// advancement as one operation (round-4 F4). Held only around the
    /// fallback serve; never acquired while `lock` is held, and fallback
    /// helpers acquire `lock` (never the reverse), so lock order is fixed.
    private let fallbackLock = NSLock()
    private var formRotation = 0
    private var questionCounter = 0
    private var fallbackRotation: [SolverSkill: Int] = [:]
    private var deliveredForms: [SolverForm] = []

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
            let formHint = nextFormHint()
            let attemptRequest = request.forAttempt(
                attempt, formHint: formHint, variationIndex: variationIndex)
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
            // F2 (round 3): enforce the rotating form hint at rendering
            // time for computed skills. A proposer that keeps returning a
            // form this generator has already delivered, despite a
            // different hint, is re-rendered in the hinted form from the
            // same structured values, so ten questions cannot all share
            // one form. A first-seen form is left as proposed.
            var effectiveProposal = proposal
            if proposal.skill != .readingComprehension,
               proposal.form != formHint,
               hasDeliveredForm(proposal.form) {
                effectiveProposal.form = formHint
            }
            // Loop-level gates (LLD 10.2 schema/safety gates, SSOT form
            // rule). These run before the solver so a proposal that could
            // never be presented does not consume solver trust by accident.
            guard effectiveProposal.skill == request.skill else {
                log.append(GenerationAttemptLog(
                    attemptNumber: attempt,
                    outcome: .skillMismatch(proposed: effectiveProposal.skill.rawValue)))
                continue
            }
            guard QuestionForms.isPresentable(effectiveProposal.form) else {
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .plainTextbookForm))
                continue
            }
            guard !effectiveProposal.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log.append(GenerationAttemptLog(attemptNumber: attempt, outcome: .emptyPromptText))
                continue
            }
            // F1: displayed text is rendered from the structured values
            // (or, for reading, checked against its passage), never the
            // proposer's unverified wording for a computed skill.
            let checked: ProposedProblem
            switch Self.checkedForPresentation(effectiveProposal) {
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
                recordDeliveredForm(question.formType)
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
        if let fallbackResult = serveFallback(for: request, log: log) {
            return fallbackResult
        }
        throw QuestionGenerationError.noVerifiedFallback(skill: request.skill.rawValue)
    }

    /// Fallback serve, serialized as one operation under `fallbackLock`:
    /// scan, presentation check, solver verification, and rotation
    /// advancement all complete before any other caller may scan, so two
    /// concurrent `generate` calls can never capture the same fallback
    /// start, serve the same entry out of turn, or overwrite each other's
    /// rotation advance (round-4 F4). Within the serve, F3 (round 3)
    /// applies: scan the skill's entries once in round-robin order,
    /// skipping presentation-invalid (or no longer verifying) candidates,
    /// instead of failing when only the first is unusable.
    private func serveFallback(for request: QuestionGenerationRequest,
                               log: [GenerationAttemptLog]) -> QuestionGenerationResult? {
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        let (fallbackStart, fallbackCandidates) = fallbackScan(for: request.skill)
        for (offset, fallback) in fallbackCandidates.enumerated() {
            guard case .ready(let checkedFallback) = Self.checkedForPresentation(fallback) else {
                continue
            }
            switch solver.verify(checkedFallback, questionId: makeQuestionID()) {
            case .success(let question):
                advanceFallbackRotation(for: request.skill, start: fallbackStart, consumed: offset + 1)
                recordDeliveredForm(question.formType)
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
                continue
            }
        }
        return nil
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

    private func hasDeliveredForm(_ form: SolverForm) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deliveredForms.contains(form)
    }

    private func recordDeliveredForm(_ form: SolverForm) {
        lock.lock()
        defer { lock.unlock() }
        deliveredForms.append(form)
    }

    /// Entries for `skill` in round-robin order starting at the current
    /// rotation, each at most once, plus the starting rotation index.
    private func fallbackScan(for skill: SolverSkill) -> (start: Int, candidates: [ProposedProblem]) {
        lock.lock()
        defer { lock.unlock() }
        let matching = fallbackBank.entries(for: skill)
        guard !matching.isEmpty else { return (fallbackRotation[skill, default: 0], []) }
        let start = fallbackRotation[skill, default: 0]
        let normalizedStart = ((start % matching.count) + matching.count) % matching.count
        let candidates = (0..<matching.count).map { matching[(normalizedStart + $0) % matching.count] }
        return (start, candidates)
    }

    private func advanceFallbackRotation(for skill: SolverSkill, start: Int, consumed: Int) {
        lock.lock()
        defer { lock.unlock() }
        fallbackRotation[skill] = start + consumed
    }
}

/// Deterministic reading question/answer check (round-2 F2, round-3 F1).
/// Passage containment plus a passage span is NOT support for an answer:
/// for each supported shape the candidate must provably answer the
/// relationship asked about, checkable from the passage text alone.
/// Accepted shapes, all fail-closed (anything else falls back):
/// - a vetted fallback-bank (passage, question, answer) tuple, matched
///   on normalized passage, question, and candidate;
/// - a color question, whose candidate colors the questioned noun in
///   the passage under a supported, non-negated template: adjective
///   immediately before the noun, or predicative after it (noun +
///   copula + optional intensifier + color). Any other construction —
///   negated, or mere proximity after the noun — fails closed;
/// - a how-many/much question, whose candidate number is the quantity
///   of the questioned noun in the passage;
/// - a who question, whose candidate is the subject (or, for an
///   auxiliary question, the non-subject participant) of the questioned
///   verb in the passage, with the rest of the questioned clause
///   (recipient/object after the verb) matching that same clause;
/// - a what-did question, whose candidate is the questioned verb's
///   actual object span (only determiners/quantities between verb and
///   candidate, the questioned subject before that verb) in the
///   passage. A noun in a following prepositional phrase is not the
///   object, however close to the verb it sits.
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
            return isQuantityAnswer(candidateTokens: candidateTokens, questionTokens: qTokens,
                                    passage: passage)
        }
        if qTokens.first == "who" {
            return isWhoAnswer(candidate: candidate, candidateTokens: candidateTokens,
                               questionTokens: qTokens, passage: passage)
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

    private static func isQuantityAnswer(candidateTokens: [String], questionTokens: [String],
                                         passage: String) -> Bool {
        guard let first = candidateTokens.first,
              numberWords.contains(first) || (!first.isEmpty && first.allSatisfy(\.isNumber))
        else { return false }
        guard let trigger = questionTokens.firstIndex(where: { $0 == "many" || $0 == "much" }),
              trigger + 1 < questionTokens.count else { return false }
        let noun = questionTokens[trigger + 1]
        let passageTokens = tokens(passage)
        for index in passageTokens.indices where passageTokens[index] == first {
            for offset in 1...3
            where index + offset < passageTokens.count && nounMatches(passageTokens[index + offset], noun) {
                return true
            }
        }
        return false
    }

    private static func isWhoAnswer(candidate: String, candidateTokens: [String],
                                    questionTokens: [String], passage: String) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCandidate.first?.isUppercase == true, passage.contains(trimmedCandidate),
              questionTokens.count >= 2 else { return false }
        let auxiliaries: Set<String> = ["did", "do", "does", "is", "are", "was", "were"]
        let sentences = SolverService.passageSentences(passage).map(tokens)
        if !auxiliaries.contains(questionTokens[1]) {
            // "Who gave ...?": candidate must be the subject span directly
            // before the questioned verb in a passage sentence, and the
            // rest of the questioned clause (recipient/object after the
            // verb) must match that same sentence after the verb. Matching
            // candidate + verb alone accepts the subject of a different
            // clause ("Maya gave Leo a book. Nora gave Sam a pen." /
            // "Who gave Sam a pen?" must not accept Maya).
            let verb = questionTokens[1]
            let questionedTail = questionTokens.dropFirst(2)
                .filter { !["the", "a", "an"].contains($0) }
            for sentenceTokens in sentences {
                guard let start = firstIndex(of: candidateTokens, in: sentenceTokens) else { continue }
                let end = start + candidateTokens.count
                guard end < sentenceTokens.count, verbMatches(sentenceTokens[end], verb) else { continue }
                let afterVerb = sentenceTokens[(end + 1)...]
                if questionedTail.allSatisfy({ tailToken in
                    afterVerb.contains(where: { nounMatches($0, tailToken) })
                }) { return true }
            }
            return false
        }
        let aux = questionTokens[1]
        let rest = Array(questionTokens.dropFirst(2))
        if ["is", "are", "was", "were"].contains(aux) {
            // "Who is the teacher?": candidate before the copula, with the
            // questioned description after it in the same sentence.
            let description = rest.filter { !["the", "a", "an"].contains($0) }
            if !description.isEmpty {
                for sentenceTokens in sentences {
                    guard let start = firstIndex(of: candidateTokens, in: sentenceTokens) else { continue }
                    let end = start + candidateTokens.count
                    guard end < sentenceTokens.count, sentenceTokens[end] == aux else { continue }
                    if description.allSatisfy({ sentenceTokens[end...].contains($0) }) { return true }
                }
            }
        }
        // "Who did Maya give ...?": candidate is a non-subject participant
        // after the questioned verb, with the questioned subject before it.
        return followsQuestionedVerb(candidateTokens: candidateTokens, rest: rest,
                                     sentences: sentences, maxDistance: 4)
    }

    private static func isColorAnswer(candidateTokens: [String], questionTokens: [String],
                                      passage: String) -> Bool {
        guard candidateTokens.count == 1, colors.contains(candidateTokens[0]) else { return false }
        // The questioned noun is the last content token ("the box's lid"
        // asks about the lid, not the box).
        let excluded: Set<String> = ["what", "color", "colour", "is", "was", "were", "are",
                                     "the", "a", "an", "s"]
        guard let noun = questionTokens.last(where: { !excluded.contains($0) }) else { return false }
        let color = candidateTokens[0]
        let negations: Set<String> = ["not", "no", "never", "isn", "aren", "wasn", "weren"]
        let copulas: Set<String> = ["is", "are", "was", "were"]
        let intensifiers: Set<String> = ["very", "bright", "dark", "light", "pale", "deep", "really"]
        for sentence in SolverService.passageSentences(passage) {
            let sentenceTokens = tokens(sentence)
            for nounIndex in sentenceTokens.indices where nounMatches(sentenceTokens[nounIndex], noun) {
                for colorIndex in sentenceTokens.indices where sentenceTokens[colorIndex] == color {
                    // Attributive template: the color immediately precedes
                    // the noun ("a blue box"), unnegated.
                    if colorIndex + 1 == nounIndex,
                       colorIndex == 0 || !negations.contains(sentenceTokens[colorIndex - 1]) {
                        return true
                    }
                    // Predicative template: noun immediately before a
                    // copula, then only intensifiers, then the color
                    // ("the box is blue"). Anything between the noun and
                    // the color beyond that template — a negation ("the
                    // box is not red"), another noun, a prepositional
                    // phrase — is unsupported and fails closed.
                    guard nounIndex < colorIndex else { continue }
                    let between = sentenceTokens[(nounIndex + 1)..<colorIndex]
                    guard let copulaOffset = between.firstIndex(where: { copulas.contains($0) }),
                          copulaOffset == between.startIndex else { continue }
                    let afterCopula = between[(copulaOffset + 1)...]
                    guard afterCopula.allSatisfy({ intensifiers.contains($0) }),
                          !sentenceTokens[nounIndex...colorIndex].contains(where: { negations.contains($0) })
                    else { continue }
                    return true
                }
            }
        }
        return false
    }

    private static func isVerbObjectAnswer(candidateTokens: [String], questionTokens: [String],
                                           passage: String) -> Bool {
        let rest = Array(questionTokens.dropFirst(2))
        let sentences = SolverService.passageSentences(passage).map(tokens)
        return followsQuestionedVerb(candidateTokens: candidateTokens, rest: rest,
                                     sentences: sentences, maxDistance: 3)
    }

    /// Shared relational core for who-object and what-did shapes: the
    /// candidate must start within `maxDistance` tokens after an occurrence
    /// of the questioned verb in a passage sentence that also contains the
    /// questioned subject before that verb. The verb is the first rest
    /// token (after at least one subject token) that governs the candidate;
    /// subject/object nouns from the question never qualify as the verb,
    /// and a candidate already named in the question never qualifies.
    private static func followsQuestionedVerb(candidateTokens: [String], rest: [String],
                                              sentences: [[String]], maxDistance: Int) -> Bool {
        guard rest.count >= 2, !candidateTokens.isEmpty else { return false }
        if candidateTokens.allSatisfy({ rest.contains($0) }) { return false }
        for verbIndex in 1..<rest.count {
            let verb = rest[verbIndex]
            guard verb.count >= 3, !stopwords.contains(verb) else { continue }
            let subjectTokens = rest[..<verbIndex].filter { !["the", "a", "an"].contains($0) }
            guard !subjectTokens.isEmpty else { continue }
            for sentenceTokens in sentences {
                guard let candidateStart = firstIndex(of: candidateTokens, in: sentenceTokens)
                else { continue }
                for index in sentenceTokens.indices where verbMatches(sentenceTokens[index], verb) {
                    let distance = candidateStart - index
                    guard distance >= 1, distance <= maxDistance else { continue }
                    // The candidate must be the verb's actual object span:
                    // only determiners / quantities may intervene between
                    // the verb and the candidate ("watered the flowers").
                    // Any other intervening token — the real object, or a
                    // preposition opening a following phrase ("planted
                    // seeds beside roses") — means the candidate is not
                    // the object, however close it sits to the verb.
                    let intervening = sentenceTokens[(index + 1)..<candidateStart]
                    guard intervening.allSatisfy({ isObjectBridgeToken($0) }) else { continue }
                    if subjectTokens.allSatisfy({ sentenceTokens[..<index].contains($0) }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Tokens allowed between a verb and its object span: determiners and
    /// quantities only. A noun, verb, or preposition in this slot means the
    /// candidate is not the verb's object.
    private static func isObjectBridgeToken(_ token: String) -> Bool {
        if ["the", "a", "an", "some", "any", "this", "that"].contains(token) { return true }
        if numberWords.contains(token) { return true }
        return !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    private static func nounMatches(_ token: String, _ noun: String) -> Bool {
        canonicalNoun(token) == canonicalNoun(noun)
    }

    private static func canonicalNoun(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count > 3 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("es"), token.count > 2 { return String(token.dropLast(2)) }
        if token.hasSuffix("s"), token.count > 1 { return String(token.dropLast()) }
        return token
    }

    private static let irregularVerbGroups: [Set<String>] = [
        ["give", "gave", "given"], ["see", "saw", "seen"], ["take", "took", "taken"],
        ["go", "went", "gone"], ["eat", "ate", "eaten"], ["write", "wrote", "written"],
        ["say", "said"], ["make", "made"], ["find", "found"], ["tell", "told"],
        ["sing", "sang", "sung"], ["run", "ran"], ["swim", "swam", "swum"],
        ["draw", "drew", "drawn"], ["bring", "brought"], ["buy", "bought"],
        ["think", "thought"], ["teach", "taught"], ["catch", "caught"],
        ["leave", "left"], ["keep", "kept"], ["feel", "felt"], ["grow", "grew", "grown"],
    ]

    private static func verbMatches(_ token: String, _ verb: String) -> Bool {
        if token == verb { return true }
        if irregularVerbGroups.contains(where: { $0.contains(token) && $0.contains(verb) }) {
            return true
        }
        let tokenStem = verbStem(token)
        return tokenStem == verbStem(verb) && tokenStem.count >= 3
    }

    private static func verbStem(_ token: String) -> String {
        if token.hasSuffix("ing"), token.count > 5 { return String(token.dropLast(3)) }
        if token.hasSuffix("ed"), token.count > 4 { return String(token.dropLast(2)) }
        if token.hasSuffix("ies"), token.count > 3 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("es"), token.count > 3 { return String(token.dropLast(2)) }
        if token.hasSuffix("s"), token.count > 3 { return String(token.dropLast()) }
        return token
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
