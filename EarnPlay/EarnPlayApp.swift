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

    var body: some View {
        Group {
            if downloadModel.isReady {
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
            } else {
                ModelDownloadView(viewModel: downloadModel)
            }
        }
        .task {
            downloadModel.refresh()
        }
    }
}
