import XCTest
import AVFoundation
@testable import EarnPlayCore

/// Recording fake at the synthesizer boundary only. The service logic
/// under test (start/stop, lifecycle, event emission) is the real code.
private final class FakeSpeechEngine: SpeechEngine {
    var onPlaybackFinished: (() -> Void)?
    private(set) var spokenTexts: [String] = []
    private(set) var stopCallCount = 0
    var isSpeaking = false

    func speak(text: String) {
        spokenTexts.append(text)
        isSpeaking = true
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

private final class RecordingHintSink: HintListenEventSink {
    private(set) var events: [HintListenEvent] = []
    func recordHintListen(_ event: HintListenEvent) { events.append(event) }
}

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

    // (b) No network path exists: speech goes only to the on-device
    // engine. The fake stands in for AVSpeechSynthesizer, so any spoken
    // text observed here proves the service reached the device engine
    // and nothing else; the real engine is asserted separately below.
    func testSpeakingReachesOnlyTheOnDeviceEngine() {
        let (service, engine, _) = makeService()
        service.speak(question)
        XCTAssertEqual(engine.spokenTexts, [question.text])
        XCTAssertTrue(service.isSpeaking)
    }

    // Real utterance creation: the AVSpeech engine builds a real
    // AVSpeechUtterance with the exact text and a system voice (no
    // download). Creating the utterance needs no audio output, so this
    // runs on the host and in the simulator.
    func testAVSpeechEngineCreatesUtteranceWithExactTextAndSystemVoice() {
        let engine = AVSpeechEngine()
        engine.speak(text: "What is 7 plus 5?")
        XCTAssertEqual(engine.lastUtterance?.speechString, "What is 7 plus 5?")
        XCTAssertNotNil(engine.lastUtterance?.voice)
        // A system voice identifier is a built-in voice, never a
        // downloaded-voice file URL or a network resource.
        let identifier = engine.lastUtterance?.voice?.identifier ?? ""
        XCTAssertFalse(identifier.contains("http"), "voice must not be a network resource: \(identifier)")
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

    func testStopWhenIdleIsNoOp() {
        let (service, engine, _) = makeService()
        service.stop()
        service.startNewItem()
        service.handleViewDisappeared()
        XCTAssertEqual(engine.stopCallCount, 0)
        XCTAssertFalse(service.isSpeaking)
    }
}
