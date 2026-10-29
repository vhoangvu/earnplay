import Foundation

/// An open unlock window, persisted so it can be re-evaluated after a
/// restart. All timing fields are on the suspend-inclusive monotonic
/// clock; `grantedWallDate` is recorded only for display/audit and is
/// never used to compute expiry.
///
/// `bootSessionID` binds the window to the boot that granted it. A
/// reloaded window whose identifier is missing (pre-change format),
/// differs from the current boot, or cannot be verified fails closed to
/// shielded and never unlocks. `explicitCategories` preserves
/// caller-supplied grant categories across enumeration reconciliation.
/// `policyVersion` is the policy version the window's app set was last
/// reconciled against; a reloaded window whose version is missing or
/// differs from the current policy fails closed, so a persisted record
/// that missed a narrowing (its re-persist failed) cannot resurrect a
/// removed app after the policy changes again.
public struct UnlockWindow: Codable, Equatable, Sendable {
    /// Apps opened by this window.
    public var unlockedApps: Set<AppRef>
    /// Categories withheld from the backstop while this window is open
    /// (explicit grant categories plus the unlocked apps' current
    /// enumeration categories), so no per-app exemption over a
    /// category shield is needed for the unlock to take effect.
    public var unlockedCategories: Set<AppCategoryRef>
    /// Suspend-inclusive monotonic time at grant.
    public var grantedAtUptime: TimeInterval
    /// Set duration in seconds.
    public var duration: TimeInterval
    /// Wall-clock date at grant (display/audit only; never expiry).
    public var grantedWallDate: Date
    /// Boot-session identifier at grant; nil means unverifiable.
    public var bootSessionID: String?
    /// Caller-supplied categories at grant, preserved across
    /// enumeration reconciliation.
    public var explicitCategories: Set<AppCategoryRef>
    /// Policy version the window's app set was last reconciled
    /// against; nil means unknown (pre-change format).
    public var policyVersion: Int?

    public init(
        unlockedApps: Set<AppRef>,
        unlockedCategories: Set<AppCategoryRef>,
        grantedAtUptime: TimeInterval,
        duration: TimeInterval,
        grantedWallDate: Date,
        bootSessionID: String? = nil,
        explicitCategories: Set<AppCategoryRef> = [],
        policyVersion: Int? = nil
    ) {
        self.unlockedApps = unlockedApps
        self.unlockedCategories = unlockedCategories
        self.grantedAtUptime = grantedAtUptime
        self.duration = duration
        self.grantedWallDate = grantedWallDate
        self.bootSessionID = bootSessionID
        self.explicitCategories = explicitCategories
        self.policyVersion = policyVersion
    }

