import XCTest
@testable import EarnPlayCore

/// T7.8 theme-system tests: the store defaults to Canonical, a
/// selection persists across relaunch, and every theme provides a
/// complete token set with no fallback.
@MainActor
final class ThemeStoreTests: XCTestCase {
    private nonisolated(unsafe) var suiteName: String!
    private nonisolated(unsafe) var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "earnplay.ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Default

    func testDefaultIsCanonicalRounded() {
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme.id, "canonical-rounded")
        XCTAssertEqual(store.theme.displayName, "Canonical (design docs), rounded")
        XCTAssertEqual(store.theme, DesignSystem.defaultTheme)
        XCTAssertEqual(store.theme.palette, .canonical)
        XCTAssertEqual(store.theme.shape, .rounded)
    }

    func testCorruptStoredIDFallsBackToDefault() {
        defaults.set("not-a-theme", forKey: ThemeStore.selectionDefaultsKey)
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, DesignSystem.defaultTheme)
    }

    // MARK: - Persistence

    func testSelectionPersistsAcrossRelaunch() {
        let store = ThemeStore(defaults: defaults)
        let picked = DesignSystem.Theme(palette: .hotPink, shape: .sharp)
        store.select(picked)
        XCTAssertEqual(store.theme, picked)

        let relaunched = ThemeStore(defaults: defaults)
        XCTAssertEqual(relaunched.theme, picked)
        XCTAssertEqual(relaunched.theme.id, "hot-pink-sharp")
    }

    func testEveryThemeRoundTripsWithNoFallback() {
        for theme in DesignSystem.allThemes {
            let store = ThemeStore(defaults: defaults)
            store.select(theme)
            // A fresh store over the same defaults is a relaunch: the
            // stored id must resolve to the selected theme itself,
            // never to the default fallback.
            let relaunched = ThemeStore(defaults: defaults)
            XCTAssertEqual(relaunched.theme, theme, "theme \(theme.id) did not survive a relaunch")
            XCTAssertEqual(DesignSystem.theme(id: theme.id), theme)
        }
    }

    // MARK: - Completeness

    func testAllThemesCountAndUniqueIDs() {
        XCTAssertEqual(DesignSystem.allThemes.count, 14)
        let ids = DesignSystem.allThemes.map(\.id)
        XCTAssertEqual(Set(ids).count, 14)
    }

    func testPickerNamesAreExactAndOrdered() {
        XCTAssertEqual(DesignSystem.allThemes.map(\.displayName), [
            "Calm Forest, rounded",
            "Calm Forest, sharp",
            "Warm Playful, rounded",
            "Warm Playful, sharp",
            "Sky Blueprint, rounded",
            "Sky Blueprint, sharp",
            "System Native, rounded",
            "System Native, sharp",
            "Canonical (design docs), rounded",
            "Canonical (design docs), sharp",
            "Blush Pink, rounded",
            "Blush Pink, sharp",
            "Hot Pink, rounded",
            "Hot Pink, sharp",
        ])
    }

    func testRoundedAndSharpRadii() {
        for theme in DesignSystem.allThemes {
            switch theme.shape {
            case .rounded:
                XCTAssertEqual(theme.cardRadius, 14, theme.id)
                XCTAssertEqual(theme.buttonRadius, 10, theme.id)
                XCTAssertEqual(theme.bubbleRadius, 20, theme.id)
            case .sharp:
                XCTAssertEqual(theme.cardRadius, 10, theme.id)
                XCTAssertEqual(theme.buttonRadius, 8, theme.id)
                XCTAssertEqual(theme.bubbleRadius, 8, theme.id)
            }
        }
    }

    /// Every theme carries all 12 tokens plus 3 swatches, each a valid
    /// `#rrggbb` hex: nothing is missing, nothing falls back.
    func testEveryThemeProvidesCompleteTokenSet() {
        let hexPattern = "^#[0-9a-f]{6}$"
        for theme in DesignSystem.allThemes {
            XCTAssertEqual(theme.tokens.all.count, 12, theme.id)
            for token in theme.tokens.all {
                XCTAssertTrue(
                    token.hex.range(of: hexPattern, options: .regularExpression) != nil,
                    "\(theme.id) has non-hex token \(token.hex)")
            }
            XCTAssertEqual(theme.swatches.count, 3, theme.id)
            for swatch in theme.swatches {
                XCTAssertTrue(
                    swatch.hex.range(of: hexPattern, options: .regularExpression) != nil,
                    "\(theme.id) has non-hex swatch \(swatch.hex)")
            }
        }
    }

    /// The token table verbatim from the mockup file's palette classes.
    /// Shape never changes colors, so one entry per palette.
    func testTokenTableMatchesMockupVerbatim() {
        let expected: [DesignSystem.Palette: [String]] = [
            // background, headerBackground, headerText, tutorBackground,
            // tutorText, childBackground, childText, accent, track, fill,
            // starFill, starEmpty.
            .calmForest: ["#faf6ee", "#1e5c46", "#ffffff", "#e3efe7",
                          "#1c3a2d", "#2e7d5b", "#ffffff", "#2e7d5b",
                          "#e0dccf", "#2e7d5b", "#2e7d5b", "#cfc8b4"],
            .warmPlayful: ["#fff9f0", "#ff6b5b", "#ffffff", "#ffe9e2",
                           "#5c2a24", "#ff6b5b", "#ffffff", "#ff6b5b",
                           "#f3e3cf", "#ffc93c", "#ffc93c", "#e8d9c4"],
            .skyBlueprint: ["#f2f7fc", "#12395b", "#ffffff", "#e1edf7",
                            "#16324a", "#1f6feb", "#ffffff", "#1f6feb",
                            "#d9e6f2", "#1f6feb", "#1f6feb", "#c3d5e8"],
            .systemNative: ["#ffffff", "#f2f2f7", "#111111", "#e9e9eb",
                            "#111111", "#007aff", "#ffffff", "#007aff",
                            "#e9e9eb", "#007aff", "#007aff", "#d1d1d6"],
            .canonical: ["#f7f8fc", "#4361ee", "#ffffff", "#ffffff",
                         "#1b1b2f", "#4361ee", "#ffffff", "#4361ee",
                         "#e2e4f0", "#4361ee", "#ffb703", "#d0d0e0"],
            .blushPink: ["#fff7f9", "#c2255c", "#ffffff", "#ffe3ec",
                         "#57182e", "#f06595", "#ffffff", "#f06595",
                         "#f8d7e0", "#f06595", "#ffc2d4", "#a63a63"],
            .hotPink: ["#fff0f5", "#a61e4d", "#ffffff", "#ffd6e8",
                       "#4a0e2e", "#f72585", "#ffffff", "#f72585",
                       "#f5c6da", "#f72585", "#ff8fab", "#8e2a5b"],
        ]
        for palette in DesignSystem.Palette.allCases {
            let actual = palette.tokens.all.map(\.hex)
            XCTAssertEqual(actual, expected[palette], "token table drift in \(palette)")
            for shape in DesignSystem.Shape.allCases {
                XCTAssertEqual(
                    DesignSystem.Theme(palette: palette, shape: shape).tokens.all.map(\.hex),
                    expected[palette], "shape must not change colors: \(palette) \(shape)")
            }
        }
    }

    // MARK: - Contrast floors (fix-2 findings 1, 3, 4)

    /// The paired tutorText token is the defining boundary for stars
    /// (finding 1) and speaker glyphs (finding 3) on the fixed light
    /// header/row surfaces, and the label foreground on every fixed
    /// light card (finding 4): it must exceed 3:1 on tutorBackground
    /// in every palette. (The old accent boundary fell to ~2.4:1 in
    /// Warm Playful; the token table above pins the values, this pins
    /// the floor so a future palette cannot regress it.)
    func testTutorTextMeets3To1OnTutorBackgroundInEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            let ratio = contrastRatio(palette.tokens.tutorText, palette.tokens.tutorBackground)
            XCTAssertGreaterThan(ratio, 3.0, "\(palette) tutorText/tutorBackground is \(ratio)")
        }
    }

    /// TutorText also labels the full-screen theme background and the
    /// track badge (SimulatedShieldView): 3:1 there too, every palette.
    func testTutorTextMeets3To1OnBackgroundAndTrackInEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            let onBackground = contrastRatio(palette.tokens.tutorText, palette.tokens.background)
            XCTAssertGreaterThan(onBackground, 3.0, "\(palette) tutorText/background is \(onBackground)")
            let onTrack = contrastRatio(palette.tokens.tutorText, palette.tokens.track)
            XCTAssertGreaterThan(onTrack, 3.0, "\(palette) tutorText/track is \(onTrack)")
        }
    }

    /// Secondary labels on theme cards use tutorText at 75% opacity
    /// (`secondaryOnTheme`): still at least 4.5:1 on tutorBackground
    /// in every palette (measured 5.0-7.7 sRGB-blended), so Dark Mode
    /// keeps readable supplementary text on the fixed light cards.
    func testSecondaryOnThemeMeets4_5To1OnTutorBackgroundInEveryPalette() {
        for palette in DesignSystem.Palette.allCases {
            let mixed = mix(palette.tokens.tutorText, over: palette.tokens.tutorBackground, opacity: 0.75)
            let ratio = contrastRatio(mixed, palette.tokens.tutorBackground)
            XCTAssertGreaterThan(ratio, 4.5, "\(palette) secondaryOnTheme/tutorBackground is \(ratio)")
        }
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

    private func mix(_ fg: DesignSystem.RGB, over bg: DesignSystem.RGB, opacity: Double) -> DesignSystem.RGB {
        func blend(_ f: Double, _ b: Double) -> Int {
            Int(round((opacity * f + (1 - opacity) * b) * 255))
        }
        return DesignSystem.RGB(blend(fg.red, bg.red), blend(fg.green, bg.green), blend(fg.blue, bg.blue))
    }

    /// The swatch trios verbatim (header / middle / background). The
    /// middle swatch is NOT always the accent token.
    func testSwatchTriosMatchMockupVerbatim() {
        let expected: [DesignSystem.Palette: [String]] = [
            .calmForest: ["#1e5c46", "#2e7d5b", "#faf6ee"],
            .warmPlayful: ["#ff6b5b", "#ffc93c", "#fff9f0"],
            .skyBlueprint: ["#12395b", "#1f6feb", "#f2f7fc"],
            .systemNative: ["#007aff", "#e9e9eb", "#ffffff"],
            .canonical: ["#4361ee", "#ffb703", "#f7f8fc"],
            .blushPink: ["#c2255c", "#f06595", "#fff7f9"],
            .hotPink: ["#a61e4d", "#f72585", "#fff0f5"],
        ]
        for palette in DesignSystem.Palette.allCases {
            XCTAssertEqual(palette.swatches.map(\.hex), expected[palette], "swatch drift in \(palette)")
        }
    }
}
