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
    @StateObject private var setup = SetupFlowViewModel.makeDefault()

    var body: some View {
        if setup.step == .complete {
            mainPlaceholder
        } else {
            SetupFlowView(viewModel: setup)
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
                SpikeView()
            }
            .padding()
        }
    }
}
