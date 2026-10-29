import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 fix round 5 — restored unlock status independent of chore session
/// phase, and expiry-monitoring lifecycle tied to the window, not the view.
///
/// (a) DISPLAY: a same-boot relaunch during an active unlock restores the
/// window but starts a fresh `.idle` session. The countdown must display
/// and refresh and the expiry message must appear even though the session
/// never reaches `.granted`.
/// (b) MONITORING: hiding the granted screen mid-window (the
/// `onDisappear` → `stopStatusUpdates()` path) must NOT cancel expiry
/// monitoring while the window is still active; monitoring stops only
/// when the window has genuinely ended.
///
/// `MainActor`-isolated like the view model under test.
@MainActor
final class ChoreTradeFixRound5Tests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound5Tests-\(tag)-\(UUID().uuidString)",
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
        expiry: Date = ChoreTradeFixRound5Tests.future
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

    // MARK: - (1) Relaunch into active window: idle session shows countdown + expiry

    func testRelaunchedIdleSessionShowsCountdownAndExpiry() async {
        let directory = tmpDir("IdleCountdown")
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

        // Same-boot relaunch: fresh idle session, restored window.
        manager.stopExpiryMonitoring()
        let relaunchedManager = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: enumeration(),
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

        // Fresh session never reaches .granted, but the countdown displays.
        XCTAssertEqual(relaunched.session.phase, .idle)
        XCTAssertFalse(relaunched.session.hasGrantedUnlock)
        XCTAssertTrue(
            relaunched.shieldStatus.contains("seconds left"),
            "idle relaunch must display restored countdown, got: \(relaunched.shieldStatus)")
        XCTAssertEqual(relaunched.shieldStatus, "Device unlock active, 600 seconds left.")

        // Countdown refreshes independently of the session phase.
        clock.advance(by: 61)
        relaunched.refreshGrantedStatus()
        XCTAssertEqual(
            relaunched.shieldStatus,
            "Device unlock active, 539 seconds left.")
        XCTAssertEqual(relaunched.session.phase, .idle)

        // Expiry message appears at the deadline.
        clock.advance(by: 10 * 60)
        relaunched.refreshGrantedStatus()
        XCTAssertEqual(
            relaunched.shieldStatus,
            "Unlock expired — device is shielded again.")
        XCTAssertFalse(relaunchedManager.isUnlockActive)
        relaunched.stopStatusUpdates()
    }

    // MARK: - (2) Hiding granted screen mid-window must not cancel monitoring

    func testHidingGrantedScreenMidWindowStillReshields() async {
        let directory = tmpDir("HiddenStillReshields")
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

        // Granted screen hidden mid-window: the view's onDisappear path.
        // This must NOT cancel expiry monitoring while the window is active.
        viewModel.stopStatusUpdates()

        // Deadline passes with no further interaction — no ticker, no
        // refresh, no status call. The 1-second monitor poll has ~3
        // seconds of real time to fire.
        clock.advance(by: 10 * 60 + 1)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // Backend-only read first: only a live monitor could have re-shielded.
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

    // MARK: - (3) Window genuinely ended → monitoring stops (no leak)

    func testMonitoringStopsAfterWindowEnds() async {
        let directory = tmpDir("MonitoringStops")
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

        // Window ends; the view model observes expiry via refresh.
        clock.advance(by: 10 * 60 + 1)
        viewModel.refreshGrantedStatus()
        XCTAssertEqual(
            viewModel.shieldStatus,
            "Unlock expired — device is shielded again.")
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertTrue(backend.isShielded(app: Self.game, category: Self.games))

        // Grace for any in-flight poll to land, then baseline.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let baseline = backend.applyCount

        // No further interaction: a leaked monitor would poll every
        // second and re-apply (each refresh applies unconditionally).
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(
            backend.applyCount, baseline,
            "monitoring must stop after the window ends (no leaked polling task)")
        viewModel.stopStatusUpdates()
    }
}
