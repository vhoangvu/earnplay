import Combine
import SwiftUI
import EarnPlayCore

// MARK: - Chat challenge engine (issue #91)

/// Effort wrapper presenting the chat tutor as an installed shield's
/// challenge surface.
///
/// Engine-agnostic: it forwards every decision to an inner `any
/// ChatTutorEngine` (production: a non-recording `DemoTutorEngine`) and
/// records each chat interaction into the SAME `SimulatedShieldFlow`
/// effort session `finishChallenge` scores — one explicit flow call per
/// interaction type:
/// - child answers → `submitAttempt` (genuine attempts; blank submits stay
///   interaction-only through the flow's existing rule),
/// - delivered hints → `useHint`, and hint read-alouds → the flow's
///   `HintListenEventSink` (both are hint interactions),
/// - probe replies → `recordFollowUpInteraction` + `recordExplanation` when
///   substantive (the main-chat probe-reply shape), else `recordInteraction`,
/// - engine-labelled revisions → `recordAnswerRevision`,
/// - composer activity → `recordInteraction` (active-time anchor only).
///
/// Probe tracking: any tutor turn of kind `.probe` in an engine update arms
/// probe-reply handling for the next submission; that submission is then a
/// follow-up/explanation, never an attempt — mirroring how the main practice
/// chat treats probe replies. A restart (`startSession`) disarms, like the
/// inner session reset; resumes preserve the thread, so the arm survives.
///
/// The inner engine runs WITHOUT practice recording, so the challenge writes
/// no `SessionLog` and touches the sync outbox: unlock decisions log only
/// through the flow's existing `finishChallenge` boundary. The main practice
/// chat keeps its own recording engine untouched.
///
/// Isolation: the engine and sink protocols are nonisolated, so this class
/// is nonisolated too; every flow touch hops to the main actor explicitly.
/// All callers run on the main thread — the chat view model is MainActor and
/// the read-aloud chain is MainActor-synchronous — so the hops assert
/// (`assumeIsolated`) rather than detach. Calling off the main thread traps.
final class InstalledShieldChatEngine: ChatTutorEngine, HintListenEventSink {
    private let inner: any ChatTutorEngine
    private let flow: SimulatedShieldFlow
    private let isSubstantiveReply: (String) -> Bool
    private var awaitingProbeReply = false

    init(
        inner: any ChatTutorEngine,
        flow: SimulatedShieldFlow,
        isSubstantiveReply: @escaping (String) -> Bool = { StallingDetector().isSubstantiveReply($0) }
    ) {
        self.inner = inner
        self.flow = flow
        self.isSubstantiveReply = isSubstantiveReply
    }

    func startSession() -> ChatEngineUpdate {
        let update = inner.startSession()
        MainActor.assumeIsolated { self.didStart(update: update) }
        return update
    }

    func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
        let update = inner.submitAnswer(plainText)
        MainActor.assumeIsolated { self.didSubmit(plainText, update: update) }
        return update
    }

    func requestHint() -> ChatEngineUpdate {
        let update = inner.requestHint()
        MainActor.assumeIsolated { self.didRequestHint(update: update) }
        return update
    }

    func endSession() {
        inner.endSession()
    }

    func resumeSession() {
        inner.resumeSession()
    }

    func recordComposerActivity() {
        inner.recordComposerActivity()
        MainActor.assumeIsolated { self.flow.recordInteraction() }
    }

    /// Hint-listen entry: a hint read aloud during the challenge records as
    /// a hint interaction on the scored session. Forwarding to the flow (not
    /// a captured recorder) stays correct across denied retries and resets.
    func recordHintListen(_ event: HintListenEvent) {
        MainActor.assumeIsolated { self.flow.recordHintListen(event) }
    }

    var currentHintListenSink: (any HintListenEventSink)? { self }

    var isInputBlocked: Bool { inner.isInputBlocked }

    @MainActor
    private func didStart(update: ChatEngineUpdate) {
        awaitingProbeReply = false
        armProbeIfPresent(in: update)
    }

    @MainActor
    private func didSubmit(_ plainText: String, update: ChatEngineUpdate) {
        if awaitingProbeReply {
            awaitingProbeReply = false
            if isSubstantiveReply(plainText) {
                flow.recordFollowUpInteraction()
                flow.recordExplanation()
            } else {
                flow.recordInteraction()
            }
        } else {
            flow.submitAttempt(answer: plainText)
            if update.submittedTurnIsRevision {
                flow.recordAnswerRevision()
            }
        }
        armProbeIfPresent(in: update)
    }

    @MainActor
    private func didRequestHint(update: ChatEngineUpdate) {
        // Only a delivered hint records: an exhausted ladder returns no
        // hint turn, and an exhausted tap records nothing.
        if update.turns.contains(where: { $0.tutorMessage?.kind == .hint }) {
            flow.useHint()
        }
        armProbeIfPresent(in: update)
    }

    @MainActor
    private func armProbeIfPresent(in update: ChatEngineUpdate) {
        if update.turns.contains(where: { $0.tutorMessage?.kind == .probe }) {
            awaitingProbeReply = true
        }
    }
}

