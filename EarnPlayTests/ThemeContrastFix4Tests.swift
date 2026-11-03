import Foundation
import XCTest
import SwiftUI
import UIKit
import EarnPlayCore
@testable import EarnPlay

/// T7.8 fix-4 (issue #73) regression tests: composer/prominent button
/// label contrast (items 5+6, analytic, every palette) and shield
/// theme propagation (item 7, in-process host render).
///
/// Item 5: the Hint label is the paired tutorText token on the pale
/// composer (the SpeakerButton treatment); the old accent label fell
/// to 2.40:1 in Warm Playful. This pins the rendered pair's 4.5:1
/// floor (measured 9.94-16.88).
///
/// Item 6: the Send and Start-again labels are the fix-3
/// childTextOnChildBackground resolver on the accent chrome. Accent
/// and childBackground match in every palette (pinned here), so the
/// existing resolver supplies the readable label with no chrome
/// change; the old white label fell to 2.80-4.02 in Warm Playful,
/// System Native, Blush Pink, and Hot Pink. Measured 4.63-6.75.
///
/// Item 7: the demo chain (demo view -> cover host -> shield) carries
/// the app's theme instead of always rendering the default. The UI
/// leg is unreachable (SimulatedShieldDemoView lives only in
/// ContentView.previewHarnesses, which is dead code per the
/// WalkthroughChildTests SETUP-COMPLETION note), so this pins
/// propagation in-process: a host given Canonical sharp presents the
/// shield badge in the Canonical track, while the default host keeps
/// the Light Pink track (the control leg, proving the sampler
/// distinguishes the two themes). Issue #81 moved the default from
/// Canonical to Light Pink, so the picked contrast theme moved from
/// Hot Pink (whose track is within tolerance of the Light Pink
/// track) to Canonical (23 apart on red — see the sampler note).
/// Defaults stay defaultTheme for previews. No token values changed
/// anywhere in fix-4.
@MainActor
final class ThemeContrastFix4Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeContrastFix4Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Item 5: Hint label (tutorText on the composer)

    func testHintLabelMeets4_5To1InEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            let ratio = contrastRatio(palette.tokens.tutorText, palette.tokens.tutorBackground)
            print("FIX4-HINT \(palette) tutorText/tutorBackground=\(ratio)")
            XCTAssertGreaterThan(ratio, 4.5,
                "\(palette): Hint label (tutorText on composer tutorBackground) is \(ratio)")
        }
    }

    // MARK: - Item 6: prominent labels (resolved child text on accent)

    /// The resolver reuse is sound only because accent and
    /// childBackground are the same color in every palette: the Send
    /// and Start-again labels sit on accent, and the resolver was
    /// pinned for childBackground. A future palette that splits them
    /// fails here instead of silently shipping a low-contrast label.
    func testAccentMatchesChildBackgroundInEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            XCTAssertEqual(palette.tokens.accent, palette.tokens.childBackground,
                "\(palette): prominent-label resolver needs accent == childBackground")
        }
    }

    func testProminentButtonLabelsMeet4_5To1OnAccentInEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            for shape in DesignSystem.Shape.allCases {
                let theme = DesignSystem.Theme(palette: palette, shape: shape)
                let ratio = contrastRatio(theme.childTextOnChildBackground, theme.tokens.accent)
                print("FIX4-PROMINENT \(palette) \(shape) resolvedLabel/accent=\(ratio)")
                XCTAssertGreaterThan(ratio, 4.5,
                    "\(palette) \(shape): Send/Start-again label on accent is \(ratio)")
            }
        }
    }

    // MARK: - Item 7: shield theme propagation

    func testShieldPreviewsUseDefaultTheme() {
        XCTAssertEqual(SimulatedShieldDemoView().theme, DesignSystem.defaultTheme,
            "demo view must keep the default theme for previews")
        XCTAssertEqual(SimulatedShieldCoverHost(flow: makePresentedFlow()).theme,
            DesignSystem.defaultTheme, "cover host must keep the default theme for previews")
        XCTAssertEqual(SimulatedShieldView(flow: makePresentedFlow()).theme,
            DesignSystem.defaultTheme, "shield must keep the default theme for previews")
    }

    func testShieldChainStoresThePassedTheme() {
        let picked = DesignSystem.Theme(palette: .canonical, shape: .sharp)
        XCTAssertEqual(SimulatedShieldDemoView(theme: picked).theme, picked,
            "demo view must store the passed theme")
        XCTAssertEqual(SimulatedShieldCoverHost(flow: makePresentedFlow(), theme: picked).theme, picked,
            "cover host must store the passed theme")
    }

    /// The presented shield renders the HOST's theme, not the default:
    /// Canonical sharp through the host paints the badge in the
    /// Canonical track (tens of thousands of badge-fill pixels), and
    /// the default host still paints the default (Light Pink) track
    /// (the control leg, proving the sampler distinguishes the two
    /// themes). Pre-fix this fails: the host constructed the shield
    /// without a theme, so both renders painted the default. The
    /// badge UIView itself carries no materialized accessibility
    /// identifier (covers don't bridge Text identifiers to UIViews),
    /// so the cover bitmap is classified by track color instead.
    /// Bounds rationale: badge fill is O(200k) pixels (observed
    /// 221k/216k) while cross-theme bleed is antialiased text edges
    /// only (observed 0/2.7k), so the right theme must exceed 100k
    /// and the wrong theme must stay under 10k — a 10x separation
    /// with 2x/3x margins on the observations.
    func testShieldHostPassesThemeToPresentedShield() throws {
        let picked = DesignSystem.Theme(palette: .canonical, shape: .sharp)
        let themed = try XCTUnwrap(renderCoverTrackCounts(theme: picked),
            "themed host: shield cover did not render")
        print("FIX4-SHIELD themed picked=\(themed.picked) defaultTrack=\(themed.defaultTrack)")
        XCTAssertGreaterThan(themed.picked, 100_000,
            "themed host must paint the badge in the Canonical track")
        XCTAssertLessThan(themed.defaultTrack, 10_000,
            "themed host must NOT paint the default track (defaultTrack=\(themed.defaultTrack))")

        let plain = try XCTUnwrap(renderCoverTrackCounts(theme: nil),
            "default host: shield cover did not render")
        print("FIX4-SHIELD default picked=\(plain.picked) defaultTrack=\(plain.defaultTrack)")
        XCTAssertGreaterThan(plain.defaultTrack, 100_000,
            "default host must paint the badge in the default (Light Pink) track")
        XCTAssertLessThan(plain.picked, 10_000,
            "default host must NOT paint the Canonical track (picked=\(plain.picked))")
    }

    // MARK: - Helpers

    /// A locked demo-app flow, so the host presents the shield cover
    /// immediately (same construction as SimulatedShieldTests).
    private func makePresentedFlow() -> SimulatedShieldFlow {
        // Fresh subdirectory per flow: each PolicyStore.apply(version: 1)
        // needs a clean store, and several flows share this test's run.
        let flowDir = directory.appendingPathComponent("flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: flowDir, withIntermediateDirectories: true)
        let game = AppRef(id: "earnplay.demo.game")
        let games = AppCategoryRef(id: "games")
        let policyStore = PolicyStore(directory: flowDir)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        let backend = SimulatedShieldBackend()
        let flow = SimulatedShieldFlow(
            manager: ShieldManager(
                policyStore: policyStore,
                enumeration: ShieldEnumeration(
                    apps: [EnumeratedApp(app: game, category: games)],
                    categories: [games]
                ),
                backend: backend,
                unlockStore: FileUnlockWindowStore(directory: flowDir)
            ),
            backend: backend,
            app: game,
            category: games,
            scorer: EffortScorer(threshold: 8),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: 2,
            isSimulatedMode: true,
            decisionLogger: DecisionLogger(directory: flowDir)
        )
        XCTAssertTrue(flow.isShieldPresented, "the fixture flow must present the shield")
        return flow
    }

    /// Presents the cover host (nil theme = default init) and counts
    /// badge-track pixels in the presented cover bitmap, split by
    /// theme: the Canonical-sharp picked theme vs the Light Pink
    /// default. Tolerance 16 clears every flat fill: the two tracks
    /// differ by 23 on red (Canonical #e2e4f0 vs Light Pink #f9d6e2),
    /// and each track is >16 from the other theme's shield
    /// background and text inks on at least one channel (no stars
    /// render in the cover, so star tokens never enter the bitmap).
    /// Only antialiased text-edge bands bleed across (observed
    /// 0/2.7k), which the test's 100k/10k bounds absorb with margin.
    /// Hot Pink sharp can
    /// no longer serve as the picked theme: its track (245,198,218)
    /// is within 16 on every channel of the Light Pink track
    /// (249,214,226), so the sampler could not tell them apart.
    private func renderCoverTrackCounts(theme: DesignSystem.Theme?) -> (picked: Int, defaultTrack: Int)? {
        let flow = makePresentedFlow()
        let host: UIHostingController<SimulatedShieldCoverHost>
        if let theme {
            host = UIHostingController(rootView: SimulatedShieldCoverHost(flow: flow, theme: theme))
        } else {
            host = UIHostingController(rootView: SimulatedShieldCoverHost(flow: flow))
        }
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = host
        win.makeKeyAndVisible()
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        guard let cover = host.presentedViewController?.view else { return nil }
        cover.layoutIfNeeded()
        // Pin scale 3: the 100k/10k bounds are calibrated to a 3x
        // render (observed 216k/220k); the default format inherits
        // the screen scale, so a 2x simulator would count x4/9 and
        // fail despite correct theme propagation. No behavior change
        // on 3x runners.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: cover.bounds, format: format)
        let image = renderer.image { _ in cover.drawHierarchy(in: cover.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pickedTrack = rgb255(DesignSystem.Theme(palette: .canonical, shape: .sharp).tokens.track)
        let defaultTrack = rgb255(DesignSystem.defaultTheme.tokens.track)
        var picked = 0, plain = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let px = (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
            if near(px, pickedTrack, tolerance: 16) {
                picked += 1
            } else if near(px, defaultTrack, tolerance: 16) {
                plain += 1
            }
        }
        return (picked, plain)
    }

    private func rgb255(_ rgb: DesignSystem.RGB) -> (Int, Int, Int) {
        (Int(round(rgb.red * 255)), Int(round(rgb.green * 255)), Int(round(rgb.blue * 255)))
    }

    private func near(_ px: (Int, Int, Int), _ target: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(px.0 - target.0) <= tolerance && abs(px.1 - target.1) <= tolerance && abs(px.2 - target.2) <= tolerance
    }

    private func luminance(_ rgb: DesignSystem.RGB) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private func contrastRatio(_ a: DesignSystem.RGB, _ b: DesignSystem.RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
