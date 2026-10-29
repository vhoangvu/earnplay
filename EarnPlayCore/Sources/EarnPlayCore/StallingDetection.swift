import Foundation

/// Stalling probes (T1.5) — deterministic, never delegated to a model.
///
/// `StallingDetector` (the LLD owner module name) classifies recent
/// interaction as trying or stalling from observable signals only, and
/// fires at most one conversational probe per stalling episode ("show me
/// one step" / "what have you tried?"). A substantive reply to a probe is
/// the strongest effort signal available (LLD 4.1) and is recorded back
/// into the T1.4 effort event stream as effort. See
/// `Docs/StallingProbes.md`.
///
/// Firing rules — no single signal decides, the pattern decides:
/// - Repeated identical wrong answers: `identicalAnswersThreshold` (3)
///   consecutive identical wrong answers with no revision since the run
///   started. Varied answers never fire this rule.
/// - Rapid guessing: `rapidAnswersThreshold` (3) consecutive answers with
///   thinking-range-breaking gaps (under `rapidAnswerSeconds`, ~2s per
///   the LLD guessing line) and no revision.
/// - Hint used as an answer key: a hint interaction followed by a correct
///   answer within `hintAnswerKeyWindowSeconds` with no revision or work
///   shown in between. A hint followed by a changed answer after time is
///   trying evidence and never fires.
/// An uncertain classification defaults to a probe, never an accusation:
/// the probe is a conversational question, not a verdict.

// MARK: - Probe prompt

/// The two conversational probe wordings from the task spec. Prompts
/// alternate across probes in a session, starting with `.showOneStep`,
/// so repeated episodes do not sound like a stuck recording. T1.8 adopts
/// the probe's `TutorMessage` (kind `.probe`) into the chat thread.
public enum StallProbePrompt: String, Equatable, Sendable, CaseIterable {
    case showOneStep
    case whatHaveYouTried

    /// Child-facing probe text. Each contains its spec phrase verbatim
    /// ("show me one step" / "what have you tried").
    public var messageText: String {
        switch self {
        case .showOneStep:
            return "Show me one step — how did you start?"
        case .whatHaveYouTried:
            return "What have you tried so far?"
        }
    }
}

// MARK: - Signals and classification

/// Which stalling pattern fired a probe. Recorded on the probe so T1.6's
/// Decision log can name the evidence observed.
public enum StallSignal: String, Equatable, Sendable {
    /// The same wrong answer resubmitted without revision or new working.
    case repeatedIdenticalAnswers
    /// Consecutive answers too fast to have been read and worked.
    case rapidGuessing
    /// A hint followed by an instant correct answer with no work shown.
    case hintUsedAsAnswerKey
}

/// Trying / stalling / uncertain classification consumed by EffortScorer
/// and (later) the trade managers' offer decision.
public enum StallClassification: String, Equatable, Sendable {
    case trying
    case stalling
    case uncertain
}

// MARK: - Probe

/// One fired probe: the prompt, its chat message, when it fired, and why.
public struct StallProbe: Equatable, Sendable {
    /// 1-based sequence number within the session.
    public var sequenceNumber: Int
    public var prompt: StallProbePrompt
    /// Chat-thread message (kind `.probe`); T1.8 renders this directly.
    public var message: TutorMessage
    public var triggeredAt: Date
    public var signals: [StallSignal]

    public init(sequenceNumber: Int, prompt: StallProbePrompt,
                triggeredAt: Date, signals: [StallSignal]) {
        self.sequenceNumber = sequenceNumber
        self.prompt = prompt
        self.message = TutorMessage(
            id: "probe-\(sequenceNumber)", text: prompt.messageText, kind: .probe)
        self.triggeredAt = triggeredAt
        self.signals = signals
    }
}

// MARK: - Configuration

/// Detector thresholds. Defaults encode the LLD lines; tests and scripted
/// fixtures may narrow them, never widen them past recognition.
public struct StallDetectorConfiguration: Equatable, Sendable {
    /// Consecutive identical wrong answers that fire a probe. Default 3.
    public var identicalAnswersThreshold: Int
    /// Inter-attempt gap under which an answer counts as rapid (guessing
    /// line: "under about 2 seconds on multi-step problems"). Default 2.
    public var rapidAnswerSeconds: TimeInterval
    /// Consecutive rapid answers that fire a probe. Default 3.
    public var rapidAnswersThreshold: Int
    /// Window after a hint interaction in which a correct answer with no
    /// revision counts as answer-key use. Default 10 seconds.
    public var hintAnswerKeyWindowSeconds: TimeInterval
    /// Minimum trimmed characters for a probe reply to count as
    /// substantive effort. Default 3: filters "ok"/"?"-style non-answers
    /// while accepting any real phrase.
    public var substantiveReplyMinimumCharacters: Int

