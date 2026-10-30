import XCTest
import SwiftUI
import UIKit
import Vision
import EarnPlayCore
@testable import EarnPlay

/// T1.8 fix round 1 regression tests (issue #11).
/// Findings 1-3 are written against the pre-fix public surface so each
/// fails on the unfixed code for the stated reason; finding 4 adds
/// hosted-view coverage that did not exist before this round.
@MainActor
final class ChatFixRound1Tests: XCTestCase {

    /// Recording fake at the synthesizer boundary only (mirrors the
    /// EarnPlayCore ReadAloudServiceTests fake).
    final class RecordingSpeechEngine: SpeechEngine {
        var onPlaybackFinished: (() -> Void)?
        private(set) var spokenTexts: [String] = []
        private(set) var stopCallCount = 0
        var isSpeaking = false

        @discardableResult
        func speak(text: String) -> Bool {
            spokenTexts.append(text)
            isSpeaking = true
            return true
        }

        func stopSpeaking() {
            stopCallCount += 1
            isSpeaking = false
        }
    }

    /// Scripted engine mirroring ChatConversationTests: question ->
    /// wrong answer -> encouragement -> hint -> probe -> revision.
    final class ScriptedEngine: ChatTutorEngine {
        private(set) var submitted: [String] = []
        private(set) var hintTaps = 0

        func startSession() -> ChatEngineUpdate {
            ChatEngineUpdate(
                turns: [.tutor(TutorMessage(
                    id: "q1", text: "A farmer packs 7 eggs in each carton. She fills 8 cartons. How many eggs in all?",
                    kind: .question))],
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 0),
                composer: .numberPad)
        }

