import SwiftUI
import EarnPlayCore

/// The T2.3 first-run setup wizard in the child app.
///
/// Steps the parent through Screen Time authorization, picker
/// enumeration, the allowlist / unblockable split, and the
/// prevent-deleting-apps guidance, then commits the initial policy.
/// Every step is driven by the `SetupFlow` state machine: nothing can be
/// skipped, and an incomplete flow claims no protection.
public struct SetupFlowView: View {
    @ObservedObject var viewModel: SetupFlowViewModel
    /// The child app's theme store, passed from the app root so the
    /// setup-wide About sheet's picker drives the live app theme (the
    /// same app-scope binding `SetupCompleteView` uses).
    @ObservedObject var themes: ThemeStore
    @State private var showingAbout = false

    public init(viewModel: SetupFlowViewModel, themes: ThemeStore) {
        self.viewModel = viewModel
        self.themes = themes
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .authorization:
                    AuthorizationStepView(viewModel: viewModel)
                case .enumeration:
                    EnumerationStepView(viewModel: viewModel)
                case .selection:
                    SelectionStepView(viewModel: viewModel)
                case .preventDeletingGuidance:
                    PreventDeletingGuidanceView(viewModel: viewModel)
                case .complete:
                    // Unreachable in production (ContentView renders its
                    // own SetupCompleteView for `.complete` with the
                    // app-scope store); the fresh store reads the same
                    // persisted selection for previews and tests.
                    SetupCompleteView(viewModel: viewModel, themes: ThemeStore())
                }
            }
            .navigationTitle("Set up EarnPlay")
            .navigationBarTitleDisplayMode(.inline)
            // Setup-wide About/Demo entry (issue #87 fix round 1): the
            // download screen's About entry exists only while the model
            // is NOT ready and the completion screen's only at
            // `.complete`, so without this a model-ready install stuck in
            // setup — exactly a blocked TestFlight tester — can never
            // reach the simulate toggle. One toolbar item covers every
            // setup step; the toggle keeps its restart requirement.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("About & demo") {
                        showingAbout = true
                    }
                    .accessibilityIdentifier("setupAboutButton")
                }
            }
            .sheet(isPresented: $showingAbout) {
                NavigationStack {
                    ScrollView {
                        AboutView(themes: themes)
                            .padding()
                    }
                    .navigationTitle("About")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingAbout = false }
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.refreshAuthorizationStatus()
        }
    }
}

// MARK: - Step 1: authorization

private struct AuthorizationStepView: View {
    @ObservedObject var viewModel: SetupFlowViewModel
    @State private var isRequesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Allow Screen Time access")
                    .font(.title2.bold())
                if viewModel.isSimulatedMode {
                    SimulatedModeBadge()
                    Text("Simulated mode is on: requesting below grants " +
                        "simulated approval for the demo — not real Screen " +
                        "Time access.")
                        .font(.footnote)
                }
                Text("EarnPlay uses Screen Time to list this device's apps " +
                    "and to shield them outside earned unlocks. This step " +
                    "must be done on the child's device.")
                    .foregroundStyle(.secondary)
                if viewModel.needsReauthorization {
                    Text("Your completed setup is still saved. Approve Screen " +
                        "Time access again to restore protection — you won't " +
                        "need to pick apps again.")
                        .font(.footnote)
                }
                Button {
                    isRequesting = true
                    Task {
                        await viewModel.requestAuthorization()
                        isRequesting = false
                    }
                } label: {
                    if isRequesting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Request Screen Time access")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
                if let error = viewModel.authorizationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                SetupHonestyNote()
            }
            .padding()
        }
    }
}

// MARK: - Step 2: enumeration

private struct EnumerationStepView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the apps to manage")
                    .font(.title2.bold())
                Text("Pick every app EarnPlay should manage, plus the " +
                    "categories that backstop newly installed apps. On the " +
                    "next screen you choose which picked apps stay allowed " +
                    "and which can be earned back.")
                    .foregroundStyle(.secondary)
                if viewModel.usesSimulatedEnumeration {
                    SimulatedEnumerationPicker(viewModel: viewModel)
                } else {
                    Button("Select apps and categories") {
                        viewModel.isPickerPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text(pickedSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let error = viewModel.progressError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Continue") {
                    viewModel.continueFromEnumeration()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasEnumerationInput)
                Button("Start over", role: .destructive) {
                    viewModel.abandonSetup()
                }
                .font(.footnote)
                SetupHonestyNote()
            }
            .padding()
        }
        .familyActivityPicker(
            headerText: "Select every app EarnPlay should manage.",
            footerText: "Also select categories so newly installed apps stay shielded.",
            isPresented: $viewModel.isPickerPresented,
            selection: $viewModel.selection
        )
    }

    private var pickedSummary: String {
        let apps: Int
        let categories: Int
        if viewModel.usesSimulatedEnumeration {
            apps = viewModel.pickedSimulatedApps.count
            categories = viewModel.pickedSimulatedCategories.count
        } else {
            apps = viewModel.selection.applicationTokens.count
            categories = viewModel.selection.categoryTokens.count
        }
        if apps == 0 && categories == 0 {
            return "Nothing picked yet."
        }
        return "\(apps) app\(apps == 1 ? "" : "s"), " +
            "\(categories) categor\(categories == 1 ? "y" : "ies") picked."
    }
}