    public init(identicalAnswersThreshold: Int = 3,
                rapidAnswerSeconds: TimeInterval = 2,
                rapidAnswersThreshold: Int = 3,
                hintAnswerKeyWindowSeconds: TimeInterval = 10,
                substantiveReplyMinimumCharacters: Int = 3) {
        self.identicalAnswersThreshold = max(2, identicalAnswersThreshold)
        self.rapidAnswerSeconds = max(0, rapidAnswerSeconds)
        self.rapidAnswersThreshold = max(2, rapidAnswersThreshold)
        self.hintAnswerKeyWindowSeconds = max(0, hintAnswerKeyWindowSeconds)
        self.substantiveReplyMinimumCharacters = max(1, substantiveReplyMinimumCharacters)
    }

    public static let `default` = StallDetectorConfiguration()
}

// MARK: - Reply outcome

/// What `submitProbeReply` decided about the reply text.
public enum StallProbeReplyOutcome: Equatable, Sendable {
    /// No probe is waiting for a reply; nothing was recorded.
    case noProbePending
    /// The reply was substantive: effort was recorded and the episode
    /// closed. Carries the answered probe's sequence number.
    case substantive(probeSequenceNumber: Int)
    /// Too short to count as effort (LLD: silence keeps the stalling
    /// classification). No effort was recorded; the probe stays pending.
    case notSubstantive
}

// MARK: - Detector

/// Classifies recent interaction and fires conversational probes.
///
/// One detector per session. Feed it the same events the T1.4
/// `EffortSessionRecorder` receives (attempts with answer text and
/// correctness, revisions, hint interactions); when a stalling pattern
/// dominates it returns a `StallProbe` from the recording call. Use
/// `StallProbeSession` for the pre-wired detector-plus-recorder pair.
///
/// Episode rule: a probe fires at most once per stalling episode. After a
/// probe fires, the episode stays open — further identical or rapid
/// answers fire nothing — until trying evidence closes it (a substantive
/// probe reply, an answer revision, a varied answer, or a correct
/// answer). A later new episode may probe again.
public final class StallingDetector: @unchecked Sendable {
    public let configuration: StallDetectorConfiguration
    private let now: () -> Date
    private let lock = NSLock()

    private var attemptCount = 0
    private var lastAttemptDate: Date?
    private var lastAnswerNormalized: String?
    private var identicalRunLength = 0
    private var rapidRunLength = 0
    private var revisionObservedSinceHint = false
    private var lastHintDate: Date?
    private var hintPendingAnswerKeyCheck = false
    private var tryingEvidenceObserved = false

    private var probeCount = 0
    private var episodeOpen = false
    private var _pendingProbe: StallProbe?
    private var _probesFired: [StallProbe] = []

    public init(configuration: StallDetectorConfiguration = .default,
                now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
    }

    /// The probe waiting for a reply, if any.
    public var pendingProbe: StallProbe? {
        lock.lock(); defer { lock.unlock() }
        return _pendingProbe
    }

    /// Every probe fired this session, in order.
    public var probesFired: [StallProbe] {
        lock.lock(); defer { lock.unlock() }
        return _probesFired
    }

    /// Current classification: `.stalling` while a probe is pending, else
    /// `.trying` once trying evidence has been observed, else `.uncertain`.
    public var classification: StallClassification {
        lock.lock(); defer { lock.unlock() }
        if _pendingProbe != nil { return .stalling }
        return tryingEvidenceObserved ? .trying : .uncertain
    }

    // MARK: Recording