        func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
            submitted.append(plainText)
            if submitted.count == 1 {
                return ChatEngineUpdate(
                    turns: [.tutor(TutorMessage(id: "e1", text: "Good trying. Let's look at it another way.", kind: .encouragement))],
                    progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 1),
                    composer: .numberPad)
            }
            return ChatEngineUpdate(
                turns: [.tutor(TutorMessage(id: "e2", text: "Nice work. That was a good practice session.", kind: .encouragement))],
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 1),
                composer: .text,
                submittedTurnIsRevision: submitted.count >= 2 && plainText != submitted.first)
        }

        func requestHint() -> ChatEngineUpdate {
            hintTaps += 1
            return ChatEngineUpdate(turns: [
                .tutor(TutorMessage(id: "h1", text: "Try picturing 7 rows of 8 eggs.", kind: .hint)),
                .tutor(TutorMessage(id: "p1", text: "Show me one step: what did you try first?", kind: .probe)),
            ])
        }
    }

    private func makeSpeech() -> (service: ReadAloudService, engine: RecordingSpeechEngine) {
        let engine = RecordingSpeechEngine()
        let service = ReadAloudService(band: GradeBand(grade: "4"), engine: engine)
        return (service, engine)
    }

    // MARK: Finding 1 — advancing to a new question stops previous audio

    func testNewQuestionTurnStopsPreviousAudioButRepeatsAndHintsDoNot() {
        let (speech, fake) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: ScriptedEngine(), speech: speech)
        viewModel.startIfNeeded()

        guard let q1 = viewModel.tutorMessages.first else { return XCTFail("no opening question") }
        speech.speak(q1)
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(fake.stopCallCount, 0)

        // A NEW question turn arrives (correct answer advanced the
        // session): the previous reading must stop first.
        let q2 = TutorMessage(id: "q2", text: "What is 6 times 9?", kind: .question)
        viewModel.apply(turns: [.tutor(q2)])
        XCTAssertEqual(fake.stopCallCount, 1, "new question must call startNewItem (stop previous audio)")
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertNil(speech.currentMessageID)

        // Re-delivering the SAME question (update/repeat) must not stop.
        speech.speak(q2)
        XCTAssertTrue(speech.isSpeaking)
        viewModel.apply(turns: [.tutor(q2)])
        XCTAssertEqual(fake.stopCallCount, 1, "repeat/update of the same question must not stop audio")
        XCTAssertTrue(speech.isSpeaking)

        // A new hint (not a question) must not stop the reading either.
        let hint = TutorMessage(id: "h9", text: "Try picturing the groups.", kind: .hint)
        viewModel.apply(turns: [.tutor(hint)])
        XCTAssertEqual(fake.stopCallCount, 1, "hint turns must not stop audio")
        XCTAssertTrue(speech.isSpeaking)
    }

    // MARK: Finding 2 — completed session leaves no active composer

    func testCompletedSessionLeavesNoOrphanChildBubbles() {
        let (speech, _) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: DemoTutorEngine(maxQuestions: 1), speech: speech)
        viewModel.startIfNeeded()

        // The single demo question is 7 x 8 = 56.
        viewModel.draft = "56"
        viewModel.submitDraft()
        // Explicit session-complete state replaces the composer.
        XCTAssertEqual(viewModel.composer, .sessionComplete)
        XCTAssertTrue(viewModel.isSessionComplete)
        XCTAssertTrue(viewModel.visibleTextStrings.contains("Practice complete. Nice work."))
        XCTAssertTrue(viewModel.visibleTextStrings.contains("Start again"))
        XCTAssertFalse(viewModel.visibleTextStrings.contains("Send"))
        let countAtCompletion = viewModel.messages.count

        // Further Send / Hint taps must not append orphan child bubbles
        // or silently do nothing behind an editable composer.
        viewModel.draft = "hello again"
        viewModel.submitDraft()
        viewModel.requestHint()
        XCTAssertEqual(viewModel.messages.count, countAtCompletion,
                       "no orphan turns may appear after the session completes")
    }

    // MARK: Finding 3 — probe explanations are not graded as answers

    func testProbeReplyIsAcknowledgedNotGradedNorLabelledRevision() {
        let (speech, _) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: DemoTutorEngine(), speech: speech)
        viewModel.startIfNeeded()

        // Wrong answer -> encouragement + probe.
        viewModel.draft = "999999"
        viewModel.submitDraft()
        XCTAssertEqual(viewModel.tutorMessages.last?.kind, .probe)

        // The child explains what they tried. This reply answers the
        // probe; it is not a new answer attempt.
        viewModel.draft = "I added seven eight times"
        viewModel.submitDraft()

        guard viewModel.messages.count >= 2 else { return XCTFail("missing probe reply turns") }
        let explanationIndex = viewModel.messages.count - 2
        guard case .child(_, _, let isRevision) = viewModel.messages[explanationIndex] else {
            return XCTFail("turn before the acknowledgement should be the child explanation")
        }
        XCTAssertFalse(isRevision, "a probe explanation must not be labelled an answer revision")
        let acknowledgement = viewModel.tutorMessages.last
        XCTAssertNotNil(acknowledgement)
        XCTAssertTrue(acknowledgement?.text.contains("showing your thinking") ?? false,
                      "probe reply must be acknowledged as thinking, got: \(acknowledgement?.text ?? "nil")")
        // Still on the first question: the explanation was not graded
        // (no advance, no second retry cycle).
        XCTAssertEqual(viewModel.progress.attemptedQuestions, 1)

        // The next real answer is graded normally and advances.
        viewModel.draft = "56"
        viewModel.submitDraft()
        XCTAssertEqual(viewModel.tutorMessages.last?.kind, .question,
                       "the answer after the probe reply must be graded and advance to the next question")
    }

    // MARK: Finding 4 — hosted view: rendered order, controls, action
    //
    // The view is hosted in a real window and laid out. Assertions
    // read the RENDERED surface only: text recognized (Vision OCR,
    // top-to-bottom) from a snapshot of the hosted view, and the
    // rendered layer tree (one speaker-symbol image layer inside
    // each tutor card, none in child bubbles). Removing the speaker
    // or Hint controls, or adding score text, fails this test even
    // though every view-model ID list stays unchanged. Send/Hint are
    // invoked through the exact action bodies the rendered buttons
    // call (`submitDraft` / `requestHint`); typing goes through the
    // rendered text field itself. A speaker action is performed
    // through `SpeakerButton`'s action body (`service.toggle`) on
    // the shared service the hosted buttons observe. Synthetic
    // UITouch delivery does not reach SwiftUI buttons in a unit-test
    // host (verified by probe, 2026-10-29), so no fake tap is used.

    func testHostedChatRendersStreamOrderControlsAndSpeakerActionWithNoScore() throws {
        let (speech, fake) = makeSpeech()
        let engine = ScriptedEngine()
        let viewModel = ChatConversationViewModel(engine: engine, speech: speech)
        let (host, window) = makeHosted(viewModel: viewModel)
        _ = window
        pump(host)

        // Drive the scripted stream: type "54" into the RENDERED
        // text field, then Send's action, Hint's action, then "56".
        let field = try XCTUnwrap(renderedTextViews(in: host.view).first,
                                  "rendered composer text field missing")
        field.insertText("54")
        pump(host)
        XCTAssertEqual(viewModel.draft, "54", "typing in the rendered field must reach the draft")
        viewModel.submitDraft()
        viewModel.requestHint()
        pump(host)
        // The first submission cleared the draft; whatever the
        // rendered field still shows, replace it wholesale.
        field.selectAll(nil)
        field.insertText("56")
        pump(host)
        XCTAssertEqual(viewModel.draft, "56")
        viewModel.submitDraft()
        pump(host)

        // RENDERED message order (OCR, top to bottom).
        let rendered = renderedText(in: host.view)
        let expectedInOrder = [
            "A farmer packs 7 eggs",
            "54",
            "Good trying",
            "Try picturing 7 rows of 8 eggs",
            "Show me one step",
            "56",
            "Nice work. That was a good",
        ]
        var searchStart = rendered.startIndex
        for fragment in expectedInOrder {
            guard let range = rendered.range(of: fragment, range: searchStart..<rendered.endIndex) else {
                return XCTFail("rendered text missing or out of order: '\(fragment)' in: \(rendered)")
            }
            searchStart = range.upperBound
        }

        // RENDERED composer controls.
        XCTAssertTrue(rendered.contains("Hint"), "rendered Hint control missing: \(rendered)")
        XCTAssertTrue(rendered.contains("Send"), "rendered Send control missing: \(rendered)")

        // RENDERED speaker controls: one speaker-symbol image layer
        // per tutor message (5), at the trailing edge of tutor cards.
        XCTAssertEqual(viewModel.tutorMessages.count, 5)
        XCTAssertEqual(renderedSpeakerIconCount(in: host.view), 5,
                       "each rendered tutor bubble must carry its speaker control")

        // A speaker action: SpeakerButton's action on the first
        // rendered message speaks its exact text; repeating stops.
        let first = try XCTUnwrap(viewModel.tutorMessages.first)
        speech.toggle(first)
        XCTAssertEqual(fake.spokenTexts, [first.text])
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertEqual(speech.currentMessageID, first.id)
        speech.toggle(first)
        XCTAssertFalse(speech.isSpeaking)

        // No score-like text anywhere in the RENDERED text.
        let banned = try NSRegularExpression(
            pattern: "(?i)\\b(score|scores|points?|pts|timer|countdown|fail|failed|failure|passed|wrong|incorrect)\\b|\\d+\\s*%|\\b\\d+\\s+out of\\s+\\d+\\b")
        XCTAssertNil(banned.firstMatch(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)),
                     "score-like rendered text found: \(rendered)")
    }

    func testHostedCompletedSessionRendersCompletionInsteadOfComposer() throws {
        let (speech, _) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: DemoTutorEngine(maxQuestions: 1), speech: speech)
        let (host, window) = makeHosted(viewModel: viewModel)
        _ = window
        pump(host)

        // Answer the single demo question (7 x 8 = 56) correctly.
        let field = try XCTUnwrap(renderedTextViews(in: host.view).first,
                                  "rendered composer text field missing")
        field.insertText("56")
        pump(host)
        viewModel.submitDraft()
        pump(host)

        XCTAssertTrue(viewModel.isSessionComplete)
        XCTAssertEqual(viewModel.composer, .sessionComplete)
        // The rendered surface shows completion + restart, and the
        // editable composer (text field, Send, Hint) is gone.
        let rendered = renderedText(in: host.view)
        XCTAssertTrue(rendered.contains("Practice complete"), "completion state not rendered: \(rendered)")
        XCTAssertTrue(rendered.contains("Start again"), "restart action not rendered: \(rendered)")
        XCTAssertTrue(renderedTextViews(in: host.view).isEmpty,
                      "no editable text field may remain rendered after completion")
        XCTAssertFalse(rendered.contains("Type your answer"),
                       "composer placeholder must not remain rendered: \(rendered)")

        // Restart renders a fresh session with an editable composer.
        viewModel.restartSession()
        pump(host)
        XCTAssertFalse(viewModel.isSessionComplete)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.tutorMessages.first?.kind, .question)
        XCTAssertFalse(renderedTextViews(in: host.view).isEmpty,
                       "restart must render the composer again")
    }

    private func makeHosted(viewModel: ChatConversationViewModel)
        -> (host: UIHostingController<ChatConversationView>, window: UIWindow) {
        let host = UIHostingController(rootView: ChatConversationView(viewModel: viewModel))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    private func renderedTextViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let textView = view as? UITextView { result.append(textView) }
        for sub in view.subviews { result.append(contentsOf: renderedTextViews(in: sub)) }
        return result
    }

    /// Text recognized from a snapshot of the rendered hosted view,
    /// joined in top-to-bottom reading order.
    private func renderedText(in view: UIView) -> String {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }

    /// Speaker controls in the rendered layer tree: SF Symbol image
    /// layers at the trailing edge of tutor cards in the thread
    /// region (the header star sits higher and is excluded by size
    /// and position; child bubbles carry no image layer).
    private func renderedSpeakerIconCount(in view: UIView) -> Int {
        var layers: [CALayer] = []
        collectLayers(view.layer, into: &layers)
        // Convert frames into window coordinates via the layer tree:
        // frames in the dump are already in their superlayer space,
        // so accumulate origins along each path instead.
        var count = 0
        countSpeakerIcons(view.layer, origin: .zero, into: &count)
        _ = layers
        return count
    }

    private func collectLayers(_ layer: CALayer, into result: inout [CALayer]) {
        result.append(layer)
        for sub in layer.sublayers ?? [] { collectLayers(sub, into: &result) }
    }

    private func countSpeakerIcons(_ layer: CALayer, origin: CGPoint, into count: inout Int) {
        let global = CGRect(x: origin.x + layer.frame.origin.x,
                            y: origin.y + layer.frame.origin.y,
                            width: layer.frame.width, height: layer.frame.height)
        let name = "\(type(of: layer))"
        if name.contains("ImageLayer"),
           global.minX > 300, global.minY > 100, global.maxY < 762,
           global.width >= 14, global.width <= 24,
           global.height >= 12, global.height <= 18 {
            count += 1
        }
        for sub in layer.sublayers ?? [] {
            countSpeakerIcons(sub, origin: global.origin, into: &count)
        }
    }

    private func pump(_ host: UIHostingController<ChatConversationView>) {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()
    }
}
