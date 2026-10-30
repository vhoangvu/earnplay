import XCTest
import SwiftUI
import UIKit
import Vision
import EarnPlayCore
@testable import EarnPlay

/// T1.8 fix round 2 regression tests (issue #11, PR #57).
/// Item 1: composer height is bounded. Item 2: fallback reading
/// passages render/speak exactly once. Items 3+4: rendered controls
/// are driven through the accessibility tree when the unit-test host
/// vends it; where it provably does not, the binding assertions are
/// strengthened as far as honestly possible and the unverified
/// remainder is stated in the test names/comments (no fake taps).
@MainActor
final class ChatFixRound2Tests: XCTestCase {

    final class RecordingSpeechEngine: SpeechEngine {
        var onPlaybackFinished: (() -> Void)?
        private(set) var spokenTexts: [String] = []
        private(set) var stopCallCount = 0
        var isSpeaking = false
        @discardableResult
        func speak(text: String) -> Bool { spokenTexts.append(text); isSpeaking = true; return true }
        func stopSpeaking() { stopCallCount += 1; isSpeaking = false }
    }

    final class ScriptedEngine: ChatTutorEngine {
        private(set) var submitted: [String] = []
        private(set) var hintTaps = 0
        func startSession() -> ChatEngineUpdate {
            ChatEngineUpdate(
                turns: [.tutor(TutorMessage(id: "q1", text: "A farmer packs 7 eggs in each carton. She fills 8 cartons. How many eggs in all?", kind: .question))],
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 0),
                composer: .numberPad)
        }
        func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
            submitted.append(plainText)
            if submitted.count == 1 {
                return ChatEngineUpdate(
                    turns: [.tutor(TutorMessage(id: "e1", text: "Good trying. Let's look at it another way.", kind: .encouragement))],
                    progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 1), composer: .numberPad)
            }
            return ChatEngineUpdate(
                turns: [.tutor(TutorMessage(id: "e2", text: "Nice work. That was a good practice session.", kind: .encouragement))],
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 1), composer: .text,
                submittedTurnIsRevision: submitted.count >= 2 && plainText != submitted.first)
        }
        func requestHint() -> ChatEngineUpdate {
            hintTaps += 1
            return ChatEngineUpdate(turns: [
                .tutor(TutorMessage(id: "h1", text: "Try picturing 7 rows of 8 eggs.", kind: .hint)),
                .tutor(TutorMessage(id: "p1", text: "Show me one step: what did you try first?", kind: .probe))])
        }
    }

    private func makeSpeech() -> (ReadAloudService, RecordingSpeechEngine) {
        let fake = RecordingSpeechEngine()
        return (ReadAloudService(band: GradeBand(grade: "4"), engine: fake), fake)
    }

    // MARK: Item 1 — long multiline draft keeps composer bounded

    func testLongMultilineDraftKeepsComposerBoundedAndThreadReadable() throws {
        let (speech, _) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: ScriptedEngine(), speech: speech)
        let (host, window) = makeHosted(viewModel: viewModel); _ = window
        pump(host)
        viewModel.draft = (0..<20).map { "Line \($0) answer text that keeps going on" }.joined(separator: "\n")
        pump(host)
        let field = try XCTUnwrap(renderedTextViews(in: host.view).first, "rendered composer field missing")
        XCTAssertLessThan(field.bounds.height, 120,
                          "composer field must stay bounded (lineLimit 1...4), got height \(field.bounds.height)")
        // Thread viewport = the rendered message list (UIScrollView
        // backing chatThread), NOT window-minus-field (round-3 item 4).
        let scrollViews = renderedScrollViews(in: host.view)
        let thread = try XCTUnwrap(scrollViews.max(by: { $0.bounds.height < $1.bounds.height }),
                                   "rendered thread scroll view missing")
        // Real viewport is 479pt at the 4-line cap (header + bounded
        // composer take the rest of 844): still >half the window and
        // several message rows — the honest readable bound.
        XCTAssertGreaterThan(thread.bounds.height, 400,
                             "thread viewport must remain readable with a long draft, got \(thread.bounds.height)")
        XCTAssertGreaterThan(thread.bounds.height, host.view.bounds.height / 2,
                             "thread viewport must retain most of the screen")
    }

    // MARK: Item 2 — fallback reading passage exactly once

    func testFallbackReadingPromptAlreadyEmbedsPassageEvidence() {
        // Evidence for the dedupe decision, from the generation path:
        // every fallback reading proposal's promptText contains its
        // passage, and SolverService.verify preserves both verbatim.
        let solver = SolverService()
        let reading = FallbackQuestionBank.demo.entries.filter { $0.skill == .readingComprehension }
        XCTAssertFalse(reading.isEmpty)
        for proposal in reading {
            let passage = try! XCTUnwrap(proposal.passage)
            XCTAssertTrue(proposal.promptText.contains(passage.trimmingCharacters(in: .whitespacesAndNewlines)),
                          "fallback promptText must already embed its passage")
            guard case .success(let q) = solver.verify(proposal, questionId: "evidence") else {
                return XCTFail("fallback reading proposal must verify")
            }
            XCTAssertEqual(q.promptText, proposal.promptText)
            XCTAssertEqual(q.passage, proposal.passage)
        }
    }

    func testFallbackReadingQuestionRendersAndSpeaksPassageExactlyOnce() throws {
        let (speech, fake) = makeSpeech()
        let engine = DemoTutorEngine(maxQuestions: 100)
        let viewModel = ChatConversationViewModel(engine: engine, speech: speech)
        viewModel.startIfNeeded()
        // Advance through every pre-reading question using the
        // solver-verified answers for the same bank the engine serves.
        let solver = SolverService()
        var answers: [String] = []
        for (i, proposal) in FallbackQuestionBank.demo.entries.enumerated() {
            guard case .success(let q) = solver.verify(proposal, questionId: "demo-q\(i + 1)") else { continue }
            answers.append(q.verifiedAnswer)
        }
        var readingText: String?
        for answer in answers {
            if let current = viewModel.tutorMessages.last(where: { $0.kind == .question }),
               current.text.contains("What did Maya plant") || current.text.contains("Maya planted") {
                // Only capture once we are on a reading question:
                // reading tutor text contains the passage sentence.
                if FallbackQuestionBank.demo.entries.contains(where: {
                    $0.skill == .readingComprehension && ($0.passage.map { current.text.contains($0) } ?? false)
                }) { readingText = current.text; break }
            }
            viewModel.draft = answer
            viewModel.submitDraft()
            if viewModel.isSessionComplete { break }
        }
        if readingText == nil, let lastQ = viewModel.tutorMessages.last(where: { $0.kind == .question }) {
            readingText = lastQ.text
        }
        let text = try XCTUnwrap(readingText, "never reached a reading question; messages: \(viewModel.messages.map(\.displayedText))")
        let passage = try XCTUnwrap(FallbackQuestionBank.demo.entries.first(where: { $0.skill == .readingComprehension })?.passage)
        let trimmed = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let occurrences = text.components(separatedBy: trimmed).count - 1
        XCTAssertEqual(occurrences, 1, "passage must appear exactly once in rendered question, got \(occurrences) in: \(text)")
        // Spoken form is the same tutor text: speaking it speaks the passage once.
        let message = try XCTUnwrap(viewModel.tutorMessages.first(where: { $0.text == text }))
        speech.toggle(message)
        XCTAssertEqual(fake.spokenTexts, [text])
        XCTAssertEqual(fake.spokenTexts.first?.components(separatedBy: trimmed).count ?? 0, 2,
                       "spoken text must contain the passage exactly once")
    }

    // MARK: Items 3+4 — rendered controls

    /// Attempts every honest in-process control-driving path against
    /// the hosted view and reports what each did. Paths tried:
    /// (a) UIView subtree search by accessibilityIdentifier,
    /// (b) UIAccessibilityContainer (accessibilityElementCount/at:),
    /// (c) accessibilityElements tree + accessibilityActivate(),
    /// (d) synthetic UITouch (round-1 probe: does not reach SwiftUI
    /// buttons — not repeated here as a claimed tap).
    /// Returns the element for `id` if any path vends it.
    private func renderedAccessibilityElement(in host: UIHostingController<ChatConversationView>, id: String) -> UIAccessibilityElement? {
        // (b) container API on every UIKit view in the subtree
        var views: [UIView] = []
        func collect(_ v: UIView) { views.append(v); v.subviews.forEach(collect) }
        collect(host.view)
        for v in views {
            if v.accessibilityIdentifier == id, let el = v as? UIAccessibilityElement { return el }
            // NSNotFound == Int.max on non-container views: iterating
            // to it would hang (round-3 item 5). Guard explicitly.
            let count = v.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let el = v.accessibilityElement(at: i) as? UIAccessibilityElement, el.accessibilityIdentifier == id { return el }
                }
            }
            if let elems = v.accessibilityElements as? [UIAccessibilityElement],
               let el = elems.first(where: { $0.accessibilityIdentifier == id }) { return el }
        }
        return nil
    }

    func testRenderedControlsDriveActionsOrDocumentHostGap() throws {
        let (speech, fake) = makeSpeech()
        let engine = ScriptedEngine()
        let viewModel = ChatConversationViewModel(engine: engine, speech: speech)
        let (host, window) = makeHosted(viewModel: viewModel); _ = window
        pump(host)

        let field = try XCTUnwrap(renderedTextViews(in: host.view).first, "rendered composer field missing")
        field.insertText("54"); pump(host)
        XCTAssertEqual(viewModel.draft, "54")

        let sendEl = renderedAccessibilityElement(in: host, id: "chatSendButton")
        let hintEl = renderedAccessibilityElement(in: host, id: "chatHintButton")
        let speakerEl = renderedAccessibilityElement(in: host, id: "speakerButton_q1")
        print("R2AX send=\(String(describing: sendEl)) hint=\(String(describing: hintEl)) speaker=\(String(describing: speakerEl)) vo=\(UIAccessibility.isVoiceOverRunning)")

        if let sendEl, let hintEl, let speakerEl {
            // Real rendered-control path: activation through the
            // accessibility tree must run the buttons' own actions.
            XCTAssertTrue(sendEl.accessibilityActivate(), "Send activation must be handled")
            pump(host)
            XCTAssertEqual(engine.submitted, ["54"], "rendered Send must submit the draft")
            XCTAssertTrue(hintEl.accessibilityActivate(), "Hint activation must be handled")
            pump(host)
            XCTAssertEqual(engine.hintTaps, 1, "rendered Hint must request a hint")
            XCTAssertTrue(speakerEl.accessibilityActivate(), "Speaker activation must be handled")
            pump(host)
            XCTAssertEqual(fake.spokenTexts, [viewModel.tutorMessages[0].text],
                           "rendered speaker must speak its own message")
        } else {
            // Host gap (documented, not a fake tap): the unit-test
            // host vends no accessibility elements for SwiftUI
            // buttons (VoiceOver off; UIKit subtree holds only the
            // scroll view and text view — probed 2026-10-29 round 2).
            // Unverified remainder: the buttons' own tap closures.
            // Strengthened binding below: rendered presence (OCR +
            // layer tree in the round-1 tests, rechecked here) plus
            // the exact action targets the rendered buttons call,
            // exercised on the same view model / speech service
            // instances the hosted buttons are bound to. Emptying a
            // button's closure would NOT be caught by this fallback;
            // it would be caught only in a UI-test (XCUITest) host.
            print("R2AX GAP: no accessibility elements vended in unit-test host; falling back to rendered-presence + action-target wiring")
            let rendered = renderedText(in: host.view)
            XCTAssertTrue(rendered.contains("Hint"), "rendered Hint missing: \(rendered)")
            XCTAssertTrue(rendered.contains("Send"), "rendered Send missing: \(rendered)")
            XCTAssertEqual(renderedSpeakerIconCount(in: host.view), 1, "rendered speaker control missing")
            viewModel.submitDraft()
            XCTAssertEqual(engine.submitted, ["54"], "Send's action target (submitDraft) must submit")
            viewModel.requestHint()
            XCTAssertEqual(engine.hintTaps, 1, "Hint's action target (requestHint) must request a hint")
            let first = try XCTUnwrap(viewModel.tutorMessages.first)
            speech.toggle(first)
            XCTAssertEqual(fake.spokenTexts, [first.text], "speaker action target (toggle) must speak its message")
            speech.toggle(first)
            XCTAssertFalse(speech.isSpeaking)
        }

        // Rendered order + no score text (also covered in round 1).
        field.selectAll(nil); field.insertText("56"); pump(host)
        if renderedAccessibilityElement(in: host, id: "chatSendButton") != nil {
            _ = renderedAccessibilityElement(in: host, id: "chatSendButton")?.accessibilityActivate()
            pump(host)
        } else {
            viewModel.submitDraft(); pump(host)
        }
        let rendered = renderedText(in: host.view)
        var start = rendered.startIndex
        for fragment in ["A farmer packs 7 eggs", "54", "Good trying", "56"] {
            guard let r = rendered.range(of: fragment, range: start..<rendered.endIndex) else {
                return XCTFail("rendered order missing '\(fragment)' in: \(rendered)")
            }
            start = r.upperBound
        }
        let banned = try NSRegularExpression(pattern: "(?i)\\b(score|scores|points?|pts|timer|countdown|fail|failed|failure|passed|wrong|incorrect)\\b|\\d+\\s*%")
        XCTAssertNil(banned.firstMatch(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)),
                     "score-like rendered text: \(rendered)")
    }

    // MARK: Hosted helpers (mirroring ChatFixRound1Tests)

    private func makeHosted(viewModel: ChatConversationViewModel) -> (UIHostingController<ChatConversationView>, UIWindow) {
        let host = UIHostingController(rootView: ChatConversationView(viewModel: viewModel))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (host, window)
    }

    // Round-3 item 5: guarded iteration terminates on NSNotFound view.
    final class NotFoundContainerView: UIView {
        override func accessibilityElementCount() -> Int { NSNotFound }
    }

    func testAccessibilityIterationTerminatesOnNSNotFoundView() throws {
        let (speech, _) = makeSpeech()
        let viewModel = ChatConversationViewModel(engine: ScriptedEngine(), speech: speech)
        let (host, window) = makeHosted(viewModel: viewModel); _ = window
        pump(host)
        host.view.addSubview(NotFoundContainerView(frame: .zero))
        pump(host)
        // Would hang pre-fix (0..<Int.max). Completing at all proves
        // the guard; result must be nil-or-found without trapping.
        _ = renderedAccessibilityElement(in: host, id: "chatSendButton")
    }

    private func renderedScrollViews(in view: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        if let sv = view as? UIScrollView { result.append(sv) }
        for s in view.subviews { result.append(contentsOf: renderedScrollViews(in: s)) }
        return result
    }

    private func renderedTextViews(in view: UIView) -> [UITextView] {
        var result: [UITextView] = []
        if let tv = view as? UITextView { result.append(tv) }
        for s in view.subviews { result.append(contentsOf: renderedTextViews(in: s)) }
        return result
    }

    private func renderedText(in view: UIView) -> String {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func renderedSpeakerIconCount(in view: UIView) -> Int {
        var count = 0
        countSpeakerIcons(view.layer, origin: .zero, into: &count)
        return count
    }

    private func countSpeakerIcons(_ layer: CALayer, origin: CGPoint, into count: inout Int) {
        let global = CGRect(x: origin.x + layer.frame.origin.x, y: origin.y + layer.frame.origin.y,
                            width: layer.frame.width, height: layer.frame.height)
        if "\(type(of: layer))".contains("ImageLayer"),
           global.minX > 300, global.minY > 100, global.maxY < 762,
           global.width >= 14, global.width <= 24, global.height >= 12, global.height <= 18 { count += 1 }
        for sub in layer.sublayers ?? [] { countSpeakerIcons(sub, origin: global.origin, into: &count) }
    }

    private func pump(_ host: UIHostingController<ChatConversationView>) {
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()
    }
}
