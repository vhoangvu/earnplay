import SwiftUI
import EarnPlayCore

/// In-app simulated shield screen (T2.4) — stands in for a real
/// ManagedSettings shield when the distribution entitlement is
/// unavailable, so the full challenge-to-unlock flow can be demonstrated.
///
/// The screen blocks the app view while `flow.isShieldPresented` and is
/// always visibly labelled as simulated (`simulatedBadgeText`): a demo
/// audience must never mistake it for a real system shield. The
/// challenge is the real Epic 1 path — attempts and hint interactions
/// record into the flow's effort session and only a granted score opens
/// the timed unlock window. This screen makes zero ManagedSettings
/// calls; real enforcement needs the T0.4 entitlement (v1, not filed).
struct SimulatedShieldView: View {
    @ObservedObject var flow: SimulatedShieldFlow
    @State private var answerText = ""
    @State private var hintRevealed = false
    @State private var attemptsSubmitted = 0

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(SimulatedShieldFlow.simulatedBadgeText)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.yellow.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("simulatedShieldBadge")

                    Text("Locked app (simulated): \(flow.app.id)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("lockedAppLabel")

                    Text("Complete the practice challenge to unlock. Effort counts — correctness does not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    Text(flow.challengePrompt)
                        .font(.body)
                        .accessibilityIdentifier("challengePromptLabel")

                    TextField("Your answer", text: $answerText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("answerField")

                    HStack {
                        Button("Submit attempt") {
                            flow.submitAttempt(answer: answerText)
                            answerText = ""
                            attemptsSubmitted += 1
                        }
                        .accessibilityIdentifier("submitAttemptButton")
                        Button("Use hint") {
                            flow.useHint()
                            hintRevealed = true
                        }
                        .accessibilityIdentifier("useHintButton")
                    }

                    if hintRevealed {
                        Text(flow.challengeHint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("hintText")
                    }

                    Button("Finish & check effort") {
                        flow.finishChallenge()
                    }
                    .accessibilityIdentifier("finishChallengeButton")

                    if let score = flow.lastScore {
                        Text(score.narration)
                            .font(.callout)
                            .accessibilityIdentifier("challengeResultLabel")
                        if let decisionText = flow.challengeDecisionText {
                            Text(decisionText)
                                .font(.callout.bold())
                                .accessibilityIdentifier("challengeDecisionLabel")
                        }
                    }
                }
                .padding()
            }
        }
        .interactiveDismissDisabled(true)
    }
}
