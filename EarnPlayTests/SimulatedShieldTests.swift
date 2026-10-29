import Foundation
import XCTest
import EarnPlayCore

/// T2.4 (issue #15) — Simulated shield fallback, exercised from the
/// child app target (simulator gate) with simulated mode forced on.
///
/// Asserts the present/dismiss/re-present sequence in order for a
/// locked demo app: the simulated shield view is presented, a granted
/// unlock dismisses it, and expiry of the shortened test timer
/// re-presents it — with ManagedSettings calls stubbed to zero
/// throughout. Verification here is via the simulated interface only;
/// real-shield enforcement needs the T0.4 entitlement (v1, not filed).
final class SimulatedShieldTests: XCTestCase {
    private var directory: URL!

    private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
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

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "earnplay.demo.game")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatedShieldTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    @MainActor
    private func makeFlow(
        clock: FakeMonotonicClock, backend: SimulatedShieldBackend
    ) -> SimulatedShieldFlow {
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
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [EnumeratedApp(app: Self.game, category: Self.games)],
                categories: [Self.games]
            ),
            backend: backend,
            clock: clock,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        // Simulated mode forced on, shortened (2s) test timer.
        return SimulatedShieldFlow(
            manager: manager,
            backend: backend,
            app: Self.game,
            category: Self.games,
            scorer: EffortScorer(threshold: 8),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: 2,
            isSimulatedMode: true,
            decisionLogger: DecisionLogger(directory: directory)
        )
    }

    @MainActor
    func testSimulatedShieldPresentDismissRePresentSequence() {
        let clock = FakeMonotonicClock()
        let backend = SimulatedShieldBackend()
        let flow = makeFlow(clock: clock, backend: backend)

        // Presented for the locked app.
        XCTAssertTrue(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented])
        XCTAssertEqual(backend.managedSettingsCallCount, 0)

        // Granted unlock dismisses: 2 attempts (4 pts) + 2 hints (4 pts).
        flow.submitAttempt(answer: "56")
        flow.submitAttempt(answer: "56 again")
        flow.useHint()
        flow.useHint()
        XCTAssertEqual(flow.finishChallenge()?.decision, .granted)
        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented, .dismissed])
        XCTAssertEqual(flow.remainingUnlockTime, 2, accuracy: 0.001)
        XCTAssertEqual(backend.managedSettingsCallCount, 0)

        // Short-timer expiry re-presents.
        clock.advance(by: 3)
        flow.tick()
        XCTAssertTrue(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented, .dismissed, .presented])
        XCTAssertEqual(flow.remainingUnlockTime, 0)
        XCTAssertEqual(backend.managedSettingsCallCount, 0)
    }

    func testSimulatedShieldIsVisiblyLabelledSimulated() {
        // The badge text the shield screen renders while presented.
        XCTAssertTrue(SimulatedShieldFlow.simulatedBadgeText.contains("SIMULATED"))
    }
}
