import Foundation
import XCTest
import EarnPlayCore

/// T3.2 fix round 3, exercised from the child app target (simulator gate),
/// mirroring the package suite through public `EarnPlayCore` API only: a
/// parent policy with an empty pool is respected (no demo seed, real
/// policy path), a failed grant surfaces failure text while staying
/// retryable, and the granted status refreshes through expiry.
final class ChoreTradeFixRound3AppTests: XCTestCase {
    private var directory: URL!

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

    /// Unlock store whose saves fail while `failSaves` is true, so a
    /// grant can fail and then succeed on retry.
    private final class FlakyUnlockStore: UnlockWindowStore, @unchecked Sendable {
        private let lock = NSLock()
        private var window: UnlockWindow?
        private var failSavesValue = true
        var failSaves: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failSavesValue }
            set { lock.lock(); defer { lock.unlock() }; failSavesValue = newValue }
        }
        func loadUnlockWindow() -> UnlockWindow? {
            lock.lock()
            defer { lock.unlock() }
            return window
        }
        func saveUnlockWindow(_ window: UnlockWindow) throws {
            lock.lock()
            defer { lock.unlock() }
            if failSavesValue {
                throw NSError(domain: "ChoreTradeFixRound3AppTests", code: 1)
            }
            self.window = window
        }
        func clearUnlockWindow() throws {
            lock.lock()
            defer { lock.unlock() }
            window = nil
        }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")
    private static let future = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound3AppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
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

    private func makeManager(
        clock: AdvancingClock? = nil,
        backend: SimulatedShieldBackend? = nil,
        unlockStore: (any UnlockWindowStore)? = nil
    ) -> (ShieldManager, SimulatedShieldBackend, AdvancingClock) {
        let usedClock = clock ?? AdvancingClock()
        let usedBackend = backend ?? SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(chorePool: [
            ChorePoolEntry(
                chore: "Wash the car",
                unlockMinutes: 10,
                expiry: Self.future,
                weeklyCap: 3,
                verificationMode: .parentConfirm)
        ])), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [EnumeratedApp(app: Self.game, category: Self.games)],
                categories: [Self.games]
            ),
            backend: usedBackend,
            clock: usedClock,
            unlockStore: unlockStore ?? FileUnlockWindowStore(directory: directory)
        )
        return (manager, usedBackend, usedClock)
    }

    @MainActor
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

    // MARK: - Finding 1: empty parent pools are respected, never demo-seeded

    func testParentPolicyWithEmptyPoolResolvesToNoOffersAndRealPath() {
        let resolution = ChoreTradePoolSource.resolve(policy: parentPolicy(chorePool: []))
        XCTAssertFalse(resolution.isDemo)
        XCTAssertTrue(resolution.pool.isEmpty)
        XCTAssertEqual(resolution.poolSourceCaption, "Parent's chores (policy v1)")
        var session = ChoreTradeSession(pool: resolution.pool)
        XCTAssertNil(session.makeOffer(at: Date()))
    }

    func testDefaultPolicyResolvesToDemoSeed() {
        let resolution = ChoreTradePoolSource.resolve(policy: Policy.defaultPolicy)
        XCTAssertTrue(resolution.isDemo)
        XCTAssertEqual(resolution.pool, DemoChorePool.seeded())
    }

    // MARK: - Finding 2: grant failure feedback, confirmation retryable

    func testFailedGrantShowsFailureAndConfirmationStaysRetryable() async {
        let store = FlakyUnlockStore()
        store.failSaves = true
        let (manager, _, _) = makeManager(unlockStore: store)
        let pool = DemoChorePool.seeded()
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)

            viewModel.parentConfirm()
            XCTAssertEqual(viewModel.grantSucceeded, false)
            XCTAssertNotNil(viewModel.confirmationFailureText)
            guard case .doneAwaitingConfirm = viewModel.session.phase else {
                XCTFail("failed grant must stay retryable, got \(viewModel.session.phase)")
                return
            }

            store.failSaves = false
            viewModel.parentConfirm()
            XCTAssertEqual(viewModel.grantSucceeded, true)
            XCTAssertNil(viewModel.confirmationFailureText)
            XCTAssertTrue(viewModel.session.hasGrantedUnlock)
            XCTAssertTrue(manager.isUnlockActive)
        }
    }

    // MARK: - Finding 3: granted status refreshes through expiry

    func testGrantedStatusShowsExpiredAfterWindowEnds() async {
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let (manager, _, _) = makeManager(clock: clock, backend: backend)
        let pool = DemoChorePool.seeded()
        // The offered chore varies by time of day; advance past the
        // longest possible grant so expiry holds either way.
        let minutes = pool.map(\.unlockMinutes).max() ?? 10
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)
            viewModel.parentConfirm()
            XCTAssertTrue(manager.isUnlockActive)

            clock.advance(by: TimeInterval(minutes * 60 + 1))
            viewModel.refreshGrantedStatus()
            XCTAssertEqual(
                viewModel.shieldStatus,
                "Unlock expired — device is shielded again.")
            XCTAssertFalse(manager.isUnlockActive)
            XCTAssertTrue(backend.isShielded(app: Self.game, category: Self.games))
        }
    }
}
