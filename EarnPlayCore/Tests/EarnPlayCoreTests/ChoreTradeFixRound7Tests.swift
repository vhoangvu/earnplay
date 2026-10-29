import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 fix round 7 — no expiry-monitoring race during task cleanup.
///
/// Fix 6 made the monitor loop stop itself: the terminal path was two
/// separate locked sections — `refreshAndHasOpenWindow()` returning
/// false, then `finishExpiryMonitoringIfGeneration()` clearing the task.
/// Between those sections the lock is free, so a grant landing exactly
/// there called `startExpiryMonitoring()`, saw the still-assigned old
/// task, and returned without starting a task — then cleanup nilled the
/// slot. Result: a newly granted window with NO monitoring task and
/// therefore no automatic re-locking. The fix makes the no-window
/// decision and the task retirement atomic under a single lock hold.
///
/// (1) Deterministic interleaving (via the terminal-poll seam): a new
///     window granted in the exact retirement window stays monitored
///     (`isExpiryMonitoring` true) and re-locks at its own expiry.
///     FAILS on the pre-fix two-section code (the grant's start sees
///     the old task and the cleanup then nils the slot).
/// (2) Grant after terminal retirement (no seam): once the old task has
///     fully retired, a new window + start gets a monitor and re-locks
///     at its own expiry. Passes pre- and post-fix; the baseline the
///     race must not regress.
final class ChoreTradeFixRound7Tests: XCTestCase {
    private func tmpDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound7Tests-\(tag)-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let game = AppRef(id: "com.example.game")
    private static let games = AppCategoryRef(id: "games")

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

    /// Lock-guarded box so the seam hook (running on the monitor task)
    /// can report back to the test thread.
    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ newValue: T) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private func parentPolicy() -> Policy {
        Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
    }

    private func enumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )
    }

    private func makeManager(
        directory: URL, clock: AdvancingClock, backend: SimulatedShieldBackend
    ) -> ShieldManager {
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy()), .applied)
        return ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration(),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider("test-boot")
        )
    }

    /// Waits (backend reads only — no manager contact) until the backend
    /// re-shields the game. Returns true when re-shielding was observed.
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
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return backend.isShielded(app: game, category: games)
    }

    // MARK: - (1) Grant in the exact retirement window stays monitored

    func testGrantInRetirementWindowStaysMonitoredAndRelocksAtOwnExpiry() async {
        let directory = tmpDir("RetirementWindow")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let manager = makeManager(directory: directory, clock: clock, backend: backend)

        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        manager.startExpiryMonitoring(pollInterval: 0.02)
        XCTAssertTrue(manager.isExpiryMonitoring)
        XCTAssertFalse(backend.isShielded(app: Self.game, category: Self.games))

        // The seam fires on the monitor task after the terminal poll
        // observes the closed window and before the loop exits — the
        // exact window where the pre-fix race drops the new monitor.
        // The hook mirrors production (grant, then ensure monitoring,
        // as `refreshGrantedStatus` does when the window is active).
        let hookFired = LockedBox(false)
        let grantSucceeded = LockedBox(false)
        manager.setMonitorTerminalPollHook {
            grantSucceeded.set(manager.grantUnlock(for: Self.game, duration: 60))
            manager.startExpiryMonitoring(pollInterval: 0.02)
            hookFired.set(true)
        }

        // Window 1 expires; the next monitor tick is the terminal poll.
        clock.advance(by: 61)

        let hookDeadline = Date().addingTimeInterval(5)
        while !hookFired.get(), Date() < hookDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(hookFired.get(), "terminal-poll seam must fire after expiry")
        manager.setMonitorTerminalPollHook(nil)
        XCTAssertTrue(grantSucceeded.get(), "seam grant of window 2 must succeed")

        // Grace for the old task's exit path to land: on pre-fix code
        // its cleanup nils the slot AFTER the hook's start early-returned,
        // leaving window 2 unmonitored — the failure this test pins.
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(
            manager.isUnlockActive,
            "window 2 must be open after the retirement-window grant")
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "window 2 granted in the retirement window must stay monitored")

        // Window 2 must re-lock at its own expiry with no interaction.
        clock.advance(by: 61)
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(
            reshielded,
            "monitored window 2 must re-shield past its own deadline")

        manager.stopExpiryMonitoring()
    }

    // MARK: - (2) Grant after terminal retirement gets a monitor

    func testGrantAfterTerminalRetirementGetsMonitorAndRelocks() async {
        let directory = tmpDir("AfterRetirement")
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let manager = makeManager(directory: directory, clock: clock, backend: backend)

        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        manager.startExpiryMonitoring(pollInterval: 0.02)
        XCTAssertTrue(manager.isExpiryMonitoring)

        // Window 1 expires; wait for the old task to fully retire
        // (self-stop landed — `isExpiryMonitoring` reads are lock-only
        // and perturb nothing).
        clock.advance(by: 61)
        let retireDeadline = Date().addingTimeInterval(5)
        while manager.isExpiryMonitoring, Date() < retireDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(
            manager.isExpiryMonitoring,
            "old task must retire itself after window 1 ends")

        // A later grant + ensure-monitoring must get a live monitor.
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        manager.startExpiryMonitoring(pollInterval: 0.02)
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertTrue(
            manager.isExpiryMonitoring,
            "window granted after retirement must get a monitor")

        // Window 2 must re-lock at its own expiry with no interaction.
        clock.advance(by: 61)
        let reshielded = await Self.waitForBackendReshield(backend)
        XCTAssertTrue(
            reshielded,
            "monitored window 2 must re-shield past its own deadline")

        manager.stopExpiryMonitoring()
    }
}
