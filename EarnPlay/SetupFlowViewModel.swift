import SwiftUI
import EarnPlayCore
import FamilyControls
import ManagedSettings

/// View model driving the T2.3 setup wizard in the child app.
///
/// Owns the framework-free `SetupFlow` state machine and bridges it to
/// FamilyControls: authorization results from `SetupAuthorizationService`
/// and picker output from the `selection` binding are translated into
/// plain values (`recordAuthorization(granted:)`,
/// `submitEnumeration(_:)`) the machine accepts. The mapping from opaque
/// picker tokens to `AppRef` identifiers is assigned here and persisted
/// via `SetupTokenStore`.
///
/// Per-app categories are recorded as unknown (`nil`): FamilyControls does
/// not reveal which category an app belongs to. T2.2's allowlist fallback
/// therefore governs the real-device path — when the allowlist holds a
/// real app, the category backstop is disabled to preserve allowlist
/// access and the completion screen reports that honestly. The picked
/// categories are still always recorded as the backstop set, and the
/// simulated path (where categories are known) shields through them.
@MainActor
public final class SetupFlowViewModel: ObservableObject {
    /// The parent's choice for one enumerated app.
    public enum AppChoice: String, CaseIterable, Identifiable, Sendable {
        case blocked
        case unblockable
        case allowed

        public var id: String { rawValue }

        public var shortLabel: String {
            switch self {
            case .blocked: return "Blocked"
            case .unblockable: return "Earn"
            case .allowed: return "Allowed"
            }
        }

        public var explanation: String {
            switch self {
            case .blocked:
                return "Stays blocked with no challenge offered."
            case .unblockable:
                return "Blocked until a completed challenge opens it."
            case .allowed:
                return "Never blocked."
            }
        }
    }

    /// One picked app with its assigned opaque identifier.
    public struct PickedApp: Identifiable {
        public var id: String { ref.id }
        public let token: ApplicationToken
        public let ref: AppRef
    }

    /// One picked category with its assigned opaque identifier.
    public struct PickedCategory: Identifiable {
        public var id: String { ref.id }
        public let token: ActivityCategoryToken
        public let ref: AppCategoryRef
    }

    /// What the completed setup staged (reported, never enforced here).
    public struct CompletionSummary: Equatable {
        public var policyVersion: Int
        public var shieldedCount: Int
        public var unblockableCount: Int
        public var allowedExtraCount: Int
        public var backstopCount: Int
    }

    @Published public private(set) var step: SetupStep = .authorization
    @Published public var isPickerPresented = false
    @Published public var selection = FamilyActivitySelection()
    @Published public private(set) var pickedApps: [PickedApp] = []
    @Published public private(set) var pickedCategories: [PickedCategory] = []
    @Published public var choices: [String: AppChoice] = [:]
    @Published public var authorizationError: String?
    @Published public var progressError: String?
    @Published public private(set) var summary: CompletionSummary?
    /// Whether the parent dismissed the completion summary. The summary
    /// (including the category-backstop-disabled warning) stays visible
    /// until an explicit Continue; reset whenever the flow leaves
    /// `complete` so a later completion shows it again.
    @Published public private(set) var summaryDismissed = false

    /// Dismisses the completion summary (the Continue action).
    public func dismissSummary() {
        summaryDismissed = true
    }

    /// True when a committed setup is waiting for Screen Time access to be
    /// approved again (see `SetupFlow.needsReauthorization`): the wizard
    /// shows the authorization step, and a grant restores completion
    /// without re-running the picker.
    public var needsReauthorization: Bool {
        flow.needsReauthorization
    }

    /// The driven state machine. Internal (not private) so app tests can
    /// drive the flow to a given step; production UI uses only the
    /// view-model methods. No behavior change.
    let flow: SetupFlow
    private let policyStore: PolicyStore
    private let backend: NonEnforcingShieldBackend
    private let authService: any SetupAuthorizationService
    private let tokenStore: SetupTokenStore

    private var appRefsByToken: [ApplicationToken: AppRef] = [:]
    private var categoryRefsByToken: [ActivityCategoryToken: AppCategoryRef] = [:]

    public init(
        flow: SetupFlow,
        policyStore: PolicyStore,
        backend: NonEnforcingShieldBackend,
        authService: any SetupAuthorizationService,
        tokenStore: SetupTokenStore
    ) {
        self.flow = flow
        self.policyStore = policyStore
        self.backend = backend
        self.authService = authService
        self.tokenStore = tokenStore
        restoreMapping()
        refresh()
    }

