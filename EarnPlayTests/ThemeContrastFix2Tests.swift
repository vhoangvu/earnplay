import XCTest
import SwiftUI
import UIKit
import Vision
import EarnPlayCore
@testable import EarnPlay

/// T7.8 fix-2 (issue #73) rendering tests: progress-star boundaries for
/// BOTH states and the speaker glyph across all 8 palettes, in light
/// and dark appearances — plus the Finding-2 settings-route proof.
///
/// Findings 1+3: each star state keeps its prescribed token color and
/// SF Symbol shape, backed by the paired tutorText token; the speaker
/// glyph itself is tutorText on the fixed light row. Pixel sampling
/// follows the ChatFixRound4 normalized-RGBA pattern (fixed RGBA8
/// layout before any byte is sampled). Contrast floors are pinned
/// analytically in ThemeStoreTests; here the render must actually
/// contain the prescribed colors and the boundary color.
///
/// Finding 2: the setup-complete screen (the view ContentView renders
/// for model-ready + complete + undismissed summary) carries the
/// About entry bound to the passed app-scope store. The UI-test
/// harness cannot reach this screen (setup completion needs Screen
/// Time authorization: WalkthroughChild04 SETUP-COMPLETION gap), so
/// this in-process test proves the route on the real view instead.
///
/// T7.8 fix-3 item A: the star sampler is differential (each star
/// state renders separately against a background-only reference;
/// only painted pixels are classified) with missing-glyph and
/// missing-boundary negative fixtures, closing the whole-bitmap
/// false-pass where the background itself counted as starEmpty.
@MainActor
final class ThemeContrastFix2Tests: XCTestCase {

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

    // MARK: - Finding 1: both star states, every palette (fix-3 item A)

