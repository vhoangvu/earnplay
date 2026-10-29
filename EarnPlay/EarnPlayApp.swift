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
                    mainPlaceholder
                } else {
                    SetupFlowView(viewModel: setup)
                }
            } else {
                ModelDownloadView(viewModel: downloadModel)
            }
        }
        .task {
            downloadModel.refresh()
        }
    }

    private var mainPlaceholder: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("EarnPlay")
                    .font(.largeTitle.bold())
                Text("Tutor chat placeholder — core v\(EarnPlayCore.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                ReadAloudPreviewView()
                Divider()
                StallProbePreviewView()
                Divider()
                SpikeView()
                Divider()
                MovementTradePreviewView()
                Divider()
                AboutView()
            }
            .padding()
        }
    }
}
