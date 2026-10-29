import SwiftUI
import EarnPlayCore

/// Preview/host view proving the T1.5 stalling-probe path without the chat
/// UI (T1.8 is not merged yet). It runs a one-question demo session on a
/// `StallProbeSession`: submitting the same wrong answer 3 times fires a
/// conversational probe ("show me one step" / "what have you tried?"); a
/// substantive reply is recorded as effort and the session continues.
///
/// T1.8 will replace this host with the real chat thread; the calls below
/// (`recordAttempt`, `recordRevision`, `recordHintInteraction`,
/// `submitProbeReply`, and rendering the probe's `TutorMessage` with a
/// speaker button) are the integration contract it must keep. The view
/// holds no behavior logic — every decision comes from `StallingDetector`
/// and the T1.4 recorder.
struct StallProbePreviewView: View {
    @StateObject private var model = StallProbePreviewModel()
    @State private var answerText = ""
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stalling probes (T1.5) — preview session")
                .font(.headline)
            Text("Demo question: what is 7 × 8? Submit the same wrong answer 3 times to see a probe. T1.8 will adopt this probe into the chat thread.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Your answer", text: $answerText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("stallAnswerField")
                Button("Submit") {
                    model.submitAnswer(answerText)
                    answerText = ""
                }
                .accessibilityIdentifier("stallSubmitAnswerButton")
            }

            Button("Hint (always available)") {
                model.useHint()
            }
            .accessibilityIdentifier("stallHintButton")
            if model.hintVisible {
                Text("Hint: think of 7 × 8 as 7 × 4, doubled.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let probe = model.pendingProbe {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        SpeakerButton(message: probe.message, service: model.speech)
                        Text(probe.message.text)
                            .font(.body)
                        Spacer()
                    }
                    HStack {
                        TextField("Show your step…", text: $replyText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("stallProbeReplyField")
                        Button("Send") {
                            model.submitReply(replyText)
                            replyText = ""
                        }
                        .accessibilityIdentifier("stallSendReplyButton")
                    }
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("stallProbeCard")
            }
            if let notice = model.replyNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("stallReplyNotice")
            }

            Text(model.statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("stallStatusLabel")

            Button("Start over (new session)") {
                model.reset()
                answerText = ""
                replyText = ""
            }
            .accessibilityIdentifier("stallResetButton")
        }
        .padding()
        .onDisappear {
            model.speech.handleViewDisappeared()
        }
    }
}

/// Thin MainActor adapter over `StallProbeSession` for the preview view.
/// It forwards events and republishes display state; all stalling and
/// effort decisions stay in EarnPlayCore.
@MainActor
final class StallProbePreviewModel: ObservableObject {
    /// Demo-only verified answer. TutorEngine + SolverService own real
    /// questions and correctness when T1.8 lands; this preview checks one
    /// fixed question locally so the probe path is exercisable now.
    static let demoVerifiedAnswer = "56"

    private(set) var session: StallProbeSession
    let speech: ReadAloudService

    @Published private(set) var pendingProbe: StallProbe?
    @Published private(set) var hintVisible = false
    @Published private(set) var replyNotice: String?
    @Published private(set) var statusLine = ""

    init(session: StallProbeSession = StallProbeSession(startedAt: Date()),
         speech: ReadAloudService? = nil) {
        self.session = session
        // Default-argument expressions are nonisolated, so the MainActor
        // service default is built here in the isolated init body.
        self.speech = speech ?? ReadAloudService(band: GradeBand(grade: "4"))
        refresh()
    }

    func submitAnswer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Changed submissions are forwarded as attempts only. A revision is
        // recorded solely from a separately observed revision/work action
        // (none exists in this preview; T1.8 owns the real signal), never
        // synthesized from a changed answer: synthesizing one here would
        // reset the rapid run and clear the pending hint check before the
        // detector examines the answer.
        session.recordAttempt(answer: trimmed,
                              isCorrect: trimmed.lowercased() == Self.demoVerifiedAnswer)
        replyNotice = nil
        refresh()
    }

    func useHint() {
        session.recordHintInteraction()
        hintVisible = true
        refresh()
    }

    func submitReply(_ text: String) {
        switch session.submitProbeReply(text) {
        case .substantive:
            replyNotice = "Effort recorded — keep going."
        case .notSubstantive:
            replyNotice = "Say a little more about what you tried."
        case .noProbePending:
            replyNotice = nil
        }
        refresh()
    }

    func reset() {
        session = StallProbeSession(startedAt: Date())
        hintVisible = false
        replyNotice = nil
        speech.startNewItem()
        refresh()
    }

    private func refresh() {
        let dismissedMessageID = pendingProbe?.message.id
        pendingProbe = session.pendingProbe
        if let dismissedMessageID,
           pendingProbe?.message.id != dismissedMessageID,
           speech.isSpeaking,
           speech.currentMessageID == dismissedMessageID {
            // The probe card carrying the speaker button is gone (a
            // substantive reply dismissed it, or a new probe replaced it).
            // Stop its playback: the whole-view onDisappear does not fire
            // here, and without this the question reads on with no stop
            // control left. Other playback is untouched.
            speech.stop()
        }
        let signals = session.signals()
        // Debug preview: event counts only. The score and threshold are
        // never shown (HLD: the child never sees the number).
        statusLine = "Attempts \(signals.genuineAttempts) · "
            + "revisions \(signals.answerRevisions) · "
            + "hints \(signals.hintInteractions) · "
            + "explanations \(signals.explanations) · "
            + "probes \(session.probesFired.count)"
    }
}

#Preview {
    StallProbePreviewView()
}
