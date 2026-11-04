import Foundation
import EarnPlayCore

/// Injectable on-device text-generation seam (issue #93).
///
/// Mirrors `ModelQuestionProposer`'s shape: production runs over the T0.2
/// `ModelRuntime` (see `live(runtime:)`), tests inject scripted closures.
/// All three closures must be thread-safe: `generateText` and `warmUp`
/// run on background queues, and `isWarm` is read from both the calling
/// thread and background queues.
final class ModelTextGenerator {
    private let generate: (String) throws -> String
    private let warm: () throws -> Void
    private let checkWarm: () -> Bool

    init(generateText: @escaping (String) throws -> String,
         warmUp: @escaping () throws -> Void,
         isWarm: @escaping () -> Bool) {
        self.generate = generateText
        self.warm = warmUp
        self.checkWarm = isWarm
    }

    func generateText(_ prompt: String) throws -> String {
        try generate(prompt)
    }

    func warmUp() throws {
        try warm()
    }

    var isWarm: Bool { checkWarm() }

    /// Production generator over one `ModelRuntime` (unbound: the model
    /// file was already sha256-verified by the first-launch download,
    /// and the runtime still rejects non-GGUF files at load). Reports
    /// warm after the first successful load or generation.
    static func live(runtime: ModelRuntime, maxTokens: Int32 = ModelTutorEngine.modelMaxTokens) -> ModelTextGenerator {
        let state = WarmState()
        return ModelTextGenerator(
            generateText: { prompt in
                let response = try runtime.generate(prompt: prompt, maxTokens: maxTokens).response
                state.warmed = true
                return response
            },
            warmUp: {
                try runtime.load()
                state.warmed = true
            },
            isWarm: { state.warmed }
        )
    }

    /// Lock-guarded warm flag shared by the live closures above.
    private final class WarmState {
        private let lock = NSLock()
        private var value = false

        var warmed: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
        }
    }
}

/// Lock-guarded box for one background-call result.
private final class LockedBox<Value> {
    private let lock = NSLock()
    private var box: Value

    init(_ value: Value) {
        self.box = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return box
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            box = newValue
        }
    }
}

/// Model-backed chat tutor (issue #93): a `ChatTutorEngine` adapter that
/// serves tutor phrasing turns (encouragement, follow-up probes) from
/// real on-device Llama inference when the model runtime is available,
/// and falls back to the wrapped deterministic engine otherwise.
///
/// Fallback chain, per reply: warm model path serves the reply's
/// phrasing turns from `ModelRuntime.generate()`; a missing/unlinked
/// runtime, a cold runtime, a generation failure, a timeout, or a
/// rejected response serves the inner engine's deterministic turns
/// verbatim instead. The sync methods never block on inference: while
/// the model path is active they return the inner update with its turns
/// withheld and deliver the turns later through `onAsyncUpdate`, in
/// request order. Progress, composer, and the echo's revision label
/// always arrive synchronously, so the session-complete boundary and
/// every scoring input behave exactly as the inner engine's.
///
/// Solver authority: questions, hints, answer verdicts, progress, and
/// composers always come from the inner deterministic engine; the model
/// only rephrases encouragement/probe turns, preserving their ids and
/// kinds. Model prompts carry no question, answer, or verdict (see
/// `promptFor(kind:)`), so model text can structurally neither confirm,
/// deny, nor leak the solver's verdict. Nothing here is ever stub or
/// fake inference: model text comes only from the generator, and any
/// failure surfaces the deterministic fallback, never invented text.
/// A restart (`startSession`) supersedes in-flight replies: follow-ups
/// captured under an older epoch are dropped rather than appending
/// stale turns to the cleared thread (see `generation`).
final class ModelTutorEngine: ChatTutorEngine {
    /// Bounded wait per withheld reply (warm runtime only): generation
    /// past this deadline falls back to the deterministic turns.
    static let defaultTimeout: TimeInterval = 30
    /// Max tokens per tutor turn: short phrasing turns, like the spike.
    static let modelMaxTokens: Int32 = 48

