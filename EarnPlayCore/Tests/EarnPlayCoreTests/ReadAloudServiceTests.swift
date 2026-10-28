import XCTest
import AVFoundation
@testable import EarnPlayCore

/// Recording fake at the synthesizer boundary only. The service logic
/// under test (start/stop, lifecycle, event emission) is the real code.
@MainActor
private final class FakeSpeechEngine: SpeechEngine {
    var onPlaybackFinished: (() -> Void)?
    private(set) var spokenTexts: [String] = []
    private(set) var stopCallCount = 0
    var isSpeaking = false
    /// When false, speak reports voice unavailability and speaks nothing,
    /// mirroring the real engine when no bundled voice exists.
    var voiceAvailable = true

    @discardableResult
    func speak(text: String) -> Bool {
        guard voiceAvailable else { return false }
        spokenTexts.append(text)
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        stopCallCount += 1
        isSpeaking = false
    }

    func simulateNaturalFinish() {
        isSpeaking = false
        onPlaybackFinished?()
    }
}

/// Counts every URL load attempted through URLProtocol while speech
/// plays. Mirrors CountingURLProtocol in the app-target tests; the
/// package tests cannot share that type across targets.
private final class SpeechCountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // Guarded by lock on every access.
    private nonisolated(unsafe) static var _count = 0
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    static func reset() {
        lock.lock()
        _count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self._count += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private final class RecordingHintSink: HintListenEventSink {
    private(set) var events: [HintListenEvent] = []
    func recordHintListen(_ event: HintListenEvent) { events.append(event) }
}

@MainActor
final class ReadAloudServiceTests: XCTestCase {
    private let question = TutorMessage(id: "q1", text: "What is 7 plus 5?", kind: .question)
    private let hint = TutorMessage(id: "h1", text: "Try counting on from 7.", kind: .hint)
    private let instruction = TutorMessage(id: "i1", text: "Take your time.", kind: .instruction)

    private func makeService(grade: String = "4")
        -> (service: ReadAloudService, engine: FakeSpeechEngine, sink: RecordingHintSink) {
        let engine = FakeSpeechEngine()
        let sink = RecordingHintSink()
        let service = ReadAloudService(
            band: GradeBand(grade: grade),
            engine: engine,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        service.hintListenSink = sink
        return (service, engine, sink)
    }

    // (a) speak is called with the exact message text for a question, a
    // hint, and an instruction message.
    func testSpeakUsesExactTextForQuestionHintAndInstruction() {
        let (service, engine, _) = makeService()
        service.speak(question)
        service.speak(hint)
        service.speak(instruction)
        XCTAssertEqual(engine.spokenTexts, [question.text, hint.text, instruction.text])
    }

    // (b) Speech playback makes no network requests: a recording
    // URLProtocol interceptor is installed while question, hint and
    // instruction messages play, and the request count must stay zero.
    // Recording the fake engine call alone cannot detect a network
    // request made alongside it, so the interceptor is the assertion.
    func testSpeakingMakesNoNetworkRequestsForQuestionHintAndInstruction() async {
        SpeechCountingURLProtocol.reset()
        URLProtocol.registerClass(SpeechCountingURLProtocol.self)
        addTeardownBlock { URLProtocol.unregisterClass(SpeechCountingURLProtocol.self) }
        let (service, engine, _) = makeService()
        service.speak(question)
        service.speak(hint)
        service.speak(instruction)
        XCTAssertEqual(engine.spokenTexts, [question.text, hint.text, instruction.text])
        XCTAssertTrue(service.isSpeaking)
        // Allow asynchronous request interception to run before
        // checking the count: an inverted expectation waits the full
        // window and passes only if nothing fulfils it meanwhile.
        let window = expectation(description: "async network interception window")
        window.isInverted = true
        await fulfillment(of: [window], timeout: 0.5)
        XCTAssertEqual(SpeechCountingURLProtocol.count, 0,
                       "speech playback attempted a network request")
    }

    // Real utterance creation: the AVSpeech engine builds a real
    // AVSpeechUtterance with the exact text and a system voice (no
    // download). Creating the utterance needs no audio output, so this
    // runs on the host and in the simulator.
    func testAVSpeechEngineCreatesUtteranceWithExactTextAndSystemVoice() {
        let engine = AVSpeechEngine()
        let started = engine.speak(text: "What is 7 plus 5?")
        // Bundled-ness is verified through the selection path itself, not
        // an identifier substring: downloaded voices also have identifiers
        // without "http", so that check proved nothing. The spoken voice
        // must be exactly what the bundled-only selector returns.
        let expected = AVSpeechEngine.bundledVoice(forLanguage: "en-US")
        if let expected {
            XCTAssertTrue(started)
            XCTAssertEqual(engine.lastUtterance?.speechString, "What is 7 plus 5?")
            XCTAssertEqual(engine.lastUtterance?.voice?.identifier, expected.identifier)
            XCTAssertEqual(engine.lastUtterance?.voice?.quality, .default,
                           "only a default-quality (OS-bundled) voice may be selected")
        } else {
            // No bundled en-US voice on this device: speak() must report
            // unavailability and hand nothing to the synthesizer. A nil
            // utterance voice would let the synthesizer choose a voice
            // without the bundled-only filter, so nil is never proof of
            // a bundled voice.
            XCTAssertFalse(started, "no bundled voice must report unavailability")
            XCTAssertNil(engine.lastUtterance,
                         "no utterance may be created without a verified bundled voice")
        }
        engine.stopSpeaking()
    }

    // No bundled voice at all: the engine speaks nothing and reports
    // unavailability instead of letting the synthesizer pick a voice.
    func testAVSpeechEngineWithNoBundledVoiceReportsUnavailableAndSpeaksNothing() {
        let engine = AVSpeechEngine(voices: [])
        XCTAssertFalse(engine.speak(text: "What is 7 plus 5?"))
        XCTAssertNil(engine.lastUtterance)
        XCTAssertFalse(engine.isSpeaking)
        // Downloaded-quality voices alone are likewise unavailable:
        // they exist on device only after a user download.
        let downloadedOnly = AVSpeechSynthesisVoice.speechVoices().filter { $0.quality != .default }
        let downloadedEngine = AVSpeechEngine(voices: downloadedOnly)
        XCTAssertFalse(downloadedEngine.speak(text: "What is 7 plus 5?"))
        XCTAssertNil(downloadedEngine.lastUtterance)
    }

    // Service level: missing voice surfaces unavailability with no
    // playback-active state and no hint-listen event.
    func testMissingVoiceReportsUnavailableWithoutPlaybackOrHintListen() {
        let (service, engine, sink) = makeService()
        engine.voiceAvailable = false
        service.speak(hint)
        XCTAssertTrue(service.isVoiceUnavailable)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertNil(service.currentMessageID)
        XCTAssertTrue(engine.spokenTexts.isEmpty)
        XCTAssertTrue(service.hintListenEvents.isEmpty)
        XCTAssertTrue(sink.events.isEmpty)
        // A later successful speak clears the unavailability report.
        engine.voiceAvailable = true
        service.speak(hint)
        XCTAssertFalse(service.isVoiceUnavailable)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(sink.events.count, 1)
    }

    // Finding 2: the selector never returns a downloaded voice. Enhanced
    // and premium voices exist on device only after a user download, so
    // any voice the selector returns must be default quality, and when
    // the candidate list contains only downloaded-quality voices for the
    // language the selector must return nil (absence -> fallback).
    func testBundledVoiceSelectionNeverSelectsDownloadedVoices() {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let selected = AVSpeechEngine.bundledVoice(forLanguage: "en-US", voices: allVoices)
        if let selected {
            XCTAssertEqual(selected.quality, .default)
            XCTAssertTrue(selected.language.hasPrefix("en"))
        }
        let downloadedOnly = allVoices.filter { $0.quality != .default }
        XCTAssertNil(
            AVSpeechEngine.bundledVoice(forLanguage: "en-US", voices: downloadedOnly),
            "selector must not fall back to a downloaded voice")
        // Absence handling: an unsupported language yields nil, which
        // speak() turns into reported unavailability, never a nil-voice
        // utterance the synthesizer would voice on its own.
        XCTAssertNil(AVSpeechEngine.bundledVoice(forLanguage: "xx-XX", voices: allVoices))
    }

    // (c) Band B: a new tutor message does not trigger speak until tapped.
    func testBandBMessageAppearanceDoesNotAutoSpeak() {
        let (service, engine, _) = makeService(grade: "4")
        service.messageDidAppear(question)
        service.messageDidAppear(hint)
        XCTAssertTrue(engine.spokenTexts.isEmpty)
        XCTAssertFalse(service.isSpeaking)
    }

    // Demo scope guard: even a Band A grade must not auto-read in this
    // build (auto-read is v1, T6.7).
    func testBandAGradeDoesNotAutoSpeakInDemoBuild() {
        let (service, engine, _) = makeService(grade: "2")
        XCTAssertEqual(service.band, .bandA)
        service.messageDidAppear(question)
        XCTAssertTrue(engine.spokenTexts.isEmpty)
        XCTAssertFalse(service.isSpeaking)
    }

    func testGradeBandSelection() {
        XCTAssertEqual(GradeBand(grade: "1"), .bandA)
        XCTAssertEqual(GradeBand(grade: "2"), .bandA)
        XCTAssertEqual(GradeBand(grade: "3"), .bandB)
        XCTAssertEqual(GradeBand(grade: "4"), .bandB)
        XCTAssertEqual(GradeBand(grade: "5"), .bandB)
    }

    // Tap speaks the text; tapping the speaking message again stops it.
    func testToggleSpeaksThenStopsSameMessage() {
        let (service, engine, _) = makeService()
        service.toggle(question)
        XCTAssertEqual(engine.spokenTexts, [question.text])
        XCTAssertTrue(service.isSpeaking)
        service.toggle(question)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    // Starting a new reading stops the current one first.
    func testSpeakingNewMessageStopsCurrentReading() {
        let (service, engine, _) = makeService()
        service.speak(question)
        service.speak(hint)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(service.currentMessageID, hint.id)
        XCTAssertTrue(service.isSpeaking)
    }

    // Starting a new item stops the current reading.
    func testStartingNewItemStopsCurrentReading() {
        let (service, engine, _) = makeService()
        service.speak(question)
        service.startNewItem()
        XCTAssertFalse(service.isSpeaking)
        XCTAssertNil(service.currentMessageID)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    // (d) Leaving the view stops the current reading.
    func testLeavingViewStopsCurrentReading() {
        let (service, engine, _) = makeService()
        service.speak(question)
        service.handleViewDisappeared()
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    // (e) Playing a hint writes exactly one hint-listen event.
    func testPlayingHintEmitsExactlyOneHintListenEvent() {
        let (service, _, sink) = makeService()
        service.speak(hint)
        XCTAssertEqual(service.hintListenEvents.count, 1)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.messageID, hint.id)
        XCTAssertEqual(sink.events.first?.messageText, hint.text)
    }

    func testNonHintMessagesEmitNoHintListenEvent() {
        let (service, _, sink) = makeService()
        service.speak(question)
        service.speak(instruction)
        XCTAssertTrue(service.hintListenEvents.isEmpty)
        XCTAssertTrue(sink.events.isEmpty)
    }

    // Stopping a hint must not emit a second event; replaying it is a
    // new listen and emits exactly one more.
    func testStoppingHintDoesNotDoubleEmitAndReplayEmitsOnceMore() {
        let (service, _, sink) = makeService()
        service.speak(hint)
        service.stop()
        XCTAssertEqual(sink.events.count, 1)
        service.speak(hint)
        XCTAssertEqual(sink.events.count, 2)
    }

    func testNaturalFinishClearsSpeakingStateWithoutEmittingAgain() {
        let (service, engine, sink) = makeService()
        service.speak(hint)
        engine.simulateNaturalFinish()
        XCTAssertFalse(service.isSpeaking)
        XCTAssertNil(service.currentMessageID)
        XCTAssertEqual(sink.events.count, 1)
    }

    func testEmptyTextNeverSpeaksOrEmits() {
        let (service, engine, sink) = makeService()
        service.speak(TutorMessage(id: "e1", text: "   ", kind: .hint))
        XCTAssertTrue(engine.spokenTexts.isEmpty)
        XCTAssertTrue(sink.events.isEmpty)
        XCTAssertFalse(service.isSpeaking)
    }

    // Regression (Copilot HIGH): message A's finish callback arriving
    // after message B has started must not clear B's speaking state.
    // Otherwise stop/lifecycle calls return early and B keeps playing
    // after the view disappears or a new item starts.
    func testStaleUtteranceFinishDoesNotClearNewerSpeakingState() async {
        let engine = AVSpeechEngine()
        var finishCount = 0
        engine.onPlaybackFinished = { finishCount += 1 }
        engine.speak(text: "Message A")
        let utteranceA = engine.lastUtterance
        engine.speak(text: "Message B")
        let utteranceB = engine.lastUtterance
        XCTAssertNotNil(utteranceA)
        XCTAssertNotNil(utteranceB)
        XCTAssertFalse(utteranceA === utteranceB)
        // A's stale completion arrives after B started: must be ignored.
        engine.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utteranceA!)
        await Task.yield()
        XCTAssertEqual(finishCount, 0, "stale finish for A must not fire the completion callback")
        // B's own completion still fires exactly once.
        engine.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utteranceB!)
        await Task.yield()
        XCTAssertEqual(finishCount, 1)
        engine.stopSpeaking()
    }

    // Same regression through the service: after A's stale completion,
    // B is still marked speaking and lifecycle stop still stops it.
    func testStaleFinishThroughServiceLeavesNewerMessageStoppable() async {
        let engine = AVSpeechEngine()
        let service = ReadAloudService(band: GradeBand(grade: "4"), engine: engine)
        let messageA = TutorMessage(id: "a1", text: "Message A", kind: .question)
        let messageB = TutorMessage(id: "b1", text: "Message B", kind: .question)
        service.speak(messageA)
        let utteranceA = engine.lastUtterance
        service.speak(messageB)
        XCTAssertNotNil(utteranceA)
        engine.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utteranceA!)
        await Task.yield()
        XCTAssertTrue(service.isSpeaking, "stale finish must not clear B's speaking state")
        XCTAssertEqual(service.currentMessageID, messageB.id)
        service.handleViewDisappeared()
        XCTAssertFalse(service.isSpeaking, "leaving the view must still stop B")
        XCTAssertNil(service.currentMessageID)
    }

    func testStopWhenIdleIsNoOp() {
        let (service, engine, _) = makeService()
        service.stop()
        service.startNewItem()
        service.handleViewDisappeared()
        XCTAssertEqual(engine.stopCallCount, 0)
        XCTAssertFalse(service.isSpeaking)
    }
}
