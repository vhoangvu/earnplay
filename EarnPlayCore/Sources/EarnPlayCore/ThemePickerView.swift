import SwiftUI

/// Shared theme picker (T7.8): the child app's About screen and the
/// admin app's Version tab embed the same view, each bound to its own
/// app's `ThemeStore`.
///
/// Each row shows the theme's 3 swatch colors (its identity) plus its
/// exact display name; the live preview above the list renders the
/// SELECTED theme's full token set, so switching visibly re-renders.
/// Color is never the only signal: selection also carries a checkmark
/// plus a selected/not-selected value, and stars keep their
/// filled/empty shapes in every theme.
public struct ThemePickerView: View {
    @ObservedObject public var store: ThemeStore

    public init(store: ThemeStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App theme")
                .font(.headline)
                .accessibilityIdentifier("themePickerTitle")
            ThemePreviewCard(theme: store.theme)
            ForEach(DesignSystem.allThemes) { theme in
                let selected = theme == store.theme
                Button {
                    store.select(theme)
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            ForEach(theme.swatches.indices, id: \.self) { index in
                                Circle()
                                    .fill(theme.swatches[index].color)
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .accessibilityHidden(true)
                        Text(theme.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(store.theme.tokens.accent.color)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("themeRow_\(theme.id)")
                .accessibilityValue(selected ? "selected" : "not selected")
            }
        }
        // No identifier on this container: a VStack-level identifier
        // propagates to descendants in the AX tree and clobbers the
        // row/preview identifiers above. Tests address themePickerTitle,
        // themeRow_<id>, and themePreview directly.
    }
}

/// Live preview rendering the selected theme's full token set:
/// header strip, tutor and child bubbles, a track/fill bar, and one
/// filled plus one empty star. Decorative as a whole (one labelled
/// element); the filled/empty star SHAPES still differ, as in chat.
struct ThemePreviewCard: View {
    var theme: DesignSystem.Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption.bold())
                .foregroundStyle(theme.tokens.headerText.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(theme.tokens.headerBackground.color)
                .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
            HStack {
                Text("Tutor bubble")
                    .font(.caption)
                    .foregroundStyle(theme.tokens.tutorText.color)
                    .padding(6)
                    .background(theme.tokens.tutorBackground.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius))
                Spacer()
                Text("Child bubble")
                    .font(.caption)
                    .foregroundStyle(theme.tokens.childText.color)
                    .padding(6)
                    .background(theme.tokens.childBackground.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.bubbleRadius))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.tokens.track.color)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.tokens.fill.color)
                        .frame(width: geometry.size.width * 0.6)
                }
            }
            .frame(height: 8)
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .foregroundStyle(theme.tokens.starFill.color)
                Image(systemName: "star")
                    .foregroundStyle(theme.tokens.starEmpty.color)
            }
            .font(.caption)
        }
        .padding(8)
        .background(theme.tokens.background.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("themePreview")
        .accessibilityLabel("Theme preview: \(theme.displayName)")
    }
}
