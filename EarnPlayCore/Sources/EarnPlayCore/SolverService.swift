import Foundation

/// Deterministic verifier for 4th-grade skills (LLD Section 5, solver contract).
///
/// Rule: the model proposes; the solver decides. Wrong answers can never be
/// taught. This service is plain deterministic code: it never calls the model,
/// never makes network requests, and never grades by heuristics. Given the
/// same inputs it always returns the same verdict.
///
/// How it is used:
/// 1. The model proposes a problem as structured data (`ProposedProblem`):
///    skill, form type, and the values that define the problem, plus a passage
///    for reading. The model's own stated answer is never taken as input.
/// 2. `SolverService` computes the correct answer deterministically from the
///    skill, form, and values.
/// 3. For reading, the proposed answer must be supported by the passage text.
/// 4. Only on success is a `VerifiedQuestion` created, with `verifiedAnswer`
///    set by this solver. Attempt correctness is judged against that answer.
///
/// The service verifies a proposed answer; it does not generate questions and
/// does not parse free-form problem text beyond the structured values in the
/// proposal. See `Docs/SolverService.md` for the full contract note.
public enum SolverSkill: String, Codable, Sendable, CaseIterable {
    case multiplicationFacts
    case multiDigitMultiplication
    case division
    case fractionComparison
    case fractionAddition
    case wordProblem
    case readingComprehension
}

/// Question form types from the LLD. Forms change presentation only; the
/// solver computes from skill + values regardless of form.
public enum SolverForm: String, Codable, Sendable, CaseIterable {
    case direct
    case story
    case reverse
    case estimation
    case whichIsWrong = "which-is-wrong"
    case irrelevantNumbers = "irrelevant-numbers"
}

public enum WordOperation: String, Codable, Sendable {
    case add, subtract, multiply, divide
}

/// A fraction, always stored normalized: reduced by the gcd and with a
/// positive denominator. Zero is stored as 0/1.
public struct SolverFraction: Equatable, Codable, Sendable, CustomStringConvertible {
    public let numerator: Int
    public let denominator: Int

    public init?(numerator: Int, denominator: Int) {
        guard denominator != 0 else { return nil }
        var n = numerator
        var d = denominator
        if d < 0 { n = -n; d = -d }
        if n == 0 {
            self.numerator = 0
            self.denominator = 1
            return
        }
        let g = SolverFraction.gcd(abs(n), d)
        self.numerator = n / g
        self.denominator = d / g
    }

    /// Parses "n/d" or a whole number "n". Returns nil when malformed.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 1, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
            self.init(numerator: n, denominator: 1)
        } else if parts.count == 2,
                  let n = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let d = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            self.init(numerator: n, denominator: d)
        } else {
            return nil
        }
    }

    public var description: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    public static func + (lhs: SolverFraction, rhs: SolverFraction) -> SolverFraction? {
        // Denominators are positive and reduced; use lcm to bound overflow.
        let g = gcd(lhs.denominator, rhs.denominator)
        let l = lhs.denominator / g
        let r = rhs.denominator / g
        let (n1, o1) = lhs.numerator.multipliedReportingOverflow(by: r)
        let (n2, o2) = rhs.numerator.multipliedReportingOverflow(by: l)
        let (sum, o3) = n1.addingReportingOverflow(n2)
        let (den, o4) = (l * g).multipliedReportingOverflow(by: r)
        guard !o1, !o2, !o3, !o4 else { return nil }
        return SolverFraction(numerator: sum, denominator: den)
    }

    /// Three-way comparison: -1, 0, or 1. Exact integer cross-multiplication.
    public func compared(to other: SolverFraction) -> Int? {
        let (l, o1) = numerator.multipliedReportingOverflow(by: other.denominator)
        let (r, o2) = other.numerator.multipliedReportingOverflow(by: denominator)
        guard !o1, !o2 else { return nil }
        if l < r { return -1 }
        if l > r { return 1 }
        return 0
    }
}

