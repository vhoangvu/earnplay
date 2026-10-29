import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.5 — Default-deny for new apps: any app not classified in the current
/// policy (including newly installed apps) is shielded until the next
/// policy sync classifies it.
///
/// Two enforcement layers: an install observed via `noteInstalledApp`
/// (the host-side simulated install transition, driven after shields
/// apply) is shielded individually in the APPLIED configuration, so the
/// backend itself — the launch gate in the simulated scope — reports
/// blocked; an app never observed stays open only when allowlisted or
/// unlocked, so an unknown token or category resolves to locked rather
/// than to allowed. T2.2 semantics for classified apps and the
/// always-allowed/unlocked exemptions are unchanged.
///
/// Demo verification runs against a simulated backend. Real shield
/// enforcement (ManagedSettings, v1) is NOT verified here.
final class DefaultDenyTests: XCTestCase {
    private var directory: URL!

    private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var uptime: TimeInterval = 1_000
        var nowUptime: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
        }
    }

    private final class SimulatedShieldBackend: ShieldBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var configuration: ShieldConfiguration = .none
        private(set) var applyCount = 0
        func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
            lock.lock()
            self.configuration = configuration
            applyCount += 1
            lock.unlock()
        }
        var currentShieldConfiguration: ShieldConfiguration {
            lock.lock()
            defer { lock.unlock() }
            return configuration
        }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let social = AppCategoryRef(id: "social")
    private static let appA = AppRef(id: "com.example.app-a")
    private static let appB = AppRef(id: "com.example.app-b")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultDenyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func policyClassifyingAB(version: Int = 1) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [.phone, Self.appB],
            unblockable: [Self.appA],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
    }

    private func enumerationAB() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.appA, category: Self.games),
                EnumeratedApp(app: Self.appB, category: Self.social),
            ],
            categories: [Self.games, Self.social]
        )
    }

    private func makeManager(
        backend: SimulatedShieldBackend, policyStore: PolicyStore
    ) -> ShieldManager {
        ShieldManager(
            policyStore: policyStore,
            enumeration: enumerationAB(),
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    /// A newly installed app is backend-enforced as locked until a policy
    /// sync classifies it. C is created AFTER the policy is applied and
    /// the manager is built — a fresh install, not a pre-existing
    /// unlisted fixture — and its install is then observed, so the
    /// new-install path itself is verified through the applied
    /// configuration, not just the query answer.
    func testFreshlyInstalledAppIsLockedUntilPolicySyncClassifiesIt() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = makeManager(backend: backend, policyStore: policyStore)

        // Classified apps keep T2.2 semantics.
        XCTAssertTrue(manager.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))

        // Fresh install AFTER setup: never enumerated, never classified.
        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")

        // Pre-install layer boundary: the query already reports locked,
        // and the backend enforces where the category backstop reaches
        // (`games` remains; `social` is withheld for allowlisted B) — but
        // the applied configuration cannot shield an app it has never
        // observed, so the backend leaves C open everywhere else.
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.social))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.games))
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertFalse(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertFalse(backend.isShielded(app: freshC, category: nil))
        XCTAssertFalse(backend.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: freshC, category: nil))
        XCTAssertTrue(manager.isShielded(app: freshC, category: unknownCategory))

        // Simulated install transition AFTER shields are applied: manager
        // AND backend observe it — the applied configuration gains C and
        // the backend (the launch gate) reports blocked.
        let appliesBefore = backend.applyCount
        manager.noteInstalledApp(freshC, category: Self.social)
        XCTAssertGreaterThan(backend.applyCount, appliesBefore)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: freshC, category: nil))
        XCTAssertTrue(backend.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertFalse(manager.grantUnlock(for: freshC, duration: 60))

        // Only a policy sync classifying C changes its state: allowlisted
        // → the applied shield drops and launch is allowed.
        var classified = policyClassifyingAB(version: 2)
        classified.alwaysAllowed.append(freshC)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertFalse(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertFalse(backend.isShielded(app: freshC, category: nil))
        XCTAssertFalse(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: freshC, category: nil))
        // C's observed category keeps the backstop precise: `games` still
        // shields, and classified A stays blocked.
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
    }

    /// A simulated install stays launch-blocked when the classifying sync
    /// keeps the app shielded: blocked pre-sync, still blocked post-sync,
    /// and unlockable now that it is classified.
    func testSimulatedInstallStillBlockedWhenSyncClassifiesAsShielded() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = makeManager(backend: backend, policyStore: policyStore)

        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        manager.noteInstalledApp(freshC, category: Self.social)

        // Launch blocked pre-sync, backend-enforced.
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))

        // Classifying sync: C becomes challenge-unlockable and enumerated
        // — still shielded (now as a classified app), still enforced.
        var classified = policyClassifyingAB(version: 2)
        classified.unblockable.append(freshC)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        var enumeration = enumerationAB()
        enumeration.apps.append(EnumeratedApp(app: freshC, category: Self.social))
        manager.updateEnumeration(enumeration)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))

        // Classified (no longer unknown), C can now earn an unlock, which
        // opens it through the applied configuration — and only it.
        XCTAssertTrue(manager.grantUnlock(for: freshC, duration: 60))
        XCTAssertFalse(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
    }

    /// Always-allowed installs stay unshielded: an enumerated allowlisted
    /// install withholds its category without joining the applied shield
    /// set, a metadata-less report never flaps the backstop, and an
    /// allowlisted-but-never-enumerated install observed with its category
    /// resolves coverage instead of disabling the backstop.
    func testAlwaysAllowedInstallsStayUnshielded() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = makeManager(backend: backend, policyStore: policyStore)

        manager.noteInstalledApp(Self.appB, category: Self.social)
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(Self.appB))
        XCTAssertFalse(backend.isShielded(app: Self.appB, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))

        // Unknown-category report for the same app: sticky knowledge, no
        // backstop flap — `games` still shields classified A.
        manager.noteInstalledApp(Self.appB)
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(Self.appB))
        XCTAssertFalse(backend.isShielded(app: Self.appB, category: Self.social))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))

        // Allowlisted but never enumerated: pre-observation the backstop
        // is disabled (unresolved coverage), and the install observation
        // resolves it.
        let allowedD = AppRef(id: "com.example.allowed-fresh-\(UUID().uuidString)")
        var classified = policyClassifyingAB(version: 2)
        classified.alwaysAllowed.append(allowedD)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: allowedD, category: Self.social))
        manager.noteInstalledApp(allowedD, category: Self.social)
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(allowedD))
        XCTAssertFalse(backend.isShielded(app: allowedD, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: allowedD, category: nil))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
    }

    /// An unlocked install stays open through the applied configuration:
    /// the observation arriving after the grant cannot re-lock the app,
    /// peers stay blocked, and ending the window re-blocks the app with
    /// backend enforcement.
    func testUnlockedInstallStaysOpenUntilWindowEnds() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = makeManager(backend: backend, policyStore: policyStore)

        let appE = AppRef(id: "com.example.unlock-fresh-\(UUID().uuidString)")
        var classified = policyClassifyingAB(version: 2)
        classified.unblockable.append(appE)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()

        XCTAssertTrue(manager.grantUnlock(for: appE, duration: 60))
        XCTAssertFalse(manager.isShielded(app: appE, category: Self.games))

        manager.noteInstalledApp(appE, category: Self.games)
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(appE))
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.contains(appE))
        XCTAssertFalse(backend.isShielded(app: appE, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: appE, category: Self.games))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))

        XCTAssertNoThrow(try manager.revokeUnlock())
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(appE))
        XCTAssertTrue(backend.isShielded(app: appE, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: appE, category: Self.games))
    }

    /// An empty classification still shields a freshly installed app —
    /// unknown never resolves to allowed, with or without a backstop —
    /// and observed installs are individually shielded in the applied
    /// configuration even with no enumeration at all.
    func testEmptyClassificationStillShieldsFreshInstall() {
        let backend = SimulatedShieldBackend()
        let empty = Policy(
            version: 1,
            alwaysAllowed: [],
            unblockable: [],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(empty), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumerationAB(),
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )

        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: freshC, category: nil))
        XCTAssertTrue(
            manager.isShielded(
                app: freshC,
                category: AppCategoryRef(id: "unknown-\(UUID().uuidString)")
            )
        )
        XCTAssertFalse(manager.grantUnlock(for: freshC, duration: 60))

        // Simulated install: backend-enforced via the applied shield set,
        // with or without category metadata.
        manager.noteInstalledApp(freshC, category: Self.games)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.games))
        XCTAssertTrue(backend.isShielded(app: freshC, category: nil))
        let freshD = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        manager.noteInstalledApp(freshD)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshD))
        XCTAssertTrue(backend.isShielded(app: freshD, category: nil))

        // Even with no enumeration at all (no backstop), default-deny
        // holds: observed installs are individually shielded, and installs
        // observed before the wipe survive it (install facts, not picks).
        manager.updateEnumeration(.empty)
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        let freshE = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        manager.noteInstalledApp(freshE, category: Self.social)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshE))
        XCTAssertTrue(backend.isShielded(app: freshE, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: freshE, category: nil))
        XCTAssertTrue(manager.isShielded(app: freshE, category: nil))
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.games))
    }
}
