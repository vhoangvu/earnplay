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

    /// Production generator over one `ModelRuntime` (digest-bound
    /// when a record knows it — see `makeProductionRuntime` — so a
    /// warm immutable cache hits by name; the runtime still rejects
    /// non-GGUF files at load). Reports warm after the first
    /// successful load or generation.
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
/// verbatim instead. The sync methods never block on inference and
/// always answer verbatim: every deterministic turn (including the
/// next question) renders immediately, so input is never accepted for
/// a question not yet shown, and the model path delivers rephrased
/// encouragement/probe replacements later through `onAsyncUpdate`, in
/// request order, applied in place by turn id. Progress, composer, and
/// the echo's revision label always arrive synchronously, so the
/// session-complete boundary and every scoring input behave exactly as
/// the inner engine's.
///
/// Solver authority: questions, hints, answer verdicts, progress, and
/// composers always come from the inner deterministic engine; the model
/// only rephrases encouragement/probe turns, preserving their ids and
/// kinds. Model prompts carry no question, answer, or verdict (see
/// `promptFor(kind:)`), and generated text carrying an unverified
/// correctness claim or answer-bearing content is rejected outright
/// (see `containsUnverifiedCorrectnessClaim`), so model text can
/// structurally neither confirm, deny, nor leak the solver's verdict.
/// Nothing here is ever stub or fake inference: model text comes only
/// from the generator, and any failure surfaces the deterministic
/// fallback, never invented text.
/// A restart (`startSession`) supersedes in-flight replies: follow-ups
/// captured under an older generation are dropped rather than appending
/// stale turns to the cleared thread (see `generation`), and every
/// async update carries its generation tag so the view model drops a
/// reply that was delivered just before the restart (see
/// `ChatEngineUpdate.sessionGeneration`).
final class ModelTutorEngine: ChatTutorEngine {
    /// Bounded wait per model-path reply (warm runtime only): generation
    /// past this deadline falls back to the deterministic turns.
    static let defaultTimeout: TimeInterval = 30
    /// Max tokens per tutor turn: short phrasing turns, like the spike.
    static let modelMaxTokens: Int32 = 48

