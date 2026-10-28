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
    @State private var isBusy = false

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
                    perform { reg in try reg.registerActiveAsPreviousKnownGood() }
                }
                .disabled(isBusy)
                Button("Roll back to previous known-good") {
                    perform { reg in try reg.rollbackToPreviousKnownGood() }
                }
                .disabled(isBusy)
                Button("Roll forward to current") {
                    perform { reg in try reg.select(bundleID: "current") }
                }
                .disabled(isBusy)
                if isBusy {
                    Text("Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .task { await reload() }
    }

    /// Round 4 F8/F4: registry load (model hashing) and snapshot
    /// copies run off the main actor; throwing reads propagate
    /// reload failures to the panel instead of showing stale data.
    private func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let (loaded, active, all) = try await Task.detached(priority: .userInitiated) {
                let r = try VersionRegistry.production()
                return (r, try r.activeBundle, try r.registeredBundles)
            }.value
            registry = loaded
            activeBundle = active
            bundles = all
        } catch {
            activeBundle = nil
            bundles = []
            statusText = "Failed to load registry: \(String(describing: error))"
        }
    }

    private func perform(_ action: @escaping @Sendable (VersionRegistry) throws -> Void) {
        guard !isBusy else { return }
        guard let registry else { Task { await reload() }; return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let (active, all, activeID) = try await Task.detached(priority: .userInitiated) {
                    try action(registry)
                    return (try registry.activeBundle, try registry.registeredBundles,
                            try registry.activeBundleID)
                }.value
                activeBundle = active
                bundles = all
                statusText = "Done. Active bundle is now \(activeID)."
            } catch {
                statusText = "Failed: \(String(describing: error))"
            }
        }
    }
}
