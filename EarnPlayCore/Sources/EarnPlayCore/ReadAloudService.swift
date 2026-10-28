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
public protocol SpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    /// Called when an utterance finishes naturally (not when stopped).
    var onPlaybackFinished: (() -> Void)? { get set }
    func speak(text: String)
    func stopSpeaking()
}

#if canImport(AVFoundation)
/// Real on-device speech engine backed by `AVSpeechSynthesizer`.
///
/// Uses the default system voice for the locale. It never calls any
/// voice-download API and contains no networking code, so it works in
/// Airplane Mode with no downloaded voice installed.
public final class AVSpeechEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    public var onPlaybackFinished: (() -> Void)?

    /// The most recent utterance handed to the synthesizer. Exposed so
    /// tests can verify real utterance creation (exact text, system voice).
    public private(set) var lastUtterance: AVSpeechUtterance?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    public func speak(text: String) {
        let utterance = AVSpeechUtterance(string: text)
        // System built-in voice only: the default voice for en-US ships
        // with the OS and needs no download and no network.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        lastUtterance = utterance
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        _ = synthesizer.stopSpeaking(at: .immediate)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                  didFinish utterance: AVSpeechUtterance) {
        onPlaybackFinished?()
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
        currentMessageID = message.id
        isSpeaking = true
        engine.speak(text: message.text)
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
