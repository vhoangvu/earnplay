import SwiftUI
import EarnPlayCore

/// Reusable speaker button attached to every tutor message in the chat
/// thread (T1.7). Demo scope is Band B: the button is always present and
/// the child taps it to hear the text. Tapping the message that is
/// currently being read stops the reading.
///
/// T1.8 integration point: the chat UI renders one `SpeakerButton` per
/// tutor message, passing the message (text + whether it is a hint, via
/// `TutorMessage.kind`) and the shared `ReadAloudService`. The chat view
/// must also call `service.handleViewDisappeared()` when it leaves the
/// screen and `service.startNewItem()` when a new item starts, so a
/// reading never survives its item or its view.
struct SpeakerButton: View {
    let message: TutorMessage
    @ObservedObject var service: ReadAloudService
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    var body: some View {
        // Always rendered for every tutor message (Band B Demo scope).
        // It is never hidden and never disabled.
        Button {
            service.toggle(message)
        } label: {
            Image(systemName: isCurrentAndSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                .foregroundStyle(theme.tokens.accent.color)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrentAndSpeaking ? "Stop reading" : "Listen to this message")
        .accessibilityIdentifier("speakerButton_\(message.id)")
    }

    private var isCurrentAndSpeaking: Bool {
        service.isSpeaking && service.currentMessageID == message.id
    }
}

#Preview {
    SpeakerButton(
        message: TutorMessage(id: "preview-q1", text: "What is 7 plus 5?", kind: .question),
        service: ReadAloudService(band: GradeBand(grade: "4"))
    )
}
