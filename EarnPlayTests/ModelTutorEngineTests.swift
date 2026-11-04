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

        // Sync: turns withheld, everything else synchronous.
        let expected = demo.submitAnswer(q1Wrong)
        let sync = engine.submitAnswer(q1Wrong)
        XCTAssertEqual(sync.turns, [])
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
        XCTAssertEqual(sync.turns, [])

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
        XCTAssertEqual(sync.turns, [])
        XCTAssertLessThan(syncElapsed, 5, "sync call blocked on inference")

        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertEqual(collector.updates.map(\.turns), [expected.turns])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "wait was not bounded")
    }

    // MARK: - Solver authority: verdicts, questions, hints untouched

    func testSolverStaysAuthoritativeOverModelText() async throws {
        // Even a model response that sounds like a verdict changes
        // nothing but phrasing-turn text: progress, composer, revision
        // flags, questions, and hints stay deterministic.
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
        XCTAssertEqual(collector.updates[0].turns.map(\.displayedText),
                       ["Ninety-nine is exactly right!", "What step did you try?"])
        XCTAssertEqual(collector.updates[1].turns.map(\.displayedText), ["Model line."])
        // The correct reply's next question arrives verbatim: the model
        // never writes question content.
        let correctFollowUp = collector.updates[2]
        let expectedMessage = try XCTUnwrap(expectedCorrect.turns[0].tutorMessage)
        XCTAssertEqual(correctFollowUp.turns, [
            .tutor(TutorMessage(id: expectedMessage.id, text: "Model line.", kind: .encouragement)),
            expectedCorrect.turns[1],
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
        XCTAssertEqual(finalSync.turns, [])
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
        // The child echo renders synchronously; the model reply arrives async.
        XCTAssertEqual(viewModel.messages.count, 2)

        let deadline = Date().addingTimeInterval(5)
        while viewModel.messages.count < 4, Date() < deadline {
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
}
