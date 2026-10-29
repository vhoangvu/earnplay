import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.5 — Default-deny for new apps: any app not classified in the current
/// policy (including newly installed apps) is shielded until the next
/// policy sync classifies it. Category shields are the backstop that
/// catches a newly installed app before it is enumerated and classified.
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
        func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
            lock.lock()
            self.configuration = configuration
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

    /// A newly installed app is locked until policy sync classifies it.
    /// C is created AFTER the policy is applied and the manager is built —
    /// a fresh install, not a pre-existing unlisted fixture — and is never
    /// added to the enumeration, so the new-install path itself is verified.
    func testFreshlyInstalledAppIsLockedUntilPolicySyncClassifiesIt() {
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

        // Classified apps keep T2.2 semantics.
        XCTAssertTrue(manager.isShielded(app: Self.appA, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.appB, category: Self.social))

        // Fresh install AFTER setup: never enumerated, never classified.
        let freshC = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(freshC))

        // Via the category backstop: `social` is withheld (allowlisted B),
        // `games` remains, and the fresh app is caught through it.
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertTrue(manager.isShielded(app: freshC, category: Self.games))

        // Unknown token resolves to locked, never to allowed — even with
        // no category metadata or an unrecognized category.
        XCTAssertTrue(manager.isShielded(app: freshC, category: nil))
        XCTAssertTrue(
            manager.isShielded(
                app: freshC,
                category: AppCategoryRef(id: "unknown-\(UUID().uuidString)")
            )
        )
        XCTAssertFalse(manager.grantUnlock(for: freshC, duration: 60))

        // Only a policy sync classifying C changes its state.
        var classified = policyClassifyingAB(version: 2)
        classified.alwaysAllowed.append(freshC)
        XCTAssertEqual(policyStore.apply(classified), .applied)
        manager.refresh()
        XCTAssertFalse(manager.isShielded(app: freshC, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: freshC, category: nil))
    }

    /// An empty classification still shields a freshly installed app —
    /// unknown never resolves to allowed, with or without a backstop.
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

        // Even with no enumeration at all (no backstop), default-deny holds.
        manager.updateEnumeration(.empty)
        let freshD = AppRef(id: "com.example.fresh-install-\(UUID().uuidString)")
        XCTAssertTrue(manager.isShielded(app: freshD, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: freshD, category: nil))
    }
}