    private enum CodingKeys: String, CodingKey {
        case unlockedApps
        case unlockedCategories
        case grantedAtUptime
        case duration
        case grantedWallDate
        case bootSessionID
        case explicitCategories
        case policyVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unlockedApps = try container.decode(Set<AppRef>.self, forKey: .unlockedApps)
        unlockedCategories = try container.decode(Set<AppCategoryRef>.self, forKey: .unlockedCategories)
        grantedAtUptime = try container.decode(TimeInterval.self, forKey: .grantedAtUptime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        grantedWallDate = try container.decode(Date.self, forKey: .grantedWallDate)
        bootSessionID = try container.decodeIfPresent(String.self, forKey: .bootSessionID)
        explicitCategories = try container.decodeIfPresent(
            Set<AppCategoryRef>.self, forKey: .explicitCategories
        ) ?? []
        policyVersion = try container.decodeIfPresent(Int.self, forKey: .policyVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(unlockedApps, forKey: .unlockedApps)
        try container.encode(unlockedCategories, forKey: .unlockedCategories)
        try container.encode(grantedAtUptime, forKey: .grantedAtUptime)
        try container.encode(duration, forKey: .duration)
        try container.encode(grantedWallDate, forKey: .grantedWallDate)
        try container.encodeIfPresent(bootSessionID, forKey: .bootSessionID)
        try container.encode(explicitCategories, forKey: .explicitCategories)
        try container.encodeIfPresent(policyVersion, forKey: .policyVersion)
    }

    /// Monotonic time at which the window expires.
    public var expiryUptime: TimeInterval { grantedAtUptime + duration }

    /// Remaining seconds at monotonic time `now`; negative when expired.
    public func remaining(atUptime now: TimeInterval) -> TimeInterval {
        expiryUptime - now
    }

    /// True when monotonic time has gone backwards since grant — the
    /// clock cannot be trusted and the window must not be extended.
    public func uptimeRegressed(atUptime now: TimeInterval) -> Bool {
        now < grantedAtUptime
    }
}

/// Persistence seam for the open unlock window.
///
/// Production uses `FileUnlockWindowStore`; tests may use the same file
/// store over a temporary directory (relaunch-equivalent restart).
/// Saving and clearing report failures by throwing so the manager can
/// keep in-memory state and the backend consistent with what is durably
/// stored; only a missing file on clear counts as success.
public protocol UnlockWindowStore: Sendable {
    func loadUnlockWindow() -> UnlockWindow?
    func saveUnlockWindow(_ window: UnlockWindow) throws
    func clearUnlockWindow() throws
}

/// File-backed unlock-window store (JSON in a directory, atomic write).
///
/// Follows the `PolicyStore` precedent. A missing or corrupt file loads
/// as no window: fail-closed, because with no window every enumerated
/// non-allowlist app is shielded.
public final class FileUnlockWindowStore: UnlockWindowStore, @unchecked Sendable {
    public static let windowFileName = "unlock-window.json"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default store directory, shared with `PolicyStore`.
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            directory: PolicyStore.defaultDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public func loadUnlockWindow() -> UnlockWindow? {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(Self.windowFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(UnlockWindow.self, from: data)
    }

    public func saveUnlockWindow(_ window: UnlockWindow) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(window)
        try data.write(
            to: directory.appendingPathComponent(Self.windowFileName),
            options: [.atomic]
        )
    }

    public func clearUnlockWindow() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.removeItem(
                at: directory.appendingPathComponent(Self.windowFileName)
            )
        } catch {
            let code = (error as NSError).code
            let domain = (error as NSError).domain
            if domain == NSCocoaErrorDomain && code == NSFileNoSuchFileError {
                return
            }
            if let cocoa = error as? CocoaError, cocoa.code == .fileNoSuchFile {
                return
            }
            throw error
        }
    }
}

/// Persistence seam for post-setup install observations (T2.5
/// default-deny).
///
/// Production uses `FileObservedInstallStore`; tests may use the same
/// file store over a temporary directory (relaunch-equivalent
/// restart). Saving reports failures by throwing; loading a missing
/// or corrupt file yields no observations, and re-observation (or
/// re-enumeration) restores enforcement. The manager query still
/// default-denies unknown apps when the record is lost, so only the
/// per-app backend enforcement lapses — never the gate verdict.
public protocol ObservedInstallStore: Sendable {
    func loadObservedInstalls() -> Set<EnumeratedApp>
    func saveObservedInstalls(_ installs: Set<EnumeratedApp>) throws
}

