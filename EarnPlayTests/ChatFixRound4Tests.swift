import XCTest
import SwiftUI
import UIKit
import Vision
import EarnPlayCore
@testable import EarnPlay

/// T1.8 fix round 4 (issue #11, PR #57 head 02f875b).
/// Item 1: pixel sampling normalizes into an explicitly configured
/// RGBA8 bitmap before sampling; contrast is computed on the
/// normalized data. Item 2: the voice-unavailable notice lives in
/// fixed chrome so it stays visible in a scrolled thread.
/// Item 3 is re-proven by the round-3 normalized test; items 4/5 are
/// verify-only (see the round-3 header mapping and census probe).
@MainActor
final class ChatFixRound4Tests: XCTestCase {

    final class FakeEngine: SpeechEngine {
        var onPlaybackFinished: (() -> Void)?
        var voiceAvailable = true
        private(set) var spoken: [String] = []
        var isSpeaking = false
        @discardableResult func speak(text: String) -> Bool {
            guard voiceAvailable else { return false }
            spoken.append(text); isSpeaking = true; return true
        }
        func stopSpeaking() { isSpeaking = false }
    }
    final class ManyEngine: ChatTutorEngine {
        func startSession() -> ChatEngineUpdate {
            let turns: [ChatTurn] = (1...14).map { i in
                .tutor(TutorMessage(id: "q\(i)", text: "Question number \(i): what is \(i) plus \(i)? Take your time and think about the numbers.", kind: .question))
            }
            return ChatEngineUpdate(turns: turns, progress: ChatProgress(totalQuestions: 14, attemptedQuestions: 0), composer: .numberPad)
        }
        func submitAnswer(_ t: String) -> ChatEngineUpdate { ChatEngineUpdate() }
        func requestHint() -> ChatEngineUpdate { ChatEngineUpdate() }
    }

    // MARK: Item 1 — normalized RGBA sampling

    func testNormalizedSamplingDecodesPrimarySwatch() throws {
        let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        swatch.backgroundColor = UIColor(red: 0x43 / 255, green: 0x61 / 255, blue: 0xEE / 255, alpha: 1)
        let center = normalizedCenterPixel(in: swatch)
        print("R4-ITEM1 normalizedCenter=\(center) expected=(67,97,238)")
        XCTAssertTrue(abs(center.0 - 0x43) <= 1, "normalized red \(center.0) != 67")
        XCTAssertTrue(abs(center.1 - 0x61) <= 1, "normalized green \(center.1) != 97")
        XCTAssertTrue(abs(center.2 - 0xEE) <= 1, "normalized blue \(center.2) != 238")
    }

