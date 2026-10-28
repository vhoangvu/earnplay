import XCTest
@testable import EarnPlayCore

/// T1.2: generation + verification loop. Every presented question in
/// these tests is re-checked against `SolverService` — no test trusts
/// the loop's own word that a question was verified.
final class QuestionGenerationTests: XCTestCase {
    private let solver = SolverService()

    // MARK: - Stubs

    /// Scripted proposer: hands out one scripted step per call, then nil.
    private final class StubProposer: QuestionProposing, @unchecked Sendable {
        enum Step {
            case proposal(ProposedProblem)
            case nothing
            case boom
        }

        private var steps: [Step]
        private(set) var calls = 0
        private(set) var requests: [QuestionGenerationRequest] = []

        init(steps: [Step]) { self.steps = steps }

        func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? {
            calls += 1
            requests.append(request)
            guard !steps.isEmpty else { return nil }
            switch steps.removeFirst() {
            case .proposal(let problem): return problem
            case .nothing: return nil
            case .boom: throw StubError.boom
            }
        }
    }

    private enum StubError: Error { case boom }

    /// Fault-injected proposer for the 100-problem harness, in the shape
    /// of the task-card test (a model stub returning ~30% invalid items):
    /// every 5th question fails on all attempts (forcing the fallback),
    /// every 3rd question fails on its first attempt (forcing a retry),
    /// the rest propose valid varied problems on the first attempt.
    private final class FaultyProposer: QuestionProposing, @unchecked Sendable {
        private(set) var calls = 0
        private var questionIndex = 0

        func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? {
            calls += 1
            if request.attemptNumber == 1 { questionIndex += 1 }
            if questionIndex % 5 == 0 || (request.attemptNumber == 1 && questionIndex % 3 == 0) {
                return ProposedProblem(
                    skill: request.skill, form: .story, operands: [99, 99],
                    promptText: "Broken problem, never show this.")
            }
            let a = (calls % 12) + 1
            let b = ((calls / 3) % 12) + 1
            return ProposedProblem(
                skill: .multiplicationFacts, form: request.formHint ?? .story,
                operands: [a, b],
                promptText: "A stall packs \(a) baskets with \(b) apples in each basket. How many apples in all?")
        }
    }

    private func validFacts(form: SolverForm = .story, a: Int = 7, b: Int = 8) -> ProposedProblem {
        ProposedProblem(
            skill: .multiplicationFacts, form: form, operands: [a, b],
            promptText: "A farmer packs \(a) eggs in each of \(b) cartons. How many eggs in all?")
    }

    private func assertReallyVerified(_ question: VerifiedQuestion,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotEqual(question.formType, .direct, "plain textbook form must never be presented", file: file, line: line)
        XCTAssertFalse(question.promptText.trimmingCharacters(in: .whitespaces).isEmpty,
                       "presented question must have text", file: file, line: line)
        XCTAssertEqual(
            solver.checkAnswer(question, proposedAnswer: question.verifiedAnswer), .correct,
            "presented question must grade correct against its own verified answer",
            file: file, line: line)
    }

    // MARK: - Verification pass path

