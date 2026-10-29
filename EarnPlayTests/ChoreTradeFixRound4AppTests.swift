import Foundation
import XCTest
import EarnPlayCore

/// T3.2 fix round 4, exercised from the child app target (simulator gate),
/// mirroring the package suite through public `EarnPlayCore` API only: a
/// same-boot relaunch during a persisted unlock window resumes expiry
/// monitoring, so the backend re-shields past the deadline with no
/// further interaction and the status reflects expiry.
@MainActor
final class ChoreTradeFixRound4AppTests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound4AppTests-\(tag)-\(UUID().uuidString)",
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

    func testRelaunchedViewModelResumesExpiryMonitoring() async {
        let directory = tmpDir("ResumeMonitoring")
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
        XCTAssertTrue(manager.isUnlockActive)

        // Same-boot relaunch: the old process — including its expiry
        // monitor — is gone; only the persisted window survives.
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

        let relaunchedViewModel = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: relaunchedManager)
        XCTAssertTrue(
            relaunchedViewModel.shieldStatus.contains("seconds left"),
            "relaunched VM must show the restored window's countdown, got: \(relaunchedViewModel.shieldStatus)")

        // The deadline passes with no further interaction.
        clock.advance(by: 10 * 60 + 1)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // Backend-only read first: only a resumed monitor could have
        // re-shielded.
        XCTAssertTrue(
            backend.isShielded(app: Self.game, category: Self.games),
            "backend must re-shield past the deadline with no interaction")
        XCTAssertFalse(relaunchedManager.isUnlockActive)
        relaunchedViewModel.refreshGrantedStatus()
        XCTAssertEqual(
            relaunchedViewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        relaunchedViewModel.stopStatusUpdates()
    }
}
