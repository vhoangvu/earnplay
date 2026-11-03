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
    /// The admin app's current theme, passed from the app root (same
    /// pattern as `DashboardView`) so this page follows the
    /// Version-tab picker. Defaults to the default theme for previews.
    /// Row text and cell backgrounds stay adaptive system: fixed theme
    /// inks on system cells would wash out in Dark Mode (the dashboard
    /// cards pair theme text with fixed light fills for the same
    /// reason). The theme shows in the control tint, the Save chrome,
    /// and the button radius below.
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme
    /// Finding 7: invoked after a successful save so the app-scope
    /// sync service flushes the queued policy immediately.
    var onPolicySaved: (() -> Void)? = nil
    @State private var store = PolicyStore()
    @State private var queue = PolicyUpdateQueue()
    @State private var state = PolicyEditorState()

    init(theme: DesignSystem.Theme = DesignSystem.defaultTheme,
         onPolicySaved: (() -> Void)? = nil) {
        self.theme = theme
        self.onPolicySaved = onPolicySaved
    }

    var body: some View {
        NavigationStack {
            Form {
                versionSection
                appListSection(
                    title: "Always allowed",
                    footnote: "Never blocked. Defaults: Phone, Messages, EarnPlay itself.",
                    apps: $state.draft.alwaysAllowed
                )
                appListSection(
                    title: "Unblockable",
                    footnote: "Locked by default; the ONLY apps a completed challenge can open.",
                    apps: $state.draft.unblockable
                )
                appListSection(
                    title: "Never-unlockable overrides",
                    footnote: "Stay locked with no challenge offered, even if unblockable.",
                    apps: $state.draft.neverUnlockableOverrides
                )
                unlockDurationsSection
                effortFloorSection
                tradeCapsSection
                chorePoolSection
                movementSection
                saveSection
            }
            // Steppers, toggles, and control chrome take the theme
            // accent instead of system blue, in both appearances. The
            // plain row actions ("Add chore", the app-list "Add") carry
            // their own adaptive ink below: accent text is 1.81:1 on
            // light cells.
            .tint(theme.tokens.accent.color)
            .navigationTitle("Policy Editor")
            .task { reload() }
        }
    }

    // MARK: - Version

    private var versionSection: some View {
        Section("Version") {
            Text("Current version: \(state.baseVersion)")
            Text("Saving creates version \(state.baseVersion + 1)")
                .foregroundStyle(.secondary)
            Text("Updates queued for sync: \(state.pendingCount)")
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
                "Practice-earned unlock: \(state.draft.unlockDurations.practiceMinutes) min",
                value: $state.draft.unlockDurations.practiceMinutes,
                in: 1 ... 240
            )
            Stepper(
                "Trade unlock: \(state.draft.unlockDurations.tradeMinutes) min",
                value: $state.draft.unlockDurations.tradeMinutes,
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
                "Minimum genuine attempts: \(state.draft.effortFloorSettings.minGenuineAttempts)",
                value: $state.draft.effortFloorSettings.minGenuineAttempts,
                in: 0 ... 20
            )
            Stepper(
                "Minimum hint / follow-up interactions: \(state.draft.effortFloorSettings.minHintOrFollowUpInteractions)",
                value: $state.draft.effortFloorSettings.minHintOrFollowUpInteractions,
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
                "Max trade offers per session: \(state.draft.tradeCaps.maxTradesPerSession)",
                value: $state.draft.tradeCaps.maxTradesPerSession,
                in: 0 ... 10
            )
            Stepper(
                "Weekly max movement trades: \(state.draft.tradeCaps.weeklyMaxMovementTrades)",
                value: $state.draft.tradeCaps.weeklyMaxMovementTrades,
                in: 0 ... 21
            )
            Stepper(
                "Weekly max chore trades: \(state.draft.tradeCaps.weeklyMaxChoreTrades)",
                value: $state.draft.tradeCaps.weeklyMaxChoreTrades,
                in: 0 ... 21
            )
        } header: { Text("Trade caps") } footer: {
            Text("Suggested weekly movement range: 2–3.")
        }
    }

    // MARK: - Chore pool

    private var chorePoolSection: some View {
        Section {
            if state.draft.chorePool.isEmpty {
                Text("No chores. The AI can only offer parent-stocked chores.")
                    .foregroundStyle(.secondary)
            }
            ForEach(state.draft.chorePool.indices, id: \.self) { index in
                DisclosureGroup(state.draft.chorePool[index].chore.isEmpty
                    ? "Chore \(index + 1)" : state.draft.chorePool[index].chore) {
                    TextField("Chore", text: $state.draft.chorePool[index].chore)
                        // Stable handle for the issue #71 walkthrough
                        // (one per expanded chore row). No behavior change.
                        .accessibilityIdentifier("policyChoreNameField")
                    Stepper(
                        "Unlock minutes: \(state.draft.chorePool[index].unlockMinutes)",
                        value: $state.draft.chorePool[index].unlockMinutes,
                        in: 1 ... 240
                    )
                    DatePicker(
                        "Expiry",
                        selection: $state.draft.chorePool[index].expiry,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Stepper(
                        "Weekly cap: \(state.draft.chorePool[index].weeklyCap)",
                        value: $state.draft.chorePool[index].weeklyCap,
                        in: 0 ... 21
                    )
                    Picker(
                        "Verification",
                        selection: $state.draft.chorePool[index].verificationMode
                    ) {
                        Text("Parent confirms").tag(ChoreVerificationMode.parentConfirm)
                        Text("Photo proof (async)").tag(ChoreVerificationMode.photoAsync)
                    }
                }
            }
            .onDelete { state.draft.chorePool.remove(atOffsets: $0) }
            Button("Add chore") {
                state.draft.chorePool.append(ChorePoolEntry(
                    chore: "",
                    unlockMinutes: 10,
                    expiry: Calendar.current.date(
                        byAdding: .day, value: 7, to: Date()
                    ) ?? Date(timeIntervalSinceNow: 7 * 24 * 3600),
                    weeklyCap: 2,
                    verificationMode: .parentConfirm
                ))
            }
            // Adaptive ink, NOT the form's accent tint: the Light Pink
            // accent is 1.81:1 on light cells (the picker-checkmark
            // precedent). Default-style Button tint overrides
            // .foregroundStyle(.primary); .foregroundColor(.primary)
            // survives and reads in both appearances.
            .foregroundColor(.primary)
            // Stable handle for the issue #71 walkthrough.
            // No behavior change.
            .accessibilityIdentifier("policyAddChoreButton")
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
                "Max repetitions: \(state.draft.movementSettings.maxReps)",
                value: $state.draft.movementSettings.maxReps,
                in: 1 ... 500
            )
            Stepper(
                "Movement trade unlock: \(state.draft.movementSettings.tradeUnlockDurationMinutes) min",
                value: $state.draft.movementSettings.tradeUnlockDurationMinutes,
                in: 1 ... 240
            )
        } header: { Text("Movement trade") } footer: {
            Text("Activities the AI may offer. Movement unlocks are shorter than practice-earned unlocks.")
        }
    }

    private func activityBinding(for activity: MovementActivity) -> Binding<Bool> {
        Binding(
            get: { state.draft.movementSettings.allowedActivities.contains(activity) },
            set: { enabled in
                if enabled, !state.draft.movementSettings.allowedActivities.contains(activity) {
                    state.draft.movementSettings.allowedActivities.append(activity)
                } else if !enabled {
                    state.draft.movementSettings.allowedActivities.removeAll { $0 == activity }
                }
            }
        )
    }

    // MARK: - Save

    private var saveSection: some View {
        Section {
            // Primary action on the accent chrome: the label takes the
            // resolved readable ink (the chat Send pattern), and the
            // chrome takes the theme's button radius.
            Button("Save (creates version \(state.baseVersion + 1))") { save() }
                .buttonStyle(.borderedProminent)
                .tint(theme.tokens.accent.color)
                .foregroundStyle(theme.childTextOnChildBackground.color)
                .buttonBorderShape(.roundedRectangle(radius: theme.buttonRadius))
                .disabled(!state.isLoaded)
                // Stable handle for the issue #71 walkthrough; the label
                // carries the dynamic next version. No behavior change.
                .accessibilityIdentifier("policySaveButton")
            Button("Discard changes", role: .destructive) { reload() }
                .disabled(!state.isLoaded)
            if !state.statusText.isEmpty {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Stable handle for the issue #71 walkthrough.
                    // No behavior change.
                    .accessibilityIdentifier("policySaveStatus")
            }
            if !state.errorText.isEmpty {
                Text(state.errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    // Stable handle for the issue #71 walkthrough.
                    // No behavior change.
                    .accessibilityIdentifier("policySaveError")
            }
        } header: { Text("Version") } footer: {
            Text("Saving queues the new version for delivery to the child app at the next sync (T4.6).")
        }
    }

    // MARK: - Load / save

    private func reload() {
        state.reload(adminStore: store, queue: queue)
    }

    private func save() {
        state.save(adminStore: store, queue: queue)
        if state.errorText.isEmpty { onPolicySaved?() }
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
                // Same adaptive ink as "Add chore": the form's accent
                // tint is 1.81:1 as text on light cells. Default-style
                // Button tint overrides .foregroundStyle(.primary);
                // .foregroundColor(.primary) survives.
                .foregroundColor(.primary)
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
