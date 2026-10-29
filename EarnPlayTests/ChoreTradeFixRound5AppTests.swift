import Foundation
import XCTest
import EarnPlayCore

/// T3.2 fix round 5, exercised from the child app target (simulator gate),
/// mirroring the package suite through public `EarnPlayCore` API only:
/// a relaunched idle session shows the restored countdown and expiry,
/// hiding the granted screen mid-window still re-shields, and monitoring
/// stops once the window has genuinely ended.
@MainActor
final class ChoreTradeFixRound5AppTests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound5AppTests-\(tag)-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private final class AdvancingClock: MonotonicClock, @unchecked Sendable {
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
        private var applyCountValue = 0
        func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
            lock.lock()
            self.configuration = configuration
            applyCountValue += 1
            lock.unlock()
        }
        var currentShieldConfiguration: ShieldConfiguration {
            lock.lock()
            defer { lock.unlock() }
            return configuration
        }
        var applyCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return applyCountValue
        }
    }

    private final class FakeBootSessionProvider: BootSessionProvider, @unchecked Sendable {
        private let identifier: String?
        init(_ identifier: String? = "test-boot") { self.identifier = identifier }
        var currentBootSessionID: String? { identifier }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")
    private static let future = Date(timeIntervalSince1970: 2_000_000_000)

    private func parentPolicy(chorePool: [ChorePoolEntry]) -> Policy {
        Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: chorePool,
            movementSettings: .default
        )
    }

    private static func driveToDoneAwaitingConfirm(
        _ viewModel: ChoreTradeViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        viewModel.triggerOffer()
        XCTAssertNotNil(viewModel.session.currentOffer, file: file, line: line)
        viewModel.accept()
        viewModel.markDone()
        guard case .doneAwaitingConfirm = viewModel.session.phase else {
            XCTFail(
                "expected doneAwaitingConfirm, got \(viewModel.session.phase)",
                file: file, line: line)
            return
        }
    }

    func testRelaunchedIdleSessionShowsCountdownAndExpiry() async {
        let directory = tmpDir("IdleCountdown")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [ChorePoolEntry(
            chore: "Wash the car",
            unlockMinutes: 10,
            expiry: Self.future,
            weeklyCap: 3,
            verificationMode: .parentConfirm
        )]
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )

        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: pool)), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        let viewModel = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: manager)
        Self.driveToDoneAwaitingConfirm(viewModel)
        viewModel.parentConfirm()
        XCTAssertEqual(viewModel.grantSucceeded, true)

        manager.stopExpiryMonitoring()
        let relaunchedManager = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(relaunchedManager.isUnlockActive)
        let relaunched = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: relaunchedManager)

        XCTAssertEqual(relaunched.session.phase, .idle)
        XCTAssertFalse(relaunched.session.hasGrantedUnlock)
        XCTAssertEqual(relaunched.shieldStatus, "Device unlock active, 600 seconds left.")

        clock.advance(by: 61)
        relaunched.refreshGrantedStatus()
        XCTAssertEqual(
            relaunched.shieldStatus,
            "Device unlock active, 539 seconds left.")

        clock.advance(by: 10 * 60)
        relaunched.refreshGrantedStatus()
        XCTAssertEqual(
            relaunched.shieldStatus,
            "Unlock expired — device is shielded again.")
        relaunched.stopStatusUpdates()
    }

    func testHidingGrantedScreenMidWindowStillReshields() async {
        let directory = tmpDir("HiddenStillReshields")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [ChorePoolEntry(
            chore: "Wash the car",
            unlockMinutes: 10,
            expiry: Self.future,
            weeklyCap: 3,
            verificationMode: .parentConfirm
        )]
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )

        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: pool)), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        let viewModel = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: manager)
        Self.driveToDoneAwaitingConfirm(viewModel)
        viewModel.parentConfirm()
        XCTAssertTrue(manager.isUnlockActive)

        viewModel.stopStatusUpdates()

        clock.advance(by: 10 * 60 + 1)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        XCTAssertTrue(
            backend.isShielded(app: Self.game, category: Self.games),
            "backend must re-shield past the deadline after onDisappear with no interaction")
        XCTAssertFalse(manager.isUnlockActive)
        viewModel.refreshGrantedStatus()
        XCTAssertEqual(
            viewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        viewModel.stopStatusUpdates()
    }

    func testMonitoringStopsAfterWindowEnds() async {
        let directory = tmpDir("MonitoringStops")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [ChorePoolEntry(
            chore: "Wash the car",
            unlockMinutes: 10,
            expiry: Self.future,
            weeklyCap: 3,
            verificationMode: .parentConfirm
        )]
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )

        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: pool)), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        let viewModel = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: manager)
        Self.driveToDoneAwaitingConfirm(viewModel)
        viewModel.parentConfirm()
        XCTAssertTrue(manager.isUnlockActive)

        clock.advance(by: 10 * 60 + 1)
        viewModel.refreshGrantedStatus()
        XCTAssertEqual(
            viewModel.shieldStatus,
            "Unlock expired — device is shielded again.")

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let baseline = backend.applyCount
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(
            backend.applyCount, baseline,
            "monitoring must stop after the window ends (no leaked polling task)")
        viewModel.stopStatusUpdates()
    }
}
