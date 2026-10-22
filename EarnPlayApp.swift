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
    var body: some View {
        VStack(spacing: 12) {
            Text("EarnPlay")
                .font(.largeTitle.bold())
            Text("Tutor chat placeholder — core v\(EarnPlayCore.version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
