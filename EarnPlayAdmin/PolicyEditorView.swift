import SwiftUI
import EarnPlayCore

/// Parent-facing editor for every LLD §2.1 policy field (T4.1).
///
/// Sections check off the LLD field list one by one: always-allowed
/// apps, the unblockable list, never-unlockable overrides, unlock
/// durations, effort floor settings, trade caps, the chore pool
/// (chore, unlock minutes, expiry, weekly cap, verification mode),
/// and movement-trade settings. Saving stamps `current version + 1`,
/// persists the admin's copy, and queues the `PolicyUpdate` for T4.6
/// sync; the version line shows the increment immediately.
struct PolicyEditorView: View {
    @State private var store = PolicyStore()
    @State private var queue = PolicyUpdateQueue()
    @State private var draft = Policy.defaultPolicy
    @State private var baseVersion = 0
    @State private var pendingCount = 0
    @State private var statusText = ""
    @State private var errorText = ""
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                versionSection
                appListSection(
                    title: "Always allowed",
                    footnote: "Never blocked. Defaults: Phone, Messages, EarnPlay itself.",
                    apps: $draft.alwaysAllowed
                )
                appListSection(
                    title: "Unblockable",
                    footnote: "Locked by default; the ONLY apps a completed challenge can open.",
                    apps: $draft.unblockable
                )
                appListSection(
                    title: "Never-unlockable overrides",
                    footnote: "Stay locked with no challenge offered, even if unblockable.",
                    apps: $draft.neverUnlockableOverrides
                )
                unlockDurationsSection
                effortFloorSection
                tradeCapsSection
                chorePoolSection
                movementSection
                saveSection
            }
            .navigationTitle("Policy Editor")
            .task { reload() }
        }
    }

    // MARK: - Version

    private var versionSection: some View {
        Section("Version") {
            Text("Current version: \(baseVersion)")
            Text("Saving creates version \(baseVersion + 1)")
                .foregroundStyle(.secondary)
            Text("Updates queued for sync: \(pendingCount)")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - App lists

    private func appListSection(
        title: String,
        footnote: String,
        apps: Binding<[AppRef]>
    ) -> some View {
        AppListSection(title: title, footnote: footnote, apps: apps)
    }

    // MARK: - Unlock durations

    private var unlockDurationsSection: some View {
        Section {
            Stepper(
                "Practice-earned unlock: \(draft.unlockDurations.practiceMinutes) min",
                value: $draft.unlockDurations.practiceMinutes,
                in: 1 ... 240
            )
            Stepper(
                "Trade unlock: \(draft.unlockDurations.tradeMinutes) min",
                value: $draft.unlockDurations.tradeMinutes,
                in: 1 ... 240
            )
        } header: { Text("Unlock durations") } footer: {
            Text("Trade unlocks are shorter than practice-earned unlocks (default 15 vs 30).")
        }
    }

    // MARK: - Effort floor

    private var effortFloorSection: some View {
        Section {
            Stepper(
                "Minimum genuine attempts: \(draft.effortFloorSettings.minGenuineAttempts)",
                value: $draft.effortFloorSettings.minGenuineAttempts,
                in: 0 ... 20
            )
            Stepper(
                "Minimum hint / follow-up interactions: \(draft.effortFloorSettings.minHintOrFollowUpInteractions)",
                value: $draft.effortFloorSettings.minHintOrFollowUpInteractions,
                in: 0 ... 20
            )
        } header: { Text("Effort floor") } footer: {
            Text("Below the floor, no amount of time unlocks.")
        }
    }

    // MARK: - Trade caps

    private var tradeCapsSection: some View {
        Section {
            Stepper(
                "Max trade offers per session: \(draft.tradeCaps.maxTradesPerSession)",
                value: $draft.tradeCaps.maxTradesPerSession,
                in: 0 ... 10
            )
            Stepper(
                "Weekly max movement trades: \(draft.tradeCaps.weeklyMaxMovementTrades)",
                value: $draft.tradeCaps.weeklyMaxMovementTrades,
                in: 0 ... 21
            )
            Stepper(
                "Weekly max chore trades: \(draft.tradeCaps.weeklyMaxChoreTrades)",
                value: $draft.tradeCaps.weeklyMaxChoreTrades,
                in: 0 ... 21
            )
        } header: { Text("Trade caps") } footer: {
            Text("Suggested weekly movement range: 2–3.")
        }
    }

    // MARK: - Chore pool

    private var chorePoolSection: some View {
        Section {
            if draft.chorePool.isEmpty {
                Text("No chores. The AI can only offer parent-stocked chores.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.chorePool.indices, id: \.self) { index in
                DisclosureGroup(draft.chorePool[index].chore.isEmpty
                    ? "Chore \(index + 1)" : draft.chorePool[index].chore) {
                    TextField("Chore", text: $draft.chorePool[index].chore)
                    Stepper(
                        "Unlock minutes: \(draft.chorePool[index].unlockMinutes)",
                        value: $draft.chorePool[index].unlockMinutes,
                        in: 1 ... 240
                    )
                    DatePicker(
                        "Expiry",
                        selection: $draft.chorePool[index].expiry,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper(
                        "Weekly cap: \(draft.chorePool[index].weeklyCap)",
                        value: $draft.chorePool[index].weeklyCap,
                        in: 0 ... 21
                    )
                    Picker(
                        "Verification",
                        selection: $draft.chorePool[index].verificationMode
                    ) {
                        Text("Parent confirms").tag(ChoreVerificationMode.parentConfirm)
                        Text("Photo proof (async)").tag(ChoreVerificationMode.photoAsync)
                    }
                }
            }
            .onDelete { draft.chorePool.remove(atOffsets: $0) }
            Button("Add chore") {
                draft.chorePool.append(ChorePoolEntry(
                    chore: "",
                    unlockMinutes: 10,
                    expiry: Calendar.current.date(
                        byAdding: .day, value: 7, to: Date()
                    ) ?? Date(timeIntervalSinceNow: 7 * 24 * 3600),
                    weeklyCap: 2,
                    verificationMode: .parentConfirm
                ))
            }
        } header: { Text("Chore pool") } footer: {
            Text("Offers are unusable after expiry. Photo-async grants on trust; the parent reviews later and can revoke.")
        }
    }

    // MARK: - Movement settings

    private var movementSection: some View {
        Section {
            ForEach(MovementActivity.allCases, id: \.self) { activity in
                Toggle(
                    activity.displayName,
                    isOn: activityBinding(for: activity)
                )
            }
            Stepper(
                "Max repetitions: \(draft.movementSettings.maxReps)",
                value: $draft.movementSettings.maxReps,
                in: 1 ... 500
            )
            Stepper(
                "Movement trade unlock: \(draft.movementSettings.tradeUnlockDurationMinutes) min",
                value: $draft.movementSettings.tradeUnlockDurationMinutes,
                in: 1 ... 240
            )
        } header: { Text("Movement trade") } footer: {
            Text("Activities the AI may offer. Movement unlocks are shorter than practice-earned unlocks.")
        }
    }

    private func activityBinding(for activity: MovementActivity) -> Binding<Bool> {
        Binding(
            get: { draft.movementSettings.allowedActivities.contains(activity) },
            set: { enabled in
                if enabled, !draft.movementSettings.allowedActivities.contains(activity) {
                    draft.movementSettings.allowedActivities.append(activity)
                } else if !enabled {
                    draft.movementSettings.allowedActivities.removeAll { $0 == activity }
                }
            }
        )
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            Button("Save (creates version \(baseVersion + 1))") { save() }
                .disabled(!isLoaded)
            Button("Discard changes", role: .destructive) { reload() }
                .disabled(!isLoaded)
            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: { Text("Version") } footer: {
            Text("Saving queues the new version for delivery to the child app at the next sync (T4.6).")
        }
    }

    // MARK: - Load / save

    private func reload() {
        // Deliver a save interrupted between the policy write and the
        // queue write (relaunch recovery, no manual re-save needed).
        PolicyEditorSave.recoverInterruptedSave(adminStore: store, queue: queue)
        let current = store.currentPolicy
        draft = current
        baseVersion = current.version
        pendingCount = queue.pendingUpdates().count
        errorText = ""
        isLoaded = true
    }

    private func save() {
        errorText = ""
        do {
            let (update, _) = try PolicyEditorSave.save(
                draft: draft, adminStore: store, queue: queue
            )
            draft = update
            baseVersion = update.version
            pendingCount = queue.pendingUpdates().count
            statusText = "Saved version \(update.version) — queued for sync (\(pendingCount) pending)."
        } catch {
            errorText = "Save failed: \(String(describing: error))"
        }
    }
}

/// One editable app-reference list (always-allowed, unblockable, or
/// never-unlockable). App references are opaque identifiers chosen when
/// the parent picks the app; T2.3's setup flow maps them to tokens.
private struct AppListSection: View {
    let title: String
    let footnote: String
    @Binding var apps: [AppRef]
    @State private var newAppID = ""

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(apps, id: \.self) { app in
                Text(AppListSection.displayName(for: app))
            }
            .onDelete { apps.remove(atOffsets: $0) }
            HStack {
                TextField("App ID (e.g. com.example.game)", text: $newAppID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") {
                    let id = newAppID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty, !apps.contains(AppRef(id: id)) else { return }
                    apps.append(AppRef(id: id))
                    newAppID = ""
                }
                .disabled(newAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: { Text(title) } footer: {
            Text(footnote)
        }
    }

    private static func displayName(for app: AppRef) -> String {
        switch app {
        case .phone: "Phone (built-in)"
        case .messages: "Messages (built-in)"
        case .earnPlaySelf: "EarnPlay (built-in)"
        default: app.id
        }
    }
}

private extension MovementActivity {
    var displayName: String {
        switch self {
        case .jumpingJacks: "Jumping jacks"
        case .runningInPlace: "Running in place"
        case .squats: "Squats"
        case .marchingInPlace: "Marching in place"
        }
    }
}