    /// Each star state renders SEPARATELY against its own background
    /// reference (fix-3 item A): only pixels the star actually paints
    /// (differing from the background-only render) are classified, so
    /// background pixels can no longer count as a star state. The old
    /// whole-bitmap sampler counted the Canonical background itself as
    /// starEmpty (white is within tolerance of #d0d0e0) and pooled
    /// both stars' boundaries, so it passed with a glyph removed.
    /// Production rendering is unchanged; only the sampler changed.
    func testProgressStarsKeepColorsWithBoundaryInEveryPalette() throws {
        for palette in DesignSystem.Palette.allCases {
            let theme = DesignSystem.Theme(palette: palette, shape: .rounded)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let bg = try XCTUnwrap(renderBackground(theme: theme, style: style),
                    "\(palette) style \(style.rawValue): background reference did not render")
                let filledBmp = try XCTUnwrap(renderStar(filled: true, theme: theme, style: style),
                    "\(palette) style \(style.rawValue): filled star did not render")
                let filled = starCounts(star: filledBmp, background: bg, theme: theme)
                print("FIX3-STARS \(palette) style=\(style.rawValue) filled: fill=\(filled.fill) empty=\(filled.empty) boundary=\(filled.boundary)")
                XCTAssertGreaterThan(filled.fill, 5,
                    "\(palette): filled star must keep its starFill token in style \(style.rawValue)")
                XCTAssertGreaterThan(filled.boundary, 5,
                    "\(palette): filled star must render the tutorText boundary in style \(style.rawValue)")

                let emptyBmp = try XCTUnwrap(renderStar(filled: false, theme: theme, style: style),
                    "\(palette) style \(style.rawValue): empty star did not render")
                let empty = starCounts(star: emptyBmp, background: bg, theme: theme)
                print("FIX3-STARS \(palette) style=\(style.rawValue) empty: fill=\(empty.fill) empty=\(empty.empty) boundary=\(empty.boundary)")
                XCTAssertGreaterThan(empty.empty, 5,
                    "\(palette): empty star must keep its starEmpty token in style \(style.rawValue)")
                XCTAssertGreaterThan(empty.boundary, 5,
                    "\(palette): empty star must render the tutorText boundary in style \(style.rawValue)")
            }
        }
    }

    // MARK: - Item A negative fixtures: the sampler must catch removal

    /// Missing-glyph fixture: two INDEPENDENT background-only renders
    /// compared as star-vs-background must yield ZERO of every state.
    /// Sensitivity: the old sampler returned thousands of "empty"
    /// pixels here (Canonical white is within tolerance of starEmpty
    /// #d0d0e0: diffs 47,47,31), so a removed glyph still passed; the
    /// differential sampler returns 0 because no pixel differs, so a
    /// removed glyph now fails the positive test's >5 assertions.
    /// Independent renders (not one bitmap vs itself) also prove
    /// render noise stays below the differential threshold.
    func testStarSamplerFindsNoGlyphOnBackgroundOnly() throws {
        for palette in DesignSystem.Palette.allCases {
            let theme = DesignSystem.Theme(palette: palette, shape: .rounded)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let first = try XCTUnwrap(renderBackground(theme: theme, style: style),
                    "\(palette) style \(style.rawValue): background reference did not render")
                let second = try XCTUnwrap(renderBackground(theme: theme, style: style),
                    "\(palette) style \(style.rawValue): second background reference did not render")
                let counts = starCounts(star: second, background: first, theme: theme)
                print("FIX3-NOGLYPH \(palette) style=\(style.rawValue) fill=\(counts.fill) empty=\(counts.empty) boundary=\(counts.boundary)")
                XCTAssertEqual(counts.fill, 0,
                    "\(palette): background must supply no fill pixels in style \(style.rawValue)")
                XCTAssertEqual(counts.empty, 0,
                    "\(palette): background must supply no empty pixels in style \(style.rawValue)")
                XCTAssertEqual(counts.boundary, 0,
                    "\(palette): background must supply no boundary pixels in style \(style.rawValue)")
            }
        }
    }

    /// Missing-boundary fixtures: a star WITHOUT the tutorText backing
    /// (plain single glyph in the state color) must still show its
    /// glyph color but ZERO boundary pixels — i.e. it would FAIL the
    /// positive test's boundary > 5 assertion. The glyph-present half
    /// (fill/empty > 5) proves the fixture actually rendered, so the
    /// boundary == 0 half proves detection is sensitive to the backing.
    func testStarSamplerFindsNoBoundaryWithoutBacking() throws {
        for palette in DesignSystem.Palette.allCases {
            let theme = DesignSystem.Theme(palette: palette, shape: .rounded)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let bg = try XCTUnwrap(renderBackground(theme: theme, style: style),
                    "\(palette) style \(style.rawValue): background reference did not render")
                let filledBmp = try XCTUnwrap(renderUnbackedStar(filled: true, theme: theme, style: style),
                    "\(palette) style \(style.rawValue): unbacked filled star did not render")
                let filled = starCounts(star: filledBmp, background: bg, theme: theme)
                print("FIX3-NOBOUNDARY \(palette) style=\(style.rawValue) filled: fill=\(filled.fill) boundary=\(filled.boundary)")
                XCTAssertGreaterThan(filled.fill, 5,
                    "\(palette): unbacked filled fixture must still render its glyph in style \(style.rawValue)")
                XCTAssertEqual(filled.boundary, 0,
                    "\(palette): unbacked filled star must show no boundary in style \(style.rawValue)")

                let emptyBmp = try XCTUnwrap(renderUnbackedStar(filled: false, theme: theme, style: style),
                    "\(palette) style \(style.rawValue): unbacked empty star did not render")
                let empty = starCounts(star: emptyBmp, background: bg, theme: theme)
                print("FIX3-NOBOUNDARY \(palette) style=\(style.rawValue) empty: empty=\(empty.empty) boundary=\(empty.boundary)")
                XCTAssertGreaterThan(empty.empty, 5,
                    "\(palette): unbacked empty fixture must still render its glyph in style \(style.rawValue)")
                XCTAssertEqual(empty.boundary, 0,
                    "\(palette): unbacked empty star must show no boundary in style \(style.rawValue)")
            }
        }
    }

    // MARK: - Finding 3: speaker glyph, every palette

    func testSpeakerGlyphUsesPairedTextColorInEveryPalette() throws {
        for palette in DesignSystem.Palette.allCases {
            let theme = DesignSystem.Theme(palette: palette, shape: .rounded)
            for style: UIUserInterfaceStyle in [.light, .dark] {
                let speech = ReadAloudService(band: GradeBand(grade: "4"), engine: FakeEngine())
                let msg = TutorMessage(id: "q1", text: "What is 7 times 8?", kind: .question)
                let host = UIHostingController(rootView:
                    SpeakerButton(message: msg, service: speech, theme: theme)
                        .background(theme.tokens.tutorBackground.color)
                )
                let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
                win.overrideUserInterfaceStyle = style
                win.rootViewController = host; win.makeKeyAndVisible()
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                let count = glyphSample(in: host.view, theme: theme)
                print("FIX2-GLYPH \(palette) style=\(style.rawValue) glyphPixels=\(count)")
                XCTAssertGreaterThan(count, 5,
                    "\(palette): speaker glyph must render in the paired tutorText token in style \(style.rawValue)")
            }
        }
    }

    // MARK: - Finding 2: settings route on the model-ready UI

    private final class MutableAuthorizationService: SetupAuthorizationService, @unchecked Sendable {
        var status: SetupAuthorizationState
        var grantsOnRequest: Bool
        init(status: SetupAuthorizationState = .notDetermined, grantsOnRequest: Bool = true) {
            self.status = status
            self.grantsOnRequest = grantsOnRequest
        }
        func currentStatus() -> SetupAuthorizationState { status }
        func requestAuthorization() async -> Bool {
            if grantsOnRequest { status = .approved }
            return status == .approved
        }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")
    private static let allowedApp = AppRef(id: "com.example.allowed")

    /// The model-ready setup-complete screen (ContentView's branch for
    /// download-ready + step complete + undismissed summary) renders
    /// the About entry and retains the exact app-scope store instance
    /// it was given, so the sheet's picker drives the live app theme.
    /// The store-to-picker driving itself is proven by
    /// ThemePickerUITests on both apps; this pins the route + binding.
    func testSetupCompleteCarriesAboutEntryBoundToAppStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeContrastFix2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "earnplay.ThemeContrastFix2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PolicyStore(directory: directory)
        let backend = NonEnforcingShieldBackend()
        let manager = ShieldManager(
            policyStore: store, enumeration: .empty, backend: backend,
            unlockStore: FileUnlockWindowStore(directory: directory))
        let flow = SetupFlow(
            policyStore: store, shieldManager: manager,
            enumerationStore: FileSetupEnumerationStore(directory: directory))
        let auth = MutableAuthorizationService(status: .approved)
        let viewModel = SetupFlowViewModel(
            flow: flow, policyStore: store, backend: backend,
            authService: auth, tokenStore: SetupTokenStore(directory: directory))
        viewModel.flow.recordAuthorization(granted: true)
        XCTAssertTrue(viewModel.flow.submitEnumeration(ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.allowedApp, category: Self.games),
            ],
            categories: [Self.games])))
        XCTAssertTrue(viewModel.flow.submitSelections(
            allowlist: [Self.allowedApp], unblockable: [Self.game]))
        viewModel.finishSetup()
        XCTAssertEqual(viewModel.step, .complete)
        XCTAssertNotNil(viewModel.summary)
        XCTAssertFalse(viewModel.summaryDismissed)

        // Same-store binding: the view retains the exact instance.
        let themes = ThemeStore(defaults: defaults)
        let view = SetupCompleteView(viewModel: viewModel, themes: themes)
        let mirror = Mirror(reflecting: view)
        let kept = (mirror.descendant("_themes") as? ObservedObject<ThemeStore>)?.wrappedValue
        XCTAssertTrue(kept === themes, "SetupCompleteView must retain the passed app-scope ThemeStore instance")

        // The About entry renders on the real model-ready screen.
        let host = UIHostingController(rootView: view)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = host; win.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()
        var foundID = false
        func walk(_ v: UIView) {
            if v.accessibilityIdentifier == "setupCompleteAboutButton" { foundID = true }
            v.subviews.forEach(walk)
        }
        walk(host.view)
        let text = renderedText(in: host.view)
        print("FIX2-ROUTE foundID=\(foundID) rendered=\(text)")
        XCTAssertTrue(foundID || text.contains("About"),
            "setup-complete must render the About entry; rendered: \(text)")
    }

    // MARK: - Normalized sampling helpers (fixed RGBA8 layout, as R4)

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

    private func rgb255(_ rgb: DesignSystem.RGB) -> (Int, Int, Int) {
        (Int(round(rgb.red * 255)), Int(round(rgb.green * 255)), Int(round(rgb.blue * 255)))
    }

    private func near(_ px: (Int, Int, Int), _ target: (Int, Int, Int), tolerance: Int = 50) -> Bool {
        abs(px.0 - target.0) <= tolerance && abs(px.1 - target.1) <= tolerance && abs(px.2 - target.2) <= tolerance
    }

    private struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    /// Fixed geometry shared by every star/background render so the
    /// differential comparison is pixel-aligned. The window is larger
    /// than the content frame on purpose: tiny windows (~64x48)
    /// rasterize blank via drawHierarchy (diagnosed: identical
    /// content renders in a 120x60 window but not in a 64x48 one),
    /// while the fixed content frame keeps star and background pixels
    /// aligned across renders.
    private let starFrame = CGSize(width: 64, height: 48)
    private let renderWindow = CGSize(width: 120, height: 60)

    private func render<Content: View>(_ content: Content, style: UIUserInterfaceStyle) -> Bitmap? {
        let host = UIHostingController(rootView: content)
        let win = UIWindow(frame: CGRect(origin: .zero, size: renderWindow))
        win.overrideUserInterfaceStyle = style
        win.rootViewController = host; win.makeKeyAndVisible()
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        guard let bmp = normalizedBitmap(in: host.view) else { return nil }
        return Bitmap(bytes: bmp.bytes, width: bmp.width, height: bmp.height)
    }

    private func renderStar(filled: Bool, theme: DesignSystem.Theme, style: UIUserInterfaceStyle) -> Bitmap? {
        render(
            ThemeProgressStar(filled: filled, theme: theme)
                .frame(width: starFrame.width, height: starFrame.height)
                .background(theme.tokens.tutorBackground.color),
            style: style)
    }

    private func renderBackground(theme: DesignSystem.Theme, style: UIUserInterfaceStyle) -> Bitmap? {
        render(
            Color.clear
                .frame(width: starFrame.width, height: starFrame.height)
                .background(theme.tokens.tutorBackground.color),
            style: style)
    }

    /// A star glyph with NO tutorText backing: the removed-boundary
    /// fixture. Same inner glyph (size 15, state color) as
    /// ThemeProgressStar, without the size-20 backing.
    private func renderUnbackedStar(filled: Bool, theme: DesignSystem.Theme, style: UIUserInterfaceStyle) -> Bitmap? {
        render(
            Image(systemName: filled ? "star.fill" : "star")
                .font(.system(size: 15))
                .foregroundStyle((filled ? theme.tokens.starFill : theme.tokens.starEmpty).color)
                .frame(width: starFrame.width, height: starFrame.height)
                .background(theme.tokens.tutorBackground.color),
            style: style)
    }

    /// Differential sampler (fix-3 item A): a pixel is examined only
    /// when the star render differs from the background-only render
    /// there (max-channel abs diff > 12), and is then classified with
    /// the R4 tolerance (50, boundary first). Threshold rationale: the
    /// closest star-vs-background pair across palettes differs by 24
    /// (System Native starEmpty #d1d1d6 vs tutorBackground #e9e9eb:
    /// 24,24,21), while identical-layout render noise is ~0 (proven
    /// by testStarSamplerFindsNoGlyphOnBackgroundOnly returning
    /// exactly 0); 12 splits them with margin on both sides.
    private func starCounts(star: Bitmap, background: Bitmap, theme: DesignSystem.Theme) -> (fill: Int, empty: Int, boundary: Int) {
        guard star.width == background.width && star.height == background.height else {
            XCTFail("star/background bitmap size mismatch: \(star.width)x\(star.height) vs \(background.width)x\(background.height)")
            return (0, 0, 0)
        }
        let fill = rgb255(theme.tokens.starFill)
        let empty = rgb255(theme.tokens.starEmpty)
        let boundary = rgb255(theme.tokens.tutorText)
        var f = 0, e = 0, b = 0
        for i in 0..<(star.width * star.height) {
            let o = i * 4
            let dr = abs(Int(star.bytes[o]) - Int(background.bytes[o]))
            let dg = abs(Int(star.bytes[o + 1]) - Int(background.bytes[o + 1]))
            let db = abs(Int(star.bytes[o + 2]) - Int(background.bytes[o + 2]))
            guard max(dr, max(dg, db)) > 12 else { continue }
            let px = (Int(star.bytes[o]), Int(star.bytes[o + 1]), Int(star.bytes[o + 2]))
            if near(px, boundary) { b += 1 } else if near(px, fill) { f += 1 } else if near(px, empty) { e += 1 }
        }
        return (f, e, b)
    }

    private func glyphSample(in view: UIView, theme: DesignSystem.Theme) -> Int {
        guard let bmp = normalizedBitmap(in: view) else { return 0 }
        let glyph = rgb255(theme.tokens.tutorText)
        var n = 0
        for i in 0..<(bmp.width * bmp.height) {
            let o = i * 4
            let px = (Int(bmp.bytes[o]), Int(bmp.bytes[o + 1]), Int(bmp.bytes[o + 2]))
            if near(px, glyph) { n += 1 }
        }
        return n
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
