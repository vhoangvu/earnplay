import SwiftUI
import EarnPlayCore

@main
struct EarnPlayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var downloadModel = ModelDownloadViewModel()
    @StateObject private var setup = SetupFlowViewModel.makeDefault()

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
                    // snapshot, enqueued for the existing sync.
                    ChatConversationView(engine: DemoTutorEngine(
                        recording: .productionDefault()))
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
                SyncDebugView()
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
