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

    func testGrantUnlockForAllChallengeUnlockableAndRevoke() {
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

        manager.revokeUnlock()
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
}
