import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 fix round 6 — expiry monitoring stops itself when the unlock
/// window ends.
///
/// Fix 5 made `stopStatusUpdates()` return early while the window is
/// active (correct), but nothing stopped the manager's monitor loop
/// when the window ended on its own: `startExpiryMonitoring` polls
/// `refresh()` every second until explicitly cancelled, and in the
/// hidden-screen case no view event ever fires after expiry — so the
/// loop kept re-applying shields forever (backend `applyCount` keeps
/// increasing) with no further interaction. The monitor must stop
/// itself once `refresh()` shows the window ended and shields
/// re-applied, instead of relying on a later view refresh.
///
/// (1) Hidden screen + window expires → backend `applyCount` plateaus
///     after expiry with NO `refreshGrantedStatus()` call (and no other
///     manager contact — only side-effect-free backend reads).
/// (2) Mid-window hide → monitoring continues (fix-5 preserved) and
///     re-locks at expiry.
/// (3) No leaked polling task after expiry (`isExpiryMonitoring` false
///     plus a plateau; added with the fix since the accessor is new).
///
/// `MainActor`-isolated like the view model under test.
@MainActor
final class ChoreTradeFixRound6Tests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound6Tests-\(tag)-\(UUID().uuidString)",
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
        expiry: Date = ChoreTradeFixRound6Tests.future
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

    /// Waits (backend reads only — no manager contact, so no extra
    /// applies) until the backend re-shields the game. Returns true
    /// when re-shielding was observed.
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

    // MARK: - (1) Hidden screen: applyCount plateaus after expiry, no refresh

    func testHiddenScreenApplyCountPlateausAfterExpiryWithoutRefresh() async {
        let directory = tmpDir("HiddenPlateau")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [entry("Wash the car", minutes: 10)]

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

        // Granted screen hidden mid-window: the view's onDisappear path.
        viewModel.stopStatusUpdates()

        // Deadline passes with no further interaction of any kind.
        clock.advance(by: 10 * 60 + 1)

        // Backend-only wait: only a live monitor could have re-shielded.
        // No refreshGrantedStatus(), no manager.refresh(), no
        // isUnlockActive read — every one of those re-applies and would
        // perturb the plateau measurement below.
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(
            reshielded,
            "backend must re-shield past the deadline after onDisappear with no interaction")

        // Grace for any in-flight poll to land, then baseline.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let baseline = backend.applyCount

        // Still no interaction of any kind: a monitor that never stops
        // polls every second and re-applies (each refresh applies
        // unconditionally), so applyCount would keep climbing.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(
            backend.applyCount, baseline,
            "applyCount must plateau after expiry with no refresh calls (monitor must stop itself)")
    }

    // MARK: - (2) Mid-window hide keeps monitoring (fix-5 preserved)

    func testMidWindowHideKeepsMonitoringAndRelocksAtExpiry() async {
        let directory = tmpDir("MidWindowHide")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [entry("Wash the car", minutes: 10)]

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
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertFalse(backend.isShielded(app: Self.game, category: Self.games))

        // Hide mid-window: monitoring must continue (fix 5). The live
        // 1-second monitor poll re-applies on every tick, so applyCount
        // keeps climbing while the window is open — without any view
        // event — and the backend stays unshielded.
        viewModel.stopStatusUpdates()
        let midWindowBaseline = backend.applyCount
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertGreaterThan(
            backend.applyCount, midWindowBaseline,
            "hiding mid-window must NOT stop monitoring (fix-5 behavior)")
        XCTAssertFalse(
            backend.isShielded(app: Self.game, category: Self.games),
            "window still open: backend must stay unshielded mid-window")

        // Deadline passes with no further interaction: the still-live
        // monitor re-locks on its own.
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

    // MARK: - (3) No leaked polling task after expiry

    func testNoLeakedPollingTaskAfterExpiry() async {
        let directory = tmpDir("NoLeakedTask")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let boot = FakeBootSessionProvider("test-boot")
        let pool = [entry("Wash the car", minutes: 10)]

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
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "monitoring must run once the window is granted")

        // Hide mid-window: the polling task must survive (fix 5).
        viewModel.stopStatusUpdates()
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "mid-window hide must not clear the polling task")

        // Deadline passes with no view refresh: the monitor re-locks,
        // then clears its own task.
        clock.advance(by: 10 * 60 + 1)
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(reshielded, "live monitor must re-shield past the deadline")

        // Grace for the self-stop to land after the re-locking poll.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(
            manager.isExpiryMonitoring,
            "polling task must clear itself after the window ends")

        // A cleared handle must mean a stopped loop, not a detached
        // one: the backend must stay quiet with no interaction.
        // (isExpiryMonitoring reads are lock-only and apply nothing,
        // so this plateau is unperturbed.)
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