    /// Default wiring over the on-device stores with real authorization.
    /// Pass a simulated `authService` for the Demo verification path.
    public static func makeDefault(
        authService: (any SetupAuthorizationService)? = nil
    ) -> SetupFlowViewModel {
        let store = PolicyStore()
        let backend = NonEnforcingShieldBackend()
        let auth = authService ?? FamilyControlsSetupAuthorizationService()
        let manager = ShieldManager(
            policyStore: store,
            enumeration: .empty,
            backend: backend,
            unlockStore: FileUnlockWindowStore()
        )
        let flow = SetupFlow(
            policyStore: store,
            shieldManager: manager,
            enumerationStore: FileSetupEnumerationStore(),
            authorized: auth.currentStatus() == .approved
        )
        return SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: auth,
            tokenStore: SetupTokenStore()
        )
    }

    // MARK: - Steps

    /// Records the current system authorization status, if approved. Call
    /// when the wizard appears so an already-authorized device starts past
    /// the authorization step.
    public func refreshAuthorizationStatus() {
        if authService.currentStatus() == .approved {
            flow.recordAuthorization(granted: true)
        }
        refresh()
    }

    /// Requests Screen Time authorization; records a grant with the flow.
    public func requestAuthorization() async {
        authorizationError = nil
        let approved = await authService.requestAuthorization()
        flow.recordAuthorization(granted: approved)
        if !approved {
            authorizationError = "Screen Time authorization was not granted. " +
                "On this device that is expected without the FamilyControls " +
                "entitlement (not filed) — and the simulator has no Screen " +
                "Time authorization at all. The Demo verifies setup through " +
                "the simulated path instead."
        }
        refresh()
    }

    /// Submits the current picker selection as the setup enumeration.
    public func continueFromEnumeration() {
        progressError = nil
        rebuildMappingFromSelection()
        let enumeration = currentEnumeration()
        guard !enumeration.apps.isEmpty || !enumeration.categories.isEmpty else {
            progressError = "Pick at least one app or category before continuing."
            return
        }
        guard flow.submitEnumeration(enumeration) else {
            progressError = "Setup is not ready for enumeration yet. " +
                "Complete the authorization step first."
            return
        }
        try? tokenStore.saveMapping(currentMapping())
        for app in pickedApps where choices[app.id] == nil {
            choices[app.id] = .blocked
        }
        refresh()
    }

    /// Returns from the selection step to the picker step (re-pick).
    public func restartEnumeration() {
        progressError = nil
        flow.restartEnumeration()
        refresh()
    }

    public func setAllChoices(_ choice: AppChoice) {
        for app in pickedApps {
            choices[app.id] = choice
        }
    }

    /// Submits the allowlist / unblockable split.
    public func continueFromSelection() {
        progressError = nil
        var allowlist = Set<AppRef>()
        var unblockable = Set<AppRef>()
        for app in pickedApps {
            switch choices[app.id] ?? .blocked {
            case .allowed:
                allowlist.insert(app.ref)
            case .unblockable:
                unblockable.insert(app.ref)
            case .blocked:
                break
            }
        }
        guard flow.submitSelections(allowlist: allowlist, unblockable: unblockable) else {
            progressError = "Setup is not ready for app choices yet. " +
                "Go back and pick apps first."
            return
        }
        refresh()
    }

    /// Acknowledges the prevent-deleting-apps guidance and commits setup.
    ///
    /// Rechecks live Screen Time authorization first: access may have been
    /// revoked while the user was in Settings, and the grant recorded
    /// earlier in the flow must not be trusted at commit time. When access
    /// is no longer approved, the run is abandoned (no policy is saved),
    /// the wizard returns to authorization, and an authorization error is
    /// shown instead of committing.
    public func finishSetup() {
        progressError = nil
        guard authService.currentStatus() == .approved else {
            flow.abandon()
            refresh()
            authorizationError = "Screen Time authorization is no longer approved. " +
                "Approve access again to finish setup — nothing was saved."
            return
        }
        switch flow.acknowledgePreventDeletingGuidance() {
        case .finished:
            refresh()
        case .notReady:
            progressError = "Setup is not ready to finish yet. " +
                "Complete each step in order first."
        case .persistenceFailed:
            progressError = "Could not save the setup policy. " +
                "Check storage and try again — setup is still incomplete " +
                "and nothing is shielded."
        }
    }

    /// Abandons an in-progress setup run. No-op once complete.
    public func abandonSetup() {
        flow.abandon()
        authorizationError = nil
        progressError = nil
        refresh()
    }

    // MARK: - Mapping

    private func refresh() {
        step = flow.currentStep
        if step == .complete {
            rebuildSummary()
        } else {
            summary = nil
            summaryDismissed = false
        }
    }

    private func rebuildSummary() {
        let policy = policyStore.currentPolicy
        let config = backend.currentShieldConfiguration
        let builtinCount = Set(policy.alwaysAllowed)
            .intersection([.phone, .messages, .earnPlaySelf]).count
        summary = CompletionSummary(
            policyVersion: policy.version,
            shieldedCount: config.shieldedApplications.count,
            unblockableCount: policy.unblockable.count,
            allowedExtraCount: max(0, policy.alwaysAllowed.count - builtinCount),
            backstopCount: config.shieldedCategories.count
        )
    }

    /// Pairs the current picker selection with identifiers, preserving
    /// existing identifiers and pruning deselected tokens.
    private func rebuildMappingFromSelection() {
        let appTokens = selection.applicationTokens
        appRefsByToken = appRefsByToken.filter { appTokens.contains($0.key) }
        for token in appTokens where appRefsByToken[token] == nil {
            appRefsByToken[token] = AppRef(id: UUID().uuidString)
        }
        var orderedApps = pickedApps.filter { appTokens.contains($0.token) }
        let orderedAppTokens = Set(orderedApps.map(\.token))
        let newAppTokens = appTokens.subtracting(orderedAppTokens)
            .sorted { String(describing: $0) < String(describing: $1) }
        for token in newAppTokens {
            if let ref = appRefsByToken[token] {
                orderedApps.append(PickedApp(token: token, ref: ref))
            }
        }
        pickedApps = orderedApps

        let categoryTokens = selection.categoryTokens
        categoryRefsByToken = categoryRefsByToken.filter { categoryTokens.contains($0.key) }
        for token in categoryTokens where categoryRefsByToken[token] == nil {
            categoryRefsByToken[token] = AppCategoryRef(id: UUID().uuidString)
        }
        var orderedCategories = pickedCategories.filter { categoryTokens.contains($0.token) }
        let orderedCategoryTokens = Set(orderedCategories.map(\.token))
        let newCategoryTokens = categoryTokens.subtracting(orderedCategoryTokens)
            .sorted { String(describing: $0) < String(describing: $1) }
        for token in newCategoryTokens {
            if let ref = categoryRefsByToken[token] {
                orderedCategories.append(PickedCategory(token: token, ref: ref))
            }
        }
        pickedCategories = orderedCategories
    }

    private func currentEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: pickedApps.map { EnumeratedApp(app: $0.ref, category: nil) },
            categories: Set(pickedCategories.map(\.ref))
        )
    }

    private func currentMapping() -> SetupTokenMapping {
        SetupTokenMapping(
            applicationTokens: pickedApps.map(\.token),
            applicationRefIDs: pickedApps.map(\.ref.id),
            categoryTokens: pickedCategories.map(\.token),
            categoryRefIDs: pickedCategories.map(\.ref.id)
        )
    }

    /// Restores the persisted token mapping for display (picked-app labels
    /// after a relaunch, or the previous picks when re-running an
    /// incomplete setup). Never changes the flow's step.
    private func restoreMapping() {
        guard let mapping = tokenStore.loadMapping() else { return }
        var apps: [PickedApp] = []
        for (token, refID) in zip(mapping.applicationTokens, mapping.applicationRefIDs) {
            let ref = AppRef(id: refID)
            appRefsByToken[token] = ref
            apps.append(PickedApp(token: token, ref: ref))
        }
        var categories: [PickedCategory] = []
        for (token, refID) in zip(mapping.categoryTokens, mapping.categoryRefIDs) {
            let ref = AppCategoryRef(id: refID)
            categoryRefsByToken[token] = ref
            categories.append(PickedCategory(token: token, ref: ref))
        }
        pickedApps = apps
        pickedCategories = categories
        selection.applicationTokens = Set(mapping.applicationTokens)
        selection.categoryTokens = Set(mapping.categoryTokens)
    }
}
