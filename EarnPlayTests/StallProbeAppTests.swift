import XCTest
@testable import EarnPlay
import EarnPlayCore

/// App-target coverage for T1.5: the stalling-probe path the child app's
/// session UI drives, exercised on the simulator through the same
/// `StallProbeSession` the preview view owns. Mirrors the package suite's
/// acceptance fixtures: exactly one probe on a stalling stream, none on a
/// varied stream, and a substantive reply recorded as T1.4 effort.
final class StallProbeAppTests: XCTestCase {
    func testStallingStreamFiresOneProbeAndReplyRecordsEffort() {
        let start = Date(timeIntervalSince1970: 200_000)
        let session = StallProbeSession(startedAt: start)
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(5)))
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(15)))
        let probe = session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(25))
        XCTAssertNotNil(probe)
        XCTAssertEqual(session.probesFired.count, 1)
        // At most once per episode: further identical answers stay silent.
        XCTAssertNil(session.recordAttempt(
            answer: "12", isCorrect: false, at: start.addingTimeInterval(35)))
        XCTAssertEqual(session.probesFired.count, 1)

        XCTAssertEqual(session.submitProbeReply(
            "I tried adding the tops", at: start.addingTimeInterval(50)),
            .substantive(probeSequenceNumber: 1))
        let signals = session.signals(at: start.addingTimeInterval(51))
        XCTAssertEqual(signals.followUpInteractions, 1)
        XCTAssertEqual(signals.explanations, 1)
    }

    func testVariedStreamFiresNoProbe() {
        let start = Date(timeIntervalSince1970: 210_000)
        let session = StallProbeSession(startedAt: start)
        session.recordAttempt(answer: "12", isCorrect: false,
                              at: start.addingTimeInterval(5))
        session.recordRevision(at: start.addingTimeInterval(12))
        session.recordAttempt(answer: "14", isCorrect: false,
                              at: start.addingTimeInterval(30))
        session.recordAttempt(answer: "13", isCorrect: false,
                              at: start.addingTimeInterval(60))
        XCTAssertTrue(session.probesFired.isEmpty)
        XCTAssertNil(session.pendingProbe)
    }
}

/// Fix round 1 (issue #8 review): changed submissions are forwarded as
/// attempts. The preview synthesizes no revision from a changed answer —
/// revisions come only from a separately observed revision/work action —
/// so rapid varied guesses and hint-then-instant-correct fire through it.
@MainActor
final class StallProbePreviewModelTests: XCTestCase {
    func testRapidVariedGuessesThroughSubmitAnswerFireProbe() {
        let model = StallProbePreviewModel()
        model.submitAnswer("10")
        model.submitAnswer("11")
        XCTAssertNil(model.pendingProbe)
        model.submitAnswer("13")
        XCTAssertNotNil(model.pendingProbe)
        XCTAssertEqual(model.session.probesFired.count, 1)
        XCTAssertTrue(model.pendingProbe?.signals.contains(.rapidGuessing) ?? false)
    }

    func testHintThenImmediateCorrectAnswerThroughViewFiresAnswerKeyProbe() {
        let model = StallProbePreviewModel()
        model.submitAnswer("12")
        XCTAssertNil(model.pendingProbe)
        model.useHint()
        model.submitAnswer("56")
        XCTAssertNotNil(model.pendingProbe)
        XCTAssertEqual(model.pendingProbe?.signals, [.hintUsedAsAnswerKey])
        XCTAssertEqual(model.session.probesFired.count, 1)
    }
}

/// Fix round 2 (issue #8 review): after a substantive reply the success
/// notice must be present even though no probe is pending — the view renders
/// it outside the pending-probe conditional. Rejected replies keep their
/// notice while the probe stays pending.
@MainActor
final class StallProbePreviewNoticeTests: XCTestCase {
    func testSubstantiveReplyKeepsSuccessNoticeWithNoProbePending() {
        let model = StallProbePreviewModel()
        model.submitAnswer("12")
        model.submitAnswer("12")
        model.submitAnswer("12")
        XCTAssertNotNil(model.pendingProbe)
        model.submitReply("I tried adding the tops")
        XCTAssertNil(model.pendingProbe)
        XCTAssertEqual(model.replyNotice, "Effort recorded — keep going.")
    }

