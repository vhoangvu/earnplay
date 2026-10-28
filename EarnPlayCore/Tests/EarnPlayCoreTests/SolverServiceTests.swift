import XCTest
@testable import EarnPlayCore

final class SolverServiceTests: XCTestCase {
    private let solver = SolverService()

    private func problem(_ skill: SolverSkill, operands: [Int] = [],
                         fractions: [SolverFraction] = [], operation: WordOperation? = nil,
                         irrelevant: [Int] = [], passage: String? = nil,
                         candidate: String? = nil,
                         form: SolverForm = .direct) -> ProposedProblem {
        ProposedProblem(skill: skill, form: form, operands: operands, fractions: fractions,
                        operation: operation, irrelevantValues: irrelevant, passage: passage,
                        candidateAnswer: candidate,
                        promptText: "test prompt")
    }

    private func frac(_ n: Int, _ d: Int) -> SolverFraction {
        let f = SolverFraction(numerator: n, denominator: d)
        XCTAssertNotNil(f)
        return f!
    }

    // MARK: Multiplication facts to 12x12

    func testMultiplicationFactCorrect() {
        let p = problem(.multiplicationFacts, operands: [7, 8])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "56"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "56"), .correct)
    }

    func testMultiplicationFactIncorrect() {
        let p = problem(.multiplicationFacts, operands: [7, 8])
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "54"), .incorrect(expected: "56"))
    }

    func testMultiplicationFactBoundary12x12() {
        let p = problem(.multiplicationFacts, operands: [12, 12])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "144"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "144"), .correct)
    }

    func testMultiplicationFactBeyond12Rejected() {
        let p = problem(.multiplicationFacts, operands: [13, 3])
        guard case .rejected(.outOfRange) = solver.solve(p) else {
            return XCTFail("13x3 must be rejected for facts skill, got \(solver.solve(p))")
        }
    }

    func testMultiplicationFactWrongOperandCountInvalid() {
        let p = problem(.multiplicationFacts, operands: [5])
        guard case .rejected(.invalidInput) = solver.solve(p) else {
            return XCTFail("single operand must be invalid")
        }
        guard case .invalid(.invalidInput) = solver.checkAnswer(p, proposedAnswer: "5") else {
            return XCTFail("checkAnswer must surface invalid input")
        }
    }

    // MARK: Multi-digit multiplication

    func testMultiDigitMultiplicationCorrect() {
        let p = problem(.multiDigitMultiplication, operands: [123, 45])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "5535"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "5535"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "5534"), .incorrect(expected: "5535"))
    }

    func testMultiDigitMultiplicationNegativeRejected() {
        let p = problem(.multiDigitMultiplication, operands: [-3, 40])
        guard case .rejected(.invalidInput) = solver.solve(p) else {
            return XCTFail("negative operand must be invalid")
        }
    }

    // MARK: Division

    func testDivisionExactCorrect() {
        let p = problem(.division, operands: [144, 12])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "12"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "12"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "11"), .incorrect(expected: "12"))
    }

    func testDivisionWithRemainder() {
        let p = problem(.division, operands: [17, 5])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "3 r 2"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "3 r 2"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "3"), .incorrect(expected: "3 r 2"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "3 r 1"), .incorrect(expected: "3 r 2"))
    }

    func testDivisionByZeroRejected() {
        let p = problem(.division, operands: [10, 0])
        XCTAssertEqual(solver.solve(p), .rejected(.divisionByZero))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "0"), .invalid(.divisionByZero))
    }

    // MARK: Fractions

    func testFractionNormalization() {
        XCTAssertEqual(frac(2, 4), frac(1, 2))
        XCTAssertEqual(frac(3, -6), frac(-1, 2))
        XCTAssertEqual(frac(0, 7).description, "0")
        XCTAssertNil(SolverFraction(numerator: 1, denominator: 0))
        XCTAssertNil(SolverFraction(parsing: "1/0"))
        XCTAssertNil(SolverFraction(parsing: "abc"))
    }

    func testFractionComparison() {
        let less = problem(.fractionComparison, fractions: [frac(1, 3), frac(1, 2)])
        XCTAssertEqual(solver.solve(less), .verified(verifiedAnswer: "<"))
        XCTAssertEqual(solver.checkAnswer(less, proposedAnswer: "<"), .correct)
        XCTAssertEqual(solver.checkAnswer(less, proposedAnswer: ">"), .incorrect(expected: "<"))

        let equal = problem(.fractionComparison, fractions: [frac(2, 4), frac(1, 2)])
        XCTAssertEqual(solver.solve(equal), .verified(verifiedAnswer: "="))
        XCTAssertEqual(solver.checkAnswer(equal, proposedAnswer: "="), .correct)

        let greater = problem(.fractionComparison, fractions: [frac(3, 4), frac(1, 2)])
        XCTAssertEqual(solver.solve(greater), .verified(verifiedAnswer: ">"))
    }

    func testFractionAdditionReducedResult() {
        let p = problem(.fractionAddition, fractions: [frac(1, 4), frac(1, 4)])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "1/2"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "1/2"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "1/3"), .incorrect(expected: "1/2"))
    }

    func testFractionAdditionUnreducedAnswerAcceptedAsSameValue() {
        // 2/4 and 1/2 are the same value; both normalize to 1/2.
        let p = problem(.fractionAddition, fractions: [frac(1, 4), frac(1, 4)])
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "2/4"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "4/8"), .correct)
    }

    func testFractionAdditionWholeNumberResult() {
        let p = problem(.fractionAddition, fractions: [frac(1, 2), frac(1, 2)])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "1"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "1"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "2/2"), .correct)
    }

    func testFractionWrongCountInvalid() {
        let p = problem(.fractionAddition, fractions: [frac(1, 2)])
        guard case .rejected(.invalidInput) = solver.solve(p) else {
            return XCTFail("one fraction must be invalid for addition")
        }
    }

    // MARK: Word problems

    func testWordProblemMultiply() {
        let p = problem(.wordProblem, operands: [6, 7], operation: .multiply, form: .story)
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "42"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "42"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "41"), .incorrect(expected: "42"))
    }

    func testWordProblemAddAndSubtract() {
        let add = problem(.wordProblem, operands: [15, 27], operation: .add, form: .story)
        XCTAssertEqual(solver.solve(add), .verified(verifiedAnswer: "42"))
        let sub = problem(.wordProblem, operands: [50, 18], operation: .subtract, form: .story)
        XCTAssertEqual(solver.solve(sub), .verified(verifiedAnswer: "32"))
    }

    func testWordProblemIrrelevantNumbersIgnored() {
        // Prompt mentions 99 stickers as a distraction; solver uses only operands.
        let p = problem(.wordProblem, operands: [4, 5], operation: .multiply,
                        irrelevant: [99], form: .irrelevantNumbers)
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "20"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "20"), .correct)
    }

    func testWordProblemMissingOperationInvalid() {
        let p = problem(.wordProblem, operands: [4, 5])
        guard case .rejected(.invalidInput) = solver.solve(p) else {
            return XCTFail("word problem without operation must be invalid")
        }
    }

    func testWordProblemDivisionByZero() {
        let p = problem(.wordProblem, operands: [10, 0], operation: .divide)
        XCTAssertEqual(solver.solve(p), .rejected(.divisionByZero))
    }

    func testWordProblemNegativeSubtractionRejected() {
        let p = problem(.wordProblem, operands: [3, 10], operation: .subtract)
        guard case .rejected(.invalidInput) = solver.solve(p) else {
            return XCTFail("negative subtraction result must be invalid")
        }
    }

    // MARK: Verify -> VerifiedQuestion (contract step 4)

    func testVerifyCreatesQuestionWithSolverAnswer() {
        let p = problem(.multiplicationFacts, operands: [9, 6])
        let result = solver.verify(p, questionId: "q1")
        guard case .success(let q) = result else { return XCTFail("expected success") }
        XCTAssertEqual(q.verifiedAnswer, "54")
        XCTAssertEqual(q.questionId, "q1")
        XCTAssertEqual(q.grade, "4")
    }

    func testVerifyRejectsBadProposal() {
        let p = problem(.division, operands: [1, 0])
        let result = solver.verify(p, questionId: "q2")
        guard case .failure(.divisionByZero) = result else {
            return XCTFail("expected divisionByZero failure, got \(result)")
        }
    }

    // MARK: Reading support (contract step 3)

    private let passage = "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. After three weeks, the first green sprout appeared."

    func testReadingSupportedAnswerWithEvidence() {
        let verdict = solver.verifyReadingSupport(passage: passage, proposedAnswer: "twelve sunflower seeds")
        guard case .supported(let evidence) = verdict else {
            return XCTFail("expected supported, got \(verdict)")
        }
        XCTAssertTrue(evidence.contains("sunflower"), "evidence must be the passage span, got: \(evidence)")
    }

    func testReadingSupportedCaseAndPunctuationInsensitive() {
        let verdict = solver.verifyReadingSupport(passage: passage, proposedAnswer: "Three Weeks")
        guard case .supported = verdict else {
            return XCTFail("case-insensitive supported answer expected, got \(verdict)")
        }
    }

    func testReadingUnsupportedAnswer() {
        let verdict = solver.verifyReadingSupport(passage: passage, proposedAnswer: "Maya planted roses")
        XCTAssertEqual(verdict, .unsupported)
    }

    func testReadingUnsupportedInventedDetail() {
        let verdict = solver.verifyReadingSupport(passage: passage, proposedAnswer: "twenty sunflower seeds")
        XCTAssertEqual(verdict, .unsupported)
    }

    func testReadingEmptyAnswerInvalid() {
        let verdict = solver.verifyReadingSupport(passage: passage, proposedAnswer: "  ")
        guard case .invalid = verdict else {
            return XCTFail("empty answer must be invalid, got \(verdict)")
        }
    }

    func testReadingMissingPassageInvalid() {
        XCTAssertEqual(solver.checkReadingAnswer(passage: nil, proposedAnswer: "twelve"),
                       .invalid(.missingPassage))
        let empty = solver.verifyReadingSupport(passage: "  ", proposedAnswer: "twelve")
        XCTAssertEqual(empty, .invalid(.missingPassage))
    }

    func testReadingSolveRequiresPassage() {
        let noPassage = problem(.readingComprehension)
        XCTAssertEqual(solver.solve(noPassage), .rejected(.missingPassage))
    }

    // MARK: Invalid / edge inputs

    func testEmptyProposedAnswerIncorrectNotCrash() {
        let p = problem(.multiplicationFacts, operands: [3, 3])
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: ""), .incorrect(expected: "9"))
    }

    func testSolverIsDeterministic() {
        let p = problem(.fractionAddition, fractions: [frac(1, 6), frac(1, 3)])
        XCTAssertEqual(solver.solve(p), solver.solve(p))
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "1/2"))
    }

    // MARK: Finding 1 — decoding goes through the validating initializer

    func testDecodedFractionNormalizesNegativeDenominator() throws {
        let json = "{\"numerator\":1,\"denominator\":-2}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SolverFraction.self, from: json)
        XCTAssertEqual(decoded.numerator, -1)
        XCTAssertEqual(decoded.denominator, 2)
        XCTAssertEqual(decoded, frac(-1, 2))
        // -1/2 < 1/3: the decoded value must compare correctly.
        XCTAssertEqual(decoded.compared(to: frac(1, 3)), -1)
    }

    func testDecodedFractionReduces() throws {
        let json = "{\"numerator\":2,\"denominator\":4}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SolverFraction.self, from: json)
        XCTAssertEqual(decoded, frac(1, 2))
    }

    func testDecodedFractionZeroDenominatorThrows() {
        let json = "{\"numerator\":1,\"denominator\":0}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SolverFraction.self, from: json))
    }

    // MARK: Finding 2 — Int.min normalization never traps

    func testFractionIntMinOverMinusOneIsNil() {
        // Int.min / -1 would be Int.max + 1, which is not representable.
        XCTAssertNil(SolverFraction(numerator: Int.min, denominator: -1))
    }

    func testFractionIntMinDenominatorIsNil() {
        XCTAssertNil(SolverFraction(numerator: 1, denominator: Int.min))
    }

    func testFractionIntMinOverOneNormalizes() {
        let f = SolverFraction(numerator: Int.min, denominator: 1)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.numerator, Int.min)
        XCTAssertEqual(f?.denominator, 1)
    }

    func testFractionOrdinaryNegativesStillNormalize() {
        XCTAssertEqual(frac(6, -8).numerator, -3)
        XCTAssertEqual(frac(6, -8).denominator, 4)
        XCTAssertEqual(frac(-3, -6), frac(1, 2))
        XCTAssertEqual(frac(0, -7).description, "0")
    }

    func testFractionAdditionIntMinAnswerDoesNotCrash() {
        let p = problem(.fractionAddition, fractions: [frac(1, 2), frac(0, 1)])
        XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: "1/2"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "-9223372036854775808/1"),
                       .incorrect(expected: "1/2"))
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "-9223372036854775808/-1"),
                       .incorrect(expected: "1/2"))
    }

    // MARK: Finding 3 — reading proposals verify and grade

    func testReadingVerifySupportedCreatesQuestionWithAnswerAndPassage() {
        let p = problem(.readingComprehension, passage: passage,
                        candidate: "twelve sunflower seeds")
        let result = solver.verify(p, questionId: "r1")
        guard case .success(let q) = result else {
            return XCTFail("supported reading answer must verify, got \(result)")
        }
        XCTAssertEqual(q.verifiedAnswer, "twelve sunflower seeds")
        XCTAssertEqual(q.passage, passage)
        XCTAssertEqual(q.skill, SolverSkill.readingComprehension.rawValue)
    }

    func testReadingCheckAnswerGradesAgainstValidatedAnswer() {
        let p = problem(.readingComprehension, passage: passage,
                        candidate: "twelve sunflower seeds")
        guard case .success(let q) = solver.verify(p, questionId: "r2") else {
            return XCTFail("supported reading answer must verify")
        }
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "twelve sunflower seeds"), .correct)
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "three weeks"),
                       .incorrect(expected: "twelve sunflower seeds"))
        XCTAssertEqual(solver.checkAnswer(q, proposedAnswer: "twelve sunflower seeds"), .correct)
        XCTAssertEqual(solver.checkAnswer(q, proposedAnswer: "twelve roses"),
                       .incorrect(expected: "twelve sunflower seeds"))
    }

    func testReadingVerifyUnsupportedDoesNotVerify() {
        let p = problem(.readingComprehension, passage: passage,
                        candidate: "Maya planted roses")
        let result = solver.verify(p, questionId: "r3")
        guard case .failure(.unsupportedReadingAnswer) = result else {
            return XCTFail("unsupported reading answer must not verify, got \(result)")
        }
        XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: "Maya planted roses"),
                       .invalid(.unsupportedReadingAnswer))
    }

    func testReadingVerifyMissingPassageRejects() {
        let p = problem(.readingComprehension, candidate: "twelve")
        guard case .failure(.missingPassage) = solver.verify(p, questionId: "r4") else {
            return XCTFail("missing passage must reject as missingPassage")
        }
    }

    func testReadingVerifyMissingCandidateRejects() {
        let p = problem(.readingComprehension, passage: passage)
        guard case .failure(.invalidInput) = solver.verify(p, questionId: "r5") else {
            return XCTFail("reading proposal without a candidate answer must be invalid")
        }
    }

    // MARK: Findings 4-5 — whole-token support and supporting sentences

    func testReadingPartialWordNotSupported() {
        let verdict = solver.verifyReadingSupport(
            passage: "Maya planted sixteen seeds.", proposedAnswer: "six")
        XCTAssertEqual(verdict, .unsupported)
    }

    func testReadingWholeTokenSupported() {
        let verdict = solver.verifyReadingSupport(
            passage: "Maya planted sixteen seeds.", proposedAnswer: "sixteen")
        guard case .supported = verdict else {
            return XCTFail("whole token must be supported, got \(verdict)")
        }
    }

    func testReadingMultiWordNeedsFullSpanWithBoundaries() {
        let p = "Maya planted sixteen seeds in the garden."
        guard case .supported = solver.verifyReadingSupport(
            passage: p, proposedAnswer: "sixteen seeds") else {
            return XCTFail("full multi-word span must be supported")
        }
        XCTAssertEqual(solver.verifyReadingSupport(passage: p, proposedAnswer: "teen seeds"),
                       .unsupported)
        XCTAssertEqual(solver.verifyReadingSupport(passage: p, proposedAnswer: "sixteen seed"),
                       .unsupported)
    }

    func testReadingCrossSentenceAnswerUnsupported() {
        let verdict = solver.verifyReadingSupport(
            passage: "Maya planted seeds. Birds ate them.", proposedAnswer: "seeds birds")
        XCTAssertEqual(verdict, .unsupported)
    }
}

