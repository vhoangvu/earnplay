import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.5 fix round 3 — regression tests for the three review findings.
///
/// 1. Install observations persist across manager recreation: a
///    recreated manager restores observed installs before its initial
///    configuration is applied, keeping every observed shield.
/// 2. Re-enumeration reconciles superseded categories: when the
///    enumeration names an app, its mapping wins and the observed entry
///    for that app is dropped — while coverage for genuinely
///    unenumerated observed apps never regresses.
/// 3. The launch gate (`ShieldManager.isShielded`) denies a fresh,
///    never-observed app before its first launch; the backend answers
///    only enforced observed/enumerated state and is not the gate.
///
/// T2.2 classified-app semantics (classified A shielded in games,
/// allowlisted B unshielded in social) and the round-2 resolutions
/// (backend-enforced observations, simulated install transition) are
/// pinned throughout and must not regress.
final class DefaultDenyFixRound3Tests: XCTestCase {
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
    private static let movies = AppCategoryRef(id: "movies")
    private static let appA = AppRef(id: "com.example.app-a")
    private static let appB = AppRef(id: "com.example.app-b")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultDenyFixRound3-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Finding 1: observations survive recreation

    /// A recreated manager restores observed installs before its initial
    /// configuration is applied: one apply, and C is already shielded in
    /// it — backend-enforced, in every category.
    func testRecreatedManagerRestoresObservedInstallShield() {
        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")
        let backend1 = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        do {
            let manager = ShieldManager(
                policyStore: policyStore,
                enumeration: enumerationAB(),
                backend: backend1,
                clock: FakeMonotonicClock(),
                unlockStore: FileUnlockWindowStore(directory: directory),
                observedInstallStore: FileObservedInstallStore(directory: directory)
            )
            manager.noteInstalledApp(freshC, category: Self.social)
            XCTAssertTrue(backend1.isShielded(app: freshC, category: Self.social))
        }

        // Restart-equivalent: fresh backend and stores over the same
        // directory, same setup enumeration.
        let backend2 = SimulatedShieldBackend()
        let manager2 = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: enumerationAB(),
            backend: backend2,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory),
            observedInstallStore: FileObservedInstallStore(directory: directory)
        )
        XCTAssertEqual(backend2.applyCount, 1)
        XCTAssertTrue(manager2.currentConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend2.currentShieldConfiguration.shieldedApplications.contains(freshC))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: nil))
        XCTAssertTrue(backend2.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(manager2.isShielded(app: freshC, category: nil))
        // Classified-app semantics intact across the restart.
        XCTAssertTrue(manager2.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager2.isShielded(app: Self.appB, category: Self.social))
    }

    // MARK: - Finding 2: enumeration wins on re-enumeration

    /// Observe allowlisted D in games, re-enumerate D in social: the
    /// enumeration mapping wins — games returns to the backstop, social
    /// stays withheld — while a genuinely unenumerated observed app E
    /// keeps its movies coverage (never-regress).
    func testReenumerationSupersedesObservedCategory() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let base = ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.appA, category: Self.games),
                EnumeratedApp(app: Self.appB, category: Self.social),
            ],
            categories: [Self.games, Self.social, Self.movies]
        )
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: base,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        let appD = AppRef(id: "com.example.allowlisted-d-\(UUID().uuidString)")
        let appE = AppRef(id: "com.example.allowlisted-e-\(UUID().uuidString)")
        var classified = policyClassifyingAB(version: 2)
        classified.alwaysAllowed.append(appD)
        classified.alwaysAllowed.append(appE)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()

        manager.noteInstalledApp(appD, category: Self.games)
        manager.noteInstalledApp(appE, category: Self.movies)
        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.games))

        var reenumerated = base
        reenumerated.apps.append(EnumeratedApp(app: appD, category: Self.social))
        manager.updateEnumeration(reenumerated)

        // Enumeration wins for D: games shields again, social withheld.
        // E is genuinely unenumerated, so movies stays withheld.
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        XCTAssertTrue(backend.isShielded(app: probe, category: Self.games))
        XCTAssertFalse(backend.isShielded(app: probe, category: Self.movies))
        XCTAssertFalse(manager.isShielded(app: appD, category: Self.social))
        XCTAssertFalse(backend.isShielded(app: appD, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: appE, category: Self.movies))
        // Classified-app semantics intact.
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))
    }

    /// An observation for an enumerated app is dropped even during an
    /// active unlock, so no obsolete category lingers in the window:
    /// unlocking enumerated E (social) and then observing E in games
    /// must not withhold games.
    func testObservationOfEnumeratedAppDoesNotWidenUnlock() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(policyClassifyingAB()), .applied)
        let appE = AppRef(id: "com.example.unlock-e-\(UUID().uuidString)")
        var classified = policyClassifyingAB(version: 2)
        classified.unblockable.append(appE)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        var enumeration = enumerationAB()
        enumeration.apps.append(EnumeratedApp(app: appE, category: Self.social))
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )

        XCTAssertTrue(manager.grantUnlock(for: appE, duration: 60))
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        manager.noteInstalledApp(appE, category: Self.games)

        let probe = AppRef(id: "com.example.probe-\(UUID().uuidString)")
        XCTAssertEqual(manager.currentConfiguration.shieldedCategories, [Self.games])
        XCTAssertTrue(backend.isShielded(app: probe, category: Self.games))
        XCTAssertTrue(backend.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: appE, category: Self.social))
        XCTAssertFalse(backend.isShielded(app: appE, category: Self.social))
    }

    // MARK: - Finding 3: gate denies before observation

    /// The launch gate denies a fresh, never-observed app in
    /// social/nil/unknown categories before its first launch, while
    /// classified semantics and exemptions hold.
    func testLaunchGateDeniesFreshAppBeforeObservation() {
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

        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: freshC, category: nil))
        XCTAssertTrue(manager.isShielded(app: freshC, category: unknownCategory))
        XCTAssertTrue(
            manager.isShielded(
                app: AppRef(id: "unknown-token-\(UUID().uuidString)"),
                category: Self.social
            )
        )
        XCTAssertTrue(manager.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: nil))
    }
}
