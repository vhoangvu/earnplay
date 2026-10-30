import SwiftUI
import EarnPlayCore

/// App-scope admin sync (finding 6): owned and started by the app,
/// independently of the selected tab, and retained for the app's life.
final class AdminSyncController {
    let sessionStore = SessionLogStore()
    let policyQueue = PolicyUpdateQueue()
    // Round 4 (M7): persisted installation identity, pairing, and
    // secret — the same device across relaunches.
    let pairing = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Admin",
                                                    key: "earnplay.pairing.admin.v1")
    let transport: MultipeerSyncTransport
    let service: AdminSyncService
    /// Separate admin-app auditor instance (T4.5), distinct from the
    /// child-app tutor runtime. Advisory only.
    lazy var auditor = AdminAuditorController(sessionStore: sessionStore)
    private var started = false
    init() {
        transport = MultipeerSyncTransport(role: .browser, displayName: "EarnPlay-Admin", pairing: pairing)
        service = AdminSyncService(policyQueue: policyQueue, sessionStore: sessionStore,
                                   transport: transport, pairing: pairing)
    }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        // Audit immediately after a session is successfully stored
        // (item 5). Separate from onSnapshotChange, which SessionsView
        // owns; findings publish via AdminAuditorController.openFlags.
        service.onSessionStored = { [weak self] _ in self?.auditor.runAudit() }
        service.start()
        // Auditor runs at sync time over already-synced logs.
        auditor.runAudit()
    }
    /// Reset/Unpair (round 4, M7): clears pairing + secret on both
    /// the gate (persisted) and the live transport session.
    func unpair() {
        transport.unpair()
        service.flushPending()
    }
}

@main
struct EarnPlayAdminApp: App {
    @State private var syncController = AdminSyncController()
    @State private var selectedTab = 0
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                PolicyEditorView(onPolicySaved: { syncController.service.notifyPolicyEnqueued() })
                    .tabItem { Label("Policy", systemImage: "lock.shield") }
                    .tag(0)
                SessionsView(controller: syncController)
                    .tabItem { Label("Sessions", systemImage: "arrow.triangle.2.circlepath") }
                    .tag(1)
                AuditorView(auditor: syncController.auditor, onOpenPolicy: { selectedTab = 0 })
                    .tabItem { Label("Auditor", systemImage: "checkmark.shield") }
                    .tag(2)
                AdminVersionView()
                    .tabItem { Label("Version", systemImage: "info.circle") }
                    .tag(3)
            }
            .onAppear { syncController.startIfNeeded() }
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
                    Text("Model: \(ModelRuntime.reportedModelVersion(storedModelVersion: activeBundle.modelVersion))")
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
                AdminVersionView.installLoadValidator(on: r)
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

    /// Round 5 F9: a candidate must load before selection commits.
    static func installLoadValidator(on registry: VersionRegistry) {
        registry.candidateLoadValidator = { artifacts in
            guard let url = artifacts.modelURL else {
                throw VersioningError.artifactUnavailable(bundleID: "candidate", artifact: "modelFile")
            }
            try ModelRuntime(modelPath: url,
                             expectedContentDigest: artifacts.modelContentDigest).load()
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
