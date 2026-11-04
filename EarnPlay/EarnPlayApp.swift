import SwiftUI
import EarnPlayCore

@main
struct EarnPlayApp: App {
    /// App-scope child sync (issue #63 fix 3), mirroring the admin app:
    /// one shared service, retained for the app's life, started on
    /// launch — delivery no longer depends on any debug screen.
    /// StateObject (issue #65) so the pairing-request sheet observes
    /// the controller's published pending state.
    @StateObject private var syncController = ChildSyncController()
    /// App-scope theme store (T7.8): one selection for the child app,
    /// persisted in its own defaults, shared by the chat theme and the
    /// About-screen picker.
    @StateObject private var themes = ThemeStore()
    var body: some Scene {
        WindowGroup {
            ContentView(themes: themes, syncController: syncController)
                .onAppear { syncController.startIfNeeded() }
        }
    }
}

struct ContentView: View {
    @StateObject private var downloadModel = ModelDownloadViewModel()
    @StateObject private var setup: SetupFlowViewModel
    @ObservedObject var themes: ThemeStore
    /// Shared sync; the practice engine enqueues into its outbox
    /// instance and notifies its service after each durable enqueue.
    /// Observed (issue #65) so the pairing-request sheet presents
    /// whenever the controller holds a pending request.
    @ObservedObject var syncController: ChildSyncController
    @Environment(\.scenePhase) private var scenePhase

    /// The setup model shares the sync controller's policy store (issue
    /// #87 fix round 3): one live store for sync updates, the setup
    /// flow, the installed manager, and the completion UI, so an
    /// accepted update never sits in a sibling instance invisible to
    /// the installed shields until relaunch.
    init(themes: ThemeStore, syncController: ChildSyncController) {
        self.themes = themes
        self.syncController = syncController
        _setup = StateObject(wrappedValue: SetupFlowViewModel.makeDefault(
            policyStore: syncController.policyStore
        ))
    }

    /// UI-test-only chat preview (issue #77): launched with
    /// `--earnplay-ui-chat`, the app renders the practice chat directly,
    /// bypassing the model gate and setup wizard so XCUITest can pin the
    /// composer layout (the chat is otherwise unreachable on the
    /// simulator — see gap PRACTICE). Installed production builds are
    /// never launched with this argument, so this changes nothing
    /// outside UI tests (like the EARNPLAY_* environment overrides).
    static var uiChatPreviewEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--earnplay-ui-chat")
    }

    var body: some View {
        VStack(spacing: 0) {
            if Self.uiChatPreviewEnabled {
                ChatConversationView(engine: ModelTutorEngine(inner: DemoTutorEngine()), theme: themes.theme)
            } else {
                // Fix round 1 (finding 1): the unpaired child's local code
                // on a reachable production surface BEFORE any invitation —
                // the admin reads it off this screen to start pairing.
                // Hidden once paired; display alone pairs nothing.
                if let code = syncController.preInvitePairingCode {
                    Text("Pairing code (show to admin): \(code)")
                        .font(.body.monospacedDigit())
                        .padding(8)
                }
                Group {
                    if downloadModel.isReady {
                    if setup.step == .complete, !setup.summaryDismissed {
                        // The About sheet below is bound to the same
                        // app-scope store as the chat theme (fix-2
                        // finding 2), so onboarded installs keep a
                        // settings route after the download gate lifts.
                        SetupCompleteView(viewModel: setup, themes: themes)
                    } else if setup.step == .complete {
                        // Main practice screen (T1.8): the chat conversation.
                        // Band B (grade 4) demo engine over T1.2/T1.3 APIs.
                        // Practice recording (issue #63): the production
                        // SessionLog producer — per-question detail + effort
                        // snapshot, enqueued into the shared sync outbox
                        // (same instance the service drains, never a second
                        // writer over the same directory) and delivered via
                        // notifySessionEnqueued after each durable enqueue.
                        ChatConversationView(engine: ModelTutorEngine(inner: DemoTutorEngine(
                            recording: .productionDefault(
                                queue: syncController.sessionQueue,
                                // Round 2 item 4: read the persisted version
                                // per log (one file read per session). Setup
                                // commits through a separate store, so the
                                // controller's cache stays stale until
                                // restart; a fresh read carries the post-setup
                                // version with no restart. Sync
                                // version-comparison semantics unchanged.
                                policyVersion: { PolicyStore().storedVersion },
                                onSessionEnqueued: { [service = syncController.service] in
                                    service.notifySessionEnqueued()
                                },
                                // Round 2 item 2: a failed enqueue hands the
                                // finalized log to the app-scoped controller,
                                // which retains it across discarding this
                                // view/engine and retries through the shared
                                // queue on lifecycle triggers below.
                                onEnqueueFailed: { [syncController] log in
                                    syncController.handleFailedEnqueue(log)
                                }))), theme: themes.theme)
                    } else {
                        SetupFlowView(viewModel: setup, themes: themes)
                    }
                    } else {
                        ModelDownloadView(viewModel: downloadModel, themes: themes)
                    }
                }
            }
        }
        .task {
            downloadModel.refreshIfNeeded()
        }
        // Issue #87 fix round 3: an accepted sync update refreshes the
        // installed manager, cached shield flows, and completion UI
        // without a relaunch. Wired here (not in `init`, which SwiftUI
        // may re-run with a discarded model) so the hook always reaches
        // the live `@StateObject` setup model.
        .onAppear {
            syncController.onPolicyUpdate = { [weak setupVM = setup] in
                Task { @MainActor in setupVM?.refreshInstalledPolicyFromDisk() }
            }
        }
        // Production pairing confirmation (issue #65): presented
        // whenever a pending request exists, from ANY app state —
        // invitations arrive asynchronously and must interrupt wherever
        // the child is (including mid-practice-chat), never gated
        // behind setup or settings navigation. Dismissal is by explicit
        // Accept/Decline only (no swipe-away of a security decision).
        .sheet(isPresented: Binding(
            get: { syncController.pendingPairingPeer != nil },
            set: { _ in }
        )) {
            if let peer = syncController.pendingPairingPeer {
                ChildPairingRequestSheet(controller: syncController, peer: peer)
                    .interactiveDismissDisabled()
            }
        }
        // Round 2 item 2: retry retained failed-enqueue logs when the app
        // foregrounds — a real lifecycle trigger, never a timer.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                syncController.retryPendingFailedLogs()
            }
        }
    }

    /// Earlier-task preview harnesses, kept reachable for their own
    /// manual tests; not part of the practice-session screen.
    var previewHarnesses: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("EarnPlay")
                    .font(.largeTitle.bold())
                Text("Core v\(EarnPlayCore.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                SyncDebugView(controller: syncController)
                Divider()
                ReadAloudPreviewView(theme: themes.theme)
                Divider()
                SimulatedShieldDemoView(theme: themes.theme)
                Divider()
                StallProbePreviewView(theme: themes.theme)
                Divider()
                SpikeView()
                Divider()
                ChoreTradeView(theme: themes.theme)
                Divider()
                MovementTradePreviewView(theme: themes.theme)
                Divider()
                AboutView(themes: themes)
            }
            .padding()
        }
    }
}