    /// Records an answer attempt. Returns the fired probe, if this attempt
    /// completes a stalling pattern while no episode is open.
    ///
    /// - Parameters:
    ///   - answer: the submitted answer text; identical runs compare the
    ///     trimmed, case-insensitive form.
    ///   - isCorrect: judged against the solver-verified answer (LLD §5).
    ///     A correct answer is progress: it closes any open episode and
    ///     resets the stalling runs. The one exception is the answer-key
    ///     pattern (hint, then an instant correct answer with no revision),
    ///     which still fires its probe so the child can show the step.
    @discardableResult
    public func recordAttempt(answer: String, isCorrect: Bool,
                              at date: Date? = nil) -> StallProbe? {
        lock.lock(); defer { lock.unlock() }
        let at = date ?? now()
        attemptCount += 1
        if isCorrect {
            return recordCorrectAttemptLocked(answer: answer, at: at)
        }

        // A wrong answer after a hint is never answer-key use; the pending
        // hint check resolves here. (A varied answer is additionally
        // trying evidence via the branch below.)
        hintPendingAnswerKeyCheck = false

        let normalized = Self.normalize(answer)
        if !normalized.isEmpty, normalized == lastAnswerNormalized {
            identicalRunLength += 1
        } else {
            // A varied answer is trying evidence: it closes an open
            // episode (no spam) and restarts the identical run. The very
            // first attempt of a session is not evidence of anything yet.
            if attemptCount > 1 { tryingEvidenceObserved = true }
            if episodeOpen { closeEpisodeLocked() }
            identicalRunLength = 1
        }
        lastAnswerNormalized = normalized

        if let previous = lastAttemptDate {
            let gap = at.timeIntervalSince(previous)
            if gap >= 0, gap < configuration.rapidAnswerSeconds {
                rapidRunLength += 1
            } else {
                // Thinking-range gap: breaks the rapid run.
                rapidRunLength = 1
            }
        } else {
            rapidRunLength = 1
        }
        lastAttemptDate = at

        return maybeFireLocked(at: at)
    }

    /// Records an answer revision (LLD §3.1: the child engaging and
    /// changing their mind). A revision is trying evidence: it closes any
    /// open episode and breaks the stalling runs.
    public func recordRevision(at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        _ = date
        tryingEvidenceObserved = true
        revisionObservedSinceHint = true
        if episodeOpen { closeEpisodeLocked() }
        resetRunsLocked()
        hintPendingAnswerKeyCheck = false
    }

    /// Records a hint interaction for answer-key detection
    /// (hint-then-instant-correct). Pair with
    /// `recordAttempt(answer:isCorrect:)` for the following answer.
    public func recordHintInteraction(at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        lastHintDate = date ?? now()
        hintPendingAnswerKeyCheck = true
        revisionObservedSinceHint = false
    }

    /// A hint read aloud is a hint interaction for timing purposes.
    /// (The T1.4 recorder stays the canonical hint-listen sink for effort
    /// counting; call this too when the detector must see hint timing.)
    public func recordHintListen(_ event: HintListenEvent) {
        recordHintInteraction(at: event.emittedAt)
    }

    // MARK: Probe replies

    /// True when the reply text counts as substantive effort (LLD 4.1).
    public func isSubstantiveReply(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= configuration.substantiveReplyMinimumCharacters
    }

    /// Submits the child's reply to the pending probe. A substantive reply
    /// closes the episode (LLD: it outweighs earlier stalling signals on
    /// the question); anything else leaves the probe pending. Recording
    /// the reply as T1.4 effort is `StallProbeSession`'s job.
    public func submitProbeReply(_ text: String,
                                 at date: Date? = nil) -> StallProbeReplyOutcome {
        lock.lock(); defer { lock.unlock() }
        _ = date
        guard let pending = _pendingProbe else { return .noProbePending }
        guard isSubstantiveReply(text) else { return .notSubstantive }
        tryingEvidenceObserved = true
        closeEpisodeLocked()
        resetRunsLocked()
        return .substantive(probeSequenceNumber: pending.sequenceNumber)
    }

    // MARK: Private

    private static func normalize(_ answer: String) -> String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func resetRunsLocked() {
        identicalRunLength = 0
        rapidRunLength = 0
    }

    private func closeEpisodeLocked() {
        episodeOpen = false
        _pendingProbe = nil
    }

    private func recordCorrectAttemptLocked(answer: String, at: Date) -> StallProbe? {
        lastAttemptDate = at
        lastAnswerNormalized = Self.normalize(answer)
        // Answer-key pattern: hint, then an instant correct answer with no
        // revision. The probe still fires — the child got it right, but
        // showing one step verifies the hint was help, not an answer key.
        if hintPendingAnswerKeyCheck, let hintDate = lastHintDate {
            hintPendingAnswerKeyCheck = false
            let gap = at.timeIntervalSince(hintDate)
            if gap >= 0, gap < configuration.hintAnswerKeyWindowSeconds,
               !revisionObservedSinceHint {
                tryingEvidenceObserved = true
                resetRunsLocked()
                return fireLocked(at: at, signals: [.hintUsedAsAnswerKey])
            }
        }
        // Ordinary progress: the episode is over, whatever came before.
        tryingEvidenceObserved = true
        if episodeOpen { closeEpisodeLocked() }
        resetRunsLocked()
        return nil
    }