/// Structured problem proposal. The model's stated answer is never a field
/// here: the solver computes the answer itself (contract step 1-2).
public struct ProposedProblem: Equatable, Sendable {
    public var skill: SolverSkill
    public var form: SolverForm
    /// Integer operands. Meaning per skill:
    /// multiplication/division: [a, b]; word problem: the relevant numbers.
    public var operands: [Int]
    /// Fraction operands for the fraction skills: exactly two.
    public var fractions: [SolverFraction]
    /// Word-problem operation. Required for `.wordProblem`.
    public var operation: WordOperation?
    /// Numbers present in the prompt that must be ignored
    /// (form `.irrelevantNumbers`). Never used in computation.
    public var irrelevantValues: [Int]
    /// Passage text for reading questions.
    public var passage: String?
    /// The question as presented to the child.
    public var promptText: String
    public var difficulty: Int
    public var grade: String

    public init(skill: SolverSkill, form: SolverForm = .direct, operands: [Int] = [],
                fractions: [SolverFraction] = [], operation: WordOperation? = nil,
                irrelevantValues: [Int] = [], passage: String? = nil,
                promptText: String = "", difficulty: Int = 1, grade: String = "4") {
        self.skill = skill
        self.form = form
        self.operands = operands
        self.fractions = fractions
        self.operation = operation
        self.irrelevantValues = irrelevantValues
        self.passage = passage
        self.promptText = promptText
        self.difficulty = difficulty
        self.grade = grade
    }
}

public enum SolverRejectionReason: Equatable, Sendable, Error {
    case invalidInput(String)
    case divisionByZero
    case outOfRange(String)
    case unsupportedReadingAnswer
    case missingPassage
}

/// Result of solving a proposal: either the verified answer or a rejection
/// that triggers regeneration / the safe fallback (contract steps 5-6).
public enum SolverOutcome: Equatable, Sendable {
    case verified(verifiedAnswer: String)
    case rejected(SolverRejectionReason)
}

/// A question cleared for presentation. Created only by `SolverService`;
/// `verifiedAnswer` is never taken from model output (contract step 4).
public struct VerifiedQuestion: Equatable, Sendable {
    public let questionId: String
    public let skill: String
    public let formType: SolverForm
    public let promptText: String
    public let verifiedAnswer: String
    public let difficulty: Int
    public let grade: String
}

public enum AnswerVerdict: Equatable, Sendable {
    case correct
    case incorrect(expected: String)
    case invalid(SolverRejectionReason)
}

/// Reading-support verdict (contract step 3). Distinct from correct/incorrect:
/// it states whether the passage supports the answer, with the supporting
/// passage span as evidence when supported.
public enum ReadingSupportVerdict: Equatable, Sendable {
    case supported(evidence: String)
    case unsupported
    case invalid(SolverRejectionReason)
}

public struct SolverService: Sendable {
    public init() {}

    // MARK: - Solve (contract step 2)

