import Combine
import SwiftUI
import EarnPlayCore

/// Demo state for the T2.4 simulated shields section.
///
/// Holds one `ShieldManager` over a sandboxed demo policy/window store
/// (`Application Support/EarnPlay/SimulatedDemo/`, separate from any
/// real policy cache) fronting a `SimulatedShieldBackend`, plus one
/// `SimulatedShieldFlow` per tapped demo app. Unlocks use the demo
/// policy's practice duration. Decision logging is demo-scoped too: one
/// `DecisionLogger` over the same isolated directory, so demo grants
/// and denials never touch production logging. Nothing here touches
/// ManagedSettings or FamilyControls; real enforcement needs the T0.4
/// entitlement (v1, not filed).
@MainActor
final class SimulatedShieldDemoState: ObservableObject {
    struct DemoApp {
        let ref: AppRef
        let category: AppCategoryRef
        let name: String
    }

    private let policyStore: PolicyStore
    private let manager: ShieldManager
    private let backend = SimulatedShieldBackend()
    private let decisionLogger: DecisionLogger
    private var flows: [String: SimulatedShieldFlow] = [:]

    let apps: [DemoApp] = [
        DemoApp(
            ref: AppRef(id: "earnplay.demo.game"),
            category: AppCategoryRef(id: "games"),
            name: "Demo Game"
        ),
        DemoApp(
            ref: AppRef(id: "earnplay.demo.video"),
            category: AppCategoryRef(id: "entertainment"),
            name: "Demo Video"
        ),
    ]

    @Published var activeAppID: String?

    /// - Parameter directory: Policy/window/decision-log store root.
    ///   Defaults to the persistent demo path; tests inject a temporary
    ///   directory.
    init(directory: URL? = nil) {
        let directory = directory ?? PolicyStore.defaultDirectory()
            .appendingPathComponent("SimulatedDemo", isDirectory: true)
        self.decisionLogger = DecisionLogger(directory: directory)
        let store = PolicyStore(directory: directory)
        if store.storedVersion == 0 {
            _ = store.apply(Policy(
                version: 1,
                alwaysAllowed: [.phone, .messages, .earnPlaySelf],
                unblockable: apps.map(\.ref),
                neverUnlockableOverrides: [],
                unlockDurations: .default,
                effortFloorSettings: .default,
                tradeCaps: .default,
                chorePool: [],
                movementSettings: .default
            ))
        }
        self.policyStore = store
        self.manager = ShieldManager(
            policyStore: store,
            enumeration: ShieldEnumeration(
                apps: apps.map { EnumeratedApp(app: $0.ref, category: $0.category) },
                categories: Set(apps.map(\.category))
            ),
            backend: backend,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    /// Selects a demo app, creating its challenge flow on first tap and
    /// refreshing a cached flow so re-selecting never shows stale unlock
    /// state (the flows share one manager, so another app's unlock ends
    /// this app's window without ticking this flow).
    func select(_ id: String, isSimulatedMode: Bool) {
        flow(for: id, isSimulatedMode: isSimulatedMode)?.tick()
        activeAppID = id
    }

    /// The challenge flow for a demo app, created on demand.
    func flow(for id: String, isSimulatedMode: Bool) -> SimulatedShieldFlow? {
        if let existing = flows[id] { return existing }
        guard let entry = apps.first(where: { $0.ref.id == id }) else { return nil }
        let minutes = policyStore.currentPolicy.unlockDurations.practiceMinutes
        let flow = SimulatedShieldFlow(
            manager: manager,
            backend: backend,
            app: entry.ref,
            category: entry.category,
            scorer: EffortScorer(),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: TimeInterval(minutes) * 60,
            isSimulatedMode: isSimulatedMode,
            decisionLogger: decisionLogger,
            decisionDurationMinutes: minutes
        )
        flows[id] = flow
        return flow
    }

    /// Drops all flows (e.g. when the debug toggle flips).
    func resetFlows() {
        flows = [:]
        activeAppID = nil
    }
}

/// Host for one demo app's flow: shows the unlocked state with a live
/// countdown and presents the blocking shield screen while the flow
/// reports the app shielded. Ticks the flow every second so the
/// countdown stays live and expiry re-presents.
struct SimulatedShieldCoverHost: View {
    @ObservedObject var flow: SimulatedShieldFlow
    /// The app's current theme, forwarded to the presented shield so
    /// a theme switch re-renders it (fix-4 item 7). Defaults to
    /// the default theme for previews.
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if flow.isShieldPresented {
                Text("Locked (simulated) — complete the challenge to unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simulatedLockedLabel")
            } else {
                Text("Unlocked (simulated) — \(Int(flow.remainingUnlockTime))s left")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("unlockCountdownLabel")
            }
        }
        .fullScreenCover(
            isPresented: Binding(get: { flow.isShieldPresented }, set: { _ in }),
            content: { SimulatedShieldView(flow: flow, theme: theme) }
        )
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            flow.tick()
        }
    }
}

/// Demo section for simulated shields (T2.4): the debug-settings toggle
/// forcing simulated mode, tappable locked-app entries, and the
/// unlocked countdown. Manual steps (toggle on, tap entry, complete
/// challenge, countdown visible, expiry re-locks) are manual-only and
/// unverified unless actually run on device.
struct SimulatedShieldDemoView: View {
    @StateObject private var demo = SimulatedShieldDemoState()
    @AppStorage(SimulatedShieldMode.forceUserDefaultsKey) private var forceSimulated = false
    /// The app's current theme, forwarded through the cover host to
    /// the shield (fix-4 item 7). Defaults to the default theme for previews.
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme

    private var simulatedOn: Bool { SimulatedShieldMode.isForced() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Simulated shields (T2.4 demo)")
                .font(.headline)
            Toggle("Force simulated shields (demo)", isOn: $forceSimulated)
                .accessibilityIdentifier("forceSimulatedToggle")
            if !simulatedOn {
                Text("Simulated shields OFF — nothing is blocked in this build. Real enforcement needs the T0.4 entitlement (v1, not filed).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("simulatedOffLabel")
            } else {
                ForEach(demo.apps, id: \.ref.id) { entry in
                    Button("Locked app (simulated): \(entry.name)") {
                        demo.select(entry.ref.id, isSimulatedMode: true)
                    }
                    .accessibilityIdentifier("lockedAppEntry-\(entry.ref.id)")
                }
                if let id = demo.activeAppID,
                   let flow = demo.flow(for: id, isSimulatedMode: true) {
                    SimulatedShieldCoverHost(flow: flow, theme: theme)
                }
            }
        }
        .padding()
        .onChange(of: forceSimulated) { _, _ in demo.resetFlows() }
    }
}