// MARK: - Chat challenge surface (issue #91)

/// Installed-shield challenge surface (issue #91): the chat tutor with the
/// simulated badge always visible, finishing through the flow's EXISTING
/// `finishChallenge` boundary — same floor rule, same threshold math, same
/// decision logging, no new scoring rules.
///
/// Installed path only: `SimulatedShieldDemoView`'s one-question surface
/// stays as-is. Blocked targets never reach this view (the panel renders
/// the informational status instead).
struct InstalledShieldChatChallengeView: View {
    @ObservedObject var flow: SimulatedShieldFlow
    @StateObject private var chatViewModel: ChatConversationViewModel
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    /// - Parameter engine: challenge engine override for tests; production
    ///   wraps a non-recording `DemoTutorEngine` over `flow`.
    init(
        flow: SimulatedShieldFlow,
        theme: DesignSystem.Theme = DesignSystem.defaultTheme,
        engine: (any ChatTutorEngine)? = nil
    ) {
        self.flow = flow
        self.theme = theme
        let challengeEngine = engine ?? InstalledShieldChatEngine(
            inner: DemoTutorEngine(), flow: flow
        )
        _chatViewModel = StateObject(wrappedValue: ChatConversationViewModel(
            engine: challengeEngine,
            speech: ReadAloudService(band: GradeBand(grade: "4"))))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(SimulatedShieldFlow.simulatedBadgeText)
                    .font(.headline)
                    .foregroundStyle(theme.tokens.tutorText.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(theme.tokens.track.color)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
                    .accessibilityIdentifier("simulatedShieldBadge")

                Text("Locked app (simulated): \(flow.app.id)")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryOnTheme)
                    .accessibilityIdentifier("lockedAppLabel")

                Text("Chat with the tutor to build effort, then finish to check it. Effort counts — correctness does not.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryOnTheme)
            }
            .padding()

            ChatConversationView(viewModel: chatViewModel, theme: theme)

            VStack(alignment: .leading, spacing: 8) {
                Button("Finish & check effort") {
                    flow.finishChallenge()
                }
                .accessibilityIdentifier("finishChallengeButton")

                if let score = flow.lastScore {
                    Text(score.narration)
                        .font(.callout)
                        .foregroundStyle(theme.tokens.tutorText.color)
                        .accessibilityIdentifier("challengeResultLabel")
                }
                if let decisionText = flow.challengeDecisionText {
                    Text(decisionText)
                        .font(.callout.bold())
                        .foregroundStyle(theme.tokens.tutorText.color)
                        .accessibilityIdentifier("challengeDecisionLabel")
                }
            }
            .padding()
        }
        .background(theme.tokens.background.color)
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Chat challenge cover host (issue #91)

/// Host for one installed app's chat challenge flow: the unlocked countdown
/// and the blocking shield screen, mirroring `SimulatedShieldCoverHost`
/// except the presented content is the chat challenge. Ticks the flow every
/// second so the countdown stays live and expiry re-presents.
struct InstalledShieldChatCoverHost: View {
    @ObservedObject var flow: SimulatedShieldFlow
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if flow.isShieldPresented {
                Text("Locked (simulated) — complete the challenge to unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simulatedLockedLabel")
            } else {
                Text("Unlocked (simulated) — \(Int(flow.remainingUnlockTime))s left")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("unlockCountdownLabel")
            }
        }
        .fullScreenCover(
            isPresented: Binding(get: { flow.isShieldPresented }, set: { _ in }),
            content: { InstalledShieldChatChallengeView(flow: flow, theme: theme) }
        )
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            flow.tick()
        }
    }
}
