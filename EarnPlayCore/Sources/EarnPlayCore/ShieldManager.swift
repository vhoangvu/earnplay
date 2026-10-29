import Foundation

/// An open unlock window, persisted so it can be re-evaluated after a
/// restart. All timing fields are on the monotonic (uptime) clock;
/// `grantedWallDate` is recorded only for display/audit and is never
/// used to compute expiry.
public struct UnlockWindow: Codable, Equatable, Sendable {
    /// Apps opened by this window.
    public var unlockedApps: Set<AppRef>
    /// Categories withheld from the backstop while this window is open
    /// (the unlocked apps' categories), so no per-app exemption over a
    /// category shield is needed for the unlock to take effect.
    public var unlockedCategories: Set<AppCategoryRef>
    /// Monotonic uptime at grant.
    public var grantedAtUptime: TimeInterval
    /// Set duration in seconds.
    public var duration: TimeInterval
    /// Wall-clock date at grant (display/audit only; never expiry).
    public var grantedWallDate: Date

    public init(
        unlockedApps: Set<AppRef>,
        unlockedCategories: Set<AppCategoryRef>,
        grantedAtUptime: TimeInterval,
        duration: TimeInterval,
        grantedWallDate: Date
    ) {
        self.unlockedApps = unlockedApps
        self.unlockedCategories = unlockedCategories
        self.grantedAtUptime = grantedAtUptime
        self.duration = duration
        self.grantedWallDate = grantedWallDate
    }

    /// Monotonic uptime at which the window expires.
    public var expiryUptime: TimeInterval { grantedAtUptime + duration }

    /// Remaining seconds at monotonic time `now`; negative when expired.
    public func remaining(atUptime now: TimeInterval) -> TimeInterval {
        expiryUptime - now
    }

    /// True when uptime has gone backwards since grant — the device
    /// rebooted (uptime reset), so elapsed time on this clock cannot
    /// be trusted and the window must not be extended.
    public func uptimeRegressed(atUptime now: TimeInterval) -> Bool {
        now < grantedAtUptime
    }
}

/// Persistence seam for the open unlock window.
///
/// Production uses `FileUnlockWindowStore`; tests may use the same file
/// store over a temporary directory (relaunch-equivalent restart).
public protocol UnlockWindowStore: Sendable {
    func loadUnlockWindow() -> UnlockWindow?
    func saveUnlockWindow(_ window: UnlockWindow)
    func clearUnlockWindow()
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

    public func saveUnlockWindow(_ window: UnlockWindow) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(window) else { return }
        try? data.write(
            to: directory.appendingPathComponent(Self.windowFileName),
            options: [.atomic]
        )
    }

    public func clearUnlockWindow() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(
            at: directory.appendingPathComponent(Self.windowFileName)
        )
    }
}

/// Applies and removes shields from policy (T2.2).
///
/// Enumeration-first: every app enumerated at setup except the policy
/// allowlist (`Policy.alwaysAllowed`) is shielded individually, and
/// category shields backstop newly installed apps that are not yet
/// enumerated. No per-app exemption overriding a category shield is
/// used anywhere — see `ShieldConfiguration`.
///
/// Unlock timers run on an injected `MonotonicClock` (system uptime in
/// production). Changing the device wall clock cannot extend an
/// unlock: wall time is recorded at grant for display only and never
/// read for expiry. On expiry the manager re-applies shields
/// automatically (via expiry monitoring, or `refresh()`), and on
/// initialisation it re-evaluates any persisted open window after a
/// restart — resuming it on the same boot, re-locking fail-closed if
/// it expired or if uptime regressed (device reboot).
///
/// All backend access goes through `ShieldBackend`, so T2.4's
/// simulated backend substitutes without changing this class.
public final class ShieldManager: @unchecked Sendable {
    private let policyStore: PolicyStore
    private let backend: any ShieldBackend
    private let clock: any MonotonicClock
    private let unlockStore: any UnlockWindowStore
    private let nowWallDate: @Sendable () -> Date

    private let lock = NSLock()
    private var enumeration: ShieldEnumeration
    private var window: UnlockWindow?
    private var lastConfiguration: ShieldConfiguration = .none
    private var monitorTask: Task<Void, Never>?

