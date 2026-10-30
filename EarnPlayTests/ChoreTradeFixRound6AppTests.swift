import Foundation
import XCTest
import EarnPlayCore

/// T3.2 fix round 6, exercised from the child app target (simulator gate),
/// mirroring the package suite through public `EarnPlayCore` API only:
/// a hidden screen's backend `applyCount` plateaus after expiry with no
/// refresh calls, a mid-window hide keeps monitoring (fix-5 preserved),
/// and no polling task leaks past the window end.
@MainActor
final class ChoreTradeFixRound6AppTests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound6AppTests-\(tag)-\(UUID().uuidString)",
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

    private static func waitForBackendReshield(
        _ backend: SimulatedShieldBackend,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(
            Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if backend.isShielded(app: game, category: games) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return backend.isShielded(app: game, category: games)
    }

    private func makeGrantedStack(
        _ tag: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (ChoreTradeViewModel, ShieldManager, SimulatedShieldBackend, AdvancingClock) {
        let directory = tmpDir(tag)
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
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: pool)), .applied, file: file, line: line)
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
        Self.driveToDoneAwaitingConfirm(viewModel, file: file, line: line)
        viewModel.parentConfirm()
        XCTAssertTrue(manager.isUnlockActive, file: file, line: line)
        return (viewModel, manager, backend, clock)
    }

    func testHiddenScreenApplyCountPlateausAfterExpiryWithoutRefresh() async {
        let (viewModel, _, backend, clock) = makeGrantedStack("HiddenPlateau")
        XCTAssertFalse(backend.isShielded(app: Self.game, category: Self.games))

        viewModel.stopStatusUpdates()
        clock.advance(by: 10 * 60 + 1)

        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(
            reshielded,
            "backend must re-shield past the deadline after onDisappear with no interaction")

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let baseline = backend.applyCount
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(
            backend.applyCount, baseline,
            "applyCount must plateau after expiry with no refresh calls (monitor must stop itself)")
    }

    func testMidWindowHideKeepsMonitoringAndRelocksAtExpiry() async {
        let (viewModel, _, backend, clock) = makeGrantedStack("MidWindowHide")

        viewModel.stopStatusUpdates()
        let midWindowBaseline = backend.applyCount
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertGreaterThan(
            backend.applyCount, midWindowBaseline,
            "hiding mid-window must NOT stop monitoring (fix-5 behavior)")
        XCTAssertFalse(
            backend.isShielded(app: Self.game, category: Self.games),
            "window still open: backend must stay unshielded mid-window")

        clock.advance(by: 10 * 60 + 1)
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(
            reshielded,
            "live monitor must re-shield past the deadline after a mid-window hide")

        viewModel.refreshGrantedStatus()
        XCTAssertEqual(
            viewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        viewModel.stopStatusUpdates()
    }

    func testNoLeakedPollingTaskAfterExpiry() async {
        let (viewModel, manager, backend, clock) = makeGrantedStack("NoLeakedTask")
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "monitoring must run once the window is granted")

        viewModel.stopStatusUpdates()
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "mid-window hide must not clear the polling task")

        clock.advance(by: 10 * 60 + 1)
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(reshielded, "live monitor must re-shield past the deadline")

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(
            manager.isExpiryMonitoring,
            "polling task must clear itself after the window ends")

        let baseline = backend.applyCount
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(
            backend.applyCount, baseline,
            "no leaked polling task may re-apply after expiry")

        viewModel.refreshGrantedStatus()
        XCTAssertEqual(
            viewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        viewModel.stopStatusUpdates()
        XCTAssertFalse(manager.isExpiryMonitoring)
    }
}
