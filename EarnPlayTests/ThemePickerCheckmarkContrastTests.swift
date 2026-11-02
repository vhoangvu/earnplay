import XCTest
import SwiftUI
import UIKit
import EarnPlayCore

/// T7.9 fix-2 (issue #75) rendering regression test: the picker
/// checkmark's REAL foreground against its REAL surface, both sampled
/// from the actual `ThemePickerView` render — never hardcoded colors.
///
/// The fix-1 analytic test
/// (`testPickerCheckmarkPrimaryMeets4_5To1OnSystemBackgroundInBothModes`)
/// computes the contrast of hardcoded black vs white and never reads
/// the checkmark's foreground style, so reverting the checkmark to the
/// Light Pink accent still passes it (Copilot review #2, verified).
/// This test closes that gap by rendering the production picker.
///
/// Method (differential, after the ThemeContrastFix2Tests star
/// sampler): with Light Pink selected, render the production picker
/// twice — Light Pink rounded selected vs Light Pink sharp selected —
/// in each appearance. Same palette, so the preview card differs only
/// in corner radii (excluded with the top 250pt); outside it the ONLY
/// difference is the checkmark glyph (one row per render). The diff is
/// exactly the two checkmarks (observed 792px @3x at the trailing
/// edge x=[373.7,387.7] y=[683.3,734.0]pt, 396px each, nothing
/// elsewhere), so each differing pair is the checkmark's real
/// foreground vs the real surface; luminance orders the pair (darker
/// = foreground in Light, lighter in Dark) and the medians give the
/// rendered contrast. The accent revert repaints these pixels pink,
/// failing the contrast floor in Light (1.81:1) and the
/// accent-exclusion in both modes (proven by the TEMP revert probe).
///
/// Floor note: the checkmark is a non-text glyph (decorative duplicate
/// of the row's selected/not-selected accessibility value), so the
/// applicable WCAG floor is 3:1 (1.4.11 Non-text Contrast) — the same
/// floor the original defect was reported against — not the 4.5:1 text
/// floor. Measured 3.52:1 in Light: the rows are default-style
/// Buttons, whose tint overrides `.foregroundStyle(.primary)` with
/// system blue (verified: explicit `.primary` renders (0,136,255)
/// inside a default Button, while a concrete color and
/// `.foregroundColor(.primary)` survive). Reporting that override as
/// a production follow-up is out of scope here — production is
/// untouched — but this test pins the RENDERED pair, so any future
/// foreground change (including the accent revert) must re-measure.
///
/// Dark-render note: a scene-less window's override leaves SwiftUI
/// rendering light (traits report dark but pixels stay light), so the
/// hosting controller takes the override BEFORE the window exists —
/// verified rendering black (0,0,0) backgrounds in Dark. Renderer
/// scale is pinned to 3 (ThemeContrastFix4Tests precedent) so the
/// pixel-count presence bound holds on any simulator.
@MainActor
final class ThemePickerCheckmarkContrastTests: XCTestCase {