    func testRejectedReplyKeepsNoticeWithProbePending() {
        let model = StallProbePreviewModel()
        model.submitAnswer("12")
        model.submitAnswer("12")
        model.submitAnswer("12")
        XCTAssertNotNil(model.pendingProbe)
        model.submitReply("...")
        XCTAssertNotNil(model.pendingProbe)
        XCTAssertEqual(model.replyNotice, "Say a little more about what you tried.")
    }
}

/// Recording fake at the synthesizer boundary only. The service and model
/// logic under test (speak/stop, reply handling, card dismissal) is the
/// real code.
@MainActor
private final class ProbeSpeechFakeEngine: SpeechEngine {
    var onPlaybackFinished: (() -> Void)?
    private(set) var stopCallCount = 0
    var isSpeaking = false

    @discardableResult
    func speak(text: String) -> Bool {
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        stopCallCount += 1
        isSpeaking = false
    }
}

/// Fix round 3 (issue #8 review): the speaker button lives inside the
/// `pendingProbe` card, so a substantive reply — which clears the card —
/// must stop the probe's read-aloud playback, or it plays on with no stop
/// control left. Non-substantive replies keep the card and must leave
/// playback alone; start-over reset keeps its existing stop behavior.
@MainActor
final class StallProbePreviewSpeechTests: XCTestCase {
    private func makeModelWithFiredProbe()
        -> (model: StallProbePreviewModel, engine: ProbeSpeechFakeEngine) {
        let engine = ProbeSpeechFakeEngine()
        let speech = ReadAloudService(band: GradeBand(grade: "4"), engine: engine)
        let model = StallProbePreviewModel(speech: speech)
        model.submitAnswer("12")
        model.submitAnswer("12")
        model.submitAnswer("12")
        return (model, engine)
    }

    func testSubstantiveReplyStopsProbePlaybackWhenCardDismisses() {
        let (model, engine) = makeModelWithFiredProbe()
        guard let probe = model.pendingProbe else {
            XCTFail("expected a pending probe after 3 identical wrong answers")
            return
        }
        model.speech.speak(probe.message)
        XCTAssertTrue(model.speech.isSpeaking)
        XCTAssertEqual(model.speech.currentMessageID, probe.message.id)

        model.submitReply("I tried adding the tops")

        XCTAssertNil(model.pendingProbe, "substantive reply dismisses the probe card")
        XCTAssertEqual(model.replyNotice, "Effort recorded — keep going.")
        XCTAssertFalse(model.speech.isSpeaking,
                       "dismissing the probe card must stop its playback")
        XCTAssertNil(model.speech.currentMessageID)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testNonSubstantiveReplyKeepsProbePlayback() {
        let (model, engine) = makeModelWithFiredProbe()
        guard let probe = model.pendingProbe else {
            XCTFail("expected a pending probe after 3 identical wrong answers")
            return
        }
        model.speech.speak(probe.message)
        XCTAssertTrue(model.speech.isSpeaking)

        model.submitReply("...")

        XCTAssertNotNil(model.pendingProbe, "rejected reply keeps the probe card")
        XCTAssertTrue(model.speech.isSpeaking,
                      "playback must continue while the card stays")
        XCTAssertEqual(model.speech.currentMessageID, probe.message.id)
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testResetStopsProbePlaybackUnchanged() {
        let (model, engine) = makeModelWithFiredProbe()
        guard let probe = model.pendingProbe else {
            XCTFail("expected a pending probe after 3 identical wrong answers")
            return
        }
        model.speech.speak(probe.message)
        XCTAssertTrue(model.speech.isSpeaking)

        model.reset()

        XCTAssertNil(model.pendingProbe)
        XCTAssertNil(model.replyNotice)
        XCTAssertFalse(model.hintVisible)
        XCTAssertFalse(model.speech.isSpeaking)
        XCTAssertNil(model.speech.currentMessageID)
        XCTAssertEqual(engine.stopCallCount, 1)
    }
}
