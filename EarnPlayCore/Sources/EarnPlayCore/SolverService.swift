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
///    and a candidate answer for reading. For the computed skills the model's
///    own stated answer is never taken as input.
/// 2. `SolverService` computes the correct answer deterministically from the
///    skill, form, and values.
/// 3. For reading, the candidate answer must be supported by the passage text.
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

    private enum CodingKeys: String, CodingKey {
        case numerator, denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int.self, forKey: .numerator)
        let denominator = try container.decode(Int.self, forKey: .denominator)
        guard let fraction = SolverFraction(numerator: numerator, denominator: denominator) else {
            throw DecodingError.dataCorruptedError(
                forKey: .denominator, in: container,
                debugDescription: "Invalid fraction")
        }
        self = fraction
    }

    public init?(numerator: Int, denominator: Int) {
        guard denominator != 0 else { return nil }
        let negative = (numerator < 0) != (denominator < 0)
        var n = numerator.magnitude
        var d = denominator.magnitude
        var a = n, b = d
        while b != 0 { (a, b) = (b, a % b) }
        n /= a
        d /= a
        guard let normalizedDenominator = Int(exactly: d) else { return nil }
        if negative && n == Int.min.magnitude {
            self.numerator = Int.min
        } else {
            guard let normalizedNumerator = Int(exactly: n) else { return nil }
            self.numerator = negative ? -normalizedNumerator : normalizedNumerator
        }
        self.denominator = normalizedDenominator
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

/// Structured problem proposal. For the computed skills the model's stated
/// answer is never a field here: the solver computes the answer itself
/// (contract step 1-2). Reading proposals carry `candidateAnswer`, which the
/// solver only keeps after the passage-support check (step 3).
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
    /// Candidate answer for reading questions. The model proposes it; the
    /// solver validates it against `passage` before anything is presented.
    /// Ignored for every other skill, where the solver computes the answer.
    public var candidateAnswer: String?
    /// The question as presented to the child.
    public var promptText: String
    public var difficulty: Int
    public var grade: String

    public init(skill: SolverSkill, form: SolverForm = .direct, operands: [Int] = [],
                fractions: [SolverFraction] = [], operation: WordOperation? = nil,
                irrelevantValues: [Int] = [], passage: String? = nil,
                candidateAnswer: String? = nil,
                promptText: String = "", difficulty: Int = 1, grade: String = "4") {
        self.skill = skill
        self.form = form
        self.operands = operands
        self.fractions = fractions
        self.operation = operation
        self.irrelevantValues = irrelevantValues
        self.passage = passage
        self.candidateAnswer = candidateAnswer
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
    /// Passage retained for reading questions, so grading and review can
    /// trace the verified answer back to its supporting text.
    public let passage: String?
    /// Structured values this question was verified from. Binds the
    /// question to its original proposal: without these, two different
    /// problems sharing one prompt and answer (6×6 vs 9×4, both 36; 2+2
    /// vs 2×2, both 4) verify to equal questions, so a re-verification
    /// check (`rechecked == question`) would accept a mismatched
    /// question/proposal pair and hint the wrong problem.
    public let sourceOperands: [Int]
    public let sourceFractions: [SolverFraction]
    public let sourceOperation: WordOperation?

    fileprivate init(questionId: String, skill: String, formType: SolverForm,
                     promptText: String, verifiedAnswer: String, difficulty: Int,
                     grade: String, passage: String? = nil,
                     sourceOperands: [Int] = [], sourceFractions: [SolverFraction] = [],
                     sourceOperation: WordOperation? = nil) {
        self.questionId = questionId
        self.skill = skill
        self.formType = formType
        self.promptText = promptText
        self.verifiedAnswer = verifiedAnswer
        self.difficulty = difficulty
        self.grade = grade
        self.passage = passage
        self.sourceOperands = sourceOperands
        self.sourceFractions = sourceFractions
        self.sourceOperation = sourceOperation
    }
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
            // Reading has no computed answer: the proposal carries a
            // candidate answer that must be supported by the passage.
            guard let passage = problem.passage, !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(.missingPassage)
            }
            guard let candidate = problem.candidateAnswer,
                  !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(.invalidInput("reading proposal needs a candidate answer"))
            }
            switch verifyReadingSupport(passage: passage, proposedAnswer: candidate) {
            case .supported:
                return .verified(verifiedAnswer: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
            case .unsupported:
                return .rejected(.unsupportedReadingAnswer)
            case .invalid(let reason):
                return .rejected(reason)
            }
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
                grade: problem.grade,
                passage: problem.passage,
                sourceOperands: problem.operands,
                sourceFractions: problem.fractions,
                sourceOperation: problem.operation))
        case .rejected(let reason):
            return .failure(reason)
        }
    }

    // MARK: - Judge an attempt (contract step 7)

    /// Correctness is always judged against the solver-computed answer.
    /// For reading, the solver-computed answer is the candidate that
    /// `verifyReadingSupport` confirmed against the passage.
    public func checkAnswer(_ problem: ProposedProblem, proposedAnswer: String) -> AnswerVerdict {
        switch solve(problem) {
        case .rejected(let reason):
            return .invalid(reason)
        case .verified(let expected):
            return grade(given: proposedAnswer, expected: expected, skill: problem.skill)
        }
    }

    /// Grades an attempt against a question that already passed `verify`.
    public func checkAnswer(_ question: VerifiedQuestion, proposedAnswer: String) -> AnswerVerdict {
        grade(given: proposedAnswer, expected: question.verifiedAnswer,
              skill: SolverSkill(rawValue: question.skill))
    }

    private func grade(given rawGiven: String, expected: String, skill: SolverSkill?) -> AnswerVerdict {
        let given = rawGiven.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty else { return .incorrect(expected: expected) }
        switch skill {
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
        case .readingComprehension:
            // Reading answers match on normalized text (case and
            // punctuation do not change the answer's meaning).
            return Self.normalizeForSupport(given) == Self.normalizeForSupport(expected)
                ? .correct : .incorrect(expected: expected)
        default:
            return given == expected ? .correct : .incorrect(expected: expected)
        }
    }

    // MARK: - Reading support (contract step 3)

    /// Verifies that `proposedAnswer` is supported by `passage`.
    ///
    /// Deterministic rule, no heuristics: after normalization (lowercase,
    /// collapsed whitespace, trimmed surrounding punctuation) the answer must
    /// appear as a whole-token span of the passage, inside a single passage
    /// sentence. When supported, the verdict carries that sentence as
    /// evidence. An answer that needs inference, paraphrase, or outside
    /// knowledge is unsupported by definition — the solver cannot confirm
    /// it from the passage alone.
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
        let answerSpan = " \(normalizedAnswer) "
        guard " \(normalizedPassage) ".contains(answerSpan) else { return .unsupported }
        // Evidence: the first passage sentence containing the complete answer span.
        for sentence in Self.passageSentences(cleanPassage) {
            if " \(Self.normalizeForSupport(sentence)) ".contains(answerSpan) {
                return .supported(evidence: sentence)
            }
        }
        return .unsupported
    }

    /// Splits a passage into sentences without dropping punctuation.
    /// A boundary is a terminator (`.`, `!`, `?`) followed by whitespace
    /// or the end of the passage; closing quotes/brackets after a
    /// terminator stay with their sentence. Periods inside a sentence —
    /// decimals and unambiguous abbreviations — are not boundaries, and
    /// commas, quotes, apostrophes, and other internal punctuation are
    /// kept verbatim in the returned sentences. A line break is not by
    /// itself a boundary: it is whitespace unless a sentence terminator
    /// (`.`, `!`, `?`) establishes a boundary. An abbreviation period is
    /// suppressed only in unambiguous context — a lowercase or numeric
    /// continuation, a numeric label (`Fig.`/`No.`/`Vol.`) before a
    /// digit, or a capitalized title before a proper name. Sentence-
    /// final ordinary words (`no`, `fig`, `rep`, …) are boundaries.
    static func passageSentences(_ passage: String) -> [String] {
        let abbreviations: Set<String> = [
            "dr", "mr", "mrs", "ms", "st", "jr", "sr", "prof", "sgt",
            "capt", "lt", "gen", "sen", "rep", "gov", "fig", "no", "vol",
        ]
        let titles: Set<String> = [
            "dr", "mr", "mrs", "ms", "prof", "sgt", "capt", "lt", "gen", "sen", "rep", "gov",
        ]
        let numericLabels: Set<String> = ["fig", "no", "vol"]
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}"]
        let chars = Array(passage)
        var sentences: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" || c == "\r" {
                current.append(" ")
                i += 1
                continue
            }
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, closers.contains(chars[j]) { j += 1 }
                let atEnd = j >= chars.count
                if atEnd || chars[j].isWhitespace {
                    var isInternalPeriod = false
                    if c == "." {
                        let token = current.dropLast()
                            .split(whereSeparator: { !$0.isLetter })
                            .last.map(String.init) ?? ""
                        let word = token.lowercased()
                        if abbreviations.contains(word) {
                            var k = j
                            while k < chars.count, chars[k].isWhitespace { k += 1 }
                            let next = k < chars.count ? chars[k] : nil
                            if let next, next.isLowercase {
                                isInternalPeriod = true
                            } else if let next, next.isNumber,
                                      numericLabels.contains(word),
                                      token.first?.isUppercase == true {
                                isInternalPeriod = true
                            } else if let next, next.isUppercase,
                                      token.first?.isUppercase == true,
                                      titles.contains(word) {
                                isInternalPeriod = true
                            }
                        }
                    }
                    if !isInternalPeriod {
                        for k in (i + 1)..<j { current.append(chars[k]) }
                        flush()
                        i = j
                        continue
                    }
                }
            }
            i += 1
        }
        flush()
        return sentences
    }

    /// Full reading check: support first, then the question-level verdict.
    /// An unsupported answer can never be judged correct.
    public func checkReadingAnswer(passage: String?, proposedAnswer: String) -> ReadingSupportVerdict {
        guard let passage else { return .invalid(.missingPassage) }
        return verifyReadingSupport(passage: passage, proposedAnswer: proposedAnswer)
    }

    /// Lowercases and tokenizes on non-alphanumeric boundaries, keeping
    /// numeric punctuation inside a number: `2.5` stays one token (never
    /// `2 5` or `25`), `1/2` stays one token, and a thousands comma is
    /// dropped only when the complete token is a valid thousands-grouped
    /// number (`1,000` becomes `1000`, `1,000,000` becomes `1000000`).
    /// Commas that are not valid thousands separators are token
    /// boundaries (`1,2,3` becomes `1 2 3`, never `123`). Distinct
    /// numbers therefore never conflate during support checks or
    /// reading grading.
    static func normalizeForSupport(_ text: String) -> String {
        let chars = Array(text.lowercased())
        var rawTokens: [String] = []
        var current = ""
        func flushToken() {
            if !current.isEmpty { rawTokens.append(current) }
            current = ""
        }
        for index in chars.indices {
            let c = chars[index]
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if (c == "." || c == "/" || c == ","),
                      current.last?.isNumber == true,
                      index + 1 < chars.count, chars[index + 1].isNumber {
                current.append(c)
            } else {
                flushToken()
            }
        }
        flushToken()
        var tokens: [String] = []
        for token in rawTokens {
            if token.contains(",") {
                if Self.isThousandsGroupedNumber(token) {
                    tokens.append(token.filter { $0 != "," })
                } else {
                    tokens.append(contentsOf: token.split(separator: ",")
                        .map(String.init).filter { !$0.isEmpty })
                }
            } else {
                tokens.append(token)
            }
        }
        return tokens.joined(separator: " ")
    }

    /// True only for a complete thousands-grouped number: a leading
    /// group of 1-3 digits, then one or more groups of exactly 3
    /// digits, with an optional decimal fraction (`1,000`, `1,000.5`).
    static func isThousandsGroupedNumber(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isNumber }) else { return false }
        }
        let groups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count >= 2 else { return false }
        guard groups[0].count >= 1, groups[0].count <= 3,
              groups[0].allSatisfy({ $0.isNumber }) else { return false }
        for group in groups.dropFirst() {
            guard group.count == 3, group.allSatisfy({ $0.isNumber }) else { return false }
        }
        return true
    }
}
