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

// MARK: - Challenge layout measurement (PR #92 fix round 4)

/// One layout measurement pass over the portrait challenge body.
///
/// Heights size the chat (see `innerChatHeight`); frames let tests
/// prove the controls reachable. Frames are in the `.global` space:
/// consumers translate them with one UIKit anchor (the materialized
/// composer field), which also cross-checks the hook's truthfulness.
/// Every field has exactly one probe; absent views (e.g. Hint/Send
/// after session completion) report nil — never a stale frame.
struct ChallengeLayoutReport: Equatable {
    var shieldHeaderHeight: CGFloat? = nil
    var finishFooterHeight: CGFloat? = nil
    var chatHeaderHeight: CGFloat? = nil
    var chatComposerHeight: CGFloat? = nil
    /// Voice-unavailable notice height; nil when the notice is absent
    /// (the usual case), so it never gates `isComplete`.
    var chatNoticeHeight: CGFloat? = nil
    var composerFieldFrame: CGRect? = nil
    var hintButtonFrame: CGRect? = nil
    var sendButtonFrame: CGRect? = nil
    var finishButtonFrame: CGRect? = nil
    /// Simulated-badge frame (round 5, finding 1): proves the pinned
    /// badge stays visible while the controls are reveal-scrolled.
    var badgeFrame: CGRect? = nil

    /// True once every probe in an active session has reported.
    var isComplete: Bool {
        shieldHeaderHeight != nil && finishFooterHeight != nil
            && chatHeaderHeight != nil && chatComposerHeight != nil
            && composerFieldFrame != nil && hintButtonFrame != nil
            && sendButtonFrame != nil && finishButtonFrame != nil
            && badgeFrame != nil
    }

    fileprivate mutating func merge(_ other: ChallengeLayoutReport) {
        shieldHeaderHeight = other.shieldHeaderHeight ?? shieldHeaderHeight
        finishFooterHeight = other.finishFooterHeight ?? finishFooterHeight
        chatHeaderHeight = other.chatHeaderHeight ?? chatHeaderHeight
        chatComposerHeight = other.chatComposerHeight ?? chatComposerHeight
        chatNoticeHeight = other.chatNoticeHeight ?? chatNoticeHeight
        composerFieldFrame = other.composerFieldFrame ?? composerFieldFrame
        hintButtonFrame = other.hintButtonFrame ?? hintButtonFrame
        sendButtonFrame = other.sendButtonFrame ?? sendButtonFrame
        finishButtonFrame = other.finishButtonFrame ?? finishButtonFrame
        badgeFrame = other.badgeFrame ?? badgeFrame
    }
}

struct ChallengeLayoutReportKey: PreferenceKey {
    static var defaultValue = ChallengeLayoutReport()
    static func reduce(
        value: inout ChallengeLayoutReport,
        nextValue: () -> ChallengeLayoutReport
    ) {
        value.merge(nextValue())
    }
}