/// File-backed observed-install store (JSON in a directory, atomic write).
///
/// Follows the `FileUnlockWindowStore` precedent. A missing file loads
/// as no observations; a corrupt file likewise loads as none, and the
/// next save overwrites it.
public final class FileObservedInstallStore: ObservedInstallStore, @unchecked Sendable {
    public static let installsFileName = "observed-installs.json"

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Default store directory, shared with `PolicyStore`.
    public convenience init(fileManager: FileManager = .default) {
        self.init(
            directory: PolicyStore.defaultDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public func loadObservedInstalls() -> Set<EnumeratedApp> {
        lock.lock()
        defer { lock.unlock() }
        let url = directory.appendingPathComponent(Self.installsFileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        guard let list = try? decoder.decode([EnumeratedApp].self, from: data) else {
            return []
        }
        return Set(list)
    }

    public func saveObservedInstalls(_ installs: Set<EnumeratedApp>) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let sorted = installs.sorted {
            if $0.app.id != $1.app.id { return $0.app.id < $1.app.id }
            return ($0.category?.id ?? "") < ($1.category?.id ?? "")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sorted)
        try data.write(
            to: directory.appendingPathComponent(Self.installsFileName),
            options: [.atomic]
        )
    }
}

/// Applies and removes shields from policy (T2.2, default-deny T2.5).
///
/// Enumeration-first: every app enumerated at setup except the policy
/// allowlist (`Policy.alwaysAllowed`) is shielded individually, and
/// category shields backstop newly installed apps that are not yet
/// enumerated. No per-app exemption overriding a category shield is
/// used anywhere — see `ShieldConfiguration`. T2.5 default-deny
/// enforces in two layers: an install observed via `noteInstalledApp`
/// is shielded individually in the applied configuration (backend
/// enforcement, not just the query answer) until a policy sync
/// classifies it, while an app never observed stays open only when
/// allowlisted or unlocked, so an unknown token or category resolves
/// to locked rather than to allowed. The launch gate is
/// `isShielded(app:category:)` — backend state plus the default-deny
/// backstop — so a newly installed, not-yet-observed app is blocked
/// before its first launch; `ShieldBackend.isShielded` answers only
/// the enforced observed/enumerated state and is not the gate. The
/// backstop applies only while shields are active (`shieldsActive`):
/// before setup completes it stays off and the gate reports backend
/// state, so an inactive system claims no protection.
///
/// Unlock timers run on an injected suspend-inclusive `MonotonicClock`
/// (continuous time in production). Changing the device wall clock
/// cannot extend an unlock, and sleeping past the real-time deadline
/// expires it. Each window is bound to its grant-time boot session: on
/// expiry the manager re-applies shields automatically (via expiry
/// monitoring, or `refresh()`), and on initialisation it re-evaluates
/// any persisted open window after a restart — resuming it on the same
/// boot, re-locking fail-closed if it expired, if the boot session
/// differs or cannot be verified, or if uptime regressed.
///
/// Grants commit in-memory and backend state only after the new window
/// is durably persisted; a failed save leaves the previous window
/// untouched and reports failure. Revocation clears state only after
/// durable removal and throws when removal fails. Active windows are
/// reconciled against the current policy (apps that stop being
/// challenge-unlockable are removed with their category suppression)
/// and against the current enumeration (category associations follow
/// the latest mapping). When a real allowlisted app has unknown or
/// missing category metadata, the category backstop is disabled to
/// preserve allowlist access. The same fallback covers unlocks: when a
/// real unlocked app has unknown or missing category metadata and no
/// caller-supplied category covers it, the backstop is disabled while
/// the window is open, so a grant never reports success while the app
/// remains shielded and re-enumeration cannot re-lock it mid-window.
///
/// All backend access goes through `ShieldBackend`, so T2.4's
/// simulated backend substitutes without changing this class.
public final class ShieldManager: @unchecked Sendable {
    private let policyStore: PolicyStore
    private let backend: any ShieldBackend
    private let clock: any MonotonicClock
    private let unlockStore: any UnlockWindowStore
    private let bootSession: any BootSessionProvider
    private let nowWallDate: @Sendable () -> Date

    private let lock = NSLock()
    private var enumeration: ShieldEnumeration
    /// Apps observed installed after setup via `noteInstalledApp` (T2.5
    /// default-deny), at most one entry per app. Observations are install
    /// facts, not picker state, and are never deleted just because the
    /// enumeration names the app: while enumerated, the enumeration's
    /// category governs (see the effective-observed filter in
    /// `computeConfigurationLocked`); when later unpicked, the retained
    /// entry restores the individual shield. A non-allowlisted
    /// observation is shielded individually in the applied configuration
    /// until a policy sync classifies it. Observations persist through
    /// `observedInstallStore` when one is provided, and are restored
    /// before the initial configuration is applied, so a recreated
    /// manager keeps every observed shield.
    private var observedInstalls: Set<EnumeratedApp> = []
    private let observedInstallStore: (any ObservedInstallStore)?
    private var window: UnlockWindow?
    private var lastConfiguration: ShieldConfiguration = .none
    /// Latched "shields active" signal for the T2.5 default-deny
    /// fallback in `isShielded`. Set once this instance applies shields
    /// from a real enumeration or install observation (or is explicitly
    /// engaged via `applyShields()` / `updateEnumeration(_:)`), and
    /// never unset in-instance: an applied configuration that happens
    /// to shield nothing (e.g. every enumerated app allowlisted, so the
    /// computed configuration is `.none`) still counts as active,
    /// while a fresh or not-yet-handed-an-enumeration manager (setup
    /// incomplete, or a relaunch whose SetupFlow withheld the
    /// committed enumeration pending reauthorization) stays inactive
    /// and `isShielded` falls through to backend state. Deliberately
    /// neither `policyStore.storedVersion > 0` — a revoked relaunch
    /// still has a stored policy while its shields are not restored —
    /// nor `lastConfiguration != .none` — an applied-but-empty
    /// configuration must still default-deny.
    private var shieldsActive = false
    private var monitorTask: Task<Void, Never>?
    /// True when a reconciliation narrowed or revoked the in-memory
    /// window but persisting that change failed, so the on-disk record
    /// is stale. Later refreshes retry the write; until one succeeds, a
    /// restart must not trust the stale record (see the policy-version
    /// binding in `init`).
    private var reconciliationUnpersisted = false

    /// Creates a manager and immediately re-evaluates state: any
    /// persisted unlock window is resumed or expired, and the correct
    /// shield configuration is applied to the backend. This is the
    /// restart path — a relaunched app gets the same effective shields
    /// it had, with elapsed monotonic time accounted for.
    ///
    /// A reloaded window fails closed when its boot-session identifier
    /// is missing, differs from the current boot, or cannot be
    /// verified, even when the new boot's uptime falls inside the old
    /// grant-expiry interval. It likewise fails closed when its
    /// policy version is missing or differs from the current policy:
    /// the record may have missed a narrowing whose re-persist failed,
    /// and must not resurrect a removed app after a later policy change.
    ///
    /// `nowWallDate` is injected only so tests can jump the wall clock;
    /// it never influences expiry.
    ///
    /// `observedInstallStore` persists post-setup install observations
    /// across recreation: previously observed installs are restored as-is
    /// before the initial configuration is applied, so a recreated
    /// manager keeps every observed shield. While an observed app stays
    /// enumerated, the enumeration's category governs; the retained entry
    /// restores the shield if the app is later unpicked. Without a store,
    /// observations are memory-only for this instance's lifetime.
    public init(
        policyStore: PolicyStore,
        enumeration: ShieldEnumeration,
        backend: any ShieldBackend,
        clock: any MonotonicClock = SystemUptimeClock(),
        unlockStore: any UnlockWindowStore,
        bootSession: any BootSessionProvider = SystemBootSessionProvider(),
        nowWallDate: @escaping @Sendable () -> Date = { Date() },
        observedInstallStore: (any ObservedInstallStore)? = nil
    ) {
        self.policyStore = policyStore
        self.enumeration = enumeration
        self.backend = backend
        self.clock = clock
        self.unlockStore = unlockStore
        self.bootSession = bootSession
        self.nowWallDate = nowWallDate
        self.observedInstallStore = observedInstallStore
        if let observedInstallStore {
            observedInstalls = observedInstallStore.loadObservedInstalls()
        }
        if let loaded = unlockStore.loadUnlockWindow() {
            let currentID = bootSession.currentBootSessionID
            if loaded.bootSessionID == nil
                || currentID == nil
                || loaded.bootSessionID != currentID
                || loaded.policyVersion == nil
                || loaded.policyVersion != policyStore.currentPolicy.version {
                self.window = nil
                try? unlockStore.clearUnlockWindow()
            } else {
                self.window = loaded
            }
        }
        refreshLocked()
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Shield application

    /// Recomputes shields from the current policy + enumeration and
    /// applies them, honouring any still-open unlock window. Explicitly
    /// applying shields engages the shield system: the T2.5
    /// default-deny fallback in `isShielded` is active from here on,
    /// even if the applied configuration shields nothing.
    public func applyShields() {
        lock.lock()
        defer { lock.unlock() }
        shieldsActive = true
        refreshLocked()
    }

    /// Replaces the setup enumeration (e.g. after a re-pick in T2.3, or
    /// after a newly installed app is enumerated) and re-applies. The
    /// active window's category associations are reconciled against the
    /// replacement enumeration before shields are reapplied.
    ///
    /// Observed entries are retained: while the replacement names an app,
    /// its enumeration mapping governs and the retained observation is
    /// filtered out of placement, so a stale category can neither widen
    /// allowlist coverage nor linger in an active unlock. When the app is
    /// later unpicked, the retained entry restores its shield — coverage
    /// never regresses.
    public func updateEnumeration(_ enumeration: ShieldEnumeration) {
        lock.lock()
        defer { lock.unlock() }
        self.enumeration = enumeration
        // Handing the manager its enumeration engages the shield
        // system (setup commit, relaunch restore, abandon, re-pick):
        // the T2.5 default-deny fallback applies from here on, even
        // if the replacement enumeration is empty.
        shieldsActive = true
        refreshLocked()
    }

    /// Records an app installed after setup and re-applies shields.
    ///
    /// The observation promotes the install into the applied
    /// configuration: a non-allowlisted, non-unlocked app is shielded
    /// individually — backend-enforced, so the backend's answer for the
    /// app (the launch gate in the simulated scope) reports blocked —
    /// until a policy sync classifies it. An allowlisted install
    /// withholds its category like an enumerated pick, and an unlocked
    /// install stays open, so neither exemption regresses. Category
    /// knowledge is sticky: a report without metadata never discards a
    /// previously observed category for the same app.
    ///
    /// This is the host/simulated observation seam for T2.5 default-deny
    /// (demo scope: simulated backend; no real device shields). On
    /// device, re-enumeration via `updateEnumeration` is the observation
    /// path; here the host drives installs directly after shields apply.
    ///
    /// When the current enumeration already names `app`, its mapping
    /// governs while the observation is still recorded: the retained
    /// entry is filtered out of placement, so it can neither widen
    /// allowlist coverage nor linger in an active unlock, and it restores
    /// the shield if the app is later unpicked. The app keeps its
    /// enumeration placement (shielded when non-allowlisted).
    ///
    /// The updated observation set is persisted best-effort when an
    /// observed-install store is provided; in-memory and backend state
    /// always commit regardless, so current-process enforcement never
    /// depends on the write — only restart recovery does.
    public func noteInstalledApp(_ app: AppRef, category: AppCategoryRef? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let prior = observedInstalls.first(where: { $0.app == app })?.category
        observedInstalls = observedInstalls.filter { $0.app != app }
        observedInstalls.insert(EnumeratedApp(app: app, category: category ?? prior))
        try? observedInstallStore?.saveObservedInstalls(observedInstalls)
        refreshLocked()
    }

    /// The most recently applied shield configuration.
    public var currentConfiguration: ShieldConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return lastConfiguration
    }

    /// Effective shielding: the backend's applied state plus T2.5
    /// default-deny for never-observed apps.
    ///
    /// This is the launch gate: launch decisions must route through this
    /// query, never through `ShieldBackend.isShielded` alone. The
    /// backend answers only the enforced observed/enumerated state and
    /// cannot name an app it has never observed, so it leaves a fresh,
    /// never-enumerated app open outside the category backstop; this
    /// query closes that gap.
    ///
    /// A backend shield always wins — install-observed apps are shielded
    /// in the applied configuration itself. Otherwise, while shields are
    /// active, the app stays open only when the current policy
    /// allowlists it or an open window unlocks it; every other app —
    /// including one that was never observed and presents an unknown
    /// token or category — resolves to locked until a policy sync
    /// classifies it. T2.2 semantics for classified apps are unchanged:
    /// this only closes the unknown path that previously resolved to
    /// allowed.
    ///
    /// The default-deny fallback is scoped to active shields (see
    /// `shieldsActive`): before any policy/configuration has been
    /// applied — fresh manager, setup incomplete, or a relaunch whose
    /// committed enumeration was withheld pending reauthorization —
    /// the query falls through to backend state, so an inactive shield
    /// system never reports protection it has not applied.
    public func isShielded(app: AppRef, category: AppCategoryRef? = nil) -> Bool {
        if backend.isShielded(app: app, category: category) {
            return true
        }
        if policyStore.currentPolicy.alwaysAllowed.contains(app) {
            return false
        }
        lock.lock()
        let unlocked = window?.unlockedApps.contains(app) ?? false
        let active = shieldsActive
        lock.unlock()
        if unlocked {
            return false
        }
        return active
    }

    // MARK: - Unlock

    /// Grants an unlock for one challenge-unlockable app for
    /// `duration` seconds (monotonic). Returns false — leaving shields
    /// untouched — when the policy does not allow a challenge unlock
    /// for `app` (always-allowed apps need none; never-unlockable or
    /// unlisted apps get none), when `duration` is not positive, or
    /// when the new window cannot be durably persisted. A reported
    /// success always leaves the app unshielded: when its enumeration
    /// category is unknown or missing and no explicit `category` is
    /// supplied, the category backstop is disabled while the window is
    /// open (mirroring the allowlist fallback) instead of leaving a
    /// category shield active over the unlock.
    @discardableResult
    public func grantUnlock(
        for app: AppRef,
        category: AppCategoryRef? = nil,
        duration: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard duration > 0, policyStore.currentPolicy.isChallengeUnlockable(app) else {
            return false
        }
        var explicit: Set<AppCategoryRef> = []
        if let category { explicit.insert(category) }
        var lookedUp: Set<AppCategoryRef> = []
        if let found = enumeration.apps.first(where: { $0.app == app })?.category {
            lookedUp.insert(found)
        }
        return openWindowLocked(
            apps: [app],
            categories: explicit.union(lookedUp),
            explicit: explicit,
            duration: duration
        )
    }

    /// Grants an unlock for every enumerated challenge-unlockable app
    /// for `duration` seconds (monotonic). Returns false when no app
    /// qualifies, `duration` is not positive, or persistence fails. A
    /// reported success always leaves every unlocked app unshielded:
    /// when any unlocked app has unknown or missing category metadata,
    /// the category backstop is disabled while the window is open.
    @discardableResult
    public func grantUnlockForAllChallengeUnlockable(duration: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard duration > 0 else { return false }
        let policy = policyStore.currentPolicy
        var apps: Set<AppRef> = []
        var categories: Set<AppCategoryRef> = []
        for entry in enumeration.apps where policy.isChallengeUnlockable(entry.app) {
            apps.insert(entry.app)
            if let category = entry.category { categories.insert(category) }
        }
        guard !apps.isEmpty else { return false }
        return openWindowLocked(
            apps: apps, categories: categories, explicit: [], duration: duration
        )
    }

    /// Convenience: grant using the policy's practice unlock duration.
    @discardableResult
    public func grantPracticeUnlock(for app: AppRef, category: AppCategoryRef? = nil) -> Bool {
        let minutes = policyStore.currentPolicy.unlockDurations.practiceMinutes
        return grantUnlock(for: app, category: category, duration: TimeInterval(minutes) * 60)
    }

    /// Immediately re-locks: durably removes any open window and
    /// re-applies. A missing window file counts as success; any other
    /// deletion failure is thrown and the in-memory window is preserved
    /// so revocation is never reported complete before durable removal.
    public func revokeUnlock() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try unlockStore.clearUnlockWindow()
        } catch {
            throw error
        }
        window = nil
        refreshLocked()
    }

