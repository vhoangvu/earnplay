import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.2 — ShieldManager: enumeration-first shielding, monotonic unlock
/// timers, automatic re-lock, and restart re-evaluation.
///
/// Demo verification runs against a simulated backend (a test double
/// for the `ShieldBackend` interface T2.4 will implement for the
/// simulated-shield fallback). Real shield enforcement (ManagedSettings,
/// v1, entitlement-gated) is NOT verified by these tests and is never
/// claimed as verified here.
final class ShieldManagerTests: XCTestCase {
    private var directory: URL!

    // MARK: - Test doubles

    /// Injectable monotonic clock: time moves only when the test moves it.
    private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var uptime: TimeInterval

        init(start: TimeInterval = 1_000) { uptime = start }

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

    /// Mutable wall clock the test can jump arbitrarily.
    private final class FakeWallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            self.date = date
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func jump(by seconds: TimeInterval) {
            lock.lock()
            date = date.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    /// Simulated shield backend for T2.4's interface: records the last
    /// applied configuration and answers effective shielding from it
    /// via the shared `ShieldConfiguration.isShielded` contract
    /// (per-app shield OR category shield; no exemption semantics).
    private final class SimulatedShieldBackend: ShieldBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var configuration: ShieldConfiguration = .none
        private(set) var applyCount = 0

        func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
            lock.lock()
            self.configuration = configuration
            applyCount += 1
            lock.unlock()
        }

