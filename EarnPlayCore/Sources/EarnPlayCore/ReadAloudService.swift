import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Grade band (LLD Section 2 / HLD grade bands)

/// Grade band selected by the grade parameter. Band A is grades 1--2,
/// Band B is grades 3--5 (the demo ships grade 4, Band B).
public enum GradeBand: String, Equatable, Sendable {
    case bandA
    case bandB

    public init(grade: String) {
        switch grade.trimmingCharacters(in: .whitespaces) {
        case "1", "2":
            self = .bandA
        default:
            // Grades 3--5, and any unrecognised value, use Band B. The demo
            // only ships Band B behaviour, so defaulting here never enables
            // the v1 Band A auto-read path by accident.
            self = .bandB
        }
    }
}

// MARK: - Tutor message shape (T1.8 integration point)

/// Kind of a tutor message in the chat thread. Questions, hints and
/// instructions come from T1.1--T1.3; encouragement and probes are also
/// tutor messages in the thread (HLD chat description).
public enum TutorMessageKind: String, Equatable, Sendable {
    case question
    case hint
    case instruction
    case encouragement
    case probe

    public var isHint: Bool { self == .hint }
}

/// Minimal tutor-message shape the speaker button attaches to.
///
/// T1.8 integration point: the chat UI must pass, for every tutor message,
/// the message text and whether it is a hint. It does that by building a
/// `TutorMessage` (text + kind) and handing it, together with the shared
/// `ReadAloudService`, to `SpeakerButton`. The chat UI holds no TTS logic
/// of its own; it only renders the button on every tutor message.
public struct TutorMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let kind: TutorMessageKind

    public init(id: String, text: String, kind: TutorMessageKind) {
        self.id = id
        self.text = text
        self.kind = kind
    }

    public var isHint: Bool { kind.isHint }
}

// MARK: - Hint-listen event (for EffortScorer, T1.4)

/// Emitted exactly once each time a hint message is read aloud, so the
/// EffortScorer (T1.4) can count the hint-listen as a hint interaction
/// (LLD 3.5). Non-hint messages never produce this event.
public struct HintListenEvent: Equatable, Sendable {
    public let messageID: String
    public let messageText: String
    public let emittedAt: Date

    public init(messageID: String, messageText: String, emittedAt: Date) {
        self.messageID = messageID
        self.messageText = messageText
        self.emittedAt = emittedAt
    }
}

/// Sink the EffortScorer (T1.4) implements to receive hint-listen events.
/// Until T1.4 lands, the service also keeps its own `hintListenEvents`
/// log so the behaviour is testable on its own.
public protocol HintListenEventSink: AnyObject {
    func recordHintListen(_ event: HintListenEvent)
}

// MARK: - Speech engine boundary

/// The only boundary that touches speech hardware. The real engine wraps
/// `AVSpeechSynthesizer`; tests substitute a recording fake at this
/// boundary only, never faking the service logic above it.
///
/// On-device rule: implementations must use the system's built-in speech
/// only. No network calls and no downloaded voices, ever.
@MainActor
public protocol SpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    /// Called when an utterance finishes naturally (not when stopped).
    var onPlaybackFinished: (() -> Void)? { get set }
    /// Starts speaking with a verified OS-bundled voice. Returns false
    /// when no bundled voice is available: nothing is spoken, and the
    /// caller must surface unavailability rather than mark playback
    /// active. Implementations must never hand the synthesizer an
    /// utterance whose voice was not verified bundled, and must never
    /// fall back to a downloaded voice or a network fetch.
    @discardableResult
    func speak(text: String) -> Bool
    func stopSpeaking()
}

#if canImport(AVFoundation)
/// Real on-device speech engine backed by `AVSpeechSynthesizer`.
///
/// Uses only a verified OS-bundled voice. It never calls any
/// voice-download API and contains no networking code, so it works in
/// Airplane Mode with no downloaded voice installed. When no bundled
/// voice is available it speaks nothing and reports unavailability.
@MainActor
public final class AVSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voicesOverride: [AVSpeechSynthesisVoice]?
    public var onPlaybackFinished: (() -> Void)?

    /// The most recent utterance handed to the synthesizer. Exposed so
    /// tests can verify real utterance creation (exact text, system voice).
    public private(set) var lastUtterance: AVSpeechUtterance?

    /// - Parameter voices: voice list to select from. Defaults to the
    ///   live `AVSpeechSynthesisVoice.speechVoices()`; tests pass an
    ///   explicit list (for example empty) to force the missing-voice path.
    public init(voices: [AVSpeechSynthesisVoice]? = nil) {
        self.voicesOverride = voices
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Selects an OS-bundled voice for `language` from `voices`.
    ///
    /// Bundled-only policy: `AVSpeechSynthesisVoice(language:)` can return
    /// an installed downloaded voice (its header promises an enhanced
    /// voice "if available"), so language lookup alone does not enforce
    /// T1.7's no-download requirement. Bundled voices ship at default
    /// quality; enhanced/premium voices exist on device only after a
    /// user download. Personal voices are user-created, not bundled.
    /// Returns nil when no bundled voice matches; callers must then
    /// report unavailability and speak nothing. A nil utterance voice
    /// would let the synthesizer choose a voice without this filter,
    /// so it is never an acceptable fallback.
    public static func bundledVoice(
        forLanguage language: String = "en-US",
        voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
    ) -> AVSpeechSynthesisVoice? {
        func isBundled(_ voice: AVSpeechSynthesisVoice) -> Bool {
            voice.quality == .default && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        return voices.first { $0.language == language && isBundled($0) }
            ?? voices.first { $0.language.hasPrefix(String(language.prefix(2))) && isBundled($0) }
    }

    @discardableResult
    public func speak(text: String) -> Bool {
        // Bundled voice only, verified through bundledVoice above. When
        // no bundled voice is present, speak nothing and report
        // unavailability: a nil voice would let the synthesizer select
        // a voice without the bundled-only filter.
        guard let voice = Self.bundledVoice(
            forLanguage: "en-US",
            voices: voicesOverride ?? AVSpeechSynthesisVoice.speechVoices()
        ) else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        lastUtterance = utterance
        synthesizer.speak(utterance)
        return true
    }

    public func stopSpeaking() {
        _ = synthesizer.stopSpeaking(at: .immediate)
    }

    // The delegate conformance is nonisolated (the synthesizer may call
    // this off the main actor), so it forwards only the finished
    // utterance's identity and hops to the main actor for the check.
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  let lastUtterance,
                  ObjectIdentifier(lastUtterance) == finishedID else { return }
            // Ignore completions for older utterances: a stale finish for
            // a previous message must not clear the speaking state of the
            // message that replaced it, or stop/lifecycle calls would
            // return early and let the newer reading play on.
            self.onPlaybackFinished?()
        }
    }
}
#endif