    /// True while an unlock window is open and unexpired.
    public var isUnlockActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return window != nil
    }

    /// Remaining unlock seconds on the monotonic clock; 0 when no
    /// window is open or the window has expired. Wall-clock changes
    /// have no effect on this value.
    public var remainingUnlockTime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        guard let window else { return 0 }
        return max(0, window.remaining(atUptime: clock.nowUptime))
    }

    /// The open window, if any (after expiry re-evaluation).
    public var currentUnlockWindow: UnlockWindow? {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return window
    }

    // MARK: - Expiry

    /// Re-evaluates expiry against the monotonic clock and re-applies
    /// shields if the window has ended. Callers may call this on any
    /// lifecycle event; expiry monitoring calls it automatically.
    public func refresh() {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
    }

    /// Starts automatic re-lock: polls the monotonic clock and applies
    /// shields as soon as the window expires. Idempotent.
    public func startExpiryMonitoring(pollInterval: TimeInterval = 1) {
        lock.lock()
        if monitorTask != nil {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0.01, pollInterval) * 1_000_000_000)
                )
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
        monitorTask = task
        lock.unlock()
    }

    /// Stops automatic re-lock polling.
    public func stopExpiryMonitoring() {
        lock.lock()
        monitorTask?.cancel()
        monitorTask = nil
        lock.unlock()
    }

    // MARK: - Internals (caller holds `lock`, except at init)

    /// Persists the new window first and commits it to memory and the
    /// backend only on success. Returns false without touching current
    /// state when persistence fails.
    @discardableResult
    private func openWindowLocked(
        apps: Set<AppRef>,
        categories: Set<AppCategoryRef>,
        explicit: Set<AppCategoryRef>,
        duration: TimeInterval
    ) -> Bool {
        let newWindow = UnlockWindow(
            unlockedApps: apps,
            unlockedCategories: categories,
            grantedAtUptime: clock.nowUptime,
            duration: duration,
            grantedWallDate: nowWallDate(),
            bootSessionID: bootSession.currentBootSessionID,
            explicitCategories: explicit,
            policyVersion: policyStore.currentPolicy.version
        )
        do {
            try unlockStore.saveUnlockWindow(newWindow)
        } catch {
            return false
        }
        window = newWindow
        reconciliationUnpersisted = false
        refreshLocked()
        return true
    }

    /// Expires the window if due (boot mismatch, uptime regression, or
    /// elapsed duration), reconciles it against the current policy and
    /// enumeration, recomputes the configuration, and applies it. A
    /// reconciliation whose persistence previously failed is retried, so
    /// a transient write failure cannot leave a stale record behind.
    private func refreshLocked() {
        if let current = window {
            let now = clock.nowUptime
            if let storedID = current.bootSessionID,
               let currentID = bootSession.currentBootSessionID,
               storedID != currentID {
                window = nil
                try? unlockStore.clearUnlockWindow()
            } else if current.uptimeRegressed(atUptime: now)
                || current.remaining(atUptime: now) <= 0 {
                window = nil
                try? unlockStore.clearUnlockWindow()
            } else {
                reconcileWindowLocked()
            }
        } else if reconciliationUnpersisted {
            // A past reconciliation revoked the window in memory but its
            // clear failed: retry so a restart cannot resurrect the stale
            // record. A missing file counts as success.
            do {
                try unlockStore.clearUnlockWindow()
                reconciliationUnpersisted = false
            } catch {
                // Still failing: stay flagged and retry on a later refresh.
            }
        }
        // Applying shields from a real enumeration or a restored /
        // observed install engages the shield system for the T2.5
        // fallback. A bare refresh of a fresh manager (empty
        // enumeration, no observations) does not: shields stay
        // inactive until setup hands over an enumeration.
        if !enumeration.apps.isEmpty || !enumeration.categories.isEmpty
            || !observedInstalls.isEmpty {
            shieldsActive = true
        }
        let configuration = computeConfigurationLocked()
        lastConfiguration = configuration
        backend.applyShieldConfiguration(configuration)
    }

    /// Removes apps that stopped being challenge-unlockable under the
    /// current policy and recomputes category suppression from the
    /// current enumeration plus preserved explicit grant categories.
    /// When re-enumeration loses an unlocked app's category metadata,
    /// its suppression is dropped here and the configuration disables
    /// the backstop instead, so the app stays open until its window
    /// expires rather than re-locking mid-window. The narrowed window
    /// is stamped with the current policy version and re-persisted; a
    /// failed write is flagged and retried on later refreshes, and a
    /// restart refuses records whose version has drifted, so a removed
    /// app cannot come back from a stale record after the policy
    /// changes again.
    private func reconcileWindowLocked() {
        guard let current = window else { return }
        let policy = policyStore.currentPolicy
        let filtered = current.unlockedApps.filter { policy.isChallengeUnlockable($0) }
        if filtered.isEmpty {
            window = nil
            do {
                try unlockStore.clearUnlockWindow()
                reconciliationUnpersisted = false
            } catch {
                reconciliationUnpersisted = true
            }
            return
        }
        var lookedUp: Set<AppCategoryRef> = []
        for app in filtered {
            if let found = enumeration.apps.first(where: { $0.app == app })?.category {
                lookedUp.insert(found)
            }
        }
        var narrowed = current
        narrowed.unlockedApps = filtered
        narrowed.unlockedCategories = current.explicitCategories.union(lookedUp)
        narrowed.policyVersion = policy.version
        if narrowed != current || reconciliationUnpersisted {
            window = narrowed
            do {
                try unlockStore.saveUnlockWindow(narrowed)
                reconciliationUnpersisted = false
            } catch {
                reconciliationUnpersisted = true
            }
        }
    }

    private func computeConfigurationLocked() -> ShieldConfiguration {
        let policy = policyStore.currentPolicy
        let allowed = Set(policy.alwaysAllowed)
        let builtIns: Set<AppRef> = [.phone, .messages, .earnPlaySelf]

        // Placement sources: the setup enumeration plus post-setup
        // install observations (T2.5 default-deny). Retained observations
        // for enumerated apps are filtered out here, so the enumeration
        // mapping governs while named and no app is placed twice or
        // withholds a stale category; when later unpicked, the retained
        // entry restores placement. Either source places an app — a
        // non-allowlisted install is shielded individually in the
        // applied configuration until a sync classifies it, and an
        // allowlisted install withholds its category like a picked app.
        // An allowlisted app is covered when its enumeration mapping
        // (when named) or its observation (when unenumerated) names a
        // category, so a later observation can resolve coverage without
        // ever regressing it.
        let namedApps = Set(enumeration.apps.map(\.app))
        let effectiveObserved = observedInstalls.filter { !namedApps.contains($0.app) }
        var placements = enumeration.apps
        placements.append(contentsOf: effectiveObserved)
        var shieldedApps: Set<AppRef> = []
        var categoriesOfAllowed: Set<AppCategoryRef> = []
        var knownCategories: [AppRef: Set<AppCategoryRef>] = [:]
        for entry in placements {
            if allowed.contains(entry.app) {
                if let category = entry.category {
                    categoriesOfAllowed.insert(category)
                    knownCategories[entry.app, default: []].insert(category)
                }
            } else {
                shieldedApps.insert(entry.app)
            }
        }
        var allowlistCoverageIncomplete = false
        for app in allowed where !builtIns.contains(app) {
            if knownCategories[app, default: []].isEmpty {
                allowlistCoverageIncomplete = true
                break
            }
        }

        // Unlock coverage: a real unlocked app whose enumeration
        // category is unknown or missing — and which no caller-supplied
        // category covers — cannot have its actual category withheld,
        // so the backstop must be disabled while its window is open.
        // Otherwise the grant would report success while a category
        // shield stays active over the app. A single-app window with an
        // explicit grant category is covered by that category; built-ins
        // never need coverage, mirroring the allowlist rule.
        var unlockCoverageIncomplete = false
        if let window, !window.unlockedApps.isEmpty {
            let singleExplicitCovered =
                window.unlockedApps.count == 1 && !window.explicitCategories.isEmpty
            if !singleExplicitCovered {
                for app in window.unlockedApps where !builtIns.contains(app) {
                    let found = enumeration.apps.first(where: { $0.app == app })?.category
                        ?? effectiveObserved.first(where: { $0.app == app })?.category
                    if found == nil {
                        unlockCoverageIncomplete = true
                        break
                    }
                }
            }
        }

        // Category backstop: every category seen at setup, withholding
        // only categories that contain an always-allowed app (otherwise
        // the backstop would shield the allowlist, and only a per-app
        // exemption over the category shield could undo that — exactly
        // what this design must not rely on). When a real allowlisted
        // app has unknown or missing category metadata, the backstop is
        // disabled entirely to preserve allowlist access; likewise when
        // a real unlocked app has unresolved category coverage, so the
        // unlock takes effect and re-enumeration cannot re-lock it.
        var backstop = enumeration.categories
        for entry in enumeration.apps {
            if let category = entry.category { backstop.insert(category) }
        }
        if allowlistCoverageIncomplete || unlockCoverageIncomplete {
            backstop = []
        } else {
            backstop.subtract(categoriesOfAllowed)
        }

        // Open unlock window: remove the unlocked apps individually,
        // and withhold their categories from the backstop so the unlock
        // does not depend on an exemption overriding a category shield.
        // When unlock coverage is incomplete the backstop is already
        // empty, so every unlocked app is open regardless of its actual
        // category.
        if let window {
            shieldedApps.subtract(window.unlockedApps)
            backstop.subtract(window.unlockedCategories)
            // T2.5: withhold install-observed categories of unlocked apps
            // as well, so an observation arriving after the grant cannot
            // re-lock the app through the backstop. Retained entries for
            // enumerated apps are excluded, so an obsolete category
            // cannot linger in the unlock.
            for entry in effectiveObserved where window.unlockedApps.contains(entry.app) {
                if let category = entry.category { backstop.remove(category) }
            }
        }

        return ShieldConfiguration(
            shieldedApplications: shieldedApps,
            shieldedCategories: backstop
        )
    }
}
