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

    public init(viewModel: SetupFlowViewModel) {
        self.viewModel = viewModel
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
                Button("Select apps and categories") {
                    viewModel.isPickerPresented = true
                }
                .buttonStyle(.borderedProminent)
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
                .disabled(selectionIsEmpty)
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

    private var selectionIsEmpty: Bool {
        viewModel.selection.applicationTokens.isEmpty
            && viewModel.selection.categoryTokens.isEmpty
    }

    private var pickedSummary: String {
        let apps = viewModel.selection.applicationTokens.count
        let categories = viewModel.selection.categoryTokens.count
        if apps == 0 && categories == 0 {
            return "Nothing picked yet."
        }
        return "\(apps) app\(apps == 1 ? "" : "s"), " +
            "\(categories) categor\(categories == 1 ? "y" : "ies") picked."
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
                    VStack(alignment: .leading, spacing: 8) {
                        Label(app.token)
                        Picker(
                            "Choice",
                            selection: Binding(
                                get: { viewModel.choices[app.id] ?? .blocked },
                                set: { viewModel.choices[app.id] = $0 }
                            )
                        ) {
                            ForEach(SetupFlowViewModel.AppChoice.allCases) { choice in
                                Text(choice.shortLabel).tag(choice)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text((viewModel.choices[app.id] ?? .blocked).explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if !viewModel.pickedCategories.isEmpty {
                    Section("Category backstop") {
                        ForEach(viewModel.pickedCategories) { category in
                            Label(category.token)
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
                if !viewModel.pickedApps.isEmpty {
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