    /// Production model-file resolution (finding 5): the default
    /// lookup when its file exists and passes the GGUF magic check,
    /// else the persisted registry's active bundle model file — a
    /// retained snapshot stays usable for inference even when the
    /// default/current file is gone or corrupt (fix round 3 finding
    /// 2: a corrupt default must not win over the validated
    /// snapshot), the same fallback the readiness gate accepts.
    /// Cheap (existence + 4-byte magic only, no hashing) and
    /// main-thread safe. No digest is bound here (that would hash on
    /// the main thread); the readiness gate already validated
    /// off-main, load still checks GGUF magic, and a file that
    /// vanishes after resolution fails load so the tutor falls back
    /// deterministically. The registry snapshot is not retained (no
    /// registry instance is held): the load copies bytes to an
    /// immutable artifact promptly, and a mid-load disappearance
    /// surfaces fallback, never an error.
    static func resolveProductionModelURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                          fileManager: FileManager = .default,
                                          registryStoreURL: URL? = nil) -> URL? {
        if let url = ModelRuntime.defaultModelURL(environment: environment, fileManager: fileManager),
           fileManager.fileExists(atPath: url.path),
           ModelRuntime.isGGUFFile(at: url) {
            return url
        }
        return VersionRegistry.activeBundleModelFileURL(storeURL: registryStoreURL, fileManager: fileManager)
    }

    /// Production runtime construction (fix round 3 finding 1):
    /// binds the expected content digest when a record already knows
    /// it, so a warm immutable cache hits by name with no
    /// full-source hash and no temp copy on a hit. The digest comes
    /// from the pinned download record at the first-launch
    /// destination (that file was installed sha256-verified), else
    /// from the active bundle record when the resolved file IS its
    /// validated snapshot. Any other file (env/Documents/cache paths
    /// no record describes, or a file that merely shares bytes with
    /// the snapshot) stays unbound: the runtime keeps its hash-first
    /// fallback, and a bound digest is still enforced before any
    /// early return, exactly as on the copy path. Cheap (path
    /// compares + one small registry decode, no hashing) and
    /// main-thread safe.
    static func makeProductionRuntime(for url: URL, fileManager: FileManager = .default,
                                      registryStoreURL: URL? = nil) -> ModelRuntime {
        let digest: String?
        if url.standardizedFileURL.path == ModelDownloader.defaultDestinationURL(fileManager: fileManager).standardizedFileURL.path {
            digest = ModelDownloadConfiguration.production.expectedSHA256
        } else if let snapshot = VersionRegistry.activeBundleModelFileURL(storeURL: registryStoreURL, fileManager: fileManager),
                  snapshot.standardizedFileURL.path == url.standardizedFileURL.path {
            digest = VersionRegistry.activeBundleModelContentDigest(storeURL: registryStoreURL, fileManager: fileManager)
        } else {
            digest = nil
        }
        return ModelRuntime(modelPath: url, expectedContentDigest: digest)
    }

    /// Production availability probe: the llama framework was linked at
    /// build time AND a model file resolves (default lookup or
    /// retained registry artifact). Existence checks only (no
    /// hashing), so it is safe on the main thread. When false the
    /// engine is pure deterministic fallback.
    static func isModelAvailable(fileManager: FileManager = .default) -> Bool {
        guard ModelRuntime.isRuntimeLinked else { return false }
        return resolveProductionModelURL(fileManager: fileManager) != nil
    }

    /// Production factory: live model path when available, else the
    /// inner engine's deterministic behavior verbatim.
    convenience init(inner: ChatTutorEngine) {
        if Self.isModelAvailable(), let url = Self.resolveProductionModelURL() {
            self.init(inner: inner, generator: .live(runtime: Self.makeProductionRuntime(for: url)))
        } else {
            self.init(inner: inner, generator: nil)
        }
    }

    /// Test seam: explicit generator (nil = model absent) and timeout.
    /// Construction starts no model work: warm-up is deferred until
    /// the retained engine's first use (see `ensureWarmUpStarted`), so
    /// engines constructed and discarded by a parent view refresh
    /// never start unused model loads.
    init(inner: ChatTutorEngine, generator: ModelTextGenerator?, timeout: TimeInterval = ModelTutorEngine.defaultTimeout) {
        self.inner = inner
        self.generator = generator
        self.timeout = timeout
    }

    private let inner: any ChatTutorEngine
    private let generator: ModelTextGenerator?
    private let timeout: TimeInterval
    /// Reply generation: `startSession` clears the thread, so it bumps
    /// this and pipeline jobs captured under an older generation are
    /// dropped instead of appending stale turns to the new session.
    /// Guarded by `stateLock` (written on the calling thread, read on
    /// the pipeline and by the view model's staleness check).
    private let stateLock = NSLock()
    private var generation = 0
    /// One-shot warm-up gate (finding 6): set under `stateLock` when
    /// the first use dispatches the background model load.
    private var didBeginWarmUp = false
    /// Serial reply pipeline: rephrase jobs run and deliver here in
    /// request order, so an async reply can never pass an earlier one.
    /// Never the main queue: sync methods only enqueue and return.
    /// Each job's total wait is bounded by one `timeout` measured from
    /// its submission (see `process`), so a hung generation delays
    /// later replies by at most one timeout each, never forever.
    private let pipeline = DispatchQueue(label: "com.vhoangvu.earnplay.model-tutor", qos: .userInitiated)
    private let workQueue = DispatchQueue.global(qos: .userInitiated)
    /// Single-flight model-call lease (finding 4): a timed-out worker
    /// keeps running while holding the runtime lock, so a later call
    /// must fall back rather than queue obsolete inference behind it.
    /// Acquired (without waiting) before dispatching a worker,
    /// released by the worker when its call finishes — including after
    /// the waiter already timed out — so the model path resumes once
    /// the stale call actually ends.
    private let inferenceLease = DispatchSemaphore(value: 1)

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
    /// Live session generation for the view model's async staleness
    /// check: bumped by every `startSession` (see `generation`).
    var currentSessionGeneration: Int { currentGeneration() }

    /// Deferred model warm-up (finding 6): the first use of the
    /// retained engine dispatches the background model load, once.
    /// The sync path stays verbatim deterministic until the runtime
    /// reports warm, so a cold start never delays a reply — and an
    /// engine that is constructed but never used (a parent view
    /// refresh discards it in favor of the retained one) starts no
    /// model load at all.
    private func ensureWarmUpStarted() {
        stateLock.lock()
        guard !didBeginWarmUp else {
            stateLock.unlock()
            return
        }
        didBeginWarmUp = true
        stateLock.unlock()
        if let generator {
            workQueue.async { try? generator.warmUp() }
        }
    }

    // MARK: - Reply processing

    /// Tutor turns the model may rephrase: encouragement and follow-up
    /// probes carry no verified content, so rewording them cannot teach
    /// wrong math. Questions and hints are solver-verified and are never
    /// rephrased; instructions are session framing.
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
        ensureWarmUpStarted()
        // No subscriber, no model, or a cold runtime: the inner
        // update goes out verbatim and synchronously.
        guard let generator, generator.isWarm, let deliver = onAsyncUpdate else { return update }
        let eligible = update.turns.indices.filter { Self.isModelEligible(update.turns[$0]) }
        guard !eligible.isEmpty else { return update }
        let prompts: [String] = eligible.map {
            guard case .tutor(let message) = update.turns[$0] else { return Self.promptFor(kind: .encouragement) }
            return Self.promptFor(kind: message.kind)
        }
        let replyTurns = update.turns
        // Finding 7: the reply's deadline starts at SUBMISSION, before
        // the serial pipeline queues it — queue wait counts against the
        // timeout, so rapid submissions behind a stalled generation
        // fall back within one timeout of their own submission instead
        // of each waiting out a fresh timeout after dequeueing.
        let deadline = Date().addingTimeInterval(timeout)
        pipeline.async { [weak self] in
            guard let self else { return }
            // A restart superseded this reply before it ran: drop it
            // without spending inference on a cleared thread.
            guard self.currentGeneration() == generation else { return }
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
            // Eligible turns only (rephrased or deterministic fallback),
            // tagged with the requesting generation: the sync update
            // already rendered every turn, so the view model applies
            // these as in-place replacements by turn id and drops them
            // if a restart landed between delivery and application.
            deliver(ChatEngineUpdate(turns: eligible.map { turns[$0] }, sessionGeneration: generation))
        }
        // Finding 2: the sync update is the inner update VERBATIM —
        // every deterministic turn, including the next question after
        // a correct answer, renders before inference completes, so
        // Send/Hint always act on the shown question. The model path
        // only upgrades eligible phrasing in place via the async
        // replacements above; progress, composer, and the echo's
        // revision label behave exactly as the inner engine's.
        return update
    }

    /// One bounded model call on a worker queue: the worker result on
    /// success, nil when another call is still in flight (finding 4),
    /// on failure, timeout, or rejected text (the caller then keeps
    /// the deterministic turn). A call past its timeout keeps running
    /// detached — it still holds the lease and warms the runtime — but
    /// its text is discarded; the group accounts its late leave
    /// harmlessly and its lease release reopens the model path.
    private func generateTurn(generator: ModelTextGenerator, prompt: String, timeout: TimeInterval) -> String? {
        // Finding 4: single-flight — a timed-out worker still holds
        // the runtime lock, so a new call must fall back NOW rather
        // than queue obsolete inference behind it and run past its own
        // deadline. Never waits for the lease: waiting here would
        // serialize behind the stale call this avoids.
        guard inferenceLease.wait(timeout: .now()) == .success else { return nil }
        let lease = inferenceLease
        let box = LockedBox<String?>(nil)
        let group = DispatchGroup()
        group.enter()
        workQueue.async {
            // Fix round 3 finding 3: release the lease BEFORE leaving
            // the group — the waiter (or a later call hitting the
            // `wait(.now())` guard) must never observe completion
            // with the lease still held, which would spuriously force
            // fallback. Single-flight semantics and the never-wait
            // guard are unchanged.
            defer {
                lease.signal()
                group.leave()
            }
            box.value = try? generator.generateText(prompt)
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        guard let raw = box.value else { return nil }
        let clean = ChildTextSanitizer.plainText(raw)
        guard !clean.isEmpty, !Self.containsUnverifiedCorrectnessClaim(clean) else { return nil }
        return clean
    }

    /// Fail-closed screen for generated phrasing (finding 3, round 2
    /// finding 2): true when the text asserts answer correctness,
    /// carries answer-bearing content, or otherwise states math or
    /// success the model cannot verify. The model is never told the
    /// question, answer, or verdict, so ANY correctness or success
    /// claim in its output is unverified by construction — including
    /// a true-sounding one — and the turn falls back to the
    /// deterministic wording instead of passing through on character
    /// filtering. Digits, number words (hyphenated compounds like
    /// "fifty-four" match on each part), arithmetic/result words
    /// ("add", "sum", "twice", "calculate"), verdict words, and
    /// success/praise phrasing ("nailed it", "crushed it", "great
    /// job", "well done", scores, stars) are all rejected:
    /// generated text must never be the source of a correctness or
    /// success claim — the deterministic path already supplies
    /// encouragement. Generic effort, process, and ability praise
    /// ("Nice trying", "Keep up the good work", "You are bright and
    /// capable") passes, as do bare ordinals ("first", "second"),
    /// which state no math. A denylist cannot name every paraphrase,
    /// so this is one layer among several: prompts also forbid
    /// verdicts (see `promptFor`), and anything suspicious falls
    /// back rather than through.
    static func containsUnverifiedCorrectnessClaim(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        return text.range(of: Self.deniedClaimPattern,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Word-boundary alternation over `deniedClaimTerms`, built once.
    private static let deniedClaimPattern: String =
        #"\b("# + deniedClaimTerms.joined(separator: "|") + #")\b"#

    /// Denied terms for the screen above. Deliberately NOT denied:
    /// effort/process/ability praise (nice, good, work, effort,
    /// bright, capable, hard, best, go), bare ordinals (first,
    /// second), and probe verbs (show, step, solve, point) — those
    /// pass through, everything suspicious falls back.
    private static let deniedClaimTerms: [String] = [
        // Verdict words (finding 3): explicit correctness claims.
        "correct", "correctly", "incorrect", "incorrectly",
        "right", "wrong", "true", "false", "answer", "answers",
        // Spelled-out numbers (round 2 finding 2): any one of these
        // can carry an unverified math claim ("Seven times eight
        // equals fifty-four").
        "zero", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "hundreds", "thousand", "thousands",
        "million", "millions", "billion", "billions",
        "dozen", "dozens", "half", "halves", "halfway",
        "quarter", "quarters",
        // Arithmetic and result words: "plus", "equals", and "total"
        // turn even number-free text into math content.
        "plus", "minus", "times", "multiplied", "multiply",
        "divided", "divide", "equals", "equal", "total",
        "product", "quotient", "remainder", "subtract",
        "subtracted", "subtraction", "multiplication", "division",
        "add", "adds", "added", "adding", "addition",
        "sum", "sums", "summed", "difference", "differences",
        "calculate", "calculates", "calculated", "calculating",
        "calculation", "twice", "thrice", "double", "doubles",
        "doubled", "triple", "triples", "tripled",
        // Success/praise verdicts (round 2 finding 2): completion
        // and evaluation claims ("You nailed it!", "Great job!").
        "nail", "nails", "nailed", "ace", "aced", "solved",
        "crush", "crushes", "crushed", "crushing",
        "kill", "kills", "killed", "killing",
        "slay", "slays", "slayed", "slaying",
        "done", "mastered", "perfect", "perfectly", "perfection",
        "excellent", "excellence", "great", "greatly", "greatest",
        "awesome", "amazing", "fantastic", "wonderful",
        "brilliant", "outstanding", "superb", "stellar",
        "incredible", "fabulous", "splendid", "terrific",
        "marvelous", "marvellous", "phenomenal", "remarkable",
        "impressive", "proud", "job", "jobs", "winner",
        "champion", "superstar", "congratulations", "congrats",
        "bravo", "hooray", "hurray", "hurrah", "yay", "woohoo",
        "win", "wins", "winning", "won", "lose", "loses",
        "losing", "lost", "pass", "passing", "passed", "fail",
        "failing", "failed", "score", "scores", "scored",
        "scoring", "grade", "grades", "star", "stars", "success",
        "succeed", "succeeds", "succeeded", "successful",
        "successfully", "complete", "completely", "completed",
        "finish", "finished", "exactly", "precisely", "absolutely",
        "well done", "way to go", "did well", "done well", "do well",
    ]
}