    /// Production availability probe: the llama framework was linked at
    /// build time AND a model file resolves. File-existence only (no
    /// hashing), so it is safe on the main thread. When false the
    /// engine is pure deterministic fallback.
    static func isModelAvailable(fileManager: FileManager = .default) -> Bool {
        guard ModelRuntime.isRuntimeLinked else { return false }
        guard let url = ModelRuntime.defaultModelURL() else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Production factory: live model path when available, else the
    /// inner engine's deterministic behavior verbatim.
    convenience init(inner: ChatTutorEngine) {
        if Self.isModelAvailable(), let url = ModelRuntime.defaultModelURL() {
            self.init(inner: inner, generator: .live(runtime: ModelRuntime(modelPath: url)))
        } else {
            self.init(inner: inner, generator: nil)
        }
    }

    /// Test seam: explicit generator (nil = model absent) and timeout.
    init(inner: ChatTutorEngine, generator: ModelTextGenerator?, timeout: TimeInterval = ModelTutorEngine.defaultTimeout) {
        self.inner = inner
        self.generator = generator
        self.timeout = timeout
        if let generator {
            // Background warm-up (model load) at construction: the sync
            // path stays verbatim deterministic until the runtime
            // reports warm, so a cold start never delays a reply.
            workQueue.async { try? generator.warmUp() }
        }
    }

    private let inner: any ChatTutorEngine
    private let generator: ModelTextGenerator?
    private let timeout: TimeInterval
    /// Reply epoch: `startSession` clears the thread, so it bumps this
    /// and pipeline jobs captured under an older epoch are dropped
    /// instead of appending stale turns to the new session. Guarded by
    /// `stateLock` (written on the calling thread, read on the pipeline).
    private let stateLock = NSLock()
    private var generation = 0
    /// Serial reply pipeline: withheld replies are generated and
    /// delivered here in request order, so an async reply can never
    /// pass an earlier one. Never the main queue: sync methods only
    /// enqueue and return. Each pipeline wait is bounded by `timeout`,
    /// so a hung generation delays later replies by at most one
    /// timeout each, never forever.
    private let pipeline = DispatchQueue(label: "com.vhoangvu.earnplay.model-tutor", qos: .userInitiated)
    private let workQueue = DispatchQueue.global(qos: .userInitiated)

    /// True when the next reply takes the model path (test/diagnostic aid).
    var isModelPathActive: Bool { generator?.isWarm == true }

    var onAsyncUpdate: ((ChatEngineUpdate) -> Void)?

    func startSession() -> ChatEngineUpdate {
        let update = inner.startSession()
        return process(update, generation: beginNewGeneration())
    }
    func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
        process(inner.submitAnswer(plainText), generation: currentGeneration())
    }
    func requestHint() -> ChatEngineUpdate { process(inner.requestHint(), generation: currentGeneration()) }

