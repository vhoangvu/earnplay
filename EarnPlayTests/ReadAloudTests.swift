import XCTest
import EarnPlayCore

/// App-target coverage for T1.7: the service the speaker button drives,
/// exercised through the real AVSpeechSynthesizer engine boundary.
/// Utterance creation and start/stop state are real; no audio output is
/// asserted because the simulator cannot produce audible speech.
@MainActor
final class ReadAloudTests: XCTestCase {
    func testSpeakerButtonContractEveryTutorMessageKindIsSpeakable() {
        // The button is rendered for every tutor message; each kind must
        // accept a speak request with its exact text.
        let service = ReadAloudService(band: GradeBand(grade: "4"))
        let messages = [
            TutorMessage(id: "q1", text: "What is 7 plus 5?", kind: .question),
            TutorMessage(id: "h1", text: "Try counting on from 7.", kind: .hint),
            TutorMessage(id: "i1", text: "Take your time.", kind: .instruction),
        ]
        for message in messages {
            service.speak(message)
            XCTAssertEqual(service.currentMessageID, message.id)
            service.stop()
            XCTAssertNil(service.currentMessageID)
        }
        XCTAssertEqual(service.hintListenEvents.count, 1)
        XCTAssertEqual(service.hintListenEvents.first?.messageID, "h1")
    }

    // Acceptance (b): speech playback makes no network requests. The
    // recording CountingURLProtocol (shared with the model-runtime
    // tests) is installed while question, hint and instruction play
    // through the real engine; the count must stay zero.
    func testSpeakingMakesNoNetworkRequestsForQuestionHintAndInstruction() async {
        CountingURLProtocol.reset()
        URLProtocol.registerClass(CountingURLProtocol.self)
        addTeardownBlock { URLProtocol.unregisterClass(CountingURLProtocol.self) }
        let service = ReadAloudService(band: GradeBand(grade: "4"))
        let messages = [
            TutorMessage(id: "q1", text: "What is 7 plus 5?", kind: .question),
            TutorMessage(id: "h1", text: "Try counting on from 7.", kind: .hint),
            TutorMessage(id: "i1", text: "Take your time.", kind: .instruction),
        ]
        for message in messages {
            service.speak(message)
            service.stop()
        }
        // Allow asynchronous request interception to run before
        // checking the count: an inverted expectation waits the full
        // window and passes only if nothing fulfils it meanwhile.
        let window = expectation(description: "async network interception window")
        window.isInverted = true
        await fulfillment(of: [window], timeout: 1.0)
        XCTAssertEqual(CountingURLProtocol.count, 0,
                       "speech playback attempted a network request")
    }

    func testLeavingViewStopsReadingWithRealEngine() {
        let service = ReadAloudService(band: GradeBand(grade: "4"))
        service.speak(TutorMessage(id: "q1", text: "What is 7 plus 5?", kind: .question))
        XCTAssertTrue(service.isSpeaking)
        service.handleViewDisappeared()
        XCTAssertFalse(service.isSpeaking)
    }
}
