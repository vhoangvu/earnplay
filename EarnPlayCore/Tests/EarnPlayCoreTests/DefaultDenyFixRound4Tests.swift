import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.5 fix round 4 — preserve unclassified shields across re-picks.
///
/// Fix 3's enumeration-wins rule deleted the observed entry for any app
/// the enumeration named. Re-picking without a policy sync then lost the
/// install identity: the unpicked app's individual backend shield
/// disappeared while the allowlisted peer suppressed the backstop,
/// leaving the app unshielded at the backend even though the manager
/// query still denied it.
///
/// Round 4 retains install identity: the observed entry is never deleted
/// just because the enumeration names the app. The enumeration's
/// category governs while the app is enumerated (via the effective-
/// observed filter in `computeConfigurationLocked`), and the observed
/// entry restores the individual shield when the app is later unpicked.
/// The same retention rule applies at all three prune sites (init
/// restore, `updateEnumeration`, `noteInstalledApp`), with the store
/// kept consistent with the in-memory set.
///
/// T2.2 classified-app semantics (classified A shielded in games,
/// allowlisted B unshielded in social) and the never-regress-coverage
/// guarantee for genuinely unenumerated observed apps are pinned
/// throughout and must not regress. Fix-3 F2 (stale-category
/// withholding) must stay fixed: while enumerated, only the
/// enumeration's category is withheld.
final class DefaultDenyFixRound4Tests: XCTestCase {
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
            .appendingPathComponent("DefaultDenyFixRound4-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - (a) observe -> enumerate -> unpick restores individual shield

    /// Observe unclassified C in social, enumerate C, then re-pick only
    /// A/B without syncing policy: C's individual backend shield must
    /// return. The probe in social stays open (B withholds social) while
    /// C in social is blocked via its individual shield — proving the
    /// shield is per-app, not the backstop.
    func testUnpickRestoresObservedIndividualShield() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumerationAB(),
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )

        let freshC = AppRef(id: "com.example.unclassified-c-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")