    private func currentGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    private func beginNewGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation += 1
        return generation
    }

    func endSession() { inner.endSession() }
    func resumeSession() { inner.resumeSession() }
    func recordComposerActivity() { inner.recordComposerActivity() }
    var currentHintListenSink: (any HintListenEventSink)? { inner.currentHintListenSink }
    var isInputBlocked: Bool { inner.isInputBlocked }

    // MARK: - Reply processing

    /// Tutor turns the model may rephrase: encouragement and follow-up
    /// probes carry no verified content, so rewording them cannot teach
    /// wrong math. Questions and hints are solver-verified and are never
    /// withheld or rewritten; instructions are session framing.
    private static func isModelEligible(_ turn: ChatTurn) -> Bool {
        guard case .tutor(let message) = turn else { return false }
        return message.kind == .encouragement || message.kind == .probe
    }

    /// Fixed per-kind model prompt, assembled through the sanctioned
    /// `TutorPrompt` layer. Deliberately carries NO question, answer, or
    /// verdict: the model only rephrases encouragement/probes, so it is
    /// never told anything correctness-bearing and its text can neither
    /// confirm, deny, nor leak the solver's verdict. Exact wording is
    /// pinned by test; prompt changes are conscious updates.
    static func promptFor(kind: TutorMessageKind) -> String {
        let context: String
        let label: String
        switch kind {
        case .encouragement:
            label = "Tutor turn: encouragement."
            context = """
                Tutor turn: encouragement.
                Write one short encouraging sentence for an elementary-school child who is practising math.
                Do not state, confirm, or hint at any answer. Do not ask a question.
                Do not mention scores, rules, or thresholds.
                """
        case .probe:
            label = "Tutor turn: follow-up probe."
            context = """
                Tutor turn: follow-up probe.
                Write one short question asking the child to show one step of what they tried.
                Do not give or hint at the answer. Do not mention scores, rules, or thresholds.
                """
        default:
            label = "Tutor turn."
            context = "Tutor turn. Write one short tutor sentence. Do not state any answer."
        }
        return TutorPrompt.assemble(sessionContext: context, childInput: label)
    }

    private func process(_ update: ChatEngineUpdate, generation: Int) -> ChatEngineUpdate {
        // No subscriber, no model, or a cold runtime: the inner
        // update goes out verbatim and synchronously. In particular a
        // missing subscriber never withholds turns that nobody delivers.
        guard let generator, generator.isWarm, let deliver = onAsyncUpdate else { return update }
        let eligible = update.turns.indices.filter { Self.isModelEligible(update.turns[$0]) }
        guard !eligible.isEmpty else { return update }
        let prompts: [String] = eligible.map {
            guard case .tutor(let message) = update.turns[$0] else { return Self.promptFor(kind: .encouragement) }
            return Self.promptFor(kind: message.kind)
        }
        let replyTurns = update.turns
        pipeline.async { [weak self] in
            guard let self else { return }
            // A restart superseded this reply before it ran: drop it
            // without spending inference on a cleared thread.
            guard self.currentGeneration() == generation else { return }
            let deadline = Date().addingTimeInterval(self.timeout)
            var turns = replyTurns
            for (position, index) in eligible.enumerated() {
                guard deadline.timeIntervalSinceNow > 0 else { break }
                guard case .tutor(let message) = turns[index] else { continue }
                if let text = self.generateTurn(
                    generator: generator, prompt: prompts[position],
                    timeout: deadline.timeIntervalSinceNow
                ) {
                    turns[index] = .tutor(TutorMessage(id: message.id, text: text, kind: message.kind))
                }
            }
            // A restart landed mid-generation: the thread was cleared,
            // so this reply is stale and must not append to the new one.
            guard self.currentGeneration() == generation else { return }
            deliver(ChatEngineUpdate(turns: turns))
        }
        // Turns withheld for the async model reply; progress, composer,
        // and the echo's revision label stay synchronous, so the
        // session-complete boundary behaves exactly as the inner engine's.
        return ChatEngineUpdate(turns: [], progress: update.progress, composer: update.composer,
                                submittedTurnIsRevision: update.submittedTurnIsRevision)
    }

    /// One bounded model call on a worker queue: the worker result on
    /// success, nil on failure, timeout, or rejected text (the caller
    /// then keeps the deterministic turn). A call past its timeout keeps
    /// running detached — it still warms the runtime — but its text is
    /// discarded; the group accounts its late leave harmlessly.
    private func generateTurn(generator: ModelTextGenerator, prompt: String, timeout: TimeInterval) -> String? {
        let box = LockedBox<String?>(nil)
        let group = DispatchGroup()
        group.enter()
        workQueue.async {
            defer { group.leave() }
            box.value = try? generator.generateText(prompt)
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        guard let raw = box.value else { return nil }
        let clean = ChildTextSanitizer.plainText(raw)
        return clean.isEmpty ? nil : clean
    }
}