// MARK: - Simulated enumeration picker (forced mode)

/// Demo app/category multi-select for forced-mode setup (issue #87 fix
/// round 1): simulated approval never grants real FamilyControls
/// authorization, so the system picker cannot produce tokens on this
/// path. Picks feed the setup enumeration through the same
/// `continueFromEnumeration()` submission as tokens; the unforced flow
/// keeps the real picker exactly as-is.
private struct SimulatedEnumerationPicker: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulated mode is on: the system picker cannot list " +
                "apps without real Screen Time authorization, so pick " +
                "demo apps and categories below. Selections are " +
                "simulated — not real device apps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Demo apps")
                .font(.headline)
            ForEach(SimulatedSetupCatalog.apps) { app in
                Toggle(
                    isOn: binding(for: app.id, in: \.simulatedAppIDs)
                ) {
                    VStack(alignment: .leading) {
                        Text(app.name)
                        Text(app.category.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("simulatedAppPick-\(app.id)")
            }
            Text("Demo categories")
                .font(.headline)
            ForEach(SimulatedSetupCatalog.categories) { category in
                Toggle(
                    category.name,
                    isOn: binding(for: category.id, in: \.simulatedCategoryIDs)
                )
                .accessibilityIdentifier("simulatedCategoryPick-\(category.id)")
            }
        }
    }

    private func binding(
        for id: String,
        in keyPath: ReferenceWritableKeyPath<SetupFlowViewModel, Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel[keyPath: keyPath].contains(id) },
            set: { selected in
                if selected {
                    viewModel[keyPath: keyPath].insert(id)
                } else {
                    viewModel[keyPath: keyPath].remove(id)
                }
            }
        )
    }
}

// MARK: - Step 3: allowlist / unblockable split