        var currentShieldConfiguration: ShieldConfiguration {
            lock.lock()
            defer { lock.unlock() }
            return configuration
        }
    }

    /// Injectable boot-session identifier: tests control reboot vs same boot.
    private final class FakeBootSessionProvider: BootSessionProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var identifier: String?

        init(_ identifier: String? = "test-boot") { self.identifier = identifier }

        var currentBootSessionID: String? {
            lock.lock()
            defer { lock.unlock() }
            return identifier
        }

        func setID(_ newValue: String?) {
            lock.lock()
            identifier = newValue
            lock.unlock()
        }
    }

    /// File store wrapper that can fail saves or clears on demand.
    private final class FailableUnlockWindowStore: UnlockWindowStore, @unchecked Sendable {
        private let wrapped: FileUnlockWindowStore
        private let lock = NSLock()
        var failNextSave = false
        var failNextClear = false

        init(directory: URL) {
            wrapped = FileUnlockWindowStore(directory: directory)
        }

        func loadUnlockWindow() -> UnlockWindow? {
            wrapped.loadUnlockWindow()
        }

        func saveUnlockWindow(_ window: UnlockWindow) throws {
            lock.lock()
            let shouldFail = failNextSave
            lock.unlock()
            if shouldFail {
                throw NSError(domain: "ShieldManagerTests", code: 1)
            }
            try wrapped.saveUnlockWindow(window)
        }

        func clearUnlockWindow() throws {
            lock.lock()
            let shouldFail = failNextClear
            lock.unlock()
            if shouldFail {
                throw NSError(domain: "ShieldManagerTests", code: 2)
            }
            try wrapped.clearUnlockWindow()
        }
    }

    // MARK: - Fixtures

    private static let games = AppCategoryRef(id: "games")
    private static let social = AppCategoryRef(id: "social")
    private static let entertainment = AppCategoryRef(id: "entertainment")

    private static let game = AppRef(id: "com.example.game")
    private static let video = AppRef(id: "com.example.video")
    private static let socialApp = AppRef(id: "com.example.social")
    private static let browser = AppRef(id: "com.example.browser")
    /// Always-allowed app sharing the `games` category with `game`.
    private static let allowedGame = AppRef(id: "com.example.allowed-game")
    private static let newSocial = AppRef(id: "com.example.new-social")

    private func samplePolicy() -> Policy {
        Policy(
            version: 1,
            alwaysAllowed: [.phone, Self.allowedGame],
            unblockable: [Self.game, Self.video],
            neverUnlockableOverrides: [Self.browser],
            unlockDurations: UnlockDurations(practiceMinutes: 30, tradeMinutes: 15),
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
    }

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.video, category: Self.entertainment),
                EnumeratedApp(app: Self.socialApp, category: Self.social),
                EnumeratedApp(app: Self.browser, category: Self.social),
                EnumeratedApp(app: Self.allowedGame, category: Self.games),
            ],
            categories: [Self.games, Self.social, Self.entertainment]
        )
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeManager(
        clock: FakeMonotonicClock,
        backend: SimulatedShieldBackend,
        wall: FakeWallClock = FakeWallClock()
    ) -> ShieldManager {
        let policyStore = PolicyStore(directory: directory)
        if policyStore.storedVersion == 0 {
            XCTAssertEqual(policyStore.apply(samplePolicy()), .applied)
        }
        return ShieldManager(
            policyStore: policyStore,
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            nowWallDate: { wall.now() }
        )
    }

    // MARK: - Enumeration-first shielding

    func testEveryEnumeratedNonAllowlistAppIsShieldedAndAllowlistIsNot() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)

        let config = manager.currentConfiguration
        XCTAssertEqual(
            config.shieldedApplications,
            [Self.game, Self.video, Self.socialApp, Self.browser]
        )
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.browser, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: .phone))
        XCTAssertEqual(backend.currentShieldConfiguration, config)
    }

    func testUnenumeratedNewlyInstalledAppIsShieldedViaCategoryBackstop() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)

        // Not enumerated, not individually shielded — only the social
        // category backstop can shield it.
        XCTAssertFalse(manager.currentConfiguration.shieldedApplications.contains(Self.newSocial))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))

        // Once enumerated (T2.3 re-pick), it is shielded individually too.
        var enumeration = sampleEnumeration()
        enumeration.apps.append(EnumeratedApp(app: Self.newSocial, category: Self.social))
        manager.updateEnumeration(enumeration)
        XCTAssertTrue(manager.currentConfiguration.shieldedApplications.contains(Self.newSocial))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
    }

    func testNoPerAppExemptionOverCategoryShield() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)

        // `allowedGame` shares `games` with the blocked `game`. The
        // manager must not shield `games` and exempt `allowedGame`:
        // the category is withheld entirely, and `game` is still
        // shielded by its individual (enumeration-first) shield.
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))

        // Unlocking `video` withholds the `entertainment` category
        // instead of exempting `video` from it: during the window the
        // category shield is gone, `video` is open, and an enumerated
        // peer in that category would still be shielded individually.
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.entertainment))
        XCTAssertTrue(manager.grantUnlock(for: Self.video, duration: 60))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.entertainment))
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.entertainment))
    }

    // MARK: - Acceptance flow (60-second unlock, wall-clock jump)

    func testSixtySecondUnlockExpiresAndWallClockJumpDoesNotExtendIt() {
        let clock = FakeMonotonicClock()
        let wall = FakeWallClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend, wall: wall)

        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertEqual(manager.remainingUnlockTime, 60, accuracy: 0.001)
        XCTAssertTrue(manager.isUnlockActive)

        // Other apps stay shielded during the window.
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))

        // Mid-window wall-clock jump of +2 hours must not change the
        // remaining time: expiry is computed on the monotonic clock.
        clock.advance(by: 10)
        wall.jump(by: 2 * 60 * 60)
        XCTAssertEqual(manager.remainingUnlockTime, 50, accuracy: 0.001)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        // A wall-clock jump backwards likewise has no effect.
        wall.jump(by: -3 * 60 * 60)
        XCTAssertEqual(manager.remainingUnlockTime, 50, accuracy: 0.001)

        // Advance the monotonic clock to expiry: automatic re-lock
        // state (checked via refresh, and by the accessors).
        clock.advance(by: 50)
        manager.refresh()
        XCTAssertEqual(manager.remainingUnlockTime, 0)
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(backend.currentShieldConfiguration.shieldedApplications.contains(Self.game))
    }

    func testAutomaticRelockViaExpiryMonitoring() async {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)
        manager.startExpiryMonitoring(pollInterval: 0.02)
        defer { manager.stopExpiryMonitoring() }

        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        clock.advance(by: 61)
        // No manual refresh: monitoring must re-lock on its own.
        var relocked = false
        for _ in 0..<50 {
            if manager.isShielded(app: Self.game, category: Self.games) {
                relocked = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(relocked, "expiry monitoring did not re-lock after monotonic expiry")
    }

    // MARK: - Restart re-evaluation

    func testOpenWindowIsReEvaluatedAfterAppRestart() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let wall = FakeWallClock()
        let manager = makeManager(clock: clock, backend: backend, wall: wall)
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))

        clock.advance(by: 25)
        // Relaunch equivalent: a new manager over the same stores and
        // the same (continuing) monotonic clock and backend.
        let relaunched = makeManager(clock: clock, backend: backend, wall: wall)
        XCTAssertTrue(relaunched.isUnlockActive)
        XCTAssertEqual(relaunched.remainingUnlockTime, 35, accuracy: 0.001)
        XCTAssertFalse(relaunched.isShielded(app: Self.game, category: Self.games))

        clock.advance(by: 35)
        relaunched.refresh()
        XCTAssertTrue(relaunched.isShielded(app: Self.game, category: Self.games))
    }

    func testExpiredWindowIsRelockedOnRestartWithoutWaiting() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))

        clock.advance(by: 120)
        let relaunched = makeManager(clock: clock, backend: backend)
        XCTAssertFalse(relaunched.isUnlockActive)
        XCTAssertTrue(relaunched.isShielded(app: Self.game, category: Self.games))
    }

    func testDeviceRebootUptimeRegressionRelocksFailClosed() {
        let clock = FakeMonotonicClock(start: 5_000)
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        // Device reboot: uptime resets below the grant time. The new
        // manager must not treat the old deadline as still ahead.
        let rebootedClock = FakeMonotonicClock(start: 10)
        let relaunched = makeManager(clock: rebootedClock, backend: backend)
        XCTAssertFalse(relaunched.isUnlockActive)
        XCTAssertEqual(relaunched.remainingUnlockTime, 0)
        XCTAssertTrue(relaunched.isShielded(app: Self.game, category: Self.games))
    }

    func testCorruptPersistedWindowFailsClosedToShielded() throws {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))

        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(FileUnlockWindowStore.windowFileName)
        )
        let relaunched = makeManager(clock: clock, backend: backend)
        XCTAssertFalse(relaunched.isUnlockActive)
        XCTAssertTrue(relaunched.isShielded(app: Self.game, category: Self.games))
    }

    // MARK: - Unlock eligibility and revocation

    func testUnlockRefusedForNeverUnlockableAlwaysAllowedAndBadDuration() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)

        XCTAssertFalse(manager.grantUnlock(for: Self.browser, duration: 60))
        XCTAssertFalse(manager.grantUnlock(for: Self.socialApp, duration: 60))
        XCTAssertFalse(manager.grantUnlock(for: Self.allowedGame, duration: 60))
        XCTAssertFalse(manager.grantUnlock(for: Self.game, duration: 0))
        XCTAssertFalse(manager.grantUnlock(for: Self.game, duration: -5))
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.browser, category: Self.social))
    }

    func testGrantUnlockForAllChallengeUnlockableAndRevoke() throws {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)

        XCTAssertTrue(manager.grantUnlockForAllChallengeUnlockable(duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.entertainment))
        // Never-unlockable / non-unblockable apps stay shielded.
        XCTAssertTrue(manager.isShielded(app: Self.browser, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))

        try manager.revokeUnlock()
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))
    }

    func testPracticeUnlockUsesPolicyDuration() {
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: FakeMonotonicClock(), backend: backend)
        XCTAssertTrue(manager.grantPracticeUnlock(for: Self.game))
        // Policy fixture: practiceMinutes = 30.
        XCTAssertEqual(manager.remainingUnlockTime, 30 * 60, accuracy: 0.001)
    }

    // MARK: - Production clock sanity

    func testSystemUptimeClockIsPositiveAndNonDecreasing() {
        let clock = SystemUptimeClock()
        let first = clock.nowUptime
        let second = clock.nowUptime
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }

    // MARK: - Fix round 1 (issue #13): Copilot 2nd review

    private func makeCustomManager(
        policy: Policy,
        enumeration: ShieldEnumeration,
        backend: SimulatedShieldBackend,
        clock: FakeMonotonicClock,
        unlockStore: any UnlockWindowStore,
        bootSession: FakeBootSessionProvider,
        wall: FakeWallClock = FakeWallClock()
    ) -> (ShieldManager, PolicyStore) {
        let policyStore = PolicyStore(directory: directory)
        if policyStore.storedVersion == 0 {
            XCTAssertEqual(policyStore.apply(policy), .applied)
        }
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: unlockStore,
            bootSession: bootSession,
            nowWallDate: { wall.now() }
        )
        return (manager, policyStore)
    }

    func testSleepPastDeadlineExpiresUnlock() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let (manager, _) = makeCustomManager(
            policy: samplePolicy(),
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider()
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 5 * 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        // Suspend-inclusive time (awake + sleep) past the real-time deadline.
        clock.advance(by: 5 * 60 + 1)
        manager.refresh()
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 0)
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testSystemUptimeClockIsSuspendInclusive() {
        let continuous = SystemUptimeClock().nowUptime
        let awake = ProcessInfo.processInfo.systemUptime
        XCTAssertGreaterThan(continuous, 0)
        // Continuous time includes sleep, so it is never behind awake-only uptime.
        XCTAssertGreaterThanOrEqual(continuous, awake - 5)
    }

    func testRebootWithNewUptimeInsideOldWindowFailsClosed() {
        let backend = SimulatedShieldBackend()
        let clockBefore = FakeMonotonicClock(start: 1_000)
        let bootBefore = FakeBootSessionProvider("boot-1")
        let (manager, _) = makeCustomManager(
            policy: samplePolicy(),
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clockBefore,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: bootBefore
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        // Reboot: new boot's uptime (1,020) falls between the old grant
        // (1,000) and expiry (1,060). Uptime comparison alone would resume
        // with 40 seconds remaining; the boot-session binding must fail closed.
        let clockAfter = FakeMonotonicClock(start: 1_020)
        let bootAfter = FakeBootSessionProvider("boot-2")
        let policyStore = PolicyStore(directory: directory)
        let relaunched = ShieldManager(
            policyStore: policyStore,
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clockAfter,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: bootAfter
        )
        XCTAssertFalse(relaunched.isUnlockActive)
        XCTAssertEqual(relaunched.remainingUnlockTime, 0)
        XCTAssertTrue(relaunched.isShielded(app: Self.game, category: Self.games))
    }

    func testUnverifiableBootSessionFailsClosed() throws {
        // Old persisted format without a boot-session identifier.
        let legacyJSON = """
        {"unlockedApps":[{"id":"com.example.game"}],"unlockedCategories":[{"id":"games"}],\
        "grantedAtUptime":1000,"duration":60,"grantedWallDate":600000}
        """.data(using: .utf8)!
        try legacyJSON.write(
            to: directory.appendingPathComponent(FileUnlockWindowStore.windowFileName)
        )
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(samplePolicy()), .applied)
        let legacy = ShieldManager(
            policyStore: policyStore,
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: FakeMonotonicClock(start: 1_020),
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider("boot-1")
        )
        XCTAssertFalse(legacy.isUnlockActive)
        XCTAssertTrue(legacy.isShielded(app: Self.game, category: Self.games))

        // New window that cannot verify the current boot on reload.
        let clock = FakeMonotonicClock(start: 2_000)
        let (manager, _) = makeCustomManager(
            policy: samplePolicy(),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider("boot-1")
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        let unverifiable = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider(nil)
        )
        XCTAssertFalse(unverifiable.isUnlockActive)
        XCTAssertTrue(unverifiable.isShielded(app: Self.game, category: Self.games))
    }

    func testFailedWriteGrantLeavesPreviousWindowUntouched() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let boot = FakeBootSessionProvider()
        let failingStore = FailableUnlockWindowStore(directory: directory)
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(samplePolicy()), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clock,
            unlockStore: failingStore,
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 30 * 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        failingStore.failNextSave = true
        XCTAssertFalse(manager.grantUnlock(for: Self.video, duration: 60))
        XCTAssertEqual(manager.currentUnlockWindow?.unlockedApps, [Self.game])
        XCTAssertEqual(manager.remainingUnlockTime, 30 * 60, accuracy: 0.001)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))

        let relaunched = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertEqual(relaunched.currentUnlockWindow?.unlockedApps, [Self.game])
        XCTAssertFalse(relaunched.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(relaunched.isShielded(app: Self.video, category: Self.entertainment))
    }

    func testFailedDeleteRevocationThrowsAndPreservesWindow() throws {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let boot = FakeBootSessionProvider()
        let failingStore = FailableUnlockWindowStore(directory: directory)
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(samplePolicy()), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clock,
            unlockStore: failingStore,
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))

        failingStore.failNextClear = true
        XCTAssertThrowsError(try manager.revokeUnlock())
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        let relaunchedBeforeFix = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(relaunchedBeforeFix.isUnlockActive)

        failingStore.failNextClear = false
        XCTAssertNoThrow(try manager.revokeUnlock())
        XCTAssertFalse(manager.isUnlockActive)
        // Missing file counts as success: revoking again must not throw.
        XCTAssertNoThrow(try manager.revokeUnlock())

        let relaunchedAfterFix = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertFalse(relaunchedAfterFix.isUnlockActive)
        XCTAssertTrue(relaunchedAfterFix.isShielded(app: Self.game, category: Self.games))
    }

    func testPolicyRemovalOfUnlockedAppRelocksIt() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let boot = FakeBootSessionProvider()
        let (manager, policyStore) = makeCustomManager(
            policy: samplePolicy(),
            enumeration: sampleEnumeration(),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlockForAllChallengeUnlockable(duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.entertainment))

        var narrowed = samplePolicy()
        narrowed = Policy(
            version: 2,
            alwaysAllowed: narrowed.alwaysAllowed,
            unblockable: [Self.game],
            neverUnlockableOverrides: [Self.browser, Self.video],
            unlockDurations: narrowed.unlockDurations,
            effortFloorSettings: narrowed.effortFloorSettings,
            tradeCaps: narrowed.tradeCaps,
            chorePool: narrowed.chorePool,
            movementSettings: narrowed.movementSettings
        )
        XCTAssertEqual(policyStore.apply(narrowed), .applied)
        manager.refresh()
        XCTAssertEqual(manager.currentUnlockWindow?.unlockedApps, [Self.game])
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.entertainment))

        let relaunched = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: sampleEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertEqual(relaunched.currentUnlockWindow?.unlockedApps, [Self.game])
        XCTAssertTrue(relaunched.isShielded(app: Self.video, category: Self.entertainment))
    }

    func testEnumerationCategoryChangeMidWindowReconciles() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let boot = FakeBootSessionProvider()
        let policyStore = PolicyStore(directory: directory)
        var enumerationPolicy = samplePolicy()
        enumerationPolicy = Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: enumerationPolicy.unblockable,
            neverUnlockableOverrides: enumerationPolicy.neverUnlockableOverrides,
            unlockDurations: enumerationPolicy.unlockDurations,
            effortFloorSettings: enumerationPolicy.effortFloorSettings,
            tradeCaps: enumerationPolicy.tradeCaps,
            chorePool: enumerationPolicy.chorePool,
            movementSettings: enumerationPolicy.movementSettings
        )
        XCTAssertEqual(policyStore.apply(enumerationPolicy), .applied)

        // Unknown category at grant, known after re-enumeration.
        let unknown = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.video, category: nil)],
            categories: []
        )
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: unknown,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.video, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.video, category: nil))

        let known = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.video, category: Self.entertainment)],
            categories: [Self.entertainment]
        )
        manager.updateEnumeration(known)
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.entertainment))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.entertainment))

        // Changed mapping drops the obsolete category suppression.
        let changed = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.video, category: Self.social)],
            categories: [Self.entertainment, Self.social]
        )
        manager.updateEnumeration(changed)
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.social))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.entertainment))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.social))

        let relaunched = ShieldManager(
            policyStore: PolicyStore(directory: directory),
            enumeration: changed,
            backend: SimulatedShieldBackend(),
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertFalse(relaunched.isShielded(app: Self.video, category: Self.social))
    }

    func testAllowlistedAppWithNilCategoryPreservesAccess() {
        let backend = SimulatedShieldBackend()
        let enumeration = ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.allowedGame, category: nil),
            ],
            categories: [Self.games]
        )
        let (manager, _) = makeCustomManager(
            policy: samplePolicy(),
            enumeration: enumeration,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider()
        )
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testAllowlistedAppAbsentFromEnumerationPreservesAccess() {
        let backend = SimulatedShieldBackend()
        let missing = AppRef(id: "com.example.allowed-missing")
        var policy = samplePolicy()
        policy = Policy(
            version: 1,
            alwaysAllowed: [.phone, missing],
            unblockable: policy.unblockable,
            neverUnlockableOverrides: policy.neverUnlockableOverrides,
            unlockDurations: policy.unlockDurations,
            effortFloorSettings: policy.effortFloorSettings,
            tradeCaps: policy.tradeCaps,
            chorePool: policy.chorePool,
            movementSettings: policy.movementSettings
        )
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )
        let (manager, _) = makeCustomManager(
            policy: policy,
            enumeration: enumeration,
            backend: backend,
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: FakeBootSessionProvider()
        )
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: missing, category: Self.games))
    }

    // MARK: - Fix round 2 (issue #13): unresolved grant category coverage

    private func unlockOnlyPolicy() -> Policy {
        Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game, Self.video],
            neverUnlockableOverrides: [Self.browser],
            unlockDurations: UnlockDurations(practiceMinutes: 30, tradeMinutes: 15),
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
    }

    func testGrantWithNilCategoryAndBackstopPreservesAccess() {
        let backend = SimulatedShieldBackend()
        let clock = FakeMonotonicClock()
        let boot = FakeBootSessionProvider()
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: nil)],
            categories: [Self.games]
        )
        let (manager, _) = makeCustomManager(
            policy: unlockOnlyPolicy(),
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        // Pre-grant the actual category backstop shields the app.
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))

        // No explicit category: the grant must not report success while
        // the app remains shielded via the backstop.
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: nil))
    }

    func testGrantForAllWithNilCategoryPreservesAccess() {
        let backend = SimulatedShieldBackend()
        let clock = FakeMonotonicClock()
        let boot = FakeBootSessionProvider()
        let enumeration = ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: nil),
                EnumeratedApp(app: Self.video, category: Self.entertainment),
            ],
            categories: [Self.games, Self.entertainment]
        )
        let (manager, _) = makeCustomManager(
            policy: unlockOnlyPolicy(),
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlockForAllChallengeUnlockable(duration: 60))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.video, category: Self.entertainment))
    }

    func testReenumerationMetadataLossMidWindowPreservesAccess() {
        let backend = SimulatedShieldBackend()
        let clock = FakeMonotonicClock()
        let boot = FakeBootSessionProvider()
        let known = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(unlockOnlyPolicy()), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: known,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        XCTAssertTrue(manager.grantUnlock(for: Self.game, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.games))

        // Re-enumeration loses the category mapping mid-window: the app
        // must stay open until expiry, not re-lock via the backstop.
        clock.advance(by: 10)
        manager.updateEnumeration(ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: nil)],
            categories: [Self.games]
        ))
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertGreaterThan(manager.remainingUnlockTime, 0)
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.isEmpty)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testGrantWithExplicitCategoryKeepsOtherBackstop() {
        let backend = SimulatedShieldBackend()
        let clock = FakeMonotonicClock()
        let boot = FakeBootSessionProvider()
        let enumeration = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: nil)],
            categories: [Self.games, Self.social]
        )
        let (manager, _) = makeCustomManager(
            policy: unlockOnlyPolicy(),
            enumeration: enumeration,
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory),
            bootSession: boot
        )
        // Caller-supplied category covers the nil-enumeration app: only
        // that category is withheld, the rest of the backstop stays.
        XCTAssertTrue(manager.grantUnlock(for: Self.game, category: Self.games, duration: 60))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.currentConfiguration.shieldedCategories.contains(Self.games))
        XCTAssertTrue(manager.currentConfiguration.shieldedCategories.contains(Self.social))
    }
}