    func testValidProposalIsVerifiedAndPresentedOnFirstAttempt() throws {
        let stub = StubProposer(steps: [.proposal(validFacts())])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))

        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.attemptsUsed, 1)
        XCTAssertEqual(result.attempts.map(\.outcome), [.verified])
        XCTAssertEqual(result.question.verifiedAnswer, "56")
        XCTAssertEqual(result.question.skill, SolverSkill.multiplicationFacts.rawValue)
        assertReallyVerified(result.question)
    }

    // MARK: - Verification failure -> retry path

    func testSolverRejectionRetriesThenPresentsVerifiedProposal() throws {
        let invalid = ProposedProblem(
            skill: .multiplicationFacts, form: .story, operands: [99, 99],
            promptText: "Way out of range, the solver must reject this.")
        let stub = StubProposer(steps: [.proposal(invalid), .proposal(validFacts(a: 6, b: 7))])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))

        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.attemptsUsed, 2)
        XCTAssertEqual(result.attempts.count, 2)
        guard case .solverRejected = result.attempts[0].outcome else {
            return XCTFail("first attempt must log a solver rejection, got \(result.attempts[0].outcome)")
        }
        XCTAssertEqual(result.attempts[1].outcome, .verified)
        XCTAssertEqual(result.question.verifiedAnswer, "42")
        assertReallyVerified(result.question)
    }

    func testThrowNilMismatchAndTextbookFormAllCountAsFailedAttempts() throws {
        let wrongSkill = ProposedProblem(
            skill: .division, form: .story, operands: [48, 8],
            promptText: "Right shape, wrong skill for this request.")
        let stub = StubProposer(steps: [
            .boom, .nothing, .proposal(wrongSkill),
            .proposal(validFacts(form: .direct)), .proposal(validFacts(form: .reverse, a: 9, b: 6)),
        ])
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 5)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))

        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.attemptsUsed, 5)
        guard case .proposerFailed = result.attempts[0].outcome else {
            return XCTFail("throw must log proposerFailed, got \(result.attempts[0].outcome)")
        }
        XCTAssertEqual(result.attempts[1].outcome, .noProposal)
        XCTAssertEqual(result.attempts[2].outcome, .skillMismatch(proposed: SolverSkill.division.rawValue))
        XCTAssertEqual(result.attempts[3].outcome, .plainTextbookForm)
        XCTAssertEqual(result.attempts[4].outcome, .verified)
        XCTAssertEqual(result.question.verifiedAnswer, "54")
        assertReallyVerified(result.question)
    }

    // MARK: - Retry exhaustion -> fallback path

    func testRetryExhaustionFallsBackToPreVerifiedQuestionForSameSkill() throws {
        let invalid = ProposedProblem(
            skill: .division, form: .story, operands: [10, 0],
            promptText: "Division by zero, never show this.")
        let stub = StubProposer(steps: Array(repeating: .proposal(invalid), count: 10))
        let generator = QuestionGenerator(proposer: stub) // default bound: 3
        let result = try generator.generate(QuestionGenerationRequest(skill: .division))

        XCTAssertEqual(result.source, .fallbackBank)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.attemptsUsed, QuestionGenerator.defaultMaxAttempts)
        XCTAssertEqual(stub.calls, QuestionGenerator.defaultMaxAttempts,
                       "proposer must never be called past the retry bound")
        XCTAssertEqual(result.attempts.count, QuestionGenerator.defaultMaxAttempts)
        XCTAssertTrue(result.attempts.allSatisfy {
            if case .solverRejected(.divisionByZero) = $0.outcome { return true }
            return false
        }, "every logged attempt must be the division-by-zero rejection: \(result.attempts)")
        XCTAssertEqual(result.question.skill, SolverSkill.division.rawValue)
        assertReallyVerified(result.question)
    }

    func testRetryBoundOfOneIsRespected() throws {
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 10))
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))

        XCTAssertEqual(stub.calls, 1)
        XCTAssertEqual(result.attemptsUsed, 1)
        XCTAssertTrue(result.usedFallback)
        assertReallyVerified(result.question)
    }

    func testNoVerifiedFallbackThrowsInsteadOfPresentingAnything() {
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 10))
        let generator = QuestionGenerator(
            proposer: stub, fallbackBank: FallbackQuestionBank(proposals: []), maxAttempts: 2)
        XCTAssertThrowsError(try generator.generate(QuestionGenerationRequest(skill: .division))) { error in
            XCTAssertEqual(error as? QuestionGenerationError,
                           .noVerifiedFallback(skill: SolverSkill.division.rawValue))
        }
    }

    // MARK: - 100-problem harness (task-card automated test shape)

    func testHundredProblemRunWithThirtyPercentFaultInjection() throws {
        let proposer = FaultyProposer()
        let generator = QuestionGenerator(proposer: proposer)
        var fallbackCount = 0
        var formsSeen: Set<SolverForm> = []

        for index in 0..<100 {
            let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
            XCTAssertLessThanOrEqual(result.attemptsUsed, generator.maxAttempts,
                                     "item \(index) exceeded the retry bound")
            XCTAssertEqual(result.attempts.count,
                           result.usedFallback ? generator.maxAttempts : result.attemptsUsed,
                           "item \(index) log must cover every attempt")
            // The acceptance rule: 0 unverified items reach the UI layer.
            assertReallyVerified(result.question)
            formsSeen.insert(result.question.formType)
            if result.usedFallback { fallbackCount += 1 }
        }
        XCTAssertEqual(fallbackCount + (100 - fallbackCount), 100)
        XCTAssertGreaterThan(fallbackCount, 0,
                             "30% fault injection over 100 items must exhaust retries sometimes")
        XCTAssertGreaterThan(proposer.calls, 100, "faults must have caused retries")
    }

    // MARK: - Form variety (no plain textbook form in generated output)

    func testGeneratedQuestionsVaryInFormAndAreNeverTextbook() throws {
        // Proposer follows the loop's rotating form hint, like the real
        // model proposer is prompted to.
        let hintFollower = HintFollowingProposer()
        let generator = QuestionGenerator(proposer: hintFollower)

        var forms: [SolverForm] = []
        for _ in 0..<10 {
            let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
            forms.append(result.question.formType)
            assertReallyVerified(result.question)
        }
        XCTAssertFalse(forms.contains(.direct), "no plain textbook form may be generated: \(forms)")
        XCTAssertGreaterThanOrEqual(Set(forms).count, 3,
                                    "at least 3 different forms must appear, got \(forms)")
    }

    private final class HintFollowingProposer: QuestionProposing, @unchecked Sendable {
        func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? {
            ProposedProblem(
                skill: request.skill, form: request.formHint ?? .story, operands: [7, 8],
                promptText: "Seven shelves hold 8 books each in the library corner. How many books in all?")
        }
    }

    // MARK: - Fallback bank

    func testFallbackBankCoversEverySkillAndEveryEntryIsSolverVerified() {
        let bank = FallbackQuestionBank.demo
        XCTAssertEqual(bank.skillsCovered, Set(SolverSkill.allCases),
                       "fallback bank must cover every diagnostic skill area")
        XCTAssertGreaterThanOrEqual(bank.entries.count, SolverSkill.allCases.count * 2)
        for entry in bank.entries {
            guard case .verified(let answer) = solver.solve(entry) else {
                return XCTFail("bank entry must verify: \(entry.skill) \(entry.promptText)")
            }
            XCTAssertNotEqual(entry.form, .direct)
            XCTAssertFalse(entry.promptText.isEmpty)
            _ = answer
        }
        // Hand-checked answers for one entry per skill.
        XCTAssertEqual(solver.solve(bank.entries(for: .multiplicationFacts)[0]),
                       .verified(verifiedAnswer: "56"))
        XCTAssertEqual(solver.solve(bank.entries(for: .division)[1]),
                       .verified(verifiedAnswer: "3 r 2"))
        XCTAssertEqual(solver.solve(bank.entries(for: .fractionAddition)[0]),
                       .verified(verifiedAnswer: "3/4"))
        XCTAssertEqual(solver.solve(bank.entries(for: .readingComprehension)[0]),
                       .verified(verifiedAnswer: "twelve sunflower seeds"))
    }

    func testFallbackBankDropsEntriesTheSolverRejects() {
        let bad = ProposedProblem(
            skill: .division, form: .story, operands: [1, 0], promptText: "Broken on purpose.")
        let textbook = ProposedProblem(
            skill: .multiplicationFacts, form: .direct, operands: [2, 3], promptText: "What is 2 × 3?")
        let bank = FallbackQuestionBank(proposals: [bad, textbook, validFacts()])
        XCTAssertEqual(bank.entries.count, 1)
        XCTAssertEqual(bank.entries.first?.skill, .multiplicationFacts)
        XCTAssertNil(bank.proposal(for: .division, rotationIndex: 0))
    }

    func testFallbackServingRotatesInsteadOfRepeatingOneQuestion() throws {
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 20))
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        var prompts: Set<String> = []
        for _ in 0..<3 {
            let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
            XCTAssertTrue(result.usedFallback)
            prompts.insert(result.question.promptText)
        }
        XCTAssertGreaterThanOrEqual(prompts.count, 2, "fallback serving should rotate entries")
    }

    // MARK: - Model proposer parsing and prompting

    func testParserReadsStructuredProposalFromModelText() {
        let text = """
        Here is the problem: {"skill":"multiplicationFacts","form":"story","operands":[7,8],"fractions":[],"operation":null,"irrelevantValues":[],"passage":null,"candidateAnswer":null,"promptText":"Seven bags hold 8 marbles each. How many marbles?","difficulty":1,"grade":"4"} Hope that helps!
        """
        let parsed = ProposedProblemParser.parse(text)
        XCTAssertEqual(parsed?.skill, .multiplicationFacts)
        XCTAssertEqual(parsed?.form, .story)
        XCTAssertEqual(parsed?.operands, [7, 8])
        XCTAssertEqual(parsed?.promptText, "Seven bags hold 8 marbles each. How many marbles?")
    }

    func testParserRejectsGarbageUnknownSkillAndBadFractions() {
        XCTAssertNil(ProposedProblemParser.parse("no json here at all"))
        XCTAssertNil(ProposedProblemParser.parse("{\"skill\":\"cooking\",\"form\":\"story\",\"promptText\":\"x\"}"))
        XCTAssertNil(ProposedProblemParser.parse(
            "{\"skill\":\"fractionAddition\",\"form\":\"story\",\"fractions\":[\"1/0\"],\"promptText\":\"x\"}"))
        XCTAssertNil(ProposedProblemParser.parse("{\"skill\":\"multiplicationFacts\",\"form\":\"story\""))
    }

    func testModelProposerPromptAsksForVariedFormAndNoStatedAnswer() {
        let request = QuestionGenerationRequest(skill: .division, difficulty: 2)
            .forAttempt(1, formHint: .reverse)
        let prompt = ModelQuestionProposer.prompt(for: request)
        XCTAssertTrue(prompt.contains("division"))
        XCTAssertTrue(prompt.contains("reverse"))
        XCTAssertTrue(prompt.contains("never a plain textbook drill"))
        XCTAssertTrue(prompt.contains("Do NOT state the final answer"))
    }

    func testModelProposerParsesItsGeneratorReply() throws {
        let proposer = ModelQuestionProposer(generateText: { _ in
            "{\"skill\":\"multiplicationFacts\",\"form\":\"story\",\"operands\":[6,7],\"promptText\":\"Six boxes hold 7 pens each. How many pens?\"}"
        })
        let generator = QuestionGenerator(proposer: proposer)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertEqual(result.question.verifiedAnswer, "42")
        assertReallyVerified(result.question)
    }

    func testModelProposerUnparseableReplyCountsAsFailedAttemptThenFallsBack() throws {
        let proposer = ModelQuestionProposer(generateText: { _ in "I cannot do that." })
        let generator = QuestionGenerator(proposer: proposer, maxAttempts: 2)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.attempts.map(\.outcome), [.noProposal, .noProposal])
        assertReallyVerified(result.question)
    }
}
