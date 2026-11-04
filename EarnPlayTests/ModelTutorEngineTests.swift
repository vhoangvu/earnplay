import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Scripted `ModelTextGenerator`: canned responses/errors, controllable
/// warmth and delay, records every prompt. A test double for the
/// generator seam only — it never claims to be real inference.
private final class FakeModel {
    private let lock = NSLock()
    private var remaining: [String]
    private var scriptError: Error?
    private var delay: TimeInterval
    private var warm: Bool
    private var prompts: [String] = []
    private var warmUpCalls = 0

    init(responses: [String] = [], error: Error? = nil, delay: TimeInterval = 0, warm: Bool = true) {
        self.remaining = responses
        self.scriptError = error
        self.delay = delay
        self.warm = warm
    }

    var generator: ModelTextGenerator {
        ModelTextGenerator(
            generateText: { [weak self] prompt in
                guard let self else { throw ModelRuntimeError.generationFailed("fake released") }
                return try self.generate(prompt: prompt)
            },
            warmUp: { [weak self] in self?.recordWarmUp() },
            isWarm: { [weak self] in self?.isWarm ?? false }
        )
    }

    var recordedPrompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }

    var isWarm: Bool {
        lock.lock()
        defer { lock.unlock() }
        return warm
    }

    var warmUpCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return warmUpCalls
    }

    private func recordWarmUp() {
        lock.lock()
        defer { lock.unlock() }
        warmUpCalls += 1
    }

    private func generate(prompt: String) throws -> String {
        lock.lock()
        prompts.append(prompt)
        let wait = delay
        let error = scriptError
        let text = remaining.isEmpty ? "Model line." : remaining.removeFirst()
        lock.unlock()
        if wait > 0 {
            Thread.sleep(forTimeInterval: wait)
        }
        if let error {
            throw error
        }
        return text
    }
}

/// Generation-tracking scripted engine for the view-model staleness
/// test (finding 1): every `startSession` bumps the generation and
/// reports session-complete (so the view model offers restart), and
/// `emit` delivers a scripted async update on demand.
private final class GenerationEngine: ChatTutorEngine {
    private(set) var generation = 0
    var currentSessionGeneration: Int { generation }
    var onAsyncUpdate: ((ChatEngineUpdate) -> Void)?

    func startSession() -> ChatEngineUpdate {
        generation += 1
        return ChatEngineUpdate(
            turns: [.tutor(TutorMessage(id: "q\(generation)", text: "Question \(generation)",
                                                  kind: .question))],
            composer: .sessionComplete)
    }

    func submitAnswer(_ plainText: String) -> ChatEngineUpdate { ChatEngineUpdate() }
    func requestHint() -> ChatEngineUpdate { ChatEngineUpdate() }
    func emit(_ update: ChatEngineUpdate) { onAsyncUpdate?(update) }
}

/// Thread-safe collector for async engine updates (delivered on a
/// background queue while the test runs on the main actor).
private final class UpdateCollector {
    private let lock = NSLock()
    private var collected: [ChatEngineUpdate] = []