    /// Creates a manager and immediately re-evaluates state: any
    /// persisted unlock window is resumed or expired, and the correct
    /// shield configuration is applied to the backend. This is the
    /// restart path — a relaunched app gets the same effective shields
    /// it had, with elapsed monotonic time accounted for.
    ///
    /// `nowWallDate` is injected only so tests can jump the wall clock;
    /// it never influences expiry.
    public init(
        policyStore: PolicyStore,
        enumeration: ShieldEnumeration,
        backend: any ShieldBackend,
        clock: any MonotonicClock = SystemUptimeClock(),
        unlockStore: any UnlockWindowStore,
        nowWallDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policyStore = policyStore
        self.enumeration = enumeration
        self.backend = backend
        self.clock = clock
        self.unlockStore = unlockStore
        self.nowWallDate = nowWallDate
        self.window = unlockStore.loadUnlockWindow()
        refreshLocked()
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Shield application

    /// Recomputes shields from the current policy + enumeration and
    /// applies them, honouring any still-open unlock window.
    public func applyShields() {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
    }

    /// Replaces the setup enumeration (e.g. after a re-pick in T2.3, or
    /// after a newly installed app is enumerated) and re-applies.
    public func updateEnumeration(_ enumeration: ShieldEnumeration) {
        lock.lock()
        defer { lock.unlock() }
        self.enumeration = enumeration
        refreshLocked()
    }

    /// The most recently applied shield configuration.
    public var currentConfiguration: ShieldConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return lastConfiguration
    }

    /// Effective shielding, delegated to the backend's applied state.
    public func isShielded(app: AppRef, category: AppCategoryRef? = nil) -> Bool {
        backend.isShielded(app: app, category: category)
    }

    // MARK: - Unlock

    /// Grants an unlock for one challenge-unlockable app for
    /// `duration` seconds (monotonic). Returns false — leaving shields
    /// untouched — when the policy does not allow a challenge unlock
    /// for `app` (always-allowed apps need none; never-unlockable or
    /// unlisted apps get none) or when `duration` is not positive.
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
        let resolvedCategory = category
            ?? enumeration.apps.first { $0.app == app }?.category
        var categories: Set<AppCategoryRef> = []
        if let resolvedCategory { categories.insert(resolvedCategory) }
        openWindowLocked(
            apps: [app], categories: categories, duration: duration
        )
        return true
    }

    /// Grants an unlock for every enumerated challenge-unlockable app
    /// for `duration` seconds (monotonic). Returns false when no app
    /// qualifies or `duration` is not positive.
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
        openWindowLocked(apps: apps, categories: categories, duration: duration)
        return true
    }

    /// Convenience: grant using the policy's practice unlock duration.
    @discardableResult
    public func grantPracticeUnlock(for app: AppRef, category: AppCategoryRef? = nil) -> Bool {
        let minutes = policyStore.currentPolicy.unlockDurations.practiceMinutes
        return grantUnlock(for: app, category: category, duration: TimeInterval(minutes) * 60)
    }

    /// Immediately re-locks: clears any open window and re-applies.
    public func revokeUnlock() {
        lock.lock()
        defer { lock.unlock() }
        window = nil
        unlockStore.clearUnlockWindow()
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

    private func openWindowLocked(
        apps: Set<AppRef>, categories: Set<AppCategoryRef>, duration: TimeInterval
    ) {
        let newWindow = UnlockWindow(
            unlockedApps: apps,
            unlockedCategories: categories,
            grantedAtUptime: clock.nowUptime,
            duration: duration,
            grantedWallDate: nowWallDate()
        )
        window = newWindow
        unlockStore.saveUnlockWindow(newWindow)
        refreshLocked()
    }

    /// Expires the window if due (or if uptime regressed), recomputes
    /// the configuration, and applies it to the backend.
    private func refreshLocked() {
        if let current = window {
            let now = clock.nowUptime
            if current.uptimeRegressed(atUptime: now)
                || current.remaining(atUptime: now) <= 0 {
                window = nil
                unlockStore.clearUnlockWindow()
            }
        }
        let configuration = computeConfigurationLocked()
        lastConfiguration = configuration
        backend.applyShieldConfiguration(configuration)
    }

    private func computeConfigurationLocked() -> ShieldConfiguration {
        let policy = policyStore.currentPolicy
        let allowed = Set(policy.alwaysAllowed)

        var shieldedApps: Set<AppRef> = []
        var categoriesOfAllowed: Set<AppCategoryRef> = []
        for entry in enumeration.apps {
            if allowed.contains(entry.app) {
                if let category = entry.category {
                    categoriesOfAllowed.insert(category)
                }
            } else {
                shieldedApps.insert(entry.app)
            }
        }

        // Category backstop: every category seen at setup, withholding
        // only categories that contain an always-allowed app (otherwise
        // the backstop would shield the allowlist, and only a per-app
        // exemption over the category shield could undo that — exactly
        // what this design must not rely on).
        var backstop = enumeration.categories
        for entry in enumeration.apps {
            if let category = entry.category { backstop.insert(category) }
        }
        backstop.subtract(categoriesOfAllowed)

        // Open unlock window: remove the unlocked apps individually,
        // and withhold their categories from the backstop so the unlock
        // does not depend on an exemption overriding a category shield.
        if let window {
            shieldedApps.subtract(window.unlockedApps)
            backstop.subtract(window.unlockedCategories)
        }

        return ShieldConfiguration(
            shieldedApplications: shieldedApps,
            shieldedCategories: backstop
        )
    }
}