// MARK: - ReadAloudService

/// Speaks tutor-message text aloud, entirely on-device (LLD
/// ReadAloudService). Demo scope is Band B: the speaker button is always
/// present and the child taps it to hear the text. Band A auto-read
/// (reading starts automatically when a message appears) is v1 scope
/// (T6.7) and is deliberately not implemented here: `messageDidAppear`
/// never starts speech in this build, on either band.
///
/// Lifecycle: starting to speak stops any reading already in progress,
/// starting a new item stops the current reading, and leaving the view
/// stops the current reading.
@MainActor
public final class ReadAloudService: ObservableObject {
    public let band: GradeBand

    private let engine: SpeechEngine
    private let now: () -> Date

    /// Every hint-listen emitted so far, in order. The EffortScorer sink,
    /// when set, receives the same events.
    public private(set) var hintListenEvents: [HintListenEvent] = []
    public weak var hintListenSink: HintListenEventSink?

    @Published public private(set) var isSpeaking = false
    @Published public private(set) var currentMessageID: String?
    /// True when the last speak request found no OS-bundled voice. The
    /// UI observes this to say reading is unavailable; playback is not
    /// marked active and no hint-listen is recorded in that case.
    @Published public private(set) var isVoiceUnavailable = false

    public init(band: GradeBand,
                engine: SpeechEngine,
                now: @escaping () -> Date = Date.init) {
        self.band = band
        self.engine = engine
        self.now = now
        engine.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            self.currentMessageID = nil
        }
    }

    /// Production convenience: the real AVSpeechSynthesizer engine.
    #if canImport(AVFoundation)
    public convenience init(band: GradeBand, now: @escaping () -> Date = Date.init) {
        self.init(band: band, engine: AVSpeechEngine(), now: now)
    }
    #endif

    // MARK: Speaking

    /// Speaks the message text. Any reading already in progress is
    /// stopped first, so at most one message is ever being read.
    /// If the message is a hint, exactly one hint-listen event is emitted.
    public func speak(_ message: TutorMessage) {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isSpeaking {
            engine.stopSpeaking()
        }
        guard engine.speak(text: message.text) else {
            // No verified bundled voice: surface unavailability without
            // marking playback active or recording a hint listen.
            isSpeaking = false
            currentMessageID = nil
            isVoiceUnavailable = true
            return
        }
        isVoiceUnavailable = false
        currentMessageID = message.id
        isSpeaking = true
        if message.isHint {
            let event = HintListenEvent(messageID: message.id,
                                        messageText: message.text,
                                        emittedAt: now())
            hintListenEvents.append(event)
            hintListenSink?.recordHintListen(event)
        }
    }

    /// Tap behaviour for the speaker button: tapping the message that is
    /// currently being read stops it; tapping any other message reads it.
    public func toggle(_ message: TutorMessage) {
        if isSpeaking && currentMessageID == message.id {
            stop()
        } else {
            speak(message)
        }
    }

    /// Stops the current reading, if any. Safe to call when idle.
    public func stop() {
        guard isSpeaking else { return }
        engine.stopSpeaking()
        isSpeaking = false
        currentMessageID = nil
    }

    // MARK: Lifecycle hooks

    /// Starting a new item stops the current reading.
    public func startNewItem() {
        stop()
    }

    /// Leaving the view (chat, or the screen hosting the messages) stops
    /// the current reading. The chat UI calls this from `onDisappear`.
    public func handleViewDisappeared() {
        stop()
    }

    /// A tutor message appearing in the thread. Band B (Demo): does
    /// nothing; the child taps the speaker button to hear the text.
    /// Band A auto-read is v1 scope (T6.7) and is not built here, so this
    /// never starts speech in the Demo build on either band.
    public func messageDidAppear(_ message: TutorMessage) {
        // Intentionally no speech. See the class docstring.
        _ = message
    }
}
