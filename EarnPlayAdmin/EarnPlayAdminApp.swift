import SwiftUI
import EarnPlayCore

@main
struct EarnPlayAdminApp: App {
    var body: some Scene {
        WindowGroup {
            AdminVersionView()
        }
    }
}

/// Running model + prompt version and the known-limits note for that
/// version (T5.3, LLD section 10.3). Reads the production version
/// registry in EarnPlayCore, so what this screen shows is exactly what
/// new sessions stamp — one source of truth, no copied strings.
struct AdminVersionView: View {
    private var bundle: VersionBundle? {
        try? VersionRegistry.production().activeBundle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("EarnPlay Admin")
                    .font(.largeTitle.bold())
                Text("Parent dashboard placeholder — core v\(EarnPlayCore.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Running version")
                    .font(.headline)
                if let bundle {
                    Text("Model: \(bundle.modelVersion)")
                        .font(.body)
                    Text("Prompt: \(bundle.promptVersion)")
                        .font(.body)
                } else {
                    // Unreachable today: production() only throws on an
                    // empty derived version, which the build constants
                    // never produce. Shown honestly instead of a guess.
                    Text("Version unavailable — this build defines no model/prompt version.")
                        .font(.body)
                }
                Divider()
                Text("Known limits")
                    .font(.headline)
                ForEach(VersionKnownLimits.notes, id: \.self) { note in
                    Text("• \(note)")
                        .font(.subheadline)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
