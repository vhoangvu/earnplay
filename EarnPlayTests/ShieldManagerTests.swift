import Foundation
import XCTest
import EarnPlayCore

/// T2.2 — ShieldManager exercised from the child app target
/// (simulator gate), against a simulated shield backend.
///
/// Mirrors the package suite's acceptance checks: enumeration-first
/// shielding with the category backstop, and the 60-second monotonic
/// unlock that a +2-hour wall-clock jump cannot extend. Real shield
/// enforcement (ManagedSettings, v1) is not verified here.
final class ShieldManagerAppTests: XCTestCase {
    private var directory: URL!

    private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var uptime: TimeInterval = 1_000
        var nowUptime: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
        }
        func advance(by seconds: TimeInterval) {
            lock.lock()
            uptime += seconds
            lock.unlock()
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
    private static let game = AppRef(id: "com.example.game")
    private static let socialApp = AppRef(id: "com.example.social")
    private static let newSocial = AppRef(id: "com.example.new-social")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldManagerAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeManager(
        clock: FakeMonotonicClock, backend: SimulatedShieldBackend
    ) -> ShieldManager {
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game],
            neverUnlockableOverrides: [],
            unlockDurations: UnlockDurations(practiceMinutes: 30, tradeMinutes: 15),
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        return ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [
                    EnumeratedApp(app: Self.game, category: Self.games),
                    EnumeratedApp(app: Self.socialApp, category: Self.social),
                ],
                categories: [Self.games, Self.social]
            ),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    func testEnumeratedShieldedAllowlistNotAndBackstopCatchesNewApp() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)

        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: .phone))
        // Unenumerated newly installed app: shielded via category backstop.
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
    }

    func testSixtySecondUnlockRelocksAndWallClockJumpCannotExtend() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        final class WallBox: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_700_000_000)
        }
        let wallBox = WallBox()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [EnumeratedApp(app: Self.game, category: Self.games)],
                categories: [Self.games]
            ),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            nowWallDate: { wallBox.date }
        )

        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        clock.advance(by: 10)
        wallBox.date = wallBox.date.addingTimeInterval(2 * 60 * 60)
        XCTAssertEqual(manager.remainingUnlockTime, 50, accuracy: 0.001)
        clock.advance(by: 50)
        manager.refresh()
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }
}