private struct SelectionStepView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decide what each app does")
                .font(.title2.bold())
                .padding(.horizontal)
            Text("Allowed apps are never blocked. Earn apps stay blocked " +
                "until a completed challenge opens them. Everything else " +
                "stays blocked with no challenge offered.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack {
                Button("All Earn") { viewModel.setAllChoices(.unblockable) }
                Button("All Blocked") { viewModel.setAllChoices(.blocked) }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .padding(.horizontal)
            List {
                ForEach(viewModel.pickedApps) { app in
                    AppChoiceRow(viewModel: viewModel, appID: app.id) {
                        Label(app.token)
                    }
                }
                ForEach(viewModel.pickedSimulatedApps) { app in
                    AppChoiceRow(viewModel: viewModel, appID: app.id) {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.category.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !viewModel.pickedCategories.isEmpty
                    || !viewModel.pickedSimulatedCategories.isEmpty
                {
                    Section("Category backstop") {
                        ForEach(viewModel.pickedCategories) { category in
                            Label(category.token)
                        }
                        ForEach(viewModel.pickedSimulatedCategories) { category in
                            Text(category.name)
                        }
                        Text("Newly installed apps in these categories stay " +
                            "shielded until they are picked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            if let error = viewModel.progressError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            HStack {
                Button("Re-pick apps") {
                    viewModel.restartEnumeration()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Continue") {
                    viewModel.continueFromSelection()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            SetupHonestyNote()
                .padding(.horizontal)
        }
        .padding(.vertical)
    }
}

/// One app's Blocked/Earn/Allowed choice row (selection step),
/// shared by token-backed picks (whose title is the system token label)
/// and simulated picks (whose title is the catalog name). Extracted so
/// both paths render the identical control; no behavior change for the
/// token path.
private struct AppChoiceRow<Title: View>: View {
    @ObservedObject var viewModel: SetupFlowViewModel
    let appID: String
    @ViewBuilder let title: () -> Title

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title()
            Picker(
                "Choice",
                selection: Binding(
                    get: { viewModel.choices[appID] ?? .blocked },
                    set: { viewModel.choices[appID] = $0 }
                )
            ) {
                ForEach(SetupFlowViewModel.AppChoice.allCases) { choice in
                    Text(choice.shortLabel).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            Text((viewModel.choices[appID] ?? .blocked).explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Step 4: prevent-deleting-apps guidance

private struct PreventDeletingGuidanceView: View {
    @ObservedObject var viewModel: SetupFlowViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep EarnPlay from being deleted")
                    .font(.title2.bold())
                Text("Without this, EarnPlay — and its shields — can be " +
                    "removed to bypass limits. On the child's device:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    guidanceRow(1, "Open Settings, then Screen Time.")
                    guidanceRow(2, "Tap Content & Privacy Restrictions and turn them on.")
                    guidanceRow(3, "Tap iTunes & App Store Purchases.")
                    guidanceRow(4, "Tap Deleting Apps, then choose Don't Allow.")
                }
                if let error = viewModel.progressError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("I turned on delete prevention") {
                    viewModel.finishSetup()
                }
                .buttonStyle(.borderedProminent)
                Button("Start over", role: .destructive) {
                    viewModel.abandonSetup()
                }
                .font(.footnote)
                SetupHonestyNote()
            }
            .padding()
        }
    }

    private func guidanceRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .bold()
            Text(text)
        }
    }
}

// MARK: - Step 5: complete

/// The saved-policy summary, shown after setup completes (and after a
/// relaunch while the completion stands) until the parent taps Continue —
/// including the category-backstop-disabled warning when an allowlisted
/// app's unknown category disables the backstop. Public so `ContentView`
/// can keep it visible instead of jumping straight to the main screen.
///
/// T7.8 fix-2 finding 2: this screen also carries the About & theme
/// entry for the model-ready UI. Once the download gate lifts, this is
/// the only non-chat model-ready surface every onboarded install sees
/// (each launch, before Continue), and the slim chat header stays
/// stars-only per spec — so the settings route lives here, bound to
/// the same app-scope ThemeStore as the chat theme.
public struct SetupCompleteView: View {
    @ObservedObject var viewModel: SetupFlowViewModel
    /// The child app's theme store, passed from the app root so the
    /// About sheet's picker drives the live app theme.
    @ObservedObject var themes: ThemeStore
    @State private var showingAbout = false

    public init(viewModel: SetupFlowViewModel, themes: ThemeStore) {
        self.viewModel = viewModel
        self.themes = themes
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Setup complete")
                    .font(.title2.bold())
                if viewModel.isSimulatedMode {
                    SimulatedModeBadge()
                }
                Button("About & app theme") {
                    showingAbout = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("setupCompleteAboutButton")
                if let summary = viewModel.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        summaryRow("Policy version", "\(summary.policyVersion)")
                        summaryRow("Apps staged to shield", "\(summary.shieldedCount)")
                        summaryRow("Earn-to-unblock apps", "\(summary.unblockableCount)")
                        summaryRow("Extra allowed apps", "\(summary.allowedExtraCount)")
                        summaryRow(
                            "Category backstop",
                            summary.backstopCount > 0
                                ? "\(summary.backstopCount) categor\(summary.backstopCount == 1 ? "y" : "ies")"
                                : "Off — the allowlist holds an app whose category is unknown, " +
                                    "so the backstop is disabled to keep it reachable."
                        )
                    }
                    .font(.subheadline)
                }
                if !viewModel.pickedApps.isEmpty || !viewModel.pickedSimulatedApps.isEmpty {
                    Text("Managed apps")
                        .font(.headline)
                    ForEach(viewModel.pickedApps) { app in
                        HStack {
                            Label(app.token)
                            Spacer()
                            Text(viewModel.choices[app.id]?.shortLabel ?? "Blocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(viewModel.pickedSimulatedApps) { app in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(app.category.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(viewModel.choices[app.id]?.shortLabel ?? "Blocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if viewModel.supportsInstalledSimulatedShields,
                    !viewModel.pickedApps.isEmpty || !viewModel.pickedSimulatedApps.isEmpty
                {
                    InstalledShieldPanel(viewModel: viewModel, theme: themes.theme)
                }
                Text("Demo status: the policy is saved and shields are " +
                    "staged through the T2.2 shield interface. Real " +
                    "enforcement needs the FamilyControls entitlement " +
                    "(not filed) and is unverified — the Demo verifies " +
                    "shielding through the simulated path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Continue") {
                    viewModel.dismissSummary()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .sheet(isPresented: $showingAbout) {
            NavigationStack {
                ScrollView {
                    AboutView(themes: themes)
                        .padding()
                }
                .navigationTitle("About")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingAbout = false }
                    }
                }
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

// MARK: - Installed simulated shield panel

/// Reachable simulated lock/unlock over the MAIN flow's installed shield
/// composition (issue #87 fix round 1): each picked app's flow runs on
/// the same manager, policy, enumeration, and simulated backend the
/// setup committed, so testers exercise real grant/expiry behavior from
/// the completion screen — never the dead preview harness. Shown only
/// when a simulated backend is installed (forced mode); the honesty
/// badge above it is retained.
///
/// Fix round 2: blocked targets (the default Blocked choice, including
/// never-unlockable overrides) show an informational status instead of
/// the challenge host — the manager refuses their unlocks regardless
/// of effort, so presenting the full-screen challenge would trap the
/// tester. Issue #91: the challenge for unlockable targets is the chat
/// tutor (`InstalledShieldChatCoverHost`), finishing through the same
/// `finishChallenge` boundary; blocked targets keep the status below.
private struct InstalledShieldPanel: View {
    @ObservedObject var viewModel: SetupFlowViewModel
    var theme: DesignSystem.Theme = DesignSystem.defaultTheme
    @State private var activeShieldAppID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulated shields")
                .font(.headline)
            Text("Try this setup's shields: each entry opens a simulated " +
                "lock screen over the installed configuration. Simulated " +
                "only — not real enforcement.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(viewModel.pickedApps) { app in
                Button {
                    activeShieldAppID = app.id
                    _ = viewModel.selectInstalledShieldApp(app.id)
                } label: {
                    HStack {
                        Text("Simulated shield:")
                        Label(app.token)
                    }
                }
                .accessibilityIdentifier("installedShieldEntry-\(app.id)")
                if viewModel.isInstalledShieldBlocked(app.ref) {
                    InstalledBlockedStatusLabel(appID: app.id)
                }
            }
            ForEach(viewModel.pickedSimulatedApps) { app in
                Button("Simulated shield: \(app.name)") {
                    activeShieldAppID = app.id
                    _ = viewModel.selectInstalledShieldApp(app.id)
                }
                .accessibilityIdentifier("installedShieldEntry-\(app.id)")
                if viewModel.isInstalledShieldBlocked(app.ref) {
                    InstalledBlockedStatusLabel(appID: app.id)
                }
            }
            if let id = activeShieldAppID,
                let target = viewModel.installedShieldTarget(for: id)
            {
                if viewModel.isInstalledShieldBlocked(target.ref) {
                    InstalledBlockedStatusLabel(appID: id, selected: true)
                } else if let flow = viewModel.installedShieldFlow(
                    for: target.ref, category: target.category
                ) {
                    InstalledShieldChatCoverHost(flow: flow, theme: theme)
                }
            }
        }
    }
}

/// Informational blocked status for an installed shield target with no
/// challenge offered (issue #87 fix round 2): the default Blocked
/// choice and never-unlockable overrides alike. Rendered inline
/// per-row and in the selected detail in place of the challenge host,
/// so a blocked target never opens a non-dismissible challenge.
/// Internal so app tests pin the copy without driving panel taps.
struct InstalledBlockedStatusLabel: View {
    let appID: String
    var selected: Bool = false

    var body: some View {
        Text("Blocked (simulated) — no challenge offered. It stays shielded.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                selected ? "installedBlockedStatusSelected-\(appID)" : "installedBlockedStatus-\(appID)"
            )
    }
}

// MARK: - Simulated-mode honesty badge

/// Honesty badge for simulated mode in the MAIN setup flow (issue
/// #87): the same labeling `SimulatedShieldView` renders, so simulated
/// authorization and simulated shields here never look like real
/// Screen Time enforcement. Shown only when the view model runs a
/// simulated half (`isSimulatedMode`); the unforced flow is unchanged.
private struct SimulatedModeBadge: View {
    var body: some View {
        Text(SimulatedShieldFlow.simulatedBadgeText)
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("simulatedShieldBadge")
    }
}

// MARK: - Shared honesty note

private struct SetupHonestyNote: View {
    var body: some View {
        Text("Demo honesty: real Screen Time authorization and shield " +
            "enforcement need the FamilyControls entitlement (not filed). " +
            "Nothing here claims real enforcement — the Demo verifies " +
            "setup through the simulated path.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