        // Observe: individual shield, backend-enforced.
        manager.noteInstalledApp(freshC, category: Self.social)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))

        // Enumerate C (e.g. picked in social): still shielded, now via
        // enumeration placement.
        var enumerated = enumerationAB()
        enumerated.apps.append(EnumeratedApp(app: freshC, category: Self.social))
        manager.updateEnumeration(enumerated)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))

        // Re-pick only A/B without a policy sync: C's observed identity
        // must restore its individual shield.
        manager.updateEnumeration(enumerationAB())
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: freshC, category: nil))
        XCTAssertTrue(backend.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: freshC, category: nil))

        // Individual shield, not backstop: social stays withheld for B,
        // so a probe in social is open while C in social is blocked.
        // Backstop is exactly [games].
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: probe, category: Self.games))

        // Classified-app semantics intact.
        XCTAssertTrue(manager.isShielded(app: Self.appA, category: Self.games))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))
    }

    // MARK: - (b) enumeration category governs while enumerated

    /// Observe allowlisted D in games, enumerate D in social: while
    /// enumerated, ONLY social is withheld (games shields again). The
    /// retained observed entry must not reintroduce stale-category
    /// withholding — fix-3 F2 stays fixed.
    func testEnumerationCategoryGovernsWhileEnumerated() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumerationAB(),
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )

        let appD = AppRef(id: "com.example.allowlisted-d-\(UUID().uuidString)")
        var classified = policyClassifyingAB(version: 2)
        classified.alwaysAllowed.append(appD)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()

        // Observe D in games: both games and social withheld (D + B).
        manager.noteInstalledApp(appD, category: Self.games)
        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.games))
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.social))

        // Enumerate D in social: enumeration wins — games returns to the
        // backstop, social stays withheld. The retained D/games
        // observation must not linger.
        var reenumerated = enumerationAB()
        reenumerated.apps.append(EnumeratedApp(app: appD, category: Self.social))
        manager.updateEnumeration(reenumerated)

        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        XCTAssertTrue(backend.isShielded(app: probe, category: Self.games))
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: appD, category: Self.social))
        XCTAssertFalse(backend.isShielded(app: appD, category: Self.social))
        // Classified-app semantics intact.
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))
    }

    // MARK: - (c) restart retains enumerated observation

    /// Observe C, enumerate C, restart with the enumeration still naming
    /// C, then unpick C: the restored observed entry must bring C's
    /// individual shield back. Without init retention, the restart
    /// prunes C and the unpick leaves C unshielded at the backend.
    func testRestartRetainsEnumeratedObservation() {
        let freshC = AppRef(id: "com.example.unclassified-c-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)

        var enumerated = enumerationAB()
        enumerated.apps.append(EnumeratedApp(app: freshC, category: Self.social))

        do {
            let backend1 = SimulatedShieldBackend()
            let manager = ShieldManager(
                policyStore: PolicyStore(directory: directory),
                enumeration: enumerationAB(),
                backend: backend1,
                clock: FakeMonotonicClock(),
                unlockStore: FileUnlockWindowStore(directory: directory),
                observedInstallStore: FileObservedInstallStore(directory: directory)
            )
            manager.noteInstalledApp(freshC, category: Self.social)
            XCTAssertTrue(backend1.isShielded(app: freshC, category: Self.social))
            manager.updateEnumeration(enumerated)
            XCTAssertTrue(backend1.isShielded(app: freshC, category: Self.social))
            // Store must still hold the retained entry while enumerated.
            let stored = FileObservedInstallStore(directory: directory).loadObservedInstalls()
            XCTAssertTrue(stored.contains(where: { $0.app == freshC }))
        }

        // Restart-equivalent: same directory, enumeration still names C.
        let backend2 = SimulatedShieldBackend()
        let manager2 = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: enumerated,
            backend: backend2,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory),
            observedInstallStore: FileObservedInstallStore(directory: directory)
        )
        XCTAssertEqual(backend2.applyCount, 1)
        XCTAssertTrue(manager2.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: Self.social))

        // Unpick C without a policy sync: observed identity restores the
        // individual shield.
        manager2.updateEnumeration(enumerationAB())
        XCTAssertTrue(manager2.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend2.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: nil))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(manager2.isShielded(app: freshC, category: nil))
        XCTAssertEqual(manager2.currentConfiguration.shieldedCategories, [Self.games])
        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertFalse(backend2.isShielded(app: probe, category: Self.social))
        XCTAssertTrue(manager2.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager2.isShielded(app: Self.appB, category: Self.social))
    }

    // MARK: - (d) observation while enumerated is retained

    /// Enumerate unclassified C first, then observe C while enumerated,
    /// then unpick: the while-enumerated observation must be recorded
    /// (not dropped) so the unpick restores C's individual shield. While
    /// enumerated, the enumeration placement governs.
    func testObservationWhileEnumeratedRetainedForLaterUnpick() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let freshC = AppRef(id: "com.example.unclassified-c-\(UUID().uuidString)")

        var enumerated = enumerationAB()
        enumerated.apps.append(EnumeratedApp(app: freshC, category: Self.social))
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumerated,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory),
            observedInstallStore: FileObservedInstallStore(directory: directory)
        )
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))

        // Observe while enumerated: enumeration still governs (C stays
        // shielded via placement, backstop unchanged), but the install
        // identity must be recorded and persisted.
        manager.noteInstalledApp(freshC, category: Self.social)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        let stored = FileObservedInstallStore(directory: directory).loadObservedInstalls()
        XCTAssertTrue(stored.contains(where: { $0.app == freshC }))

        // Unpick without a policy sync: retained observation restores the
        // individual shield.
        manager.updateEnumeration(enumerationAB())
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend.isShielded(app: freshC, category: nil))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))
        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))
    }
}
