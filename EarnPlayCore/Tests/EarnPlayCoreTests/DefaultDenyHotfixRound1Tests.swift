import Foundation
import XCTest
@testable import EarnPlayCore

/// Hotfix fix round 1 — regression tests for empty-enumeration shield
/// activation and latch preservation (`ShieldManager`).
///
/// Latch contract: `shieldsActive` starts false; a bare `refresh()` of a
/// fresh manager (empty enumeration, no observations) does not set it;
/// `applyShields()` and `updateEnumeration(_:)` set it unconditionally,
/// even for an empty enumeration; nothing ever clears it.
///
/// `testEmptyClassificationStillShieldsFreshInstall` cannot catch a
/// regression in these explicit activation paths: it starts with a
/// non-empty enumeration and retains install observations before its
/// `updateEnumeration(.empty)`, so the latch is already on for reasons
/// unrelated to explicit activation. These tests start from a fresh
/// manager with an empty enumeration and no observations, so the only
/// thing that can engage the latch is the explicit activation call.
///
/// Throughout, the backend configuration stays `.none`: the unknown app
/// is shielded by the launch-gate latch, never by backend enforcement.
final class DefaultDenyHotfixRound1Tests: XCTestCase {
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

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultDenyHotfixRound1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func emptyPolicy(version: Int = 1) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [],
            unblockable: [],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
    }

    private func makeEmptyManager(
        backend: SimulatedShieldBackend, policyStore: PolicyStore
    ) -> ShieldManager {
        ShieldManager(
            policyStore: policyStore,
            enumeration: .empty,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    private func assertBackendConfigurationNone(
        _ backend: SimulatedShieldBackend,
        _ manager: ShieldManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            manager.currentConfiguration, .none,
            "applied configuration must stay empty with no enumeration and no observations",
            file: file, line: line
        )
        XCTAssertEqual(
            backend.currentShieldConfiguration, .none,
            "backend configuration must stay empty with no enumeration and no observations",
            file: file, line: line
        )
    }

    /// (a) Fresh manager, empty enumeration, no observations: after
    /// `refresh()` the unknown app is UNSHIELDED (latch inactive, the
    /// gate falls through to backend state). (b) The same manager, then
    /// `applyShields()`: the unknown app becomes SHIELDED.
    func testFreshEmptyManagerRefreshLeavesUnknownUnshieldedUntilApplyShields() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(emptyPolicy()), .applied)
        let manager = makeEmptyManager(backend: backend, policyStore: policyStore)

        let unknown = AppRef(id: "com.example.unknown-refresh-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")

        // (a) Bare refresh does not engage the latch.
        manager.refresh()
        assertBackendConfigurationNone(backend, manager)
        XCTAssertFalse(backend.isShielded(app: unknown, category: nil))
        XCTAssertFalse(manager.isShielded(app: unknown, category: nil))
        XCTAssertFalse(manager.isShielded(app: unknown, category: unknownCategory))

        // (b) Explicit activation engages the latch even though there is
        // nothing to enforce: the backend stays open and the gate denies.
        manager.applyShields()
        assertBackendConfigurationNone(backend, manager)
        XCTAssertFalse(backend.isShielded(app: unknown, category: nil))
        XCTAssertFalse(backend.isShielded(app: unknown, category: unknownCategory))
        XCTAssertTrue(manager.isShielded(app: unknown, category: nil))
        XCTAssertTrue(manager.isShielded(app: unknown, category: unknownCategory))
    }

    /// (c) A separate fresh manager (empty enumeration, no observations):
    /// `updateEnumeration(.empty)` makes the unknown app SHIELDED.
    /// (d) Latch preservation: a later `updateEnumeration(.empty)`
    /// replacement keeps the unknown app SHIELDED.
    func testEmptyUpdateEnumerationEngagesLatchAndSurvivesReplacement() {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(emptyPolicy()), .applied)
        let manager = makeEmptyManager(backend: backend, policyStore: policyStore)

        let unknown = AppRef(id: "com.example.unknown-update-\(UUID().uuidString)")
        let unknownCategory = AppCategoryRef(id: "unknown-\(UUID().uuidString)")

        // Pre-activation baseline: the fresh manager denies nothing.
        assertBackendConfigurationNone(backend, manager)
        XCTAssertFalse(manager.isShielded(app: unknown, category: nil))

        // (c) Handing the manager its (empty) enumeration engages the latch.
        manager.updateEnumeration(.empty)
        assertBackendConfigurationNone(backend, manager)
        XCTAssertFalse(backend.isShielded(app: unknown, category: nil))
        XCTAssertFalse(backend.isShielded(app: unknown, category: unknownCategory))
        XCTAssertTrue(manager.isShielded(app: unknown, category: nil))
        XCTAssertTrue(manager.isShielded(app: unknown, category: unknownCategory))

        // (d) A later empty replacement preserves the latch.
        manager.updateEnumeration(.empty)
        assertBackendConfigurationNone(backend, manager)
        XCTAssertFalse(backend.isShielded(app: unknown, category: nil))
        XCTAssertTrue(manager.isShielded(app: unknown, category: nil))
        XCTAssertTrue(manager.isShielded(app: unknown, category: unknownCategory))
    }
}
