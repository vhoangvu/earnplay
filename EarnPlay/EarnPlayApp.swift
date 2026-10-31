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
    var body: some Scene {
        WindowGroup {
            ContentView(syncController: syncController)
                .onAppear { syncController.startIfNeeded() }
        }
    }
}

struct ContentView: View {
    @StateObject private var downloadModel = ModelDownloadViewModel()
    @StateObject private var setup = SetupFlowViewModel.makeDefault()
    /// Shared sync; the practice engine enqueues into its outbox
    /// instance and notifies its service after each durable enqueue.
    /// Observed (issue #65) so the pairing-request sheet presents
    /// whenever the controller holds a pending request.
    @ObservedObject var syncController: ChildSyncController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if downloadModel.isReady {
                if setup.step == .complete, !setup.summaryDismissed {
                    SetupCompleteView(viewModel: setup)
                } else if setup.step == .complete {
                    // Main practice screen (T1.8): the chat conversation.
                    // Band B (grade 4) demo engine over T1.2/T1.3 APIs.
                    // Practice recording (issue #63): the production
                    // SessionLog producer — per-question detail + effort
                    // snapshot, enqueued into the shared sync outbox
                    // (same instance the service drains, never a second
                    // writer over the same directory) and delivered via
                    // notifySessionEnqueued after each durable enqueue.
                    ChatConversationView(engine: DemoTutorEngine(
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
                            })))
                } else {
                    SetupFlowView(viewModel: setup)
                }
            } else {
                ModelDownloadView(viewModel: downloadModel)
            }
        }
        .task {
            downloadModel.refreshIfNeeded()
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
                ReadAloudPreviewView()
                Divider()
                SimulatedShieldDemoView()
                Divider()
                StallProbePreviewView()
                Divider()
                SpikeView()
                Divider()
                ChoreTradeView()
                Divider()
                MovementTradePreviewView()
                Divider()
                AboutView()
            }
            .padding()
        }
    }
}
