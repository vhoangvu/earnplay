import SwiftUI
import EarnPlayCore

/// Preview/host view proving the T1.7 TTS path without the chat UI
/// (T1.8 is not merged yet). It renders sample tutor messages of each
/// kind, each with its speaker button, and exercises the lifecycle:
/// starting a new item stops the current reading, and leaving this view
/// stops the current reading.
///
/// T1.8 will replace this host with the real chat thread; the button and
/// the service calls below are the integration contract it must keep.
struct ReadAloudPreviewView: View {
    @StateObject private var service = ReadAloudService(band: GradeBand(grade: "4"))

    private let messages: [TutorMessage] = [
        TutorMessage(id: "q1", text: "What is 7 plus 5?", kind: .question),
        TutorMessage(id: "h1", text: "Try counting on from 7: 8, 9, 10…", kind: .hint),
        TutorMessage(id: "i1", text: "Take your time. There is no clock.", kind: .instruction),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-aloud (T1.7) — Band B, grade 4")
                .font(.headline)
            Text("Tap a speaker button to hear the message. Starting a new item or leaving this view stops the reading.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(messages) { message in
                HStack(alignment: .top, spacing: 8) {
                    SpeakerButton(message: message, service: service)
                    Text(message.text)
                        .font(.body)
                    Spacer()
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button("Start new item (stops reading)") {
                service.startNewItem()
            }
            .accessibilityIdentifier("startNewItemButton")

            Text(service.isSpeaking ? "Reading…" : "Not reading")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Hint-listens recorded: \(service.hintListenEvents.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
        .onDisappear {
            service.handleViewDisappeared()
        }
    }
}

#Preview {
    ReadAloudPreviewView()
}