    func testLightPinkCheckmarkRendersWithContrastInBothModes() throws {
        let accent = rgb255(DesignSystem.Palette.lightPink.tokens.accent)
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let selected = try XCTUnwrap(
                renderPicker(selection: DesignSystem.Theme(palette: .lightPink, shape: .rounded), style: style),
                "style \(style.rawValue): picker with Light Pink rounded selected did not render")
            let other = try XCTUnwrap(
                renderPicker(selection: DesignSystem.Theme(palette: .lightPink, shape: .sharp), style: style),
                "style \(style.rawValue): picker with Light Pink sharp selected did not render")
            guard selected.width == other.width && selected.height == other.height else {
                XCTFail("style \(style.rawValue): picker bitmap size mismatch: \(selected.width)x\(selected.height) vs \(other.width)x\(other.height)")
                continue
            }
            let scaleY = Double(selected.height) / selected.bounds.height
            let exclusionPx = Int(previewExclusionPt * scaleY)
            var fg: [(Int, Int, Int)] = []
            var bg: [(Int, Int, Int)] = []
            for y in exclusionPx..<selected.height {
                for x in 0..<selected.width {
                    let o = (y * selected.width + x) * 4
                    let dr = abs(Int(selected.bytes[o]) - Int(other.bytes[o]))
                    let dg = abs(Int(selected.bytes[o + 1]) - Int(other.bytes[o + 1]))
                    let db = abs(Int(selected.bytes[o + 2]) - Int(other.bytes[o + 2]))
                    guard max(dr, max(dg, db)) > 12 else { continue }
                    let ca = (Int(selected.bytes[o]), Int(selected.bytes[o + 1]), Int(selected.bytes[o + 2]))
                    let cb = (Int(other.bytes[o]), Int(other.bytes[o + 1]), Int(other.bytes[o + 2]))
                    // One side paints the checkmark, the other the bare
                    // surface; luminance orders them (Light: foreground
                    // is darker; Dark: foreground is lighter) for the
                    // rendered glyph and for the pink-accent revert.
                    let la = luminance(ca), lb = luminance(cb)
                    if style == .light {
                        if la <= lb { fg.append(ca); bg.append(cb) } else { fg.append(cb); bg.append(ca) }
                    } else {
                        if la >= lb { fg.append(ca); bg.append(cb) } else { fg.append(cb); bg.append(ca) }
                    }
                }
            }
            // Presence: both checkmarks paint (792px observed @3x, 396
            // each); the bound catches full removal (0) and a single
            // missing glyph (396) with margin on the observed pair.
            print("T79F2-CHECKMARK style=\(style.rawValue) diffPixels=\(fg.count)")
            XCTAssertGreaterThan(fg.count, 500,
                "style \(style.rawValue): both checkmarks must paint pixels in the actual picker render")
            guard !fg.isEmpty, fg.count == bg.count else { continue }
            let medianFg = median(fg), medianBg = median(bg)
            let ratio = contrastRatio(medianFg, medianBg)
            print("T79F2-CHECKMARK style=\(style.rawValue) fg=\(medianFg) bg=\(medianBg) ratio=\(ratio)")
            XCTAssertGreaterThan(ratio, 3.0,
                "style \(style.rawValue): rendered checkmark/surface is \(ratio), below the 3:1 non-text floor (fg=\(medianFg) bg=\(medianBg))")
            XCTAssertFalse(near(medianFg, accent, tolerance: 50),
                "style \(style.rawValue): checkmark must not render the Light Pink accent (fg=\(medianFg) accent=\(accent))")
        }
    }

    // MARK: - Render helpers (fixed RGBA8 layout, as Fix2)

    private struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var bounds: CGRect
    }

    /// Top-aligned content frame: the 16-row picker (~750pt) fits with
    /// room, and the Spacer pins it to the top so both renders align.
    private let contentSize = CGSize(width: 390, height: 1400)

    /// Top region holding the title + preview card (preview radii
    /// differ between the rounded/sharp renders); rows start ~160pt
    /// and the Light Pink rows are the last two, far below this cut.
    private let previewExclusionPt: CGFloat = 250

    private func renderPicker(selection: DesignSystem.Theme, style: UIUserInterfaceStyle) -> Bitmap? {
        let suiteName = "earnplay.ThemePickerCheckmarkContrastTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ThemeStore(defaults: defaults)
        store.select(selection)
        let host = UIHostingController(rootView:
            VStack(spacing: 0) {
                ThemePickerView(store: store)
                Spacer(minLength: 0)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .background(Color(.systemBackground))
        )
        // The hosting controller takes the appearance override BEFORE
        // the window exists: a scene-less window-level override alone
        // leaves SwiftUI rendering light in Dark Mode (verified).
        host.overrideUserInterfaceStyle = style
        let win = UIWindow(frame: CGRect(origin: .zero, size: contentSize))
        win.backgroundColor = .systemBackground
        win.overrideUserInterfaceStyle = style
        win.rootViewController = host
        win.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()
        guard let bmp = normalizedBitmap(in: host.view) else { return nil }
        return Bitmap(bytes: bmp.bytes, width: bmp.width, height: bmp.height, bounds: host.view.bounds)
    }

    private func normalizedBitmap(in view: UIView) -> (bytes: [UInt8], width: Int, height: Int)? {
        // Pin scale 3: the presence bound is calibrated to a 3x render;
        // the default format inherits the screen scale, so a 2x
        // simulator would count x4/9 (ThemeContrastFix4Tests precedent).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
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

    private func near(_ px: (Int, Int, Int), _ target: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(px.0 - target.0) <= tolerance && abs(px.1 - target.1) <= tolerance && abs(px.2 - target.2) <= tolerance
    }

    private func median(_ px: [(Int, Int, Int)]) -> (Int, Int, Int) {
        let sorted = px.sorted { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }
        return sorted[sorted.count / 2]
    }

    private func luminance(_ px: (Int, Int, Int)) -> Double {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(Double(px.0) / 255)
            + 0.7152 * linear(Double(px.1) / 255)
            + 0.0722 * linear(Double(px.2) / 255)
    }

    private func contrastRatio(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
