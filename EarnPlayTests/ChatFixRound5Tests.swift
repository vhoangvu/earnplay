import XCTest
import SwiftUI
import UIKit
import EarnPlayCore
@testable import EarnPlay

/// T1.8 fix round 5 (issue #11, PR #57 head 08157b6).
/// Item 1: filled progress stars are the only visual progress
/// indication, so their defining boundary must meet 3:1 against
/// the header surface. The fix keeps the starFill token fill and
/// backs each filled star with the paired tutorText token; this
/// test samples the rendered default-theme header and proves fill
/// pixels remain AND adjacent outline pixels (tutorText-near, next
/// to the fill) exceed 3:1, in both appearances. Item 2 lives in
/// ChatFixRound4Tests (blue fixture). Items 3-5 are verify-only on
/// this head (see progress log).
///
/// T7.8 fix-2: the outline is now the paired tutorText token — the
/// old accent outline fell below 3:1 in Warm Playful, Blush Pink,
/// and Hot Pink — so sampling counts dark outline pixels instead
/// of blue-classified ones.
///
/// Issue #81: the default moved from Canonical (yellow #ffb703
/// fill, near-black outline) to Light Pink (pink #f472a0 fill,
/// dark-rose #7a2148 outline), so the sampler keys off the default
/// theme's starFill/tutorText tokens at tolerance 40 instead of
/// the hardcoded yellow/dark classifiers. The assertions are
/// unchanged: fill present, outline present, outline past 3:1.
@MainActor
final class ChatFixRound5Tests: XCTestCase {

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
    final class ProgressEngine: ChatTutorEngine {
        func startSession() -> ChatEngineUpdate {
            ChatEngineUpdate(
                turns: [.tutor(TutorMessage(id: "q1", text: "What is 7 times 8?", kind: .question))],
                progress: ChatProgress(totalQuestions: 3, attemptedQuestions: 2),
                composer: .numberPad)
        }
        func submitAnswer(_ t: String) -> ChatEngineUpdate { ChatEngineUpdate() }
        func requestHint() -> ChatEngineUpdate { ChatEngineUpdate() }
    }

    // MARK: Item 1 — filled stars meet 3:1 via contrasting outline

    func testFilledStarsKeepFillWithContrastingOutlineInLightAndDark() throws {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let speech = ReadAloudService(band: GradeBand(grade: "4"), engine: FakeEngine())
            let vm = ChatConversationViewModel(engine: ProgressEngine(), speech: speech)
            let host = UIHostingController(rootView: ChatConversationView(viewModel: vm))
            let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            win.overrideUserInterfaceStyle = style
            win.rootViewController = host; win.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            host.view.layoutIfNeeded()
            XCTAssertEqual(vm.progress.attemptedQuestions, 2)
            let sample = starSample(in: host.view)
            print("R5-ITEM1 style=\(style.rawValue) fill=\(sample.fillCount) outline=\(sample.outlineCount) outlineContrast=\(sample.outlineContrastVsWhite)")
            XCTAssertGreaterThan(sample.fillCount, 5,
                                 "filled stars must keep the starFill token fill in style \(style.rawValue)")
            XCTAssertGreaterThan(sample.outlineCount, 5,
                                 "filled stars must render a contrasting outline next to the fill in style \(style.rawValue)")
            XCTAssertGreaterThan(sample.outlineContrastVsWhite, 3.0,
                                 "filled-star outline/white contrast must exceed 3:1 in style \(style.rawValue)")
        }
    }

    // MARK: Normalized sampling helpers (fixed RGBA8 layout, as R4)

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

    /// StarFill-token pixels define the star region; outline pixels
    /// are tutorText-near pixels inside that region expanded by a
    /// margin (excludes distant chrome such as bubbles). Tolerance
    /// 40 isolates both tokens in the Light Pink default: starFill
    /// #f472a0 clears the accent pink by 50+ on green/blue and the
    /// header surface by 117 on green, while tutorText #7a2148 is
    /// 80+ from the fill and the surface on every channel.
    private func starSample(in view: UIView) -> (fillCount: Int, outlineCount: Int, outlineContrastVsWhite: Double) {
        guard let bmp = normalizedBitmap(in: view) else { return (0, 0, 1) }
        let fillTarget = rgb255(DesignSystem.defaultTheme.tokens.starFill)
        let outlineTarget = rgb255(DesignSystem.defaultTheme.tokens.tutorText)
        func px(_ i: Int) -> (Int, Int, Int) {
            let o = i * 4
            return (Int(bmp.bytes[o]), Int(bmp.bytes[o + 1]), Int(bmp.bytes[o + 2]))
        }
        var fill = 0, minX = bmp.width, maxX = -1, minY = bmp.height, maxY = -1
        for y in 0..<bmp.height {
            for x in 0..<bmp.width {
                if near(px(y * bmp.width + x), fillTarget, tolerance: 40) {
                    fill += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard fill > 0, maxX >= 0 else { return (0, 0, 1) }
        let m = 14
        let x0 = max(0, minX - m), x1 = min(bmp.width - 1, maxX + m)
        let y0 = max(0, minY - m), y1 = min(bmp.height - 1, maxY + m)
        var n = 0, sr = 0.0, sg = 0.0, sb = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let p = px(y * bmp.width + x)
                if near(p, outlineTarget, tolerance: 40) {
                    n += 1; sr += Double(p.0); sg += Double(p.1); sb += Double(p.2)
                }
            }
        }
        guard n > 0 else { return (fill, 0, 1) }
        func lum(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lum(sr / Double(n) / 255) + 0.7152 * lum(sg / Double(n) / 255) + 0.0722 * lum(sb / Double(n) / 255)
        return (fill, n, 1.05 / (l + 0.05))
    }

    private func rgb255(_ rgb: DesignSystem.RGB) -> (Int, Int, Int) {
        (Int(round(rgb.red * 255)), Int(round(rgb.green * 255)), Int(round(rgb.blue * 255)))
    }

    private func near(_ px: (Int, Int, Int), _ target: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(px.0 - target.0) <= tolerance && abs(px.1 - target.1) <= tolerance && abs(px.2 - target.2) <= tolerance
    }
}
