import SwiftUI
import EarnPlayCore

@main
struct EarnPlayApp: App {
    /// App-scope child sync (issue #63 fix 3), mirroring the admin app:
    /// one shared service, retained for the app's life, started on
    /// launch — delivery no longer depends on any debug screen.
    @State private var syncController = ChildSyncController()
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
    let syncController: ChildSyncController

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
                            policyVersion: { [policyStore = syncController.policyStore] in
                                policyStore.storedVersion
                            },
                            onSessionEnqueued: { [service = syncController.service] in
                                service.notifySessionEnqueued()
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
