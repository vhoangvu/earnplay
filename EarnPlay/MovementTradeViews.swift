import EarnPlayCore
import SwiftUI
import UIKit

/// The single take-it-or-leave-it offer card. Shown only when the AI
/// initiates; there is no path for the child to summon it.
struct MovementTradeOfferCard: View {
    var activityName: String
    var targetReps: Int
    var unlockMinutes: Int
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement break?")
                .font(.headline)
            Text("Let's move for a minute! Do \(targetReps) \(activityName.lowercased()) "
                + "with the phone in your pocket to earn \(unlockMinutes) minutes.")
                .font(.body)
            HStack {
                Button("Let's go", action: onAccept)
                    .buttonStyle(.borderedProminent)
                Button("Not now", action: onDecline)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Live verified-rep counter shown during the activity.
struct MovementTradeActiveView: View {
    var activityName: String
    var verifiedCount: Int
    var targetReps: Int
    var onAbandon: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activityName)
                .font(.headline)
            Text("\(verifiedCount) / \(targetReps)")
                .font(.system(size: 48, weight: .bold))
                .accessibilityLabel("Verified reps: \(verifiedCount) of \(targetReps)")
            ProgressView(value: Double(verifiedCount), total: Double(max(1, targetReps)))
            Text("Phone in your pocket — only real reps count.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Stop", action: onAbandon)
                .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// T3.1 preview harness: simulates the AI low-motivation event that T3.3 will
/// produce, runs the real offer gate and session, and counts motion from
/// the `MotionProviderFactory` selection — fixture replay on the simulator
/// (which has no sensor) or in the DEBUG test mode, the real CoreMotion
/// sensor on a physical device. The simulate trigger is DEBUG-only;
/// production offers arrive only via `presentOffer` from the tutor.
struct MovementTradePreviewView: View {
    @StateObject private var model = MovementTradeViewModel(
        verificationConfidence: MovementVerificationConfidence.forDevice(
            isPad: UIDevice.current.userInterfaceIdiom == .pad))
    @State private var previewSession = PreviewSession()
    @State private var refusalText = ""
    @State private var replayChoice = 0 // 0 genuine, 1 shaking, 2 still

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Movement trade (T3.1)")
                .font(.headline)
            switch model.screen {
            case .none:
                Text("No offer. In production the tutor offers a trade only when it "
                    + "judges motivation is fading — the child can never ask for one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if DEBUG
                    Button("Simulate AI low-motivation offer (DEBUG)") {
                        simulateAIInitiation()
                    }
                    .font(.caption)
                #endif
                if !refusalText.isEmpty {
                    Text(refusalText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .offered:
                MovementTradeOfferCard(
                    activityName: activityLabel,
                    targetReps: model.targetReps,
                    unlockMinutes: model.unlockMinutes,
                    onAccept: {
                        model.accept(with: MotionProviderFactory.makeAcceptProvider(
                            replayProvider: replayProvider()))
                    },
                    onDecline: { model.decline() })
                #if DEBUG
                    Picker("Preview motion", selection: $replayChoice) {
                        Text("Genuine").tag(0)
                        Text("Shaking").tag(1)
                        Text("Still").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Preview replays simulated motion — on a real phone the "
                        + "pocket sensor drives the counter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                #endif
            case .active:
                MovementTradeActiveView(
                    activityName: activityLabel,
                    verifiedCount: model.verifiedCount,
                    targetReps: model.targetReps,
                    onAbandon: { model.abandon() })
            case .finished:
                Text(model.statusText)
                    .font(.body)
                if let minutes = model.grantMinutes {
                    Text("Granted \(minutes) minutes (trade unlock — shorter than practice).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activityLabel: String {
        model.activityName.isEmpty ? "Movement" : model.activityName
    }

    private func replayProvider() -> FixtureReplayProvider {
        switch replayChoice {
        case 1: return FixtureReplayProvider(samples: MotionFixtures.shakingInHand())
        case 2: return FixtureReplayProvider(samples: MotionFixtures.phoneOnTable())
        default: return FixtureReplayProvider(samples: MotionFixtures.genuineJumpingJacks(repCount: 12))
        }
    }

    #if DEBUG
        private func simulateAIInitiation() {
            refusalText = ""
            let store = MovementTradeHistoryStore()
            let history = store.history
            let context = MovementOfferContext(
                initiation: .aiLowMotivation,
                signals: EffortSignals(activeSeconds: 120, genuineAttempts: 2,
                                       hintInteractions: 1),
                sessionOffersUsed: history.offersInSession(previewSession.id),
                weeklyCompletions: history.weeklyUsageInTrailingWeek(),
                recentSessionCompletions: history.recentSessionCompletions())
            switch MovementTradeManager.decide(context: context, policy: .defaultPolicy) {
            case .offer(let offer):
                let presented = model.presentOffer(
                    offer, sessionId: previewSession.id,
                    weeklyCap: Policy.defaultPolicy.tradeCaps.weeklyMaxMovementTrades)
                if !presented {
                    refusalText = "Offer could not be presented "
                        + "(weekly limit reached or save failed)."
                }
            case .refuse(let reason):
                refusalText = "Offer refused by gate: \(reason)."
            }
        }
    #endif
}
