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

/// Running version + operator rollback (T5.3 F3/F4). Reads and
/// writes the PERSISTED production registry
/// (`VersionRegistry.production()`, Application Support store) —
/// never a fresh in-memory registry — so a selection made through
/// any registry instance backed by the same store is what this
/// panel shows, and the buttons below perform a real rollback on
/// that persisted registry.
struct AdminVersionView: View {
    @State private var registry: VersionRegistry?
    @State private var activeBundle: VersionBundle?
    @State private var bundles: [VersionBundle] = []
    @State private var statusText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("EarnPlay Admin")
                    .font(.largeTitle.bold())
                Text("Parent dashboard placeholder — core v\(EarnPlayCore.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Running version (persisted registry)")
                    .font(.headline)
                if let activeBundle {
                    Text("Active bundle: \(activeBundle.bundleID)")
                        .font(.body)
                    Text("Model: \(activeBundle.modelVersion)")
                        .font(.body)
                    Text("Prompt: \(activeBundle.promptVersion)")
                        .font(.body)
                } else {
                    Text("Version unavailable — persisted registry could not be loaded.")
                        .font(.body)
                }
                Divider()
                Text("Rollback operator controls")
                    .font(.headline)
                Button("Register active bundle as previous known-good") {
                    perform { try registry?.registerActiveAsPreviousKnownGood() }
                }
                Button("Roll back to previous known-good") {
                    perform { try registry?.rollbackToPreviousKnownGood() }
                }
                Button("Roll forward to current") {
                    perform { try registry?.select(bundleID: "current") }
                }
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Registered bundles: \(bundles.map(\.bundleID).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            let loaded = try VersionRegistry.production()
            registry = loaded
            refresh(loaded)
        } catch {
            statusText = "Failed to load registry: \(String(describing: error))"
        }
    }

    private func refresh(_ registry: VersionRegistry) {
        activeBundle = registry.activeBundle
        bundles = registry.registeredBundles
    }

    private func perform(_ action: () throws -> Void) {
        guard let registry else { reload(); return }
        do {
            try action()
            refresh(registry)
            statusText = "Done. Active bundle is now \(registry.activeBundleID)."
        } catch {
            statusText = "Failed: \(String(describing: error))"
        }
    }
}
