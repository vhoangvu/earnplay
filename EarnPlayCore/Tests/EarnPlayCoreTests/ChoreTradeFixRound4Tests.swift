import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 fix round 4 — a same-boot relaunch during a persisted unlock
/// window must resume expiry monitoring, or the simulated backend stays
/// unshielded past the deadline with no further interaction.
///
/// `MainActor`-isolated like the view model under test (the app module
/// builds without `-enable-testing`, so the view model lives in Core
/// where both gates drive the real confirm/grant/status path).
@MainActor
final class ChoreTradeFixRound4Tests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound4Tests-\(tag)-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let future = Date(timeIntervalSince1970: 2_000_000_000)
    private static let game = AppRef(id: "com.example.game")
    private static let games = AppCategoryRef(id: "games")

    private func entry(
        _ chore: String,
        minutes: Int = 10,
        expiry: Date = ChoreTradeFixRound4Tests.future
    ) -> ChorePoolEntry {
        ChorePoolEntry(
            chore: chore,
            unlockMinutes: minutes,
            expiry: expiry,
            weeklyCap: 3,
            verificationMode: .parentConfirm
        )
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

    private func enumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
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

    // MARK: - Finding: resume expiry monitoring for restored active windows

    func testRelaunchedViewModelResumesExpiryMonitoring() async {
        let directory = tmpDir("ResumeMonitoring")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [entry("Wash the car", minutes: 10)]

        // Grant an unlock through the first view model; the window
        // persists to the file store.
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: pool)), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration(),
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
        XCTAssertFalse(backend.isShielded(app: Self.game, category: Self.games))

        // Same-boot relaunch: the old process — including its expiry
        // monitor — is gone; only the persisted window survives. A new
        // manager over the same store restores the unshielded
        // configuration while the window is still active.
        manager.stopExpiryMonitoring()
        let relaunchedStore = PolicyStore(directory: directory)
        XCTAssertEqual(
            relaunchedStore.currentPolicy.version, 1,
            "relaunch must see the same parent policy version or the window cannot restore")
        let relaunchedManager = ShieldManager(
            policyStore: relaunchedStore,
            enumeration: enumeration(),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(
            relaunchedManager.isUnlockActive,
            "setup: the persisted window restores as active before the deadline")

        let relaunchedViewModel = ChoreTradeViewModel(
            pool: pool,
            poolSourceCaption: "Parent's chores (policy v1)",
            shieldManager: relaunchedManager)
        // The relaunched view model reflects the restored window.
        XCTAssertTrue(
            relaunchedViewModel.shieldStatus.contains("seconds left"),
            "relaunched VM must show the restored window's countdown, got: \(relaunchedViewModel.shieldStatus)")

        // The deadline passes with no further interaction — no confirm,
        // no ticker, no status call. The 1-second monitor poll has ~3
        // seconds of real time to fire.
        clock.advance(by: 10 * 60 + 1)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // No-interaction proof, read from the backend WITHOUT touching
        // the manager or view model first: only a resumed monitor could
        // have re-shielded (every manager read re-evaluates expiry
        // itself, so those come after).
        XCTAssertTrue(
            backend.isShielded(app: Self.game, category: Self.games),
            "backend must re-shield past the deadline with no interaction")

        // Status reflects expiry.
        XCTAssertFalse(relaunchedManager.isUnlockActive)
        XCTAssertEqual(relaunchedManager.remainingUnlockTime, 0)
        relaunchedViewModel.refreshGrantedStatus()
        XCTAssertEqual(
            relaunchedViewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        relaunchedViewModel.stopStatusUpdates()
    }
}
