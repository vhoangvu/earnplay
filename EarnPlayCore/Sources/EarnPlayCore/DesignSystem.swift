import SwiftUI

/// Single theme source (SSOT) for every app's colors and radii.
///
/// Carries the Main Page Style Explorations: 7 palettes (Calm Forest,
/// Warm Playful, Sky Blueprint, System Native, Canonical, Blush Pink,
/// Hot Pink) x rounded/sharp shapes = 14 themes. Each theme is defined
/// by its 3 swatch colors (header / middle / background trio) and
/// carries the full 12-token set verbatim from the mockup file's
/// palette classes; rounded and sharp share the palette and differ
/// only in radii. No color is ever derived at runtime: every token is
/// an explicit value below, so views render tokens directly with no
/// tint math.
///
/// No `Color(...)` literal may appear in the app targets outside this
/// file: views read `ThemeStore.theme` tokens only.
public enum DesignSystem {
    // MARK: - Token color

    /// One explicit sRGB token color. Single source for both the
    /// rendered `Color` and the `#rrggbb` hex the tests pin: both
    /// derive from the same three components, so they cannot drift.
    public struct RGB: Hashable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        /// Components as 0...255 integers, e.g. `RGB(0x43, 0x61, 0xEE)`.
        public init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
        }

        /// Lowercase `#rrggbb`, matching the mockup table verbatim.
        public var hex: String {
            String(format: "#%02x%02x%02x",
                   Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
        }

        /// The rendered color. Total: no parsing, no fallback.
        public var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    // MARK: - Token set

    /// The full 12-token color set every palette provides. Non-optional
    /// throughout: a theme either carries every token or does not
    /// exist, so views never fall back.
    public struct Tokens: Equatable, Sendable {
        public var background: RGB
        public var headerBackground: RGB
        public var headerText: RGB
        public var tutorBackground: RGB
        public var tutorText: RGB
        public var childBackground: RGB
        public var childText: RGB
        public var accent: RGB
        public var track: RGB
        public var fill: RGB
        public var starFill: RGB
        public var starEmpty: RGB

        public init(background: RGB, headerBackground: RGB, headerText: RGB,
                    tutorBackground: RGB, tutorText: RGB,
                    childBackground: RGB, childText: RGB,
                    accent: RGB, track: RGB, fill: RGB,
                    starFill: RGB, starEmpty: RGB) {
            self.background = background
            self.headerBackground = headerBackground
            self.headerText = headerText
            self.tutorBackground = tutorBackground
            self.tutorText = tutorText
            self.childBackground = childBackground
            self.childText = childText
            self.accent = accent
            self.track = track
            self.fill = fill
            self.starFill = starFill
            self.starEmpty = starEmpty
        }

        /// All 12 tokens in table order, for completeness checks.
        public var all: [RGB] {
            [background, headerBackground, headerText, tutorBackground, tutorText,
             childBackground, childText, accent, track, fill, starFill, starEmpty]
        }
    }

    // MARK: - Palettes

    /// The 7 exploration palettes, in picker order.
    public enum Palette: String, CaseIterable, Sendable {
        case calmForest = "calm-forest"
        case warmPlayful = "warm-playful"
        case skyBlueprint = "sky-blueprint"
        case systemNative = "system-native"
        case canonical
        case blushPink = "blush-pink"
        case hotPink = "hot-pink"

        /// Picker title. Canonical carries its design-docs marker.
        public var title: String {
            switch self {
            case .calmForest: return "Calm Forest"
            case .warmPlayful: return "Warm Playful"
            case .skyBlueprint: return "Sky Blueprint"
            case .systemNative: return "System Native"
            case .canonical: return "Canonical (design docs)"
            case .blushPink: return "Blush Pink"
            case .hotPink: return "Hot Pink"
            }
        }

        /// The theme's identity in the picker: the verbatim swatch trio
        /// (header / middle / background). Stored explicitly, never
        /// derived: in Warm Playful, System Native, and Canonical the
        /// middle swatch is not the accent token.
        public var swatches: [RGB] {
            switch self {
            case .calmForest:
                return [RGB(0x1E, 0x5C, 0x46), RGB(0x2E, 0x7D, 0x5B), RGB(0xFA, 0xF6, 0xEE)]
            case .warmPlayful:
                return [RGB(0xFF, 0x6B, 0x5B), RGB(0xFF, 0xC9, 0x3C), RGB(0xFF, 0xF9, 0xF0)]
            case .skyBlueprint:
                return [RGB(0x12, 0x39, 0x5B), RGB(0x1F, 0x6F, 0xEB), RGB(0xF2, 0xF7, 0xFC)]
            case .systemNative:
                return [RGB(0x00, 0x7A, 0xFF), RGB(0xE9, 0xE9, 0xEB), RGB(0xFF, 0xFF, 0xFF)]
            case .canonical:
                return [RGB(0x43, 0x61, 0xEE), RGB(0xFF, 0xB7, 0x03), RGB(0xF7, 0xF8, 0xFC)]
            case .blushPink:
                return [RGB(0xC2, 0x25, 0x5C), RGB(0xF0, 0x65, 0x95), RGB(0xFF, 0xF7, 0xF9)]
            case .hotPink:
                return [RGB(0xA6, 0x1E, 0x4D), RGB(0xF7, 0x25, 0x85), RGB(0xFF, 0xF0, 0xF5)]
            }
        }

        /// The full token set, verbatim from the mockup palette classes.
        public var tokens: Tokens {
            switch self {
            case .calmForest:
                return Tokens(
                    background: RGB(0xFA, 0xF6, 0xEE),
                    headerBackground: RGB(0x1E, 0x5C, 0x46),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xE3, 0xEF, 0xE7),
                    tutorText: RGB(0x1C, 0x3A, 0x2D),
                    childBackground: RGB(0x2E, 0x7D, 0x5B),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0x2E, 0x7D, 0x5B),
                    track: RGB(0xE0, 0xDC, 0xCF),
                    fill: RGB(0x2E, 0x7D, 0x5B),
                    starFill: RGB(0x2E, 0x7D, 0x5B),
                    starEmpty: RGB(0xCF, 0xC8, 0xB4))
            case .warmPlayful:
                return Tokens(
                    background: RGB(0xFF, 0xF9, 0xF0),
                    headerBackground: RGB(0xFF, 0x6B, 0x5B),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xFF, 0xE9, 0xE2),
                    tutorText: RGB(0x5C, 0x2A, 0x24),
                    childBackground: RGB(0xFF, 0x6B, 0x5B),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0xFF, 0x6B, 0x5B),
                    track: RGB(0xF3, 0xE3, 0xCF),
                    fill: RGB(0xFF, 0xC9, 0x3C),
                    starFill: RGB(0xFF, 0xC9, 0x3C),
                    starEmpty: RGB(0xE8, 0xD9, 0xC4))
            case .skyBlueprint:
                return Tokens(
                    background: RGB(0xF2, 0xF7, 0xFC),
                    headerBackground: RGB(0x12, 0x39, 0x5B),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xE1, 0xED, 0xF7),
                    tutorText: RGB(0x16, 0x32, 0x4A),
                    childBackground: RGB(0x1F, 0x6F, 0xEB),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0x1F, 0x6F, 0xEB),
                    track: RGB(0xD9, 0xE6, 0xF2),
                    fill: RGB(0x1F, 0x6F, 0xEB),
                    starFill: RGB(0x1F, 0x6F, 0xEB),
                    starEmpty: RGB(0xC3, 0xD5, 0xE8))
            case .systemNative:
                return Tokens(
                    background: RGB(0xFF, 0xFF, 0xFF),
                    headerBackground: RGB(0xF2, 0xF2, 0xF7),
                    headerText: RGB(0x11, 0x11, 0x11),
                    tutorBackground: RGB(0xE9, 0xE9, 0xEB),
                    tutorText: RGB(0x11, 0x11, 0x11),
                    childBackground: RGB(0x00, 0x7A, 0xFF),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0x00, 0x7A, 0xFF),
                    track: RGB(0xE9, 0xE9, 0xEB),
                    fill: RGB(0x00, 0x7A, 0xFF),
                    starFill: RGB(0x00, 0x7A, 0xFF),
                    starEmpty: RGB(0xD1, 0xD1, 0xD6))
            case .canonical:
                return Tokens(
                    background: RGB(0xF7, 0xF8, 0xFC),
                    headerBackground: RGB(0x43, 0x61, 0xEE),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xFF, 0xFF, 0xFF),
                    tutorText: RGB(0x1B, 0x1B, 0x2F),
                    childBackground: RGB(0x43, 0x61, 0xEE),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0x43, 0x61, 0xEE),
                    track: RGB(0xE2, 0xE4, 0xF0),
                    fill: RGB(0x43, 0x61, 0xEE),
                    starFill: RGB(0xFF, 0xB7, 0x03),
                    starEmpty: RGB(0xD0, 0xD0, 0xE0))
            case .blushPink:
                return Tokens(
                    background: RGB(0xFF, 0xF7, 0xF9),
                    headerBackground: RGB(0xC2, 0x25, 0x5C),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xFF, 0xE3, 0xEC),
                    tutorText: RGB(0x57, 0x18, 0x2E),
                    childBackground: RGB(0xF0, 0x65, 0x95),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0xF0, 0x65, 0x95),
                    track: RGB(0xF8, 0xD7, 0xE0),
                    fill: RGB(0xF0, 0x65, 0x95),
                    starFill: RGB(0xFF, 0xC2, 0xD4),
                    starEmpty: RGB(0xA6, 0x3A, 0x63))
            case .hotPink:
                return Tokens(
                    background: RGB(0xFF, 0xF0, 0xF5),
                    headerBackground: RGB(0xA6, 0x1E, 0x4D),
                    headerText: RGB(0xFF, 0xFF, 0xFF),
                    tutorBackground: RGB(0xFF, 0xD6, 0xE8),
                    tutorText: RGB(0x4A, 0x0E, 0x2E),
                    childBackground: RGB(0xF7, 0x25, 0x85),
                    childText: RGB(0xFF, 0xFF, 0xFF),
                    accent: RGB(0xF7, 0x25, 0x85),
                    track: RGB(0xF5, 0xC6, 0xDA),
                    fill: RGB(0xF7, 0x25, 0x85),
                    starFill: RGB(0xFF, 0x8F, 0xAB),
                    starEmpty: RGB(0x8E, 0x2A, 0x5B))
            }
        }
    }

    // MARK: - Shapes

    /// Rounded vs sharp. Palettes share tokens across shapes; only the
    /// radii below differ.
    public enum Shape: String, CaseIterable, Sendable {
        case rounded
        case sharp

        /// Card corner radius: 14 rounded, 10 sharp.
        public var cardRadius: CGFloat {
            switch self {
            case .rounded: return 14
            case .sharp: return 10
            }
        }

        /// Button corner radius: 10 rounded, 8 sharp.
        public var buttonRadius: CGFloat {
            switch self {
            case .rounded: return 10
            case .sharp: return 8
            }
        }

        /// Chat-bubble corner radius: 20 rounded, 8 sharp.
        public var bubbleRadius: CGFloat {
            switch self {
            case .rounded: return 20
            case .sharp: return 8
            }
        }
    }

    // MARK: - Theme

    /// One of the 14 switchable themes: a palette plus a shape.
    public struct Theme: Identifiable, Equatable, Sendable {
        public var palette: Palette
        public var shape: Shape

        public init(palette: Palette, shape: Shape) {
            self.palette = palette
            self.shape = shape
        }

        /// Stable persistence id, e.g. `canonical-rounded`.
        public var id: String { "\(palette.rawValue)-\(shape.rawValue)" }

        /// Exact picker name, e.g. `Canonical (design docs), rounded`.
        public var displayName: String { "\(palette.title), \(shape.rawValue)" }

        public var tokens: Tokens { palette.tokens }
        public var swatches: [RGB] { palette.swatches }
        public var cardRadius: CGFloat { shape.cardRadius }
        public var buttonRadius: CGFloat { shape.buttonRadius }
        public var bubbleRadius: CGFloat { shape.bubbleRadius }

        /// Secondary text on fixed light theme surfaces (cards, badges,
        /// the simulated-shield screen): tutorText at 75% opacity, which
        /// measures >= 5:1 against every palette's tutorBackground (see
        /// ThemeStoreTests), so supplementary labels stay readable in
        /// Dark Mode, where the adaptive `.secondary` would wash out
        /// against the fixed light surface.
        public var secondaryOnTheme: Color { tokens.tutorText.color.opacity(0.75) }

        /// Near-black text for vivid surfaces whose prescribed white
        /// text falls below WCAG AA 4.5:1 (fix-3 item B). The System
        /// Native text value (#111111), already in the token table:
        /// 4.70-6.75 on the four failing child backgrounds and 6.75
        /// on the Warm Playful header (see ThemeStoreTests). Neither
        /// white nor this dark passes everywhere (dark falls to
        /// 3.76-4.08 on the Calm/Sky/Canonical child bubbles), so the
        /// resolved properties below select per palette explicitly.
        public static let darkOverlayText = RGB(0x11, 0x11, 0x11)

        /// Text rendered ON the child bubble (fix-3 item B): the
        /// prescribed childText where it already meets 4.5:1 (Calm
        /// Forest 5.00, Sky Blueprint 4.63, Canonical 5.02), else
        /// darkOverlayText (Warm Playful 6.75, System Native 4.70,
        /// Blush Pink 6.30, Hot Pink 5.00). Prescribed tokens stay
        /// verbatim; this is an explicit per-palette selection, pinned
        /// analytically in ThemeStoreTests.
        public var childTextOnChildBackground: RGB {
            switch palette {
            case .warmPlayful, .systemNative, .blushPink, .hotPink:
                return Self.darkOverlayText
            case .calmForest, .skyBlueprint, .canonical:
                return tokens.childText
            }
        }

        /// Text rendered ON the header strip (fix-3 item B): the
        /// prescribed headerText everywhere except Warm Playful
        /// (2.80), which takes darkOverlayText (6.75). All 7 header
        /// pairs computed; only Warm Playful falls below 4.5:1
        /// (others 5.02-16.92). Pinned in ThemeStoreTests.
        public var headerTextOnHeaderBackground: RGB {
            switch palette {
            case .warmPlayful:
                return Self.darkOverlayText
            case .calmForest, .skyBlueprint, .systemNative, .canonical, .blushPink, .hotPink:
                return tokens.headerText
            }
        }
    }

    /// All 14 themes in picker order: the 7 palettes, rounded then
    /// sharp within each palette.
    public static let allThemes: [Theme] = Palette.allCases.flatMap { palette in
        Shape.allCases.map { Theme(palette: palette, shape: $0) }
    }

    /// The default theme: Canonical rounded, the docs palette with the
    /// historical card/button radii, so today's screenshots still match.
    public static let defaultTheme = Theme(palette: .canonical, shape: .rounded)

    /// Resolves a persisted id, or nil for unknown ids (the store then
    /// falls back to `defaultTheme`; known ids never fall back).
    public static func theme(id: String) -> Theme? {
        allThemes.first { $0.id == id }
    }
}

/// Holds one app's theme selection and persists it across launches.
///
/// Backed by the app's own `UserDefaults.standard`: the child and
/// admin apps share no defaults, so each persists its own selection
/// under the same key. Defaults to Canonical rounded.
@MainActor
public final class ThemeStore: ObservableObject {
    public static let selectionDefaultsKey = "earnplay.theme.selection.v1"

    @Published public private(set) var theme: DesignSystem.Theme

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.selectionDefaultsKey)
        self.theme = stored.flatMap(DesignSystem.theme(id:)) ?? DesignSystem.defaultTheme
    }

    public func select(_ theme: DesignSystem.Theme) {
        defaults.set(theme.id, forKey: Self.selectionDefaultsKey)
        self.theme = theme
    }
}
