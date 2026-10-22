import SwiftUI
import EarnPlayCore

@main
struct EarnPlayAdminApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("EarnPlay Admin")
                    .font(.largeTitle.bold())
                Text("Parent dashboard placeholder — core v\(EarnPlayCore.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
