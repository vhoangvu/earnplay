import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 fix round 3 — cached parent policies with empty pools, grant
/// failure feedback, and granted-status expiry monitoring.
///
/// View-model tests run through `MainActor.run`: `ChoreTradeViewModel` is
/// `MainActor`-isolated, and the app module builds without
/// `-enable-testing`, so the view model lives in Core where both gates
/// drive the real confirm/grant/status path.
final class ChoreTradeFixRound3Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ChoreTradeFixRound3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private static let future = Date(timeIntervalSince1970: 2_000_000_000)
    private static let game = AppRef(id: "com.example.game")
    private static let games = AppCategoryRef(id: "games")

    private func entry(
        _ chore: String,
        minutes: Int = 10,
        expiry: Date = ChoreTradeFixRound3Tests.future
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
                throw NSError(domain: "ChoreTradeFixRound3Tests", code: 1)
            }
            self.window = window
        }
        func clearUnlockWindow() throws {
            lock.lock()
            defer { lock.unlock() }
            window = nil
        }
    }

    private func parentPolicy(
        version: Int = 1,
        chorePool: [ChorePoolEntry],
        unblockable: [AppRef] = []
    ) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [.phone],
            unblockable: unblockable,
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: chorePool,
            movementSettings: .default
        )
    }

    private func makeManager(
        unblockable: [AppRef] = [ChoreTradeFixRound3Tests.game],
        clock: AdvancingClock? = nil,
        backend: SimulatedShieldBackend? = nil,
        unlockStore: (any UnlockWindowStore)? = nil
    ) -> (ShieldManager, SimulatedShieldBackend, AdvancingClock) {
        let usedClock = clock ?? AdvancingClock()
        let usedBackend = backend ?? SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(parentPolicy(
            chorePool: [entry("Wash the car")],
            unblockable: unblockable
        )), .applied)
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
        let resolution = ChoreTradePoolSource.resolve(
            policy: parentPolicy(chorePool: []))
        // No seeded chores, no demo shield policy: the real policy path.
        XCTAssertFalse(resolution.isDemo)
        XCTAssertTrue(resolution.pool.isEmpty)
        XCTAssertEqual(resolution.poolSourceCaption, "Parent's chores (policy v1)")
        // And an empty pool offers nothing.
        var session = ChoreTradeSession(pool: resolution.pool)
        XCTAssertNil(session.makeOffer(at: Date()))
        XCTAssertNil(session.currentOffer)
    }

    func testDefaultPolicyResolvesToDemoSeed() {
        XCTAssertFalse(ChoreTradePoolSource.isParentAuthored(Policy.defaultPolicy))
        let resolution = ChoreTradePoolSource.resolve(policy: Policy.defaultPolicy)
        XCTAssertTrue(resolution.isDemo)
        XCTAssertEqual(resolution.pool, DemoChorePool.seeded())
        XCTAssertEqual(resolution.poolSourceCaption, "Demo chores")
        var session = ChoreTradeSession(pool: resolution.pool)
        XCTAssertNotNil(session.makeOffer(at: Date()))
    }

    func testParentPolicyWithStockedPoolUsesParentPool() {
        let stocked = [entry("Wash the car"), entry("Paint the fence")]
        let policy = parentPolicy(version: 2, chorePool: stocked)
        XCTAssertTrue(ChoreTradePoolSource.isParentAuthored(policy))
        let resolution = ChoreTradePoolSource.resolve(policy: policy)
        XCTAssertFalse(resolution.isDemo)
        XCTAssertEqual(resolution.pool, stocked)
        XCTAssertEqual(resolution.poolSourceCaption, "Parent's chores (policy v2)")
    }

    func testParentEmptyPoolShieldPathGrantsNothingUnlikeDemoFixture() {
        // The parent path (real store + derived enumeration) for a policy
        // with no unblockable apps grants nothing — proving the demo
        // fixture (which grants) is not selected for a parent policy.
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(
            policyStore.apply(parentPolicy(chorePool: [])), .applied)
        let parentManager = ShieldManager(
            policyStore: policyStore,
            enumeration: ChoreTradeDemoShield.enumeration(
                for: policyStore.currentPolicy),
            backend: SimulatedShieldBackend(),
            clock: AdvancingClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        XCTAssertFalse(parentManager.grantChoreTradeUnlock(minutes: 10))
        XCTAssertFalse(parentManager.isUnlockActive)

        // The demo fixture pair grants, so this contrast is meaningful:
        // routing a parent policy through it would wrongly unlock.
        let demoDirectory = directory.appendingPathComponent("demo", isDirectory: true)
        let demoStore = PolicyStore(directory: demoDirectory)
        XCTAssertEqual(
            demoStore.apply(ChoreTradeDemoShield.demoPolicy(
                chorePool: DemoChorePool.seeded())), .applied)
        let demoManager = ShieldManager(
            policyStore: demoStore,
            enumeration: ChoreTradeDemoShield.demoEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: AdvancingClock(),
            unlockStore: FileUnlockWindowStore(directory: demoDirectory)
        )
        XCTAssertTrue(demoManager.grantChoreTradeUnlock(minutes: 10))
    }

    // MARK: - Finding 2: grant failure feedback, confirmation retryable

    func testFailedGrantShowsFailureAndConfirmationStaysRetryable() async {
        let store = FlakyUnlockStore()
        store.failSaves = true
        let (manager, _, _) = makeManager(unlockStore: store)
        let pool = [entry("Wash the car", minutes: 10)]
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)

            // Failed grant: failure text for the awaiting-confirm screen,
            // and the session stays put so Confirm retries.
            viewModel.parentConfirm()
            XCTAssertEqual(viewModel.grantSucceeded, false)
            XCTAssertNotNil(
                viewModel.confirmationFailureText,
                "failed grant must surface failure text in the awaiting-confirm state")
            guard case .doneAwaitingConfirm = viewModel.session.phase else {
                XCTFail("failed grant must stay retryable, got \(viewModel.session.phase)")
                return
            }
            XCTAssertFalse(manager.isUnlockActive)

            // Retryable: once persistence works, the same confirm grants.
            store.failSaves = false
            viewModel.parentConfirm()
            XCTAssertEqual(viewModel.grantSucceeded, true)
            XCTAssertNil(viewModel.confirmationFailureText)
            XCTAssertTrue(viewModel.session.hasGrantedUnlock)
            XCTAssertTrue(manager.isUnlockActive)
        }
    }

    func testFailedGrantWithNoUnlockableAppsShowsFailure() async {
        // The other failure class: the grant path finds no unlockable app.
        let (manager, _, _) = makeManager(unblockable: [])
        let pool = [entry("Wash the car", minutes: 10)]
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
        }
    }

    func testSuccessfulGrantShowsNoFailure() async {
        let (manager, _, _) = makeManager()
        let pool = [entry("Wash the car", minutes: 10)]
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)

            viewModel.parentConfirm()
            XCTAssertEqual(viewModel.grantSucceeded, true)
            XCTAssertNil(viewModel.confirmationFailureText)
            XCTAssertTrue(viewModel.session.hasGrantedUnlock)
        }
    }

    // MARK: - Finding 3: granted status refreshes through expiry

    func testGrantedStatusShowsExpiredAfterWindowEnds() async {
        let backend = SimulatedShieldBackend()
        let clock = AdvancingClock()
        let (manager, _, _) = makeManager(clock: clock, backend: backend)
        let pool = [entry("Wash the car", minutes: 10)]
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)
            viewModel.parentConfirm()
            XCTAssertTrue(manager.isUnlockActive)
            XCTAssertTrue(
                viewModel.shieldStatus.contains("seconds left"),
                "granted screen shows the live countdown, got: \(viewModel.shieldStatus)")

            // The granted screen stays open past the promised 10 minutes.
            clock.advance(by: 10 * 60 + 1)
            viewModel.refreshGrantedStatus()
            XCTAssertEqual(
                viewModel.shieldStatus,
                "Unlock expired — device is shielded again.")
            XCTAssertFalse(manager.isUnlockActive)
            XCTAssertTrue(backend.isShielded(app: Self.game, category: Self.games))
        }
    }

    func testGrantedStatusCountdownUpdatesWhileOpen() async {
        let clock = AdvancingClock()
        let (manager, _, _) = makeManager(clock: clock)
        let pool = [entry("Wash the car", minutes: 10)]
        await MainActor.run {
            let viewModel = ChoreTradeViewModel(
                pool: pool,
                poolSourceCaption: "Parent's chores (policy v1)",
                shieldManager: manager)
            Self.driveToDoneAwaitingConfirm(viewModel)
            viewModel.parentConfirm()
            XCTAssertEqual(
                viewModel.shieldStatus,
                "Device unlock active, 600 seconds left.")

            clock.advance(by: 61)
            viewModel.refreshGrantedStatus()
            XCTAssertEqual(
                viewModel.shieldStatus,
                "Device unlock active, 539 seconds left.")
            XCTAssertTrue(manager.isUnlockActive)
        }
    }
}