// MARK: - Finding 6 acceptance coverage (issue #3)
//
// Every expected value below is a literal computed by hand (cross-checked
// against Swift/Python integer and fraction arithmetic, never by calling
// the solver under test).

final class SolverAcceptanceTests: XCTestCase {
    private let solver = SolverService()

    private func frac(_ n: Int, _ d: Int) -> SolverFraction {
        let f = SolverFraction(numerator: n, denominator: d)
        XCTAssertNotNil(f)
        return f!
    }

    func testHandComputedFiftyProblemBank() {
        // Multiplication facts (8)
        let facts: [(Int, Int, String)] = [
            (6, 7, "42"), (9, 9, "81"), (3, 8, "24"), (12, 5, "60"),
            (0, 11, "0"), (11, 11, "121"), (4, 9, "36"), (8, 7, "56"),
        ]
        for (a, b, expected) in facts {
            let p = ProposedProblem(skill: .multiplicationFacts, operands: [a, b], promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected), "\(a)x\(b)")
        }

        // Multi-digit multiplication (8)
        let multiDigit: [(Int, Int, String)] = [
            (23, 4, "92"), (15, 12, "180"), (101, 9, "909"), (25, 25, "625"),
            (300, 40, "12000"), (17, 6, "102"), (99, 11, "1089"), (123, 3, "369"),
        ]
        for (a, b, expected) in multiDigit {
            let p = ProposedProblem(skill: .multiDigitMultiplication, operands: [a, b], promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected), "\(a)x\(b)")
        }

        // Division (7)
        let division: [(Int, Int, String)] = [
            (96, 8, "12"), (100, 4, "25"), (29, 6, "4 r 5"), (7, 7, "1"),
            (0, 9, "0"), (250, 10, "25"), (53, 8, "6 r 5"),
        ]
        for (a, b, expected) in division {
            let p = ProposedProblem(skill: .division, operands: [a, b], promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected), "\(a)/\(b)")
        }

        // Fraction comparison (7)
        let comparisons: [((Int, Int), (Int, Int), String)] = [
            ((1, 2), (1, 3), ">"), ((2, 5), (3, 5), "<"), ((3, 6), (1, 2), "="),
            ((5, 8), (1, 2), ">"), ((1, 4), (3, 4), "<"), ((7, 7), (1, 1), "="),
            ((2, 3), (3, 4), "<"),
        ]
        for (lhs, rhs, expected) in comparisons {
            let p = ProposedProblem(skill: .fractionComparison,
                                    fractions: [frac(lhs.0, lhs.1), frac(rhs.0, rhs.1)],
                                    promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected),
                           "\(lhs) vs \(rhs)")
        }

        // Fraction addition (7)
        let additions: [((Int, Int), (Int, Int), String)] = [
            ((1, 2), (1, 3), "5/6"), ((1, 4), (1, 4), "1/2"), ((2, 3), (1, 6), "5/6"),
            ((1, 5), (2, 5), "3/5"), ((3, 4), (1, 4), "1"), ((1, 8), (3, 8), "1/2"),
            ((5, 6), (1, 6), "1"),
        ]
        for (lhs, rhs, expected) in additions {
            let p = ProposedProblem(skill: .fractionAddition,
                                    fractions: [frac(lhs.0, lhs.1), frac(rhs.0, rhs.1)],
                                    promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected),
                           "\(lhs) + \(rhs)")
        }

        // Word problems (6)
        let words: [([Int], WordOperation, String)] = [
            ([34, 58], .add, "92"), ([90, 37], .subtract, "53"),
            ([13, 5], .multiply, "65"), ([84, 7], .divide, "12"),
            ([10, 20, 12], .add, "42"), ([23, 4], .divide, "5 r 3"),
        ]
        for (operands, operation, expected) in words {
            let p = ProposedProblem(skill: .wordProblem, operands: operands,
                                    operation: operation, promptText: "bank")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected),
                           "\(operands) \(operation)")
        }

        // Reading (7): supported answers verify; unsupported ones do not.
        let maya = "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. After three weeks, the first green sprout appeared."
        let reading: [(String, String, Bool)] = [
            (maya, "twelve sunflower seeds", true),
            (maya, "three weeks", true),
            (maya, "Maya planted roses", false),
            ("Tom has sixteen apples. He gave four to Ana.", "sixteen", true),
            ("Tom has sixteen apples. He gave four to Ana.", "six", false),
            ("Maya planted seeds. Birds ate them.", "seeds birds", false),
            ("The quick brown fox jumps over the lazy dog.", "brown fox jumps", true),
        ]
        for (passageText, candidate, supported) in reading {
            let verdict = solver.verifyReadingSupport(passage: passageText, proposedAnswer: candidate)
            if supported {
                guard case .supported = verdict else {
                    XCTFail("'\(candidate)' must be supported, got \(verdict)")
                    continue
                }
                let p = ProposedProblem(skill: .readingComprehension, passage: passageText,
                                        candidateAnswer: candidate, promptText: "bank")
                guard case .success(let q) = solver.verify(p, questionId: "bank") else {
                    XCTFail("'\(candidate)' must verify")
                    continue
                }
                XCTAssertEqual(q.verifiedAnswer, candidate)
                XCTAssertEqual(q.passage, passageText)
            } else {
                XCTAssertEqual(verdict, .unsupported, "'\(candidate)' must be unsupported")
            }
        }

        let counts = [facts.count, multiDigit.count, division.count, comparisons.count,
                      additions.count, words.count, reading.count]
        XCTAssertTrue(counts.allSatisfy { $0 >= 5 }, "each skill needs at least 5 cases: \(counts)")
        XCTAssertEqual(counts.reduce(0, +), 50)
    }

    func testTwentyWrongAnswersRejected() {
        // (problem, wrong answer, hand-computed correct answer)
        let cases: [(ProposedProblem, String, String)] = [
            (ProposedProblem(skill: .multiplicationFacts, operands: [7, 8]), "54", "56"),
            (ProposedProblem(skill: .multiplicationFacts, operands: [9, 9]), "80", "81"),
            (ProposedProblem(skill: .multiplicationFacts, operands: [3, 8]), "25", "24"),
            (ProposedProblem(skill: .multiDigitMultiplication, operands: [23, 4]), "91", "92"),
            (ProposedProblem(skill: .multiDigitMultiplication, operands: [15, 12]), "170", "180"),
            (ProposedProblem(skill: .multiDigitMultiplication, operands: [25, 25]), "525", "625"),
            (ProposedProblem(skill: .division, operands: [96, 8]), "11", "12"),
            (ProposedProblem(skill: .division, operands: [29, 6]), "4 r 4", "4 r 5"),
            (ProposedProblem(skill: .division, operands: [53, 8]), "6", "6 r 5"),
            (ProposedProblem(skill: .fractionComparison, fractions: [frac(1, 2), frac(1, 3)]), "<", ">"),
            (ProposedProblem(skill: .fractionComparison, fractions: [frac(2, 5), frac(3, 5)]), "=", "<"),
            (ProposedProblem(skill: .fractionComparison, fractions: [frac(2, 3), frac(3, 4)]), ">", "<"),
            (ProposedProblem(skill: .fractionAddition, fractions: [frac(1, 2), frac(1, 3)]), "2/5", "5/6"),
            (ProposedProblem(skill: .fractionAddition, fractions: [frac(1, 4), frac(1, 4)]), "1/3", "1/2"),
            (ProposedProblem(skill: .fractionAddition, fractions: [frac(3, 4), frac(1, 4)]), "3/4", "1"),
            (ProposedProblem(skill: .wordProblem, operands: [34, 58], operation: .add), "91", "92"),
            (ProposedProblem(skill: .wordProblem, operands: [90, 37], operation: .subtract), "54", "53"),
            (ProposedProblem(skill: .wordProblem, operands: [13, 5], operation: .multiply), "64", "65"),
            (ProposedProblem(skill: .readingComprehension,
                             passage: "Tom has sixteen apples. He gave four to Ana.",
                             candidateAnswer: "sixteen"), "six", "sixteen"),
            (ProposedProblem(skill: .readingComprehension,
                             passage: "Maya planted twelve sunflower seeds in the garden.",
                             candidateAnswer: "twelve sunflower seeds"), "twelve roses",
             "twelve sunflower seeds"),
        ]
        XCTAssertEqual(cases.count, 20)
        for (problem, wrong, expected) in cases {
            XCTAssertEqual(solver.checkAnswer(problem, proposedAnswer: wrong),
                           .incorrect(expected: expected),
                           "'\(wrong)' must be rejected for \(problem.skill)")
        }
    }

    func testFiveHundredMultiplicationPairsAgainstPrimitiveProduct() {
        // Swift's built-in integer multiplication is the independent oracle.
        for i in 0..<500 {
            let a = (i * 37) % 900 + 10
            let b = (i * 53) % 90 + 2
            let expected = "\(a * b)"
            let p = ProposedProblem(skill: .multiDigitMultiplication, operands: [a, b],
                                    promptText: "property")
            XCTAssertEqual(solver.solve(p), .verified(verifiedAnswer: expected), "\(a)x\(b)")
            XCTAssertEqual(solver.checkAnswer(p, proposedAnswer: expected), .correct, "\(a)x\(b)")
        }
    }

    func testTenReadingItems() {
        let maya = "Maya planted twelve sunflower seeds in the garden. Every morning she watered them before school. After three weeks, the first green sprout appeared."
        let items: [(String, String, Bool)] = [
            (maya, "twelve sunflower seeds", true),
            (maya, "Three Weeks", true),
            (maya, "twenty sunflower seeds", false),
            ("Maya planted sixteen seeds.", "six", false),
            ("Maya planted sixteen seeds.", "sixteen", true),
            ("Maya planted seeds. Birds ate them.", "seeds birds", false),
            ("The quick brown fox jumps over the lazy dog.", "brown fox jumps", true),
            ("Tom has sixteen apples. He gave four to Ana.", "gave four", true),
            ("Tom has sixteen apples. He gave four to Ana.", "sixteen apples he", false),
            ("Sara read five books in June. She read three more in July.", "seven books", false),
        ]
        XCTAssertEqual(items.count, 10)
        for (passageText, answer, supported) in items {
            let verdict = solver.verifyReadingSupport(passage: passageText, proposedAnswer: answer)
            if supported {
                guard case .supported(let evidence) = verdict else {
                    XCTFail("'\(answer)' must be supported, got \(verdict)")
                    continue
                }
                XCTAssertFalse(evidence.isEmpty)
            } else {
                XCTAssertEqual(verdict, .unsupported, "'\(answer)' must be unsupported")
            }
        }
    }
}