    // T7.8 fix-2: the glyph is now the paired tutorText token (the
    // old accent glyph fell below 3:1 in 3 palettes), so sampling
    // counts non-white glyph pixels instead of blue-classified ones.
    func testNormalizedSamplingFindsGlyphWithContrastInLightAndDark() throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let fake = FakeEngine()
            let speech = ReadAloudService(band: GradeBand(grade: "4"), engine: fake)
            let msg = TutorMessage(id: "q1", text: "What is 7 times 8?", kind: .question)
            let host = UIHostingController(rootView: SpeakerButton(message: msg, service: speech).background(DesignSystem.defaultTheme.tokens.tutorBackground.color))
            let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
            win.overrideUserInterfaceStyle = style
            win.rootViewController = host; win.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let sample = normalizedRGBASample(in: host.view)
            print("R4-ITEM1 style=\(style.rawValue) glyphPixels=\(sample.glyphCount) contrast=\(sample.contrastVsWhite)")
            XCTAssertGreaterThan(sample.glyphCount, 5, "normalized sampling must find the glyph in style \(style.rawValue)")
            XCTAssertGreaterThan(sample.contrastVsWhite, 3.0, "normalized glyph/white contrast must exceed 3:1 in style \(style.rawValue)")
        }
    }

    /// The normalized check must still reject a genuinely
    /// low-contrast fixture: a low-contrast BLUE glyph on the white
    /// surface (~2.72:1), chosen blue so pixels are actually sampled
    /// and the measured-contrast path is exercised (a pale-gray
    /// fixture sampled zero glyph pixels and hit the (0, 1) fallback).
    func testNormalizedSamplingFailsOnLowContrastFixture() throws {
        let fixture = Image(systemName: "speaker.wave.2.fill")
            .foregroundStyle(Color(red: 0x80 / 255, green: 0x99 / 255, blue: 0xEE / 255))
            .font(.body)
            .frame(minWidth: 44, minHeight: 44)
            .background(DesignSystem.defaultTheme.tokens.tutorBackground.color)
        let host = UIHostingController(rootView: fixture)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        win.rootViewController = host; win.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let sample = normalizedRGBASample(in: host.view)
        print("R4-ITEM1-LOW glyphPixels=\(sample.glyphCount) contrast=\(sample.contrastVsWhite)")
        XCTAssertGreaterThan(sample.glyphCount, 5, "low-contrast fixture must sample pixels before the contrast check")
        XCTAssertLessThanOrEqual(sample.contrastVsWhite, 3.0, "low-contrast fixture must not satisfy the 3:1 check")
    }

    // MARK: Item 2 — notice visible in an already-scrolled thread

    func testScrolledThreadShowsVoiceUnavailableNotice() throws {
        let fake = FakeEngine(); fake.voiceAvailable = false
        let speech = ReadAloudService(band: GradeBand(grade: "4"), engine: fake)
        let vm = ChatConversationViewModel(engine: ManyEngine(), speech: speech)
        let host = UIHostingController(rootView: ChatConversationView(viewModel: vm))
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = host; win.makeKeyAndVisible()
        pump(host)
        XCTAssertEqual(vm.messages.count, 14)
        let sv = try XCTUnwrap(findScrollView(in: host.view), "rendered thread scroll view must exist")
        XCTAssertGreaterThan(sv.contentSize.height, sv.bounds.height, "thread must overflow the viewport for this test")
        sv.contentOffset = CGPoint(x: 0, y: max(0, sv.contentSize.height - sv.bounds.height))
        pump(host)
        XCTAssertGreaterThan(sv.contentOffset.y, 100, "thread must be scrolled to the latest messages")
        let msg = try XCTUnwrap(vm.tutorMessages.last)
        speech.toggle(msg)
        XCTAssertTrue(vm.isVoiceUnavailable)
        pump(host)
        let text = renderedText(in: host.view)
        print("R4-ITEM2 rendered=\(text)")
        XCTAssertTrue(text.contains("unavailable"), "voice-unavailable notice must be in the visible viewport; rendered: \(text)")
    }

    // MARK: Normalized sampling helpers (fixed RGBA8 layout)

    private func normalizedBitmap(in view: UIView) -> (bytes: [UInt8], width: Int, height: Int)? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }

    private func normalizedCenterPixel(in view: UIView) -> (Int, Int, Int) {
        guard let bmp = normalizedBitmap(in: view) else { return (-1, -1, -1) }
        let o = ((bmp.height / 2) * bmp.width + bmp.width / 2) * 4
        return (Int(bmp.bytes[o]), Int(bmp.bytes[o + 1]), Int(bmp.bytes[o + 2]))
    }

    private func normalizedRGBASample(in view: UIView) -> (glyphCount: Int, contrastVsWhite: Double) {
        guard let bmp = normalizedBitmap(in: view) else { return (0, 1) }
        var n = 0, sr = 0.0, sg = 0.0, sb = 0.0
        for i in 0..<(bmp.width * bmp.height) {
            let o = i * 4
            let (rr, gg, bb) = (Int(bmp.bytes[o]), Int(bmp.bytes[o + 1]), Int(bmp.bytes[o + 2]))
            if rr < 200 || gg < 200 || bb < 200 {
                n += 1; sr += Double(rr); sg += Double(gg); sb += Double(bb)
            }
        }
        guard n > 0 else { return (0, 1) }
        func lum(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lum(sr / Double(n) / 255) + 0.7152 * lum(sg / Double(n) / 255) + 0.0722 * lum(sb / Double(n) / 255)
        return (n, 1.05 / (l + 0.05))
    }

    // MARK: helpers
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView, !(view is UITextView) { return sv }
        for sub in view.subviews { if let found = findScrollView(in: sub) { return found } }
        return nil
    }
    private func pump(_ host: UIHostingController<ChatConversationView>) {
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)); host.view.layoutIfNeeded()
    }
    private func renderedText(in view: UIView) -> String {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return "" }
        let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
