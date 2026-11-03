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
    /// Simulated enumeration picks (forced-mode setup): selected catalog
    /// app and category ids. The system picker cannot produce tokens
    /// without real FamilyControls authorization — which simulated
    /// approval never grants — so the forced path enumerates from
    /// `SimulatedSetupCatalog` through the same
    /// `continueFromEnumeration()` submission as tokens. Ignored unless
    /// `usesSimulatedEnumeration` (unforced setups keep the real picker
    /// exactly as-is).
    @Published public var simulatedAppIDs: Set<String> = []
    @Published public var simulatedCategoryIDs: Set<String> = []
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
    /// Installed shield backend. Internal (not private) so app tests can
    /// pin the issue-#87 composition (simulated vs non-enforcing).
    /// `any ShieldBackend` so the forced-simulated composition can install
    /// `SimulatedShieldBackend` behind the same interface; the unforced
    /// composition still installs `NonEnforcingShieldBackend`.
    let backend: any ShieldBackend
    /// Installed authorization service. Internal (not private) so app
    /// tests can pin the issue-#87 composition (simulated vs real).
    let authService: any SetupAuthorizationService
    private let tokenStore: SetupTokenStore

    /// Durable token-to-ref registries: every token ever picked in this
    /// run (or restored from the persisted mapping) keeps its identifier
    /// here for the life of the view model. Deselection prunes the current
    /// selection (`pickedApps` / `pickedCategories`) but NEVER these
    /// registries, so re-picking can never mint a new `AppRef`, change
    /// policy identity, or orphan a retained admin override.
    private var appRefsByToken: [ApplicationToken: AppRef] = [:]
    private var categoryRefsByToken: [ActivityCategoryToken: AppCategoryRef] = [:]

    public init(
        flow: SetupFlow,
        policyStore: PolicyStore,
        backend: any ShieldBackend,
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

    /// True when either installed half is simulated: the shield backend
    /// is the simulated backend, or authorization is the simulated
    /// service. The setup UI renders the simulated honesty badge off
    /// this, so a simulated authorization or simulated shields in the
    /// main flow never look like real Screen Time enforcement. Derived
    /// from the installed instances (the single source of truth), so it
    /// stays correct however the view model was constructed.
    public var isSimulatedMode: Bool {
        backend is SimulatedShieldBackend || authService is SimulatedSetupAuthorizationService
    }

    /// True when setup enumeration comes from the simulated catalog: the
    /// installed authorization service is the simulated one, whose
    /// approval never grants real FamilyControls authorization, so the
    /// system picker cannot produce tokens on this path. The enumeration
    /// step branches its picker UI off this; the unforced path keeps the
    /// real picker exactly as-is.
    public var usesSimulatedEnumeration: Bool {
        authService is SimulatedSetupAuthorizationService
    }

    /// Simulated apps currently picked, in catalog order (display and
    /// submission). Restored from the staged enumeration after a
    /// relaunch (see `restoreMapping()`), so a committed forced setup
    /// lists the same demo apps the parent picked.
    public var pickedSimulatedApps: [SimulatedSetupApp] {
        SimulatedSetupCatalog.apps.filter { simulatedAppIDs.contains($0.id) }
    }

    /// Simulated categories currently picked, in catalog order.
    public var pickedSimulatedCategories: [SimulatedSetupCategory] {
        SimulatedSetupCatalog.categories.filter { simulatedCategoryIDs.contains($0.id) }
    }

    /// True when either enumeration path holds input: real picker tokens,
    /// or — on the simulated path only — catalog picks. The enumeration
    /// Continue enables off this.
    public var hasEnumerationInput: Bool {
        !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || (usesSimulatedEnumeration
                && (!simulatedAppIDs.isEmpty || !simulatedCategoryIDs.isEmpty))
    }

    /// Default wiring over the on-device stores (issue #87).
    ///
    /// When `simulatedMode` resolves true, the flow uses the simulated
    /// pair (`SimulatedSetupAuthorizationService` +
    /// `SimulatedShieldBackend`) so gate scenarios can run where the
    /// FamilyControls entitlement is unavailable (TestFlight, simulator).
    /// When false, behavior is exactly the pre-#87 default (real
    /// FamilyControls authorization + `NonEnforcingShieldBackend`).
    ///
    /// The default resolves live through `SimulatedShieldMode.isForced()`,
    /// so the launch argument, the environment variable, and the
    /// UserDefaults toggle (the only input a TestFlight binary receives)
    /// all keep working through the same resolver with no new flag
    /// names. The mode resolves once here at composition (app launch):
    /// flipping the toggle requires a restart to take effect.
    ///
    /// An explicitly injected `authService` still wins for the auth half
    /// (the Demo verification seam); the backend half always follows
    /// `simulatedMode`.
    ///
    /// An explicitly injected `policyStore` is shared as the live store
    /// (issue #87 fix round 3): production passes the sync controller's
    /// store, so an accepted sync update lands in the same instance the
    /// setup flow, the installed manager, and this view model read —
    /// instead of a sibling instance whose disk write the setup store's
    /// in-memory cache would never see until relaunch. Nil keeps the
    /// standalone default (a fresh store over the default directory).
    public static func makeDefault(
        authService: (any SetupAuthorizationService)? = nil,
        simulatedMode: Bool = SimulatedShieldMode.isForced(),
        policyStore: PolicyStore? = nil
    ) -> SetupFlowViewModel {
        let store = policyStore ?? PolicyStore()
        let backend: any ShieldBackend =
            simulatedMode ? SimulatedShieldBackend() : NonEnforcingShieldBackend()
        let defaultAuth: any SetupAuthorizationService = simulatedMode
            ? SimulatedSetupAuthorizationService()
            : FamilyControlsSetupAuthorizationService()
        let auth = authService ?? defaultAuth
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
        switch flow.submitEnumerationResult(enumeration) {
        case .submitted:
            break
        case .persistenceFailed:
            progressError = "Could not save the picked apps. " +
                "Check available storage and try again — setup is still " +
                "incomplete and nothing is shielded."
            return
        case .notReady:
            progressError = "Setup is not ready for enumeration yet. " +
                "Complete the authorization step first."
            return
        }
        try? tokenStore.saveMapping(currentMapping())
        for app in pickedApps where choices[app.id] == nil {
            choices[app.id] = .blocked
        }
        for app in pickedSimulatedApps where choices[app.id] == nil {
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
        for app in pickedSimulatedApps {
            choices[app.id] = choice
        }
    }

    /// Submits the allowlist / unblockable split.
    public func continueFromSelection() {
        progressError = nil
        var allowlist = Set<AppRef>()
        var unblockable = Set<AppRef>()
        let refs = pickedApps.map(\.ref) + pickedSimulatedApps.map(\.ref)
        for ref in refs {
            switch choices[ref.id] ?? .blocked {
            case .allowed:
                allowlist.insert(ref)
            case .unblockable:
                unblockable.insert(ref)
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
    ///
    /// When the flow is at the enumeration step, the picker's current
    /// selection is submitted first (mapping rebuilt and saved), so
    /// tapping Start over before Continue — or after Re-pick apps returns
    /// to the picker — shields the picked apps via the restrictive
    /// abandonment path instead of abandoning with no (or a cleared)
    /// staged enumeration.
    public func abandonSetup() {
        if flow.currentStep == .enumeration {
            rebuildMappingFromSelection()
            let enumeration = currentEnumeration()
            if !enumeration.apps.isEmpty || !enumeration.categories.isEmpty {
                if flow.submitEnumeration(enumeration) {
                    try? tokenStore.saveMapping(currentMapping())
                }
            }
        }
        flow.abandon()
        authorizationError = nil
        progressError = nil
        refresh()
    }

    // MARK: - Mapping

    private func refresh() {
        step = flow.currentStep
        if step == .complete {
            // Reauthorization restores completion with a newly staged
            // enumeration (issue #87 fix round 2): sync the simulated
            // picks before the summary rebuilds, so the completion
            // screen and the installed shield panel list the same demo
            // apps the parent picked instead of an empty set behind
            // still-active shields. No-op when nothing is staged; on a
            // normal commit the staged enumeration already matches the
            // in-progress picks.
            restoreSimulatedPicksFromStagedEnumeration()
            rebuildSummary()
        } else {
            summary = nil
            summaryDismissed = false
        }
    }

    /// Derives one picked app's completion choice from the effective
    /// policy: always-allowed → Allowed; else challenge-unlockable →
    /// Earn; else Blocked. `isChallengeUnlockable` already excludes
    /// always-allowed apps and never-unlockable overrides, so an
    /// override-covered app shows Blocked even when it was picked as Earn.
    /// Internal so app tests pin the rule without picker tokens.
    /// Nonisolated: pure function of its arguments.
    nonisolated static func choice(for app: AppRef, in policy: Policy) -> AppChoice {
        if policy.alwaysAllowed.contains(app) {
            return .allowed
        }
        if policy.isChallengeUnlockable(app) {
            return .unblockable
        }
        return .blocked
    }

    private func rebuildSummary() {
        let policy = policyStore.currentPolicy
        let config = backend.currentShieldConfiguration
        let builtinCount = Set(policy.alwaysAllowed)
            .intersection([.phone, .messages, .earnPlaySelf]).count
        // Restore each picked app's choice from the effective policy: the
        // completion view reads `choices`, which a relaunch would
        // otherwise leave empty (Blocked-for-all). This also keeps a fresh
        // completion honest — the summary matches the saved policy,
        // including never-unlockable overrides, which never show Earn.
        for app in pickedApps {
            choices[app.id] = Self.choice(for: app.ref, in: policy)
        }
        for app in pickedSimulatedApps {
            choices[app.id] = Self.choice(for: app.ref, in: policy)
        }
        // Count only effectively earnable apps with the same predicate
        // each app's displayed choice uses: an override-covered app shows
        // Blocked, so it must not be counted as Earn-to-unblock.
        let earnableCount = Set(policy.unblockable)
            .filter { policy.isChallengeUnlockable($0) }.count
        summary = CompletionSummary(
            policyVersion: policy.version,
            shieldedCount: config.shieldedApplications.count,
            unblockableCount: earnableCount,
            allowedExtraCount: max(0, policy.alwaysAllowed.count - builtinCount),
            backstopCount: config.shieldedCategories.count
        )
    }

    /// Pairs the current picker selection with identifiers, reusing the
    /// durable registries. Deselected tokens leave the current selection
    /// but keep their registered identifiers, so a re-pick restores the
    /// original `AppRef` instead of minting a new policy identity.
    private func rebuildMappingFromSelection() {
        let appTokens = selection.applicationTokens
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
        var apps = pickedApps.map { EnumeratedApp(app: $0.ref, category: nil) }
        var categories = Set(pickedCategories.map(\.ref))
        if usesSimulatedEnumeration {
            // Simulated picks carry KNOWN categories (unlike
            // token-backed picks, whose categories stay unknown): the
            // simulated path shields through them. Categories stay
            // explicit picks only (like the real picker's category
            // tokens) — an app's known category is metadata, not an
            // automatic backstop entry.
            apps += pickedSimulatedApps.map {
                EnumeratedApp(app: $0.ref, category: $0.category.ref)
            }
            categories.formUnion(pickedSimulatedCategories.map(\.ref))
        }
        return ShieldEnumeration(apps: apps, categories: categories)
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
        restoreSimulatedPicksFromStagedEnumeration()
    }

    /// Restores the simulated picks from the staged enumeration, if any.
    ///
    /// A relaunch stages an enumeration only for a committed setup
    /// (where the stable catalog ids round-trip through the persisted
    /// enumeration): the completion screen and the installed shield
    /// panel list the same demo apps the parent picked. A mid-flow
    /// relaunch stages no enumeration, so in-progress simulated picks
    /// are re-picked (their restrictive shields persist regardless).
    /// Reauthorization is the same shape mid-lifecycle: the pending
    /// committed enumeration becomes staged only on re-grant, so
    /// `refresh()` re-runs this on every transition to `.complete`
    /// (issue #87 fix round 2) — before the summary rebuild — and a
    /// reauthorized demo matches the user's selections instead of an
    /// empty pick set behind still-active shields.
    private func restoreSimulatedPicksFromStagedEnumeration() {
        guard let staged = flow.pendingEnumeration else { return }
        let stagedAppIDs = Set(staged.apps.map(\.app.id))
        simulatedAppIDs = Set(
            SimulatedSetupCatalog.apps.map(\.id).filter(stagedAppIDs.contains)
        )
        let stagedCategoryIDs = Set(staged.categories.map(\.id))
        simulatedCategoryIDs = Set(
            SimulatedSetupCatalog.categories.map(\.id).filter(stagedCategoryIDs.contains)
        )
    }

    // MARK: - Installed simulated shields (main flow)

    /// True when the installed shield composition can drive simulated
    /// shield flows: the installed backend IS the simulated backend
    /// (forced mode). The completion screen's shield panel branches off
    /// this; any other composition — including simulated auth with the
    /// non-enforcing backend — hides it, since no simulated backend is
    /// installed to grant through.
    public var supportsInstalledSimulatedShields: Bool {
        backend is SimulatedShieldBackend
    }

    /// Cached shield flows over the installed composition, by app id.
    private var installedShieldFlows: [String: SimulatedShieldFlow] = [:]
    /// Policy version the cached installed flows were built under (issue
    /// #87 fix round 3): a lookup that observes a newer version drops
    /// the cache first, so effort-floor and unlock-duration changes
    /// reach already-cached flows instead of lingering behind a cache
    /// hit. Nil until the first lookup.
    private var installedShieldPolicyVersion: Int?

    /// Demo-scoped decision-log directory for installed shield flows:
    /// installed unlock decisions log here, never into production
    /// logging (mirroring `SimulatedShieldDemoState`'s isolated
    /// directory).
    public static func installedShieldLogDirectory() -> URL {
        PolicyStore.defaultDirectory()
            .appendingPathComponent("InstalledSimulatedDemo", isDirectory: true)
    }

    /// Builds a simulated shield flow over the installed composition —
    /// the same manager, policy, enumeration, and simulated backend the
    /// setup committed — so a tester exercises real grant/expiry
    /// behavior from the main experience. Returns nil unless a
    /// simulated backend is installed (see
    /// `supportsInstalledSimulatedShields`). The decision logger,
    /// unlock duration, and scorer default to production values (the
    /// policy's practice minutes, a fresh per-session scorer over the
    /// installed policy's effort floor); callers — tests — may inject
    /// their own, and an explicitly passed scorer still wins.
    public func makeInstalledSimulatedShieldFlow(
        for app: AppRef,
        category: AppCategoryRef? = nil,
        decisionLogger: DecisionLogger? = nil,
        unlockDuration: TimeInterval? = nil,
        scorer: EffortScorer? = nil
    ) -> SimulatedShieldFlow? {
        guard let backend = backend as? SimulatedShieldBackend else { return nil }
        let policy = policyStore.currentPolicy
        let minutes = policy.unlockDurations.practiceMinutes
        return SimulatedShieldFlow(
            manager: flow.installedShieldManager,
            backend: backend,
            app: app,
            category: category,
            scorer: scorer ?? EffortScorer(floorSettings: policy.effortFloorSettings),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: unlockDuration ?? TimeInterval(minutes) * 60,
            isSimulatedMode: true,
            decisionLogger: decisionLogger ?? DecisionLogger(
                directory: Self.installedShieldLogDirectory()
            ),
            decisionDurationMinutes: minutes
        )
    }

    /// True when the installed policy blocks `app` with no challenge
    /// offered (issue #87 fix round 2): the default Blocked choice and
    /// never-unlockable overrides alike. `isNeverUnlockable` already
    /// excludes always-allowed apps, so an allowed app never reports
    /// blocked here — it keeps the host path (which renders unlocked,
    /// never a trap). The installed shield panel branches off this so
    /// a blocked target shows an informational status instead of a
    /// challenge the manager would refuse regardless of effort.
    public func isInstalledShieldBlocked(_ app: AppRef) -> Bool {
        policyStore.currentPolicy.isNeverUnlockable(app)
    }

    /// Drops cached installed flows whose policy settings are stale
    /// (issue #87 fix round 3): when the installed policy version moved
    /// since the cache was built, every entry is discarded so the next
    /// lookup rebuilds under the current floor and unlock duration. A
    /// no-op when the version is unchanged, so an untouched policy
    /// keeps its cache hits (and any in-progress challenge effort).
    private func reconcileInstalledShieldFlows() {
        let version = policyStore.storedVersion
        guard installedShieldPolicyVersion != version else { return }
        installedShieldFlows.removeAll()
        installedShieldPolicyVersion = version
    }

    /// Reloads the installed policy from disk and refreshes everything
    /// derived from it (issue #87 fix round 3): the installed manager
    /// re-applies shields under the reloaded policy, cached shield
    /// flows whose settings went stale are dropped, the completion
    /// summary rebuilds, and the UI republishes. This is the
    /// cross-instance propagation path — a sync update accepted through
    /// a sibling store over the same directory becomes visible to the
    /// blocked gate and the installed flows without a relaunch. (In
    /// production the store is shared with the sync controller, so the
    /// reload is a no-op and this is purely the manager/UI refresh;
    /// the app calls it from the controller's policy-update hook.)
    public func refreshInstalledPolicyFromDisk() {
        policyStore.reloadFromDisk()
        flow.installedShieldManager.refresh()
        reconcileInstalledShieldFlows()
        if step == .complete {
            rebuildSummary()
        }
        objectWillChange.send()
    }

    /// The cached installed-composition flow for one app, created on
    /// first use. Returns nil for blocked targets (see
    /// `isInstalledShieldBlocked(_:)`), so the panel never presents a
    /// non-dismissible challenge the manager would refuse; the
    /// challenge path for unlockable targets is unchanged. A cache
    /// hit returns the flow untouched; presentation refresh happens
    /// in `selectInstalledShieldApp(_:)`, never during a view-body
    /// read. The blocked gate runs before the cache lookup so a
    /// policy change that blocks a previously unlockable app stops
    /// presenting its cached challenge; the lookup then reconciles
    /// the cache against the policy version so floor and unlock
    /// duration changes rebuild already-cached flows.
    public func installedShieldFlow(
        for app: AppRef,
        category: AppCategoryRef? = nil
    ) -> SimulatedShieldFlow? {
        if isInstalledShieldBlocked(app) { return nil }
        reconcileInstalledShieldFlows()
        if let existing = installedShieldFlows[app.id] { return existing }
        guard let flow = makeInstalledSimulatedShieldFlow(for: app, category: category) else {
            return nil
        }
        installedShieldFlows[app.id] = flow
        return flow
    }

    /// Selects one picked app's installed shield flow, refreshing a
    /// cached flow so re-selecting never shows stale unlock state (the
    /// flows share the installed manager, so another app's unlock ends
    /// this app's window without ticking this flow). Mirrors
    /// `SimulatedShieldDemoState.select(_:isSimulatedMode:)`.
    @discardableResult
    public func selectInstalledShieldApp(_ id: String) -> SimulatedShieldFlow? {
        guard let target = installedShieldTarget(for: id),
              let flow = installedShieldFlow(for: target.ref, category: target.category)
        else {
            return nil
        }
        flow.tick()
        return flow
    }

    /// The installed-shield target (ref plus known category, if any) for
    /// one picked app id, token-backed or simulated. Token-backed picks
    /// resolve with an unknown (`nil`) category, like the enumeration
    /// they submitted; simulated picks resolve with their known catalog
    /// category.
    public func installedShieldTarget(for id: String) -> (ref: AppRef, category: AppCategoryRef?)? {
        if let app = pickedApps.first(where: { $0.id == id }) {
            return (app.ref, nil)
        }
        if let app = pickedSimulatedApps.first(where: { $0.id == id }) {
            return (app.ref, app.category.ref)
        }
        return nil
    }
}
