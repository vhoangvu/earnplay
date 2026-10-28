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

    /// F6: independently re-solve the captured structured proposal and
    /// compare with the delivered answer — never stored-answer-to-itself.
    private func assertReallyVerified(_ result: QuestionGenerationResult,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let question = result.question
        XCTAssertNotEqual(question.formType, .direct, "plain textbook form must never be presented", file: file, line: line)
        XCTAssertFalse(question.promptText.trimmingCharacters(in: .whitespaces).isEmpty,
                       "presented question must have text", file: file, line: line)
        XCTAssertEqual(solver.solve(result.proposal), .verified(verifiedAnswer: question.verifiedAnswer),
                       "independent solve of captured proposal must match delivered answer", file: file, line: line)
        XCTAssertEqual(
            solver.checkAnswer(result.proposal, proposedAnswer: question.verifiedAnswer), .correct,
            "independent proposal-based grading must accept the delivered answer",
            file: file, line: line)
        if result.proposal.skill != .readingComprehension {
            XCTAssertEqual(question.promptText, QuestionPromptRenderer.render(result.proposal),
                           "displayed text must be the rendered text for the computed values", file: file, line: line)
        }
        XCTAssertEqual(result.finalVerification.outcome, .verified, "delivered item needs a final solver pass", file: file, line: line)
        XCTAssertEqual(result.finalVerification.source, result.source, file: file, line: line)
        XCTAssertEqual(result.finalVerification.questionId, question.questionId, file: file, line: line)
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
        assertReallyVerified(result)
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
        assertReallyVerified(result)
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
        assertReallyVerified(result)
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
        assertReallyVerified(result)
    }

    func testRetryBoundOfOneIsRespected() throws {
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 10))
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))

        XCTAssertEqual(stub.calls, 1)
        XCTAssertEqual(result.attemptsUsed, 1)
        XCTAssertTrue(result.usedFallback)
        assertReallyVerified(result)
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

        // F7: per-item verification record, retained as an attachment.
        var records: [String] = []
        var itemsWithoutPass: [Int] = []
        for index in 0..<100 {
            let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
            XCTAssertLessThanOrEqual(result.attemptsUsed, generator.maxAttempts,
                                     "item \(index) exceeded the retry bound")
            XCTAssertEqual(result.attempts.count,
                           result.usedFallback ? generator.maxAttempts : result.attemptsUsed,
                           "item \(index) log must cover every attempt")
            // The acceptance rule: 0 unverified items reach the UI layer.
            assertReallyVerified(result)
            let solverPass = result.finalVerification.outcome == .verified
                && solver.solve(result.proposal) == .verified(verifiedAnswer: result.question.verifiedAnswer)
            if !solverPass { itemsWithoutPass.append(index) }
            records.append("item=\(index) id=\(result.question.questionId) source=\(result.source) "
                + "attempts=\(result.attemptsUsed) solverPass=\(solverPass)")
            formsSeen.insert(result.question.formType)
            if result.usedFallback { fallbackCount += 1 }
        }
        let attachment = XCTAttachment(string: records.joined(separator: "\n"))
        attachment.name = "100-problem verification log"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(records.joined(separator: "\n"))
        XCTAssertEqual(records.count, 100)
        XCTAssertTrue(itemsWithoutPass.isEmpty,
                      "every delivered item needs a solver pass; missing: \(itemsWithoutPass)")
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
            assertReallyVerified(result)
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
        assertReallyVerified(result)
    }

    func testModelProposerUnparseableReplyCountsAsFailedAttemptThenFallsBack() throws {
        let proposer = ModelQuestionProposer(generateText: { _ in "I cannot do that." })
        let generator = QuestionGenerator(proposer: proposer, maxAttempts: 2)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.attempts.map(\.outcome), [.noProposal, .noProposal])
        assertReallyVerified(result)
    }

    // MARK: - Copilot round-1 regressions (tests-first)

    func testCopilotF1MismatchedPromptTextCannotReachUI() throws {
        // Operands [6,7] (answer 42) but text asks six boxes of eight (48).
        let mismatched = ProposedProblem(
            skill: .multiplicationFacts, form: .story, operands: [6, 7],
            promptText: "There are six boxes with eight pens in each box. How many pens in all?")
        let stub = StubProposer(steps: [.proposal(mismatched)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertEqual(result.question.verifiedAnswer, "42")
        XCTAssertFalse(result.question.promptText.lowercased().contains("eight"),
                       "displayed text must be rendered from operands, got: \(result.question.promptText)")
        XCTAssertTrue(result.question.promptText.contains("6"))
        XCTAssertTrue(result.question.promptText.contains("7"))
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "48"), .incorrect(expected: "42"))
    }

    func testCopilotF1ReverseFormTextMatchesOperands() throws {
        let mismatched = ProposedProblem(
            skill: .multiplicationFacts, form: .reverse, operands: [6, 7],
            promptText: "Work backwards: six boxes hold eight pens each. How many pens?")
        let stub = StubProposer(steps: [.proposal(mismatched)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertEqual(result.question.formType, .reverse)
        XCTAssertEqual(result.question.verifiedAnswer, "42")
        XCTAssertFalse(result.question.promptText.lowercased().contains("eight"))
        XCTAssertTrue(result.question.promptText.lowercased().contains("backward"))
    }

    func testCopilotF2F3FallbackInstructionsDoNotRevealAnswer() {
        // Format-instruction entries must not contain their own answer.
        // (.whichIsWrong lists candidate answers by design; reading passages
        // contain the supported span by design; both excluded.)
        for entry in FallbackQuestionBank.demo.entries {
            guard entry.form != .whichIsWrong,
                  entry.skill != .readingComprehension,
                  entry.skill != .fractionComparison else { continue }
            guard case .verified(let answer) = solver.solve(entry) else {
                return XCTFail("bank entry must verify: \(entry.promptText)")
            }
            XCTAssertFalse(entry.promptText.contains(answer),
                           "\(entry.skill) fallback reveals its answer \(answer): \(entry.promptText)")
        }
    }

    func testCopilotF4PromptVariesAcrossAttemptsForSameForm() {
        let first = ModelQuestionProposer.prompt(
            for: QuestionGenerationRequest(skill: .division, difficulty: 2).forAttempt(1, formHint: .reverse))
        let second = ModelQuestionProposer.prompt(
            for: QuestionGenerationRequest(skill: .division, difficulty: 2).forAttempt(2, formHint: .reverse))
        XCTAssertNotEqual(first, second, "same skill/form/attempt inputs must not reuse identical prompt")
    }

    func testCopilotF5FallbackHasSolverPassRecord() throws {
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 10))
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 2)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
        XCTAssertTrue(result.usedFallback)
        // Bounded model-attempt log stays all-failures; the fallback pass
        // is recorded separately in finalVerification.
        XCTAssertEqual(result.attempts.count, 2)
        XCTAssertFalse(result.attempts.map(\.outcome).contains(.verified))
        XCTAssertEqual(result.finalVerification.source, .fallbackBank)
        XCTAssertEqual(result.finalVerification.outcome, .verified)
        XCTAssertNil(result.finalVerification.attemptNumber)
        XCTAssertEqual(result.finalVerification.questionId, result.question.questionId)
        XCTAssertEqual(solver.solve(result.proposal), .verified(verifiedAnswer: result.question.verifiedAnswer))
    }

    func testCopilotF1ReadingTextWithoutPassageIsRejected() throws {
        let passage = "Maya planted twelve sunflower seeds in the garden."
        let badReading = ProposedProblem(
            skill: .readingComprehension, form: .story, passage: passage,
            candidateAnswer: "twelve sunflower seeds",
            promptText: "What did Maya plant?")
        let stub = StubProposer(steps: [.proposal(badReading)])
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(result)
    }

    func testCopilotFallbackServesEverySkillIndependentlyVerified() throws {
        for skill in SolverSkill.allCases {
            let stub = StubProposer(steps: Array(repeating: .nothing, count: 5))
            let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
            let result = try generator.generate(QuestionGenerationRequest(skill: skill))
            XCTAssertTrue(result.usedFallback, "\(skill) should fall back")
            XCTAssertEqual(result.question.skill, skill.rawValue)
            assertReallyVerified(result)
        }
    }

    // MARK: - Copilot round-2 regressions (tests-first)

    func testR2F1WordSubtractInvalidWhichIsWrongRetriesNotTrap() throws {
        let invalid = ProposedProblem(
            skill: .wordProblem, form: .whichIsWrong, operands: [3, 10], operation: .subtract,
            promptText: "A baker made 3 muffins. Then 10 were sold. How many left?")
        let valid = ProposedProblem(
            skill: .wordProblem, form: .story, operands: [50, 18], operation: .subtract,
            promptText: "A baker made 50 muffins. Then 18 were sold. How many left?")
        let stub = StubProposer(steps: [.proposal(invalid), .proposal(valid)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .wordProblem))
        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.question.verifiedAnswer, "32")
        guard case .solverRejected = result.attempts[0].outcome else {
            return XCTFail("invalid subtraction must be solver-rejected pre-render, got \(result.attempts[0].outcome)")
        }
        assertReallyVerified(result)
    }

    func testR2F1WordSubtractInvalidStoryVariantFallsBackNotTrap() throws {
        let invalid = ProposedProblem(
            skill: .wordProblem, form: .story, operands: [3, 10], operation: .subtract,
            promptText: "A baker made 3 muffins. Then 10 were sold. How many left?")
        let stub = StubProposer(steps: [.proposal(invalid)])
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .wordProblem))
        XCTAssertTrue(result.usedFallback)
        guard case .solverRejected = result.attempts[0].outcome else {
            return XCTFail("invalid story subtraction must be solver-rejected pre-render, got \(result.attempts[0].outcome)")
        }
        assertReallyVerified(result)
    }

    func testR2F2ContainedButWrongReadingAnswerNotDelivered() throws {
        let bad = ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Leo kept books in a blue box.", candidateAnswer: "books",
            promptText: "Read: Leo kept books in a blue box. What color was the box?")
        let stub = StubProposer(steps: [.proposal(bad)])
        let generator = QuestionGenerator(proposer: stub, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(result.usedFallback, "unverifiable reading Q/A must fall back, got \(result.question)")
        XCTAssertNotEqual(result.question.verifiedAnswer, "books")
        XCTAssertEqual(result.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(result)
    }

    func testR2F2ValidColorReadingStillPasses() throws {
        let good = ProposedProblem(
            skill: .readingComprehension, form: .story,
            passage: "Leo kept books in a blue box.", candidateAnswer: "blue",
            promptText: "Read: Leo kept books in a blue box. What color was the box?")
        let stub = StubProposer(steps: [.proposal(good)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.question.verifiedAnswer, "blue")
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "blue"), .correct)
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "books"), .incorrect(expected: "blue"))
        assertReallyVerified(result)
    }

    func testR2F3ExactDivisionRequestsJustQuotient() throws {
        let exact = ProposedProblem(
            skill: .division, form: .story, operands: [48, 8],
            promptText: "48 cookies shared among 8 friends. How many each?")
        let stub = StubProposer(steps: [.proposal(exact)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .division))
        XCTAssertEqual(result.question.verifiedAnswer, "6")
        XCTAssertFalse(result.question.promptText.contains("r remainder"),
                       "exact division must not instruct r format: \(result.question.promptText)")
        XCTAssertFalse(result.question.promptText.contains("6 r 0"))
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "6"), .correct)
        assertReallyVerified(result)
    }

    func testR2F3WordExactDivisionRequestsJustQuotient() throws {
        let exact = ProposedProblem(
            skill: .wordProblem, form: .story, operands: [36, 4], operation: .divide,
            promptText: "36 pencils shared among 4 tables. How many each?")
        let stub = StubProposer(steps: [.proposal(exact)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .wordProblem))
        XCTAssertEqual(result.question.verifiedAnswer, "9")
        XCTAssertFalse(result.question.promptText.contains("r remainder"),
                       "exact word division must not instruct r format: \(result.question.promptText)")
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "9"), .correct)
        assertReallyVerified(result)
    }

    func testR2F3NonExactDivisionStillUsesRFormat() throws {
        let nonExact = ProposedProblem(
            skill: .division, form: .story, operands: [17, 5],
            promptText: "17 cookies shared among 5 friends. How many each?")
        let stub = StubProposer(steps: [.proposal(nonExact)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .division))
        XCTAssertEqual(result.question.verifiedAnswer, "3 r 2")
        XCTAssertTrue(result.question.promptText.contains("quotient r remainder"),
                      "non-exact division must keep r format: \(result.question.promptText)")
        XCTAssertEqual(solver.checkAnswer(result.question, proposedAnswer: "3 r 2"), .correct)
        assertReallyVerified(result)
    }

    func testR2F4FractionMaxSumDistractorsDoNotTrap() throws {
        let problem = ProposedProblem(
            skill: .fractionAddition, form: .whichIsWrong,
            fractions: [SolverFraction(numerator: Int.max, denominator: 1)!,
                        SolverFraction(numerator: 0, denominator: 1)!],
            promptText: "Add the fractions.")
        let stub = StubProposer(steps: [.proposal(problem)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .fractionAddition))
        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.question.verifiedAnswer, "\(Int.max)")
        XCTAssertTrue(result.question.promptText.contains("\(Int.max - 1)"),
                      "representable alternative distractors expected: \(result.question.promptText)")
        assertReallyVerified(result)
    }

    func testR2F4FractionMaxSumStoryAndZeroSumDoNotTrap() throws {
        for fractions in [
            [SolverFraction(numerator: Int.max, denominator: 1)!, SolverFraction(numerator: 0, denominator: 1)!],
            [SolverFraction(numerator: 0, denominator: 1)!, SolverFraction(numerator: 0, denominator: 1)!],
        ] {
            let problem = ProposedProblem(
                skill: .fractionAddition, form: .story, fractions: fractions,
                promptText: "Add the fractions.")
            let stub = StubProposer(steps: [.proposal(problem)])
            let generator = QuestionGenerator(proposer: stub)
            let result = try generator.generate(QuestionGenerationRequest(skill: .fractionAddition))
            XCTAssertEqual(result.source, .modelVerified)
            assertReallyVerified(result)
        }
    }

    func testR2F5IntMaxMultiplicationDistractorsDoNotTrap() throws {
        let problem = ProposedProblem(
            skill: .multiDigitMultiplication, form: .whichIsWrong, operands: [Int.max, 1],
            promptText: "Multiply.")
        let stub = StubProposer(steps: [.proposal(problem)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .multiDigitMultiplication))
        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.question.verifiedAnswer, "\(Int.max)")
        XCTAssertTrue(result.question.promptText.contains("\(Int.max - 1)"),
                      "representable alternative distractors expected: \(result.question.promptText)")
        assertReallyVerified(result)
    }

    func testR2F5IntMaxWordMultiplyStoryVariantDoesNotTrap() throws {
        let problem = ProposedProblem(
            skill: .wordProblem, form: .story, operands: [Int.max, 1], operation: .multiply,
            promptText: "Multiply.")
        let stub = StubProposer(steps: [.proposal(problem)])
        let generator = QuestionGenerator(proposer: stub)
        let result = try generator.generate(QuestionGenerationRequest(skill: .wordProblem))
        XCTAssertEqual(result.source, .modelVerified)
        XCTAssertEqual(result.question.verifiedAnswer, "\(Int.max)")
        assertReallyVerified(result)
    }

    func testR2F6SeparateReadingFieldsResponseNotWasted() throws {
        let proposer = ModelQuestionProposer(generateText: { _ in
            "{\"skill\":\"readingComprehension\",\"form\":\"story\",\"passage\":\"Leo kept books in a blue box.\",\"candidateAnswer\":\"blue\",\"promptText\":\"What color was the box?\"}"
        })
        let generator = QuestionGenerator(proposer: proposer)
        let result = try generator.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(result.source, .modelVerified, "separate-fields reading must not waste retries: \(result.attempts)")
        XCTAssertEqual(result.attemptsUsed, 1)
        XCTAssertEqual(result.question.verifiedAnswer, "blue")
        XCTAssertTrue(result.question.promptText.contains("Leo kept books in a blue box."))
        XCTAssertTrue(result.question.promptText.contains("What color was the box?"))
        assertReallyVerified(result)
    }

    func testR2F6PromptRequestsCombinedReadingText() {
        let request = QuestionGenerationRequest(skill: .readingComprehension)
            .forAttempt(1, formHint: .story)
        let prompt = ModelQuestionProposer.prompt(for: request)
        XCTAssertTrue(prompt.lowercased().contains("combined"),
                      "reading prompt must request combined passage+question text: \(prompt)")
    }

    // MARK: - Copilot round-3 regressions (tests-first)

    private func readingProposal(passage: String, candidate: String, question: String) -> ProposedProblem {
        ProposedProblem(
            skill: .readingComprehension, form: .story, passage: passage,
            candidateAnswer: candidate, promptText: "Read: \(passage) \(question)")
    }

    func testR3F1QuantityAnswerMustMatchQuestionedNoun() throws {
        let passage = "Maya has three apples and five pears."
        let question = "How many pears does Maya have?"
        let bad = readingProposal(passage: passage, candidate: "three", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "unrelated quantity span must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "three")
        XCTAssertEqual(badResult.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "five", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "five")
        XCTAssertEqual(solver.checkAnswer(goodResult.question, proposedAnswer: "five"), .correct)
        XCTAssertEqual(solver.checkAnswer(goodResult.question, proposedAnswer: "three"), .incorrect(expected: "five"))
        assertReallyVerified(goodResult)
    }

    func testR3F1WhoAnswerMustBeSubjectOfQuestionedVerb() throws {
        let passage = "Maya gave Leo a book."
        let question = "Who gave Leo a book?"
        let bad = readingProposal(passage: passage, candidate: "Leo", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "non-subject name span must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "Leo")
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "Maya", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "Maya")
        assertReallyVerified(goodResult)
    }

    func testR3F1ColorAnswerMustDescribeQuestionedNoun() throws {
        let passage = "The blue box has a red lid."
        let question = "What color is the box's lid?"
        let bad = readingProposal(passage: passage, candidate: "blue", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "color of a different noun must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "blue")
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "red", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "red")
        assertReallyVerified(goodResult)
    }

    func testR3F1VerbObjectAnswerMustFollowQuestionedVerb() throws {
        let passage = "Maya planted seeds in the garden and watered the flowers."
        let question = "What did Maya water?"
        let bad = readingProposal(passage: passage, candidate: "seeds", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "object of a different verb must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "seeds")
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "flowers", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "flowers")
        assertReallyVerified(goodResult)
    }

    private final class AlwaysStoryProposer: QuestionProposing, @unchecked Sendable {
        func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? {
            ProposedProblem(
                skill: request.skill, form: .story, operands: [7, 8],
                promptText: "Seven shelves hold 8 books each. How many books in all?")
        }
    }

    func testR3F2ProposerIgnoringFormHintStillYieldsThreeFormsInTen() throws {
        let generator = QuestionGenerator(proposer: AlwaysStoryProposer())
        var forms: [SolverForm] = []
        for _ in 0..<10 {
            let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
            forms.append(result.question.formType)
            assertReallyVerified(result)
        }
        XCTAssertFalse(forms.contains(.direct))
        XCTAssertGreaterThanOrEqual(Set(forms).count, 3,
                                    "hint-ignoring proposer must not yield one form, got \(forms)")
    }

    func testR3F3FallbackScansPastPresentationInvalidEntry() throws {
        let passage = "Leo kept books in a blue box."
        let passageLess = ProposedProblem(
            skill: .readingComprehension, form: .story, passage: passage,
            candidateAnswer: "blue", promptText: "What color was the box?")
        let presentable = ProposedProblem(
            skill: .readingComprehension, form: .story, passage: passage,
            candidateAnswer: "blue", promptText: "Read: Leo kept books in a blue box. What color was the box?")
        let bank = FallbackQuestionBank(proposals: [passageLess, presentable])
        XCTAssertEqual(bank.entries.count, 2, "both entries are solver-accepted and must be retained")
        let stub = StubProposer(steps: Array(repeating: .nothing, count: 5))
        let generator = QuestionGenerator(proposer: stub, fallbackBank: bank, maxAttempts: 1)
        let result = try generator.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(result.source, .fallbackBank)
        XCTAssertEqual(result.question.verifiedAnswer, "blue")
        XCTAssertTrue(result.question.promptText.contains(passage))
        assertReallyVerified(result)
    }

    func testCopilotF4SamplingSeedVariesAndReplaysDeterministically() throws {
        final class Capture: @unchecked Sendable {
            var prompts: [String] = []
            var seeds: [UInt32] = []
        }
        func makeGenerator(_ capture: Capture) -> QuestionGenerator {
            let proposer = ModelQuestionProposer(generateWithSeed: { prompt, seed in
                capture.prompts.append(prompt)
                capture.seeds.append(seed)
                return "{\"skill\":\"multiplicationFacts\",\"form\":\"story\",\"operands\":[6,7],\"promptText\":\"Six boxes hold 7 pens each. How many pens?\"}"
            })
            return QuestionGenerator(proposer: proposer)
        }
        let first = Capture()
        let genA = makeGenerator(first)
        for _ in 0..<10 { _ = try genA.generate(QuestionGenerationRequest(skill: .multiplicationFacts)) }
        XCTAssertEqual(Set(first.prompts).count, first.prompts.count, "prompts must vary per question: \(first.prompts)")
        XCTAssertEqual(Set(first.seeds).count, first.seeds.count, "sampling seeds must vary per question")
        // Deterministic replay: a fresh generator reproduces the sequence.
        let second = Capture()
        let genB = makeGenerator(second)
        for _ in 0..<10 { _ = try genB.generate(QuestionGenerationRequest(skill: .multiplicationFacts)) }
        XCTAssertEqual(first.prompts, second.prompts)
        XCTAssertEqual(first.seeds, second.seeds)
        // Same request value replays to the same seed; different variation differs.
        let base = QuestionGenerationRequest(skill: .division).forAttempt(1, formHint: .story, variationIndex: 3)
        XCTAssertEqual(ModelQuestionProposer.samplingSeed(for: base), ModelQuestionProposer.samplingSeed(for: base))
        XCTAssertNotEqual(ModelQuestionProposer.samplingSeed(for: base),
                          ModelQuestionProposer.samplingSeed(
                            for: QuestionGenerationRequest(skill: .division).forAttempt(1, formHint: .story, variationIndex: 4)))
    }

    // MARK: - Copilot round-4 regressions (tests-first)

    func testR4F1WhoAnswerMustMatchFullQuestionedClause() throws {
        let passage = "Maya gave Leo a book. Nora gave Sam a pen."
        let question = "Who gave Sam a pen?"
        let bad = readingProposal(passage: passage, candidate: "Maya", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "subject of a different clause must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "Maya")
        XCTAssertEqual(badResult.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "Nora", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "Nora")
        assertReallyVerified(goodResult)
    }

    func testR4F2NegatedColorIsNotAnAssertedColor() throws {
        let passage = "The box is not red. It is blue."
        let question = "What color is the box?"
        let bad = readingProposal(passage: passage, candidate: "red", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "negated color must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "red")
        XCTAssertEqual(badResult.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(badResult)

        let predicative = readingProposal(passage: "The box is blue.", candidate: "blue", question: question)
        let predGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(predicative)]))
        let predResult = try predGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(predResult.source, .modelVerified)
        XCTAssertEqual(predResult.question.verifiedAnswer, "blue")
        assertReallyVerified(predResult)

        let attributive = readingProposal(passage: "The red box is on the table.", candidate: "red", question: question)
        let attrGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(attributive)]))
        let attrResult = try attrGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(attrResult.source, .modelVerified)
        XCTAssertEqual(attrResult.question.verifiedAnswer, "red")
        assertReallyVerified(attrResult)
    }

    func testR4F3VerbObjectMustBeActualObjectNotPrepositionalNoun() throws {
        let passage = "Maya planted seeds beside roses."
        let question = "What did Maya plant?"
        let bad = readingProposal(passage: passage, candidate: "roses", question: question)
        let badGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(bad)]), maxAttempts: 1)
        let badResult = try badGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertTrue(badResult.usedFallback, "noun in a prepositional phrase must fall back, got \(badResult.question)")
        XCTAssertNotEqual(badResult.question.verifiedAnswer, "roses")
        XCTAssertEqual(badResult.attempts.map(\.outcome), [.promptTextMismatch])
        assertReallyVerified(badResult)

        let good = readingProposal(passage: passage, candidate: "seeds", question: question)
        let goodGen = QuestionGenerator(proposer: StubProposer(steps: [.proposal(good)]))
        let goodResult = try goodGen.generate(QuestionGenerationRequest(skill: .readingComprehension))
        XCTAssertEqual(goodResult.source, .modelVerified)
        XCTAssertEqual(goodResult.question.verifiedAnswer, "seeds")
        assertReallyVerified(goodResult)
    }

    func testR4F4ConcurrentFallbackServingReservesDistinctRotations() throws {
        final class NothingProposer: QuestionProposing, @unchecked Sendable {
            func propose(request: QuestionGenerationRequest) throws -> ProposedProblem? { nil }
        }
        let bank = FallbackQuestionBank(proposals: [
            ProposedProblem(skill: .multiplicationFacts, form: .story, operands: [2, 3], promptText: "Two groups of three."),
            ProposedProblem(skill: .multiplicationFacts, form: .story, operands: [3, 4], promptText: "Three groups of four."),
            ProposedProblem(skill: .multiplicationFacts, form: .story, operands: [4, 5], promptText: "Four groups of five."),
            ProposedProblem(skill: .multiplicationFacts, form: .story, operands: [5, 6], promptText: "Five groups of six."),
        ])
        XCTAssertEqual(bank.entries.count, 4)
        let generator = QuestionGenerator(proposer: NothingProposer(), fallbackBank: bank, maxAttempts: 1)
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var prompts: [String] = []
            private(set) var errors: [String] = []
            func addPrompt(_ prompt: String) { lock.lock(); prompts.append(prompt); lock.unlock() }
            func addError(_ error: String) { lock.lock(); errors.append(error); lock.unlock() }
        }
        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            do {
                let result = try generator.generate(QuestionGenerationRequest(skill: .multiplicationFacts))
                collector.addPrompt(result.question.promptText)
            } catch {
                collector.addError(String(describing: error))
            }
        }
        let prompts = collector.prompts
        let errors = collector.errors
        XCTAssertTrue(errors.isEmpty, "concurrent fallback serving must not throw: \(errors)")
        XCTAssertEqual(prompts.count, 40)
        var counts: [String: Int] = [:]
        for prompt in prompts { counts[prompt, default: 0] += 1 }
        XCTAssertEqual(counts.count, 4, "every fallback entry must be served, got \(counts)")
        XCTAssertTrue(counts.values.allSatisfy { $0 == 10 },
                      "serialized round-robin must serve each entry exactly 10 times, got \(counts)")
    }
}