    private func maybeFireLocked(at date: Date) -> StallProbe? {
        if episodeOpen { return nil }
        // A revision breaks both runs (recordRevision resets them), so by
        // the time a threshold is reached here, no revision intervened.
        var signals: [StallSignal] = []
        if identicalRunLength >= configuration.identicalAnswersThreshold {
            signals.append(.repeatedIdenticalAnswers)
        }
        if rapidRunLength >= configuration.rapidAnswersThreshold,
           attemptCount >= configuration.rapidAnswersThreshold {
            signals.append(.rapidGuessing)
        }
        guard !signals.isEmpty else { return nil }
        return fireLocked(at: date, signals: signals)
    }

    private func fireLocked(at date: Date, signals: [StallSignal]) -> StallProbe? {
        if episodeOpen { return nil }
        probeCount += 1
        let prompt: StallProbePrompt = probeCount % 2 == 1 ? .showOneStep : .whatHaveYouTried
        let probe = StallProbe(sequenceNumber: probeCount, prompt: prompt,
                               triggeredAt: date, signals: signals)
        episodeOpen = true
        _pendingProbe = probe
        _probesFired.append(probe)
        return probe
    }
}

// MARK: - Session facade (detector + T1.4 recorder)

/// One practice session's stalling-plus-effort wiring.
///
/// Owns a `StallingDetector` and the T1.4 `EffortSessionRecorder` for the
/// same session. Attempt, revision, and hint calls feed both — the attempt
/// counts toward the T1.4 floor/score exactly as a direct recorder call
/// would — and a substantive probe reply is recorded as effort: one
/// follow-up interaction (LLD 3.3: replying to a follow-up question is a
/// real hint-or-follow-up interaction for the floor) plus one explanation
/// (LLD 4.1: the strongest effort signal available).
///
/// Non-substantive replies record only a generic interaction (active-time
/// accounting) and leave the probe pending; replies with no probe pending
/// record nothing.
public final class StallProbeSession: @unchecked Sendable {
    public let detector: StallingDetector
    public let recorder: EffortSessionRecorder

    public init(startedAt: Date,
                detectorConfiguration: StallDetectorConfiguration = .default,
                idlePauseSeconds: TimeInterval = ActiveTimeTracker.defaultIdlePauseSeconds,
                now: @escaping () -> Date = Date.init) {
        self.recorder = EffortSessionRecorder(
            startedAt: startedAt, idlePauseSeconds: idlePauseSeconds, now: now)
        self.detector = StallingDetector(configuration: detectorConfiguration, now: now)
    }

    /// Pre-wired pair for tests that inject clocks or share a recorder.
    public init(recorder: EffortSessionRecorder, detector: StallingDetector) {
        self.recorder = recorder
        self.detector = detector
    }

    public var pendingProbe: StallProbe? { detector.pendingProbe }
    public var probesFired: [StallProbe] { detector.probesFired }
    public var classification: StallClassification { detector.classification }

    /// Records an answer attempt on both the detector and the T1.4
    /// recorder. Returns the fired probe, if any.
    @discardableResult
    public func recordAttempt(answer: String, isCorrect: Bool,
                              isGenuine: Bool = true,
                              at date: Date? = nil) -> StallProbe? {
        let probe = detector.recordAttempt(
            answer: answer, isCorrect: isCorrect, at: date)
        recorder.recordAttempt(isGenuine: isGenuine, at: date)
        return probe
    }

    public func recordRevision(at date: Date? = nil) {
        detector.recordRevision(at: date)
        recorder.recordAnswerRevision(at: date)
    }

    public func recordHintInteraction(at date: Date? = nil) {
        detector.recordHintInteraction(at: date)
        recorder.recordHintInteraction(at: date)
    }

    public func recordInteraction(at date: Date? = nil) {
        recorder.recordInteraction(at: date)
    }

    /// Submits the child's reply to the pending probe. A substantive reply
    /// records one follow-up interaction plus one explanation on the T1.4
    /// recorder and closes the episode.
    public func submitProbeReply(_ text: String,
                                 at date: Date? = nil) -> StallProbeReplyOutcome {
        let outcome = detector.submitProbeReply(text, at: date)
        switch outcome {
        case .substantive:
            recorder.recordFollowUpInteraction(at: date)
            recorder.recordExplanation(at: date)
        case .notSubstantive:
            recorder.recordInteraction(at: date)
        case .noProbePending:
            break
        }
        return outcome
    }

    /// Signals as of `date` (see `EffortSessionRecorder.signals(at:)`).
    public func signals(at date: Date? = nil) -> EffortSignals {
        recorder.signals(at: date)
    }

    /// Scores the recorded session as of now.
    public func evaluate(_ scorer: EffortScorer) -> EffortScore {
        recorder.evaluate(scorer)
    }
}