    func append(_ update: ChatEngineUpdate) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(update)
    }

    var updates: [ChatEngineUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

/// Issue #93: the model-backed chat tutor falls back to the deterministic
/// engine identically when the model is absent, selects the model path
/// only when warm, and falls back on failure or timeout — without ever
/// blocking the calling thread on inference.
@MainActor
final class ModelTutorEngineTests: XCTestCase {
    /// Demo Q1 (7 x 8): correct answer and a wrong one.
    private let q1Correct = "56"
    private let q1Wrong = "54"

    // MARK: - Model absent: verbatim deterministic behavior

    func testModelAbsentMatchesDemoVerbatim() {
        let demo = DemoTutorEngine()
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: nil)
        engine.onAsyncUpdate = { _ in
            XCTFail("a model-absent engine must never emit async updates")
        }
        XCTAssertFalse(engine.isModelPathActive)

        // Dual-drive both engines through every reply shape that carries
        // phrasing turns (incorrect, probe reply, hint, retry, correct,
        // second-question incorrect): each update must be identical,
        // including message ids, progress, composers, and revision flags.
        XCTAssertEqual(engine.startSession(), demo.startSession())
        XCTAssertEqual(engine.submitAnswer(q1Wrong), demo.submitAnswer(q1Wrong))
        XCTAssertEqual(engine.submitAnswer("I added seven eight times"),
                       demo.submitAnswer("I added seven eight times"))
        XCTAssertEqual(engine.requestHint(), demo.requestHint())
        XCTAssertEqual(engine.submitAnswer("55"), demo.submitAnswer("55"))
        XCTAssertEqual(engine.submitAnswer(q1Correct), demo.submitAnswer(q1Correct))
        XCTAssertEqual(engine.submitAnswer("45"), demo.submitAnswer("45"))
    }

    func testProductionFactoryFallsBackWhenUnavailable() {
        guard !ModelTutorEngine.isModelAvailable() else {
            // Llama linked and a model file present: the live path is
            // covered by the warm-fake selection tests below, and
            // warm-up timing makes activity racy to assert here.
            return
        }
        let engine = ModelTutorEngine(inner: DemoTutorEngine())
        XCTAssertFalse(engine.isModelPathActive)
        let demo = DemoTutorEngine()
        XCTAssertEqual(engine.startSession(), demo.startSession())
        XCTAssertEqual(engine.submitAnswer(q1Wrong), demo.submitAnswer(q1Wrong))
    }

    // MARK: - Model path: substitution preserves structure

    func testWarmModelPathSubstitutesPhrasingTurns() async {
        let fake = FakeModel(responses: ["You are thinking hard!", "What step did you try?"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        XCTAssertTrue(engine.isModelPathActive)

        XCTAssertEqual(engine.startSession(), demo.startSession())

        let collector = UpdateCollector()
        let delivered = expectation(description: "async model reply delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        // Sync: the inner update verbatim — every deterministic turn
        // renders immediately (finding 2), everything else synchronous.
        let expected = demo.submitAnswer(q1Wrong)
        let sync = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(sync.turns, expected.turns)
        XCTAssertEqual(sync.progress, expected.progress)
        XCTAssertEqual(sync.composer, expected.composer)
        XCTAssertEqual(sync.submittedTurnIsRevision, expected.submittedTurnIsRevision)

        await fulfillment(of: [delivered], timeout: 5)
        let followUps = collector.updates
        XCTAssertEqual(followUps.count, 1)
        // Ids and kinds preserved, texts from the model, original order.
        XCTAssertEqual(followUps[0].turns.map(\.id), expected.turns.map(\.id))
        XCTAssertEqual(followUps[0].turns.map { $0.tutorMessage?.kind },
                       expected.turns.map { $0.tutorMessage?.kind })
        XCTAssertEqual(followUps[0].turns.map(\.displayedText),
                       ["You are thinking hard!", "What step did you try?"])
        // Progress/composer already arrived synchronously.
        XCTAssertNil(followUps[0].progress)
        XCTAssertNil(followUps[0].composer)
    }

    func testModelFailureFallsBackToDeterministicTurns() async {
        let fake = FakeModel(error: ModelRuntimeError.runtimeUnavailable)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "fallback reply delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expected = demo.submitAnswer(q1Wrong)
        let sync = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(sync.turns, expected.turns)

        await fulfillment(of: [delivered], timeout: 5)
        // A failed generation serves the deterministic turns verbatim —
        // never an error, never invented text.
        XCTAssertEqual(collector.updates.map(\.turns), [expected.turns])
    }

    // MARK: - Timeout: bounded wait, never blocked

    func testTimeoutFallsBackWithoutBlocking() async {
        // The fake sleeps far longer than the test runs: if the engine
        // ever waited synchronously, the sync call below would hang.
        let fake = FakeModel(responses: ["Too slow."], delay: 60)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 0.2)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "timeout fallback delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expected = demo.submitAnswer(q1Wrong)
        let start = Date()
        let sync = engine.submitAnswer(q1Wrong)
        let syncElapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(sync.turns, expected.turns)
        XCTAssertLessThan(syncElapsed, 5, "sync call blocked on inference")

        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(collector.updates.map(\.turns), [expected.turns])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "wait was not bounded")
    }

    // MARK: - Solver authority: verdicts, questions, hints untouched

    func testSolverStaysAuthoritativeOverModelText() async throws {
        // A model response that sounds like a verdict is REJECTED
        // (finding 3: unverified correctness claims fall back to the
        // deterministic wording); progress, composer, revision flags,
        // questions, and hints stay deterministic regardless.
        let fake = FakeModel(responses: ["Ninety-nine is exactly right!", "What step did you try?"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "replies delivered")
        delivered.expectedFulfillmentCount = 3
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expectedWrong = demo.submitAnswer(q1Wrong)
        let syncWrong = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(syncWrong.progress, expectedWrong.progress)
        XCTAssertEqual(syncWrong.composer, expectedWrong.composer)
        XCTAssertEqual(syncWrong.submittedTurnIsRevision, expectedWrong.submittedTurnIsRevision)

        // Answer the probe, then answer Q1 correctly.
        _ = demo.submitAnswer("I added seven eight times")
        _ = engine.submitAnswer("I added seven eight times")
        let expectedCorrect = demo.submitAnswer(q1Correct)
        let syncCorrect = engine.submitAnswer(q1Correct)
        XCTAssertEqual(syncCorrect.progress, expectedCorrect.progress)
        XCTAssertEqual(syncCorrect.composer, expectedCorrect.composer)

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(collector.updates.count, 3)
        // The verdict-sounding encouragement is rejected: the async
        // turn keeps the deterministic wording (finding 3). The clean
        // probe rephrase passes through.
        let expectedWrongMessage = try XCTUnwrap(expectedWrong.turns[0].tutorMessage)
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText),
                       [expectedWrongMessage.text, "What step did you try?"])
        XCTAssertEqual(collector.updates[1].turns.map(\.displayedText), ["Model line."])
        // The correct reply's next question arrived synchronously
        // (finding 2); the async update carries only the rephrased
        // encouragement — the model never writes question content.
        XCTAssertEqual(syncCorrect.turns, expectedCorrect.turns)
        let correctFollowUp = collector.updates[2]
        let expectedMessage = try XCTUnwrap(expectedCorrect.turns[0].tutorMessage)
        XCTAssertEqual(correctFollowUp.turns, [
            .tutor(TutorMessage(id: expectedMessage.id, text: "Model line.", kind: .encouragement)),
        ])
    }

    func testHintRepliesAreNeverWithheld() async {
        let fake = FakeModel(responses: ["Must never appear."])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let unexpected = expectation(description: "no async update for hints")
        unexpected.isInverted = true
        engine.onAsyncUpdate = { _ in unexpected.fulfill() }

        // Hint content is solver-verified: all three ladder levels plus
        // the exhausted tap arrive synchronously and verbatim.
        for _ in 0..<4 {
            XCTAssertEqual(engine.requestHint(), demo.requestHint())
        }
        await fulfillment(of: [unexpected], timeout: 0.5)
        XCTAssertTrue(fake.recordedPrompts.isEmpty, "hint replies must never invoke the model")
    }

    // MARK: - Ordering and prompts

    func testRestartDiscardsStaleAsyncReply() async {
        // Slow fake: earlier replies are still generating when the
        // restart lands. All scripted texts identical, so assertions
        // hold however many stale jobs generated before the drop.
        let fake = FakeModel(responses: ["Same line.", "Same line.", "Same line.", "Same line."], delay: 1.0)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let freshReply = expectation(description: "new-session reply delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            if collector.updates.count > 1 {
                XCTFail("stale reply delivered after restart")
            }
            freshReply.fulfill()
        }

        // Complete the session (Q1 56, Q2 54, Q3 99). Each correct
        // reply withholds turns for a slow async job.
        _ = engine.submitAnswer("56"); _ = demo.submitAnswer("56")
        _ = engine.submitAnswer("54"); _ = demo.submitAnswer("54")
        let finalSync = engine.submitAnswer("99")
        let finalDemo = demo.submitAnswer("99")
        XCTAssertEqual(finalSync.composer, .sessionComplete)
        XCTAssertEqual(finalSync.turns, finalDemo.turns)
        XCTAssertEqual(finalDemo.composer, .sessionComplete)

        // Restart immediately, while completion replies are in flight.
        XCTAssertEqual(engine.startSession(), demo.startSession())

        // The new session answers wrong: only its reply may arrive.
        let wrongDemo = demo.submitAnswer("54")
        _ = engine.submitAnswer("54")

        await fulfillment(of: [freshReply], timeout: 8)
        XCTAssertEqual(collector.updates.count, 1)
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText), ["Same line.", "Same line."])
        XCTAssertEqual(collector.updates[0].turns.map(\.id), wrongDemo.turns.map(\.id))
    }

    func testAsyncRepliesArriveInRequestOrder() async {
        let fake = FakeModel(responses: ["First-a.", "First-b.", "Second."])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "both replies delivered")
        delivered.expectedFulfillmentCount = 2
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        // Two rapid submissions: incorrect (encouragement + probe), then
        // the probe explanation (acknowledgement). Replies must arrive
        // in request order with uncrossed content.
        let first = demo.submitAnswer(q1Wrong)
        let second = demo.submitAnswer("I added seven eight times")
        _ = engine.submitAnswer(q1Wrong)
        _ = engine.submitAnswer("I added seven eight times")

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(collector.updates.count, 2)
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText), ["First-a.", "First-b."])
        XCTAssertEqual(collector.updates[0].turns.map(\.id), first.turns.map(\.id))
        XCTAssertEqual(collector.updates[1].turns.map(\.displayedText), ["Second."])
        XCTAssertEqual(collector.updates[1].turns.map(\.id), second.turns.map(\.id))
    }

    func testModelPromptsUseSanctionedLayerWithoutChildText() async {
        let answer = "hello-wrong-answer"
        let fake = FakeModel(responses: ["Keep going!", "Show a step?"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        _ = engine.startSession()

        let delivered = expectation(description: "reply delivered")
        engine.onAsyncUpdate = { _ in delivered.fulfill() }
        _ = engine.submitAnswer(answer)

        await fulfillment(of: [delivered], timeout: 5)
        // Exact per-kind prompts through TutorPrompt.assemble; the
        // child's answer text never enters a model prompt.
        XCTAssertEqual(fake.recordedPrompts, [
            ModelTutorEngine.promptFor(kind: .encouragement),
            ModelTutorEngine.promptFor(kind: .probe),
        ])
        for prompt in fake.recordedPrompts {
            XCTAssertTrue(TutorPrompt.systemSectionIntact(in: prompt))
            XCTAssertFalse(prompt.contains(answer))
        }
    }

    // MARK: - Live generator errors (both build configurations)

    func testLiveGeneratorSurfacesRuntimeErrors() throws {
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: "/nonexistent-model/EarnPlayModel.gguf"))
        let generator = ModelTextGenerator.live(runtime: runtime)
        XCTAssertFalse(generator.isWarm)
        if ModelRuntime.isRuntimeLinked {
            // Framework present but no file: fast load failure, no hang.
            XCTAssertThrowsError(try generator.generateText("hi"))
        } else {
            // Framework absent: every call reports .runtimeUnavailable.
            XCTAssertThrowsError(try generator.generateText("hi")) { error in
                XCTAssertEqual(error as? ModelRuntimeError, .runtimeUnavailable)
            }
            XCTAssertThrowsError(try generator.warmUp()) { error in
                XCTAssertEqual(error as? ModelRuntimeError, .runtimeUnavailable)
            }
        }
        XCTAssertFalse(generator.isWarm)
    }

    // MARK: - View-model subscription

    func testViewModelRendersAsyncModelReply() async throws {
        let fake = FakeModel(responses: ["Model encouragement!", "Model probe?"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let viewModel = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))
        viewModel.startIfNeeded()
        XCTAssertEqual(viewModel.messages.count, 1)

        viewModel.draft = q1Wrong
        viewModel.submitDraft()
        // The child echo AND the deterministic reply render
        // synchronously (finding 2); the model rephrases arrive async
        // as in-place replacements.
        XCTAssertEqual(viewModel.messages.count, 4)

        let deadline = Date().addingTimeInterval(5)
        while viewModel.messages.count < 4
                || viewModel.messages[2].displayedText != "Model encouragement!",
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(viewModel.messages.map(\.displayedText), [
            "A farmer packs 7 eggs in each carton. She fills 8 cartons for the market. How many eggs did she pack in all?",
            q1Wrong,
            "Model encouragement!",
            "Model probe?",
        ])
        XCTAssertEqual(viewModel.speakerMessageIDs.count, 3)
    }

    // MARK: - Fix round 1 finding 1: view-model staleness guard

    func testViewModelDropsStaleAsyncReplyAfterRestart() async throws {
        let engine = GenerationEngine()
        let viewModel = ChatConversationViewModel(
            engine: engine, speech: ReadAloudService(band: GradeBand(grade: "4")))
        viewModel.startIfNeeded()
        XCTAssertEqual(engine.currentSessionGeneration, 1)
        viewModel.restartSession()
        XCTAssertEqual(engine.currentSessionGeneration, 2)
        XCTAssertEqual(viewModel.messages.map(\.displayedText), ["Question 2"])

        // Stale: emitted after the restart but tagged with the
        // pre-restart generation (the engine-side guard passed just
        // before the restart bumped it). Must never append to, or
        // overwrite turns of, the cleared new session.
        engine.emit(ChatEngineUpdate(
            turns: [.tutor(TutorMessage(id: "stale", text: "Stale turn", kind: .encouragement))],
            sessionGeneration: 1))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(viewModel.messages.map(\.displayedText), ["Question 2"])

        // Current-generation and untagged updates still apply.
        engine.emit(ChatEngineUpdate(
            turns: [.tutor(TutorMessage(id: "fresh", text: "Fresh turn", kind: .encouragement))],
            sessionGeneration: 2))
        engine.emit(ChatEngineUpdate(
            turns: [.tutor(TutorMessage(id: "plain", text: "Plain turn", kind: .encouragement))]))
        let deadline = Date().addingTimeInterval(2)
        while viewModel.messages.count < 3, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(viewModel.messages.map(\.displayedText),
                       ["Question 2", "Fresh turn", "Plain turn"])
    }

    // MARK: - Fix round 1 finding 2: next question renders synchronously

    func testSyncShowsNextQuestionBeforeInferenceCompletes() async {
        let fake = FakeModel(responses: ["Keep up the good work!"], delay: 2.0)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "rephrase delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expected = demo.submitAnswer(q1Correct)
        let sync = engine.submitAnswer(q1Correct)
        // The next question renders synchronously — before the
        // still-running inference completes — and the composer matches
        // that shown question, so Send/Hint never act on an unseen one.
        XCTAssertEqual(sync.turns, expected.turns)
        XCTAssertEqual(sync.turns.count, 2)
        XCTAssertEqual(sync.turns[1].tutorMessage?.kind, .question)
        XCTAssertEqual(sync.composer, expected.composer)

        await fulfillment(of: [delivered], timeout: 8)
        // The async update carries only the encouragement replacement
        // (same id, model text) — no question turn travels async.
        XCTAssertEqual(collector.updates.count, 1)
        XCTAssertEqual(collector.updates[0].turns.count, 1)
        XCTAssertEqual(collector.updates[0].turns[0].tutorMessage?.kind, .encouragement)
        XCTAssertEqual(collector.updates[0].turns[0].displayedText, "Keep up the good work!")
        XCTAssertEqual(collector.updates[0].turns[0].id, expected.turns[0].id)
    }

    // MARK: - Fix round 1 finding 3: unverified correctness claims rejected

    func testCorrectnessClaimScreenRejectsVerdictWords() {
        let rejected = [
            "Ninety-nine is exactly right!",
            "That is correct.",
            "Correct!",
            "Your answer is wrong, try again.",
            "True! You solved it.",
            "False.",
            "The answer is 56.",
            "You got 56!",
            "5 more to go.",
            "WRONG",
        ]
        for text in rejected {
            XCTAssertTrue(ModelTutorEngine.containsUnverifiedCorrectnessClaim(text), text)
        }
        let accepted = [
            "You are thinking hard!",
            "What step did you try?",
            "Keep going, you can do it!",
            "Nice effort, try again.",
            "Take your time and look again.",
            "You are bright and capable.",
            "Correctness grows with practice.",
            "Model line.",
        ]
        for text in accepted {
            XCTAssertFalse(ModelTutorEngine.containsUnverifiedCorrectnessClaim(text), text)
        }
    }

    func testGeneratedCorrectnessClaimsFallBackToDeterministic() async {
        let fake = FakeModel(responses: ["That is exactly right", "Your answer 5 is wrong"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "fallback delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expected = demo.submitAnswer(q1Wrong)
        let sync = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(sync.turns, expected.turns)

        await fulfillment(of: [delivered], timeout: 5)
        // Both generated turns carry unverified correctness claims, so
        // the async update keeps the deterministic wording verbatim.
        XCTAssertEqual(collector.updates.map(\.turns), [expected.turns])
    }

    // MARK: - Fix round 2 finding 2: spelled-out math and praise verdicts

    func testCorrectnessClaimScreenRejectsNumberWordsAndPraiseVerdicts() {
        let rejected = [
            // The finding's own examples.
            "Seven times eight equals fifty-four",
            "You nailed it!",
            // Spelled-out math claims (no digits, no round-1 verdict word).
            "Eight plus five equals thirteen",
            "One plus one is two.",
            "Half of ten is five.",
            "A dozen eggs make twelve.",
            "The total is twenty.",
            "Add them together to check.",
            "The sum must match.",
            "Double it and see.",
            "Twice as much next time.",
            "Calculate it step by step.",
            // Praise/success verdicts without a round-1 verdict word.
            "You crushed it!",
            "You killed it!",
            "Slayed!",
            "Great job!",
            "Good job, you did it!",
            "Well done!",
            "Way to go!",
            "Perfect!",
            "Excellent work!",
            "Amazing!",
            "You are fantastic!",
            "You solved it!",
            "You aced it!",
            "Bravo!",
            "Congratulations!",
            "Exactly!",
            "Precisely!",
            "You did well!",
            "You earned a star!",
            "Your score is high.",
            "You passed the test!",
            "You finished all the questions!",
        ]
        for text in rejected {
            XCTAssertTrue(ModelTutorEngine.containsUnverifiedCorrectnessClaim(text), text)
        }
        // Effort, process, and ability praise still passes: the
        // deterministic path owns encouragement wording, and falling
        // back on THESE would cost phrasing for no safety gain.
        let accepted = [
            "Keep trying your best!",
            "Give it another go!",
            "Think step by step.",
            "Keep practising, you are working hard!",
            "Show me how you started.",
            "What did you try first?",
            "You can solve this step.",
            "Point to the part you tried.",
            "Do you want to try again?",
        ]
        for text in accepted {
            XCTAssertFalse(ModelTutorEngine.containsUnverifiedCorrectnessClaim(text), text)
        }
    }

    func testGeneratedPraiseVerdictsFallBackToDeterministic() async {
        let fake = FakeModel(responses: ["You nailed it!", "Seven times eight equals fifty-four"])
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "fallback delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let expected = demo.submitAnswer(q1Wrong)
        let sync = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(sync.turns, expected.turns)

        await fulfillment(of: [delivered], timeout: 5)
        // Both generated turns carry unverified success/math claims
        // with no digits or round-1 verdict words, so the async
        // update keeps the deterministic wording verbatim.
        XCTAssertEqual(collector.updates.map(\.turns), [expected.turns])
    }

    // MARK: - Fix round 1 finding 4: no obsolete inference behind timeouts

    func testTimedOutInferenceDoesNotQueueObsoleteCalls() async {
        // The stale worker sleeps far longer than the test runs. The
        // second reply is submitted AFTER the first timed out, with a
        // fresh deadline — it must fall back WITHOUT invoking the
        // generator behind the still-running stale call.
        let fake = FakeModel(responses: ["Too slow.", "Also slow."], delay: 60)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 1.0)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let first = expectation(description: "first fallback delivered")
        let second = expectation(description: "second fallback delivered")
        engine.onAsyncUpdate = { update in
            collector.append(update)
            if collector.updates.count == 1 {
                first.fulfill()
            } else {
                second.fulfill()
            }
        }

        let expectedFirst = demo.submitAnswer(q1Correct)
        _ = engine.submitAnswer(q1Correct)
        await fulfillment(of: [first], timeout: 10)
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText),
                       [expectedFirst.turns[0].displayedText])
        XCTAssertEqual(fake.recordedPrompts.count, 1)

        let expectedSecond = demo.submitAnswer("54")
        let syncSecond = engine.submitAnswer("54")
        XCTAssertEqual(syncSecond.turns, expectedSecond.turns)
        await fulfillment(of: [second], timeout: 10)
        XCTAssertEqual(collector.updates[1].turns.map(\.displayedText),
                       [expectedSecond.turns[0].displayedText])
        XCTAssertEqual(fake.recordedPrompts.count, 1,
                       "obsolete inference queued behind the timed-out call")
    }

    // MARK: - Fix round 1 finding 5: registry artifact resolution

    private func tempModelFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("RetainedModel.gguf")
        try Data("GGUF-fixture".utf8).write(to: url)
        return url
    }

    private func tempRegistryStore(activeBundleID: String, modelFilePath: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("version-registry.json")
        var bundle: [String: Any] = ["bundleID": activeBundleID,
                                     "modelVersion": "v", "promptVersion": "p"]
        if let modelFilePath { bundle["modelFilePath"] = modelFilePath }
        let state: [String: Any] = ["bundles": [bundle], "activeBundleID": activeBundleID]
        try JSONSerialization.data(withJSONObject: state).write(to: store)
        return store
    }

    func testResolverPrefersDefaultModelFile() throws {
        let model = try tempModelFile()
        let resolved = ModelTutorEngine.resolveProductionModelURL(
            environment: ["EARNPLAY_MODEL_PATH": model.path],
            registryStoreURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(resolved?.path, model.path)
    }

    func testResolverFallsBackToRegistryArtifact() throws {
        let snapshot = try tempModelFile()
        let store = try tempRegistryStore(activeBundleID: "previous-known-good",
                                           modelFilePath: snapshot.path)
        let resolved = ModelTutorEngine.resolveProductionModelURL(
            environment: ["EARNPLAY_MODEL_PATH": "/nonexistent-missing/EarnPlayModel.gguf"],
            registryStoreURL: store)
        XCTAssertEqual(resolved?.path, snapshot.path)
    }

    func testResolverReturnsNilWhenNothingResolves() throws {
        let resolved = ModelTutorEngine.resolveProductionModelURL(
            environment: ["EARNPLAY_MODEL_PATH": "/nonexistent-missing/EarnPlayModel.gguf"],
            registryStoreURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        XCTAssertNil(resolved)
    }

    // MARK: - Fix round 1 finding 6: warm-up deferred until first use

    func testWarmUpDeferredUntilFirstUse() async throws {
        let fake = FakeModel()
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 5)
        // Construction (plus a settle window for any eager dispatch)
        // starts no model load: a discarded engine costs nothing.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.warmUpCallCount, 0)
        // First use dispatches exactly one background warm-up.
        engine.onAsyncUpdate = { _ in }
        _ = engine.startSession()
        let deadline = Date().addingTimeInterval(2)
        while fake.warmUpCallCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(fake.warmUpCallCount, 1)
        // Later uses never re-dispatch.
        _ = engine.submitAnswer(q1Wrong)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fake.warmUpCallCount, 1)
    }

    // MARK: - Fix round 1 finding 7: deadline measured from submission

    func testQueuedReplyHonorsSubmissionDeadline() async {
        // 3d < timeout < 4d (d = 0.2s per call): the first two replies
        // fit their submission deadlines and serve model text; the
        // third dequeues with too little submission budget left and
        // falls back — without the submission-based deadline it would
        // serve model text on a fresh post-dequeue budget. The lease is
        // free throughout (every attempted call finishes), isolating
        // the deadline fix from the finding-4 lease.
        let fake = FakeModel(responses: ["Model line.", "Model line.", "Model line.", "Model line."],
                             delay: 0.2)
        let engine = ModelTutorEngine(inner: DemoTutorEngine(), generator: fake.generator, timeout: 0.7)
        let demo = DemoTutorEngine()
        _ = engine.startSession()
        _ = demo.startSession()

        let collector = UpdateCollector()
        let delivered = expectation(description: "all replies delivered")
        delivered.expectedFulfillmentCount = 3
        engine.onAsyncUpdate = { update in
            collector.append(update)
            delivered.fulfill()
        }

        let first = demo.submitAnswer(q1Wrong)
        let second = demo.submitAnswer("I added seven eight times")
        let third = demo.submitAnswer("55")
        _ = engine.submitAnswer(q1Wrong)
        _ = engine.submitAnswer("I added seven eight times")
        _ = engine.submitAnswer("55")

        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(collector.updates.count, 3)
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText), ["Model line.", "Model line."])
        XCTAssertEqual(collector.updates[0].turns.map(\.id), first.turns.map(\.id))
        XCTAssertEqual(collector.updates[1].turns.map(\.displayedText), ["Model line."])
        XCTAssertEqual(collector.updates[1].turns.map(\.id), second.turns.map(\.id))
        // Third reply: its submission budget expired in queue, so it
        // falls back to the deterministic wording (no fresh budget).
        XCTAssertEqual(collector.updates[2].turns, third.turns)
        XCTAssertEqual(fake.recordedPrompts.count, 4)
    }
}