    public func solve(_ problem: ProposedProblem) -> SolverOutcome {
        switch problem.skill {
        case .multiplicationFacts:
            guard problem.operands.count == 2 else {
                return .rejected(.invalidInput("multiplication facts need exactly 2 operands"))
            }
            let (a, b) = (problem.operands[0], problem.operands[1])
            guard (0...12).contains(a), (0...12).contains(b) else {
                return .rejected(.outOfRange("multiplication facts are limited to 12x12; got \(a)x\(b)"))
            }
            return .verified(verifiedAnswer: "\(a * b)")

        case .multiDigitMultiplication:
            guard problem.operands.count == 2 else {
                return .rejected(.invalidInput("multi-digit multiplication needs exactly 2 operands"))
            }
            let (a, b) = (problem.operands[0], problem.operands[1])
            guard a >= 0, b >= 0 else {
                return .rejected(.invalidInput("multi-digit multiplication operands must be non-negative"))
            }
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { return .rejected(.outOfRange("product overflows Int")) }
            return .verified(verifiedAnswer: "\(product)")

        case .division:
            guard problem.operands.count == 2 else {
                return .rejected(.invalidInput("division needs exactly 2 operands (dividend, divisor)"))
            }
            let (dividend, divisor) = (problem.operands[0], problem.operands[1])
            guard dividend >= 0 else {
                return .rejected(.invalidInput("dividend must be non-negative"))
            }
            guard divisor != 0 else { return .rejected(.divisionByZero) }
            guard divisor > 0 else {
                return .rejected(.invalidInput("divisor must be positive"))
            }
            let q = dividend / divisor
            let r = dividend % divisor
            return .verified(verifiedAnswer: r == 0 ? "\(q)" : "\(q) r \(r)")

        case .fractionComparison:
            guard problem.fractions.count == 2 else {
                return .rejected(.invalidInput("fraction comparison needs exactly 2 fractions"))
            }
            guard let cmp = problem.fractions[0].compared(to: problem.fractions[1]) else {
                return .rejected(.outOfRange("fraction comparison overflows Int"))
            }
            return .verified(verifiedAnswer: cmp < 0 ? "<" : (cmp > 0 ? ">" : "="))

        case .fractionAddition:
            guard problem.fractions.count == 2 else {
                return .rejected(.invalidInput("fraction addition needs exactly 2 fractions"))
            }
            guard let sum = problem.fractions[0] + problem.fractions[1] else {
                return .rejected(.outOfRange("fraction addition overflows Int"))
            }
            return .verified(verifiedAnswer: sum.description)

        case .wordProblem:
            return solveWordProblem(problem)

        case .readingComprehension:
            // Reading has no computed answer: the answer is verified against
            // the passage by `verifyReadingSupport`. Solving only validates
            // that a passage exists to verify against.
            guard let passage = problem.passage, !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(.missingPassage)
            }
            return .rejected(.invalidInput("reading answers are verified with verifyReadingSupport, not solve"))
        }
    }

    private func solveWordProblem(_ problem: ProposedProblem) -> SolverOutcome {
        guard let operation = problem.operation else {
            return .rejected(.invalidInput("word problem needs an explicit operation"))
        }
        guard problem.operands.count >= 2 else {
            return .rejected(.invalidInput("word problem needs at least 2 operands"))
        }
        guard problem.operands.allSatisfy({ $0 >= 0 }) else {
            return .rejected(.invalidInput("word problem operands must be non-negative"))
        }
        switch operation {
        case .add:
            var total = 0
            for n in problem.operands {
                let (v, o) = total.addingReportingOverflow(n)
                guard !o else { return .rejected(.outOfRange("word problem sum overflows Int")) }
                total = v
            }
            return .verified(verifiedAnswer: "\(total)")
        case .subtract:
            // Left-to-right subtraction; result must stay non-negative.
            var result = problem.operands[0]
            for n in problem.operands.dropFirst() {
                let (v, o) = result.subtractingReportingOverflow(n)
                guard !o, v >= 0 else {
                    return .rejected(.invalidInput("word problem subtraction would go negative"))
                }
                result = v
            }
            return .verified(verifiedAnswer: "\(result)")
        case .multiply:
            guard problem.operands.count == 2 else {
                return .rejected(.invalidInput("word problem multiplication needs exactly 2 operands"))
            }
            let (v, o) = problem.operands[0].multipliedReportingOverflow(by: problem.operands[1])
            guard !o else { return .rejected(.outOfRange("word problem product overflows Int")) }
            return .verified(verifiedAnswer: "\(v)")
        case .divide:
            guard problem.operands.count == 2 else {
                return .rejected(.invalidInput("word problem division needs exactly 2 operands"))
            }
            let (dividend, divisor) = (problem.operands[0], problem.operands[1])
            guard divisor != 0 else { return .rejected(.divisionByZero) }
            let q = dividend / divisor
            let r = dividend % divisor
            return .verified(verifiedAnswer: r == 0 ? "\(q)" : "\(q) r \(r)")
        }
    }

    // MARK: - Verify a proposal into a presentable question (contract step 4)

    /// On success returns the `VerifiedQuestion` that TutorEngine may present.
    /// On failure returns the rejection; the caller regenerates (bounded) or
    /// falls back to a pre-verified safe question. No unverified question is
    /// ever returned.
    public func verify(_ problem: ProposedProblem, questionId: String) -> Result<VerifiedQuestion, SolverRejectionReason> {
        switch solve(problem) {
        case .verified(let answer):
            return .success(VerifiedQuestion(
                questionId: questionId,
                skill: problem.skill.rawValue,
                formType: problem.form,
                promptText: problem.promptText,
                verifiedAnswer: answer,
                difficulty: problem.difficulty,
                grade: problem.grade))
        case .rejected(let reason):
            return .failure(reason)
        }
    }

    // MARK: - Judge an attempt (contract step 7)

    /// Correctness is always judged against the solver-computed answer.
    public func checkAnswer(_ problem: ProposedProblem, proposedAnswer: String) -> AnswerVerdict {
        switch solve(problem) {
        case .rejected(let reason):
            return .invalid(reason)
        case .verified(let expected):
            let given = proposedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !given.isEmpty else { return .incorrect(expected: expected) }
            switch problem.skill {
            case .fractionAddition:
                // Equivalent fractions are the same value: an unreduced
                // correct answer (2/4 for 1/2) is correct, because both
                // sides are normalized before comparison.
                guard let givenFraction = SolverFraction(parsing: given),
                      let expectedFraction = SolverFraction(parsing: expected) else {
                    return .incorrect(expected: expected)
                }
                return givenFraction == expectedFraction ? .correct : .incorrect(expected: expected)
            case .fractionComparison:
                let normalized = given.replacingOccurrences(of: "==", with: "=")
                return normalized == expected ? .correct : .incorrect(expected: expected)
            default:
                return given == expected ? .correct : .incorrect(expected: expected)
            }
        }
    }

    // MARK: - Reading support (contract step 3)

    /// Verifies that `proposedAnswer` is supported by `passage`.
    ///
    /// Deterministic rule, no heuristics: after normalization (lowercase,
    /// collapsed whitespace, trimmed surrounding punctuation) the answer must
    /// appear as a contiguous span of the passage. When supported, the verdict
    /// carries the matching passage span as evidence. An answer that needs
    /// inference, paraphrase, or outside knowledge is unsupported by
    /// definition — the solver cannot confirm it from the passage alone.
    public func verifyReadingSupport(passage: String, proposedAnswer: String) -> ReadingSupportVerdict {
        let cleanPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAnswer = proposedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPassage.isEmpty else { return .invalid(.missingPassage) }
        guard !cleanAnswer.isEmpty else {
            return .invalid(.invalidInput("reading answer must not be empty"))
        }
        let normalizedPassage = Self.normalizeForSupport(cleanPassage)
        let normalizedAnswer = Self.normalizeForSupport(cleanAnswer)
        guard !normalizedAnswer.isEmpty else {
            return .invalid(.invalidInput("reading answer has no checkable content"))
        }
        guard normalizedPassage.contains(normalizedAnswer) else { return .unsupported }
        // Evidence: the first passage sentence containing the answer span,
        // falling back to the matched answer text itself.
        let sentences = cleanPassage.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, Self.normalizeForSupport(trimmed).contains(normalizedAnswer) {
                return .supported(evidence: trimmed)
            }
        }
        return .supported(evidence: cleanAnswer)
    }

    /// Full reading check: support first, then the question-level verdict.
    /// An unsupported answer can never be judged correct.
    public func checkReadingAnswer(passage: String?, proposedAnswer: String) -> ReadingSupportVerdict {
        guard let passage else { return .invalid(.missingPassage) }
        return verifyReadingSupport(passage: passage, proposedAnswer: proposedAnswer)
    }

    static func normalizeForSupport(_ text: String) -> String {
        let lowered = text.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }
}
