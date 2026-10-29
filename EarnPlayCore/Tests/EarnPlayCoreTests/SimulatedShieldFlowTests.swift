import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.4 — Simulated shield fallback: the formalized simulated backend,
/// the force-simulated-mode flag, and the present/dismiss/re-present
/// flow on the T2.2 `ShieldManager` interface.
///
/// Verification here is via the simulated interface only. Real-shield
/// enforcement needs the T0.4 entitlement (v1, not filed) and is never
/// claimed by these tests.
final class SimulatedShieldFlowTests: XCTestCase {
    private var directory: URL!

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

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "earnplay.demo.game")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatedShieldFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeManager(clock: FakeMonotonicClock, backend: SimulatedShieldBackend) -> ShieldManager {
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
        return ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [EnumeratedApp(app: Self.game, category: Self.games)],
                categories: [Self.games]
            ),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    @MainActor
    private func makeFlow(
        clock: FakeMonotonicClock,
        backend: SimulatedShieldBackend,
        isSimulatedMode: Bool = true,
        unlockDuration: TimeInterval = 2
    ) -> SimulatedShieldFlow {
        SimulatedShieldFlow(
            manager: makeManager(clock: clock, backend: backend),
            backend: backend,
            app: Self.game,
            category: Self.games,
            scorer: EffortScorer(threshold: 8),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: unlockDuration,
            isSimulatedMode: isSimulatedMode
        )
    }

    /// Records enough effort to pass: 2 genuine attempts (4 pts) + 2
    /// hint interactions (4 pts) = 8 against threshold 8, floor met.
    @MainActor
    private func recordPassingEffort(on flow: SimulatedShieldFlow) {
        flow.submitAttempt(answer: "56")
        flow.submitAttempt(answer: "let me try again: 56")
        flow.useHint()
        flow.useHint()
    }

    // MARK: - Present / dismiss / re-present

    @MainActor
    func testPresentDismissRePresentSequenceWithZeroManagedSettingsCalls() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let flow = makeFlow(clock: clock, backend: backend)

        // Presented: simulated mode forced on, app locked.
        XCTAssertTrue(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented])
        XCTAssertEqual(flow.managedSettingsCallCount, 0)

        // Dismissed: a granted challenge opens the (shortened) window.
        recordPassingEffort(on: flow)
        let score = flow.finishChallenge()
        XCTAssertEqual(score.decision, .granted)
        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented, .dismissed])
        XCTAssertEqual(flow.remainingUnlockTime, 2, accuracy: 0.001)
        XCTAssertEqual(flow.managedSettingsCallCount, 0)

        // Re-presented: the short timer expires and the app re-locks.
        clock.advance(by: 3)
        flow.tick()
        XCTAssertTrue(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented, .dismissed, .presented])
        XCTAssertEqual(flow.remainingUnlockTime, 0)
        XCTAssertEqual(flow.managedSettingsCallCount, 0)
    }

    @MainActor
    func testDeniedChallengeKeepsShieldPresented() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let flow = makeFlow(clock: clock, backend: backend)

        // No effort: score 0, floor unmet — denied, shield stays up.
        let score = flow.finishChallenge()
        XCTAssertEqual(score.decision, .denied)
        XCTAssertTrue(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented])
        XCTAssertEqual(flow.managedSettingsCallCount, 0)
    }

    @MainActor
    func testSimulatedModeOffNeverPresents() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let manager = makeManager(clock: clock, backend: backend)
        let flow = SimulatedShieldFlow(
            manager: manager,
            backend: backend,
            app: Self.game,
            category: Self.games,
            scorer: EffortScorer(threshold: 8),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: 2,
            isSimulatedMode: false
        )

        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [])

        // Even a granted unlock leaves the screen down when the flag is off.
        recordPassingEffort(on: flow)
        XCTAssertEqual(flow.finishChallenge().decision, .granted)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [])

        clock.advance(by: 3)
        flow.tick()
        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [])
    }

    // MARK: - Backend

    func testBackendAppliesConfigurationAndReportsZeroManagedSettingsCalls() {
        let backend = SimulatedShieldBackend()
        let configuration = ShieldConfiguration(
            shieldedApplications: [Self.game],
            shieldedCategories: [Self.games]
        )
        backend.applyShieldConfiguration(configuration)

        XCTAssertEqual(backend.currentShieldConfiguration, configuration)
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertEqual(backend.managedSettingsCallCount, 0)
        XCTAssertTrue(backend.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(backend.isShielded(app: AppRef(id: "other"), category: Self.games))
        XCTAssertFalse(backend.isShielded(app: AppRef(id: "other"), category: nil))
    }

    // MARK: - Mode flag

    func testSimulatedModeFlagResolution() {
        let suiteName = "SimulatedShieldFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        // Nothing set: off.
        XCTAssertFalse(SimulatedShieldMode.isForced(
            environment: [:], arguments: [], userDefaults: defaults))

        // Launch argument forces on.
        XCTAssertTrue(SimulatedShieldMode.isForced(
            environment: [:],
            arguments: ["EarnPlay", SimulatedShieldMode.forceArgument],
            userDefaults: defaults))

        // Environment values force on for 1/true only.
        XCTAssertTrue(SimulatedShieldMode.isForced(
            environment: [SimulatedShieldMode.forceEnvironmentKey: "1"],
            arguments: [], userDefaults: defaults))
        XCTAssertTrue(SimulatedShieldMode.isForced(
            environment: [SimulatedShieldMode.forceEnvironmentKey: "true"],
            arguments: [], userDefaults: defaults))
        XCTAssertFalse(SimulatedShieldMode.isForced(
            environment: [SimulatedShieldMode.forceEnvironmentKey: "0"],
            arguments: [], userDefaults: defaults))

        // Debug toggle (UserDefaults) forces on and back off.
        SimulatedShieldMode.setForced(true, userDefaults: defaults)
        XCTAssertTrue(SimulatedShieldMode.isForced(
            environment: [:], arguments: [], userDefaults: defaults))
        SimulatedShieldMode.setForced(false, userDefaults: defaults)
        XCTAssertFalse(SimulatedShieldMode.isForced(
            environment: [:], arguments: [], userDefaults: defaults))
    }

    // MARK: - Honesty label

    func testSimulatedBadgeTextMarksDemoOnly() {
        XCTAssertTrue(SimulatedShieldFlow.simulatedBadgeText.contains("SIMULATED"))
        XCTAssertTrue(SimulatedShieldFlow.simulatedBadgeText.contains("NOT REAL ENFORCEMENT"))
    }
}
