import XCTest
@testable import EarnPlayCore

final class SolverServiceTests: XCTestCase {
    private let solver = SolverService()

    private func problem(_ skill: SolverSkill, operands: [Int] = [],
                         fractions: [SolverFraction] = [], operation: WordOperation? = nil,
                         irrelevant: [Int] = [], passage: String? = nil,
                         form: SolverForm = .direct) -> ProposedProblem {
        ProposedProblem(skill: skill, form: form, operands: operands, fractions: fractions,
                        operation: operation, irrelevantValues: irrelevant, passage: passage,
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
}