/// A layout-neutral measurement background: transparent, never affects
/// layout, only reports through `ChallengeLayoutReportKey`. Shared by
/// this file's probes and `ChatConversationView`'s (same module).
struct ChallengeLayoutProbe: View {
    var report: (GeometryProxy) -> ChallengeLayoutReport

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ChallengeLayoutReportKey.self,
                value: report(proxy))
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme
    private let onChatModelMount: ((ChatConversationViewModel, SimulatedShieldFlow) -> Void)?
    /// Latest measurement pass (round 4): sizes the portrait chat and,
    /// through `onControlFrames`, lets tests prove the controls
    /// reachable. Updated only on change, so layout converges instead
    /// of feeding back.
    @State private var layoutReport = ChallengeLayoutReport()
    private let onControlFrames: ((ChallengeLayoutReport) -> Void)?

    /// Minimum container width for the compact two-column layout (PR
    /// #92 fix round 3, finding 1): the sidebar reserves 280pt, and
    /// the chat keeps at least ~320pt for the number pad and the
    /// Hint/Send row. A 390pt-wide portrait phone never qualifies, so
    /// a keyboard-reduced height can never strand it in a 280pt-sidebar
    /// + 110pt-chat split. Every supported landscape phone (667pt wide
    /// and up) still qualifies.
    private static let compactMinWidth: CGFloat = 600

    /// Sidebar width in the compact layout (round 2, unchanged).
    private static let compactSidebarWidth: CGFloat = 280

    /// Thread floor in the portrait layout (round 4): the chat never
    /// shrinks below its fixed chrome (measured) plus this, so at
    /// least one message row survives and the outer column — not the
    /// chat's pinned composer — yields when the safe area shrinks.
    private static let minThreadHeight: CGFloat = 60

    /// Layout decision table (round 3, finding 1): the compact sidebar
    /// layout applies only when the vertical size class is compact
    /// (short landscape phones — every iPhone in landscape reports a
    /// compact vertical class, portrait phones and all iPads report
    /// regular) AND the container is wide enough for the sidebar. The
    /// decision reads NO height, so opening the software keyboard —
    /// which changes neither the size class nor the container width —
    /// can never flip the layout. Pure, so the table is unit-tested
    /// directly; the view feeds it the environment size class and the
    /// root reader's width.
    static func useCompactLayout(
        verticalSizeClass: UserInterfaceSizeClass?,
        width: CGFloat
    ) -> Bool {
        verticalSizeClass == .compact && width >= compactMinWidth
    }

    /// - Parameter makeEngine: challenge engine factory for tests; each
    ///   (re)mount builds its engine over its own flow. Production (nil)
    ///   wraps a non-recording `DemoTutorEngine` over `flow`. A factory
    ///   (not one shared instance) so a flow replacement rebinds effort
    ///   to the replacement session.
    /// - Parameter onChatModelMount: test hook reporting the mounted
    ///   challenge's live chat model and flow on appearance; nil in
    ///   production. Mount-time only, so it always names the identity
    ///   the surface actually uses (view `init` also runs for
    ///   identities whose `@StateObject` is then discarded).
    /// - Parameter onControlFrames: test hook receiving each new
    ///   `ChallengeLayoutReport`; nil in production. The measurement
    ///   itself is production-always (it sizes the portrait chat);
    ///   only the observation is test-gated.
    init(
        flow: SimulatedShieldFlow,
        theme: DesignSystem.Theme = DesignSystem.defaultTheme,
        makeEngine: ((SimulatedShieldFlow) -> any ChatTutorEngine)? = nil,
        onChatModelMount: ((ChatConversationViewModel, SimulatedShieldFlow) -> Void)? = nil,
        onControlFrames: ((ChallengeLayoutReport) -> Void)? = nil
    ) {
        self.flow = flow
        self.theme = theme
        self.onChatModelMount = onChatModelMount
        self.onControlFrames = onControlFrames
        let challengeEngine = makeEngine?(flow) ?? InstalledShieldChatEngine(
            inner: DemoTutorEngine(), flow: flow
        )
        _chatViewModel = StateObject(wrappedValue: ChatConversationViewModel(
            engine: challengeEngine,
            speech: ReadAloudService(band: GradeBand(grade: "4"))))
    }

    var body: some View {
        GeometryReader { proxy in
            adaptiveBody(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.tokens.background.color)
        .interactiveDismissDisabled(true)
        .onAppear {
            onChatModelMount?(chatViewModel, flow)
        }
        .onPreferenceChange(ChallengeLayoutReportKey.self) { report in
            // Deduped: heights are width-determined (stable across
            // keyboard and scroll changes), so layout converges after
            // the first pass instead of feeding back.
            if report != layoutReport {
                layoutReport = report
                onControlFrames?(report)
            }
        }
    }

    /// Both layouts share one structure (round 3, finding 1): the
    /// layout DECISION reads only the size class and the width — the
    /// keyboard changes neither, so it can never flip the layout.
    /// Round 4 feeds the height ONLY to the chat's explicit frame
    /// (sizing, never a branch): keyboard open/close changes no view
    /// type or position, so the focused composer subtree — still the
    /// inner column's middle slot in both layouts — always survives.
    private func adaptiveBody(width: CGFloat, height: CGFloat) -> some View {
        let compact = Self.useCompactLayout(
            verticalSizeClass: verticalSizeClass, width: width)
        return HStack(spacing: 0) {
            // Compact sidebar (round 2): at short landscape heights the
            // fixed header and finish footer plus the chat's number
            // pad, answer field, and Hint/Send row exceed the viewport,
            // and only the message thread scrolls — so the Finish
            // action could be pushed off-screen in this
            // non-dismissible challenge. Here the chat keeps the full
            // height on the right while the badge and Finish action sit
            // in a narrow left column, keeping both visible and tappable
            // with no scrolling at phone landscape heights. The column
            // scrolls only at even shorter heights.
            if compact {
                // Round 6: ONLY the simulated badge is pinned above the
                // sidebar scroll — the header texts and Finish footer stay
                // scrollable, preserving the round-5 guarantee that Finish
                // is never stranded at keyboard-reduced heights (a fully
                // pinned header would strand it when the viewport falls
                // below header-plus-footer). Scrolling to a denial result
                // can no longer push the enforcement indicator off-screen.
                VStack(spacing: 0) {
                    simulatedBadge
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .background(ChallengeLayoutProbe {
                            ChallengeLayoutReport(
                                shieldHeaderHeight: $0.size.height)
                        })

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            challengeHeaderTexts

                            finishFooter
                                .background(ChallengeLayoutProbe {
                                    ChallengeLayoutReport(
                                        finishFooterHeight: $0.size.height)
                                })
                        }
                        .padding(12)
                    }
                }
                .frame(width: Self.compactSidebarWidth)
            }

            // Round 5, finding 1: the portrait header — the simulated
            // badge block — is pinned ABOVE the scrolling column, never
            // inside it, so scrolling to the controls with the keyboard
            // open can never hide the simulated-enforcement indication.
            // The sizing math is unchanged: the column viewport is the
            // available height minus the pinned header, and the chat
            // keeps available-minus-chrome, so closed content still fits
            // exactly and keyboard-reduced heights still scroll the
            // column (not the chat). Round 6: the compact sidebar pins
            // ONLY the simulated badge above its scroll; the header texts
            // and Finish footer stay scrollable deliberately — at
            // landscape keyboard-reduced heights the sidebar viewport can
            // fall below header-plus-footer, where a fully pinned sidebar
            // header would strand Finish. Keyboard open/close still
            // changes no branch in either layout, so the focused composer
            // subtree still always survives (the resolved round-4
            // finding).
            if compact {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ChatConversationView(viewModel: chatViewModel, theme: theme)
                            .frame(height: innerChatHeight(
                                available: height, compact: compact))
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    challengeHeader
                        .padding()
                        .background(ChallengeLayoutProbe {
                            ChallengeLayoutReport(
                                shieldHeaderHeight: $0.size.height)
                        })

                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ChatConversationView(viewModel: chatViewModel, theme: theme)
                                .frame(height: innerChatHeight(
                                    available: height, compact: compact))

                            finishFooter
                                .padding()
                                .background(ChallengeLayoutProbe {
                                    ChallengeLayoutReport(
                                        finishFooterHeight: $0.size.height)
                                })
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Explicit chat height (round 4, portrait): the available height
    /// minus the measured shield chrome — exactly what the old
    /// flexible layout gave the chat — floored at the chat's measured
    /// fixed chrome plus the thread floor, so a shrunken safe area
    /// scrolls the outer column instead of crushing the pinned
    /// composer. Round 5, finding 2: compact applies the same
    /// fixed-plus-floor minimum instead of the bare available height,
    /// so a keyboard-reduced landscape height grows outer scroll
    /// content instead of crushing the thread and overflowing
    /// Hint/Send past the scrollable end. Unmeasured heights read 0
    /// on the first pass; the preference pass corrects them before
    /// anything settles.
    private func innerChatHeight(available: CGFloat, compact: Bool) -> CGFloat {
        let fixed = (layoutReport.chatHeaderHeight ?? 0)
            + (layoutReport.chatComposerHeight ?? 0)
            + (layoutReport.chatNoticeHeight ?? 0)
        if compact {
            return max(fixed + Self.minThreadHeight, available)
        }
        let chrome = (layoutReport.shieldHeaderHeight ?? 0)
            + (layoutReport.finishFooterHeight ?? 0)
        return max(fixed + Self.minThreadHeight, available - chrome)
    }

    private var challengeHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            simulatedBadge

            challengeHeaderTexts
        }
    }

    /// The simulated-enforcement badge alone (round 6): pinned in BOTH
    /// layouts — above the portrait column (round 5) and above the
    /// compact sidebar scroll — so reaching the controls or a denial
    /// result can never hide it. Carries the badge frame probe.
    private var simulatedBadge: some View {
        Text(SimulatedShieldFlow.simulatedBadgeText)
            .font(.headline)
            .foregroundStyle(theme.tokens.tutorText.color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
            .background(theme.tokens.track.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
            .accessibilityIdentifier("simulatedShieldBadge")
            .background(ChallengeLayoutProbe {
                ChallengeLayoutReport(badgeFrame: $0.frame(in: .global))
            })
    }

    /// The non-badge header lines: the locked-app label and the effort
    /// explainer. Pinned with the badge in portrait (part of
    /// `challengeHeader`); scrollable in the compact sidebar (round 6),
    /// so Finish stays reachable at keyboard-reduced heights.
    private var challengeHeaderTexts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Locked app (simulated): \(flow.app.id)")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryOnTheme)
                .accessibilityIdentifier("lockedAppLabel")

            Text("Chat with the tutor to build effort, then finish to check it. Effort counts — correctness does not.")
                .font(.caption)
                .foregroundStyle(theme.secondaryOnTheme)
        }
    }

    private var finishFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Finish & check effort") {
                flow.finishChallenge()
            }
            .accessibilityIdentifier("finishChallengeButton")
            .background(ChallengeLayoutProbe {
                ChallengeLayoutReport(finishButtonFrame: $0.frame(in: .global))
            })

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
    private let makeEngine: ((SimulatedShieldFlow) -> any ChatTutorEngine)?
    private let onChatModelMount: ((ChatConversationViewModel, SimulatedShieldFlow) -> Void)?

    /// - Parameters:
    ///   - makeEngine: forwarded to the challenge view (see its docs).
    ///   - onChatModelMount: forwarded to the challenge view (see its
    ///     docs). Both are nil in production.
    init(
        flow: SimulatedShieldFlow,
        theme: DesignSystem.Theme = DesignSystem.defaultTheme,
        makeEngine: ((SimulatedShieldFlow) -> any ChatTutorEngine)? = nil,
        onChatModelMount: ((ChatConversationViewModel, SimulatedShieldFlow) -> Void)? = nil
    ) {
        self.flow = flow
        self.theme = theme
        self.makeEngine = makeEngine
        self.onChatModelMount = onChatModelMount
    }

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
            // Keyed by flow identity (PR #92 fix round 1): a policy refresh
            // replaces the cached installed flow mid-challenge, and without
            // this SwiftUI reuses the challenge's @StateObject — chat effort
            // would keep recording into the discarded session while Finish
            // scores the replacement's empty one. The new identity recreates
            // the chat model with, and bound to, the replacement flow.
            content: {
                InstalledShieldChatChallengeView(
                    flow: flow,
                    theme: theme,
                    makeEngine: makeEngine,
                    onChatModelMount: onChatModelMount
                )
                .id(ObjectIdentifier(flow))
            }
        )
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            flow.tick()
        }
    }
}
