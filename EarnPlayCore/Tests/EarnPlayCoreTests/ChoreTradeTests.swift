import Foundation
import XCTest
@testable import EarnPlayCore

/// T3.2 — Chore trade: single-offer state machine, decline exclusion,
/// expiry filter, rotation + time-of-day fit, and the parent-confirm
/// unlock grant.
///
/// The explicit check runs through every flow test: Done alone grants
/// nothing — no record, no minutes, no ShieldManager unlock — until the
/// parent confirms.
final class ChoreTradeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChoreTradeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let future = Date(timeIntervalSince1970: 2_000_000_000)
    private static let past = Date(timeIntervalSince1970: 1_600_000_000)

    private func entry(
        _ chore: String,
        minutes: Int = 10,
        expiry: Date = ChoreTradeTests.future
    ) -> ChorePoolEntry {
        ChorePoolEntry(
            chore: chore,
            unlockMinutes: minutes,
            expiry: expiry,
            weeklyCap: 3,
            verificationMode: .parentConfirm
        )
    }

    /// Neutral names (no daypart keywords) so rotation tests isolate recency.
    private func neutralPool() -> [ChorePoolEntry] {
        [entry("Wash the car", minutes: 10), entry("Paint the fence", minutes: 15)]
    }

    // MARK: - Full flow in order

    func testOfferAcceptDoneConfirmGrantsInOrder() {
        var session = ChoreTradeSession(pool: neutralPool())
        let t0 = Self.now

        // Offer: exactly one chore surfaces, nothing granted.
        let offer = session.makeOffer(at: t0)
        XCTAssertNotNil(offer)
        XCTAssertEqual(session.currentOffer?.entry, offer?.entry)
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertNil(session.grantedMinutes)
        XCTAssertNil(session.grantedRecord)

        // Accept.
        XCTAssertTrue(session.acceptOffer(at: t0.addingTimeInterval(60)))
        XCTAssertEqual(session.currentOffer?.entry.chore, offer?.entry.chore)
        XCTAssertFalse(session.hasGrantedUnlock)

        // Done: the explicit check — Done alone grants nothing.
        XCTAssertTrue(session.markDone(at: t0.addingTimeInterval(120)))
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertNil(session.grantedMinutes)
        XCTAssertNil(session.grantedRecord)

        // Parent confirm: the unlock grant, for the stated minutes.
        let record = session.parentConfirm(at: t0.addingTimeInterval(180))
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.chore, offer?.entry.chore)
        XCTAssertEqual(record?.grantedUnlockMinutes, offer?.entry.unlockMinutes)
        XCTAssertEqual(record?.sessionID, session.sessionID)
        XCTAssertTrue(session.hasGrantedUnlock)
        XCTAssertEqual(session.grantedMinutes, offer?.entry.unlockMinutes)
        XCTAssertEqual(session.grantedRecord, record)
        XCTAssertNil(session.currentOffer)

        // No double-grant: a second confirm returns nil.
        XCTAssertNil(session.parentConfirm(at: t0.addingTimeInterval(240)))
        // One completed trade per session: no further offers.
        XCTAssertNil(session.makeOffer(at: t0.addingTimeInterval(300)))
    }

    func testDoneAloneGrantsNothingAndConfirmBeforeDoneReturnsNil() {
        // Idle: confirm is nil.
        var idle = ChoreTradeSession(pool: neutralPool())
        XCTAssertNil(idle.parentConfirm(at: Self.now))
        XCTAssertFalse(idle.hasGrantedUnlock)

        // Offered but not accepted: confirm is nil.
        var offered = ChoreTradeSession(pool: neutralPool())
        XCTAssertNotNil(offered.makeOffer(at: Self.now))
        XCTAssertNil(offered.parentConfirm(at: Self.now))

        // Accepted but not done: confirm is nil, Done then grants nothing.
        var accepted = ChoreTradeSession(pool: neutralPool())
        XCTAssertNotNil(accepted.makeOffer(at: Self.now))
        XCTAssertTrue(accepted.acceptOffer(at: Self.now))
        XCTAssertNil(accepted.parentConfirm(at: Self.now))
        XCTAssertTrue(accepted.markDone(at: Self.now))
        XCTAssertFalse(accepted.hasGrantedUnlock)
        XCTAssertNil(accepted.grantedMinutes)
        XCTAssertNil(accepted.grantedRecord)
    }

    // MARK: - Order violations fail

    func testOutOfOrderTransitionsFail() {
        var session = ChoreTradeSession(pool: neutralPool())

        // Nothing active: accept/decline/done all fail.
        XCTAssertFalse(session.acceptOffer(at: Self.now))
        XCTAssertFalse(session.declineOffer())
        XCTAssertFalse(session.markDone(at: Self.now))

        // Offered: done fails (must accept first).
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertFalse(session.markDone(at: Self.now))
        // One active offer: no second offer while one is up.
        let current = session.currentOffer
        XCTAssertNil(session.makeOffer(at: Self.now))
        XCTAssertEqual(session.currentOffer, current)

        // Accepted: decline fails (no decline path after accept).
        XCTAssertTrue(session.acceptOffer(at: Self.now))
        XCTAssertFalse(session.declineOffer())
        XCTAssertFalse(session.acceptOffer(at: Self.now))
    }

    // MARK: - Decline exclusion

    func testDeclinedChoreIsNotReofferedInSession() {
        var session = ChoreTradeSession(pool: neutralPool())

        let first = session.makeOffer(at: Self.now)
        XCTAssertNotNil(first)
        XCTAssertTrue(session.declineOffer())
        // Practice resumes: idle, nothing granted, no current offer.
        XCTAssertNil(session.currentOffer)
        XCTAssertFalse(session.hasGrantedUnlock)

        // The next offer is a different chore, never the declined one.
        let second = session.makeOffer(at: Self.now)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second?.entry.chore, first?.entry.chore)

        // Decline that too: the pool is exhausted, no offer.
        XCTAssertTrue(session.declineOffer())
        XCTAssertNil(session.makeOffer(at: Self.now))
    }

    func testSingleChorePoolOfferDeclineLeavesNoOffer() {
        var session = ChoreTradeSession(pool: [entry("Wash the car")])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertTrue(session.declineOffer())
        XCTAssertNil(session.makeOffer(at: Self.now))
        XCTAssertFalse(session.hasGrantedUnlock)
    }

    // MARK: - Expiry filter

    func testExpiredChoreIsNeverOffered() {
        let pool = [
            entry("Expired chore", expiry: Self.past),
            entry("Live chore", expiry: Self.future),
        ]
        var session = ChoreTradeSession(pool: pool)
        let offer = session.makeOffer(at: Self.now)
        XCTAssertEqual(offer?.entry.chore, "Live chore")
    }

    func testAllExpiredPoolOffersNothing() {
        let pool = [entry("Old chore", expiry: Self.past)]
        var session = ChoreTradeSession(pool: pool)
        XCTAssertNil(session.makeOffer(at: Self.now))
        XCTAssertNil(session.currentOffer)
    }

    func testExpiryAtNowCountsAsExpired() {
        let pool = [entry("Edge chore", expiry: Self.now)]
        let eligible = ChoreTradeSession.eligibleChores(
            pool: pool, declined: [], now: Self.now
        )
        XCTAssertTrue(eligible.isEmpty)
        var session = ChoreTradeSession(pool: pool)
        XCTAssertNil(session.makeOffer(at: Self.now))
    }

    // MARK: - Accept rejects expired offers (fix round 2)

    func testAcceptOfferRejectsExpiredOfferAndReturnsToIdle() {
        // Offered while live, accepted after its expiry.
        var session = ChoreTradeSession(pool: [
            entry("Wash the car", expiry: Self.now.addingTimeInterval(60)),
        ])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertFalse(session.acceptOffer(at: Self.now.addingTimeInterval(120)))
        // Back to idle: no current offer, nothing completed or granted,
        // and the order still fails closed from here.
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(session.currentOffer)
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertNil(session.grantedMinutes)
        XCTAssertNil(session.grantedRecord)
        XCTAssertFalse(session.markDone(at: Self.now.addingTimeInterval(121)))
        XCTAssertNil(session.parentConfirm(at: Self.now.addingTimeInterval(122)))
        // The expired chore is not re-offered.
        XCTAssertNil(session.makeOffer(at: Self.now.addingTimeInterval(120)))
    }

    func testAcceptOfferAtExactExpiryCountsAsExpired() {
        var session = ChoreTradeSession(pool: [
            entry("Wash the car", expiry: Self.now.addingTimeInterval(60)),
        ])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertFalse(session.acceptOffer(at: Self.now.addingTimeInterval(60)))
        XCTAssertEqual(session.phase, .idle)
    }

    func testAcceptOfferJustBeforeExpiryStillAccepts() {
        var session = ChoreTradeSession(pool: [
            entry("Wash the car", expiry: Self.now.addingTimeInterval(60)),
        ])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertTrue(session.acceptOffer(at: Self.now.addingTimeInterval(59)))
        XCTAssertEqual(session.currentOffer?.entry.chore, "Wash the car")
    }

    func testExpiredAcceptFreesSessionForAnotherEligibleChore() {
        // "Paint the fence" was offered in an earlier session, so
        // rotation offers expiring "Wash the car" first.
        var session = ChoreTradeSession(
            pool: [
                entry("Wash the car", expiry: Self.now.addingTimeInterval(60)),
                entry("Paint the fence", expiry: Self.future),
            ],
            priorHistory: ["Paint the fence"]
        )
        let first = session.makeOffer(at: Self.now)
        XCTAssertEqual(first?.entry.chore, "Wash the car")
        XCTAssertFalse(session.acceptOffer(at: Self.now.addingTimeInterval(120)))
        XCTAssertEqual(session.phase, .idle)
        // Another eligible chore can still be offered and accepted.
        let second = session.makeOffer(at: Self.now.addingTimeInterval(120))
        XCTAssertEqual(second?.entry.chore, "Paint the fence")
        XCTAssertTrue(session.acceptOffer(at: Self.now.addingTimeInterval(121)))
    }

    // MARK: - Rotation and time-of-day fit

    func testRotationPrefersNeverOfferedOverPriorHistory() {
        // "Wash the car" was offered in an earlier session; the fresh
        // chore wins even though it sorts later.
        let session = ChoreTradeSession(
            pool: neutralPool(), priorHistory: ["Wash the car"]
        )
        var mutable = session
        let offer = mutable.makeOffer(at: Self.now)
        XCTAssertEqual(offer?.entry.chore, "Paint the fence")
    }

    func testInSessionRotationLeastRecentlyOfferedFirst() {
        var session = ChoreTradeSession(pool: [
            entry("Wash the car"), entry("Paint the fence"), entry("Walk the dog"),
        ])
        let first = session.makeOffer(at: Self.now)?.entry.chore
        XCTAssertNotNil(first)
        XCTAssertTrue(session.declineOffer())
        let second = session.makeOffer(at: Self.now)?.entry.chore
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        // Neither repeats a declined chore; rotation covers the pool.
        XCTAssertTrue(session.declineOffer())
        let third = session.makeOffer(at: Self.now)?.entry.chore
        XCTAssertNotNil(third)
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(third, second)
    }

    func testTimeOfDayFitPrefersMatchingChore() {
        let pool = [
            entry("Make the bed"),
            entry("Help with dinner dishes"),
        ]
        // Morning hour: the bed chore wins.
        let morning = ChoreTradeSession.selectNextOffer(
            pool: pool, declined: [], history: [], now: Self.now, hour: 9
        )
        XCTAssertEqual(morning?.chore, "Make the bed")
        // Evening hour: the dinner chore wins.
        let evening = ChoreTradeSession.selectNextOffer(
            pool: pool, declined: [], history: [], now: Self.now, hour: 19
        )
        XCTAssertEqual(evening?.chore, "Help with dinner dishes")
    }

    func testSelectionIsDeterministicForSameInputs() {
        let pool = neutralPool() + [entry("Walk the dog")]
        let first = ChoreTradeSession.selectNextOffer(
            pool: pool, declined: [], history: ["Walk the dog"], now: Self.now, hour: 14
        )
        let second = ChoreTradeSession.selectNextOffer(
            pool: pool, declined: [], history: ["Walk the dog"], now: Self.now, hour: 14
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - Demo seed

    func testDemoSeedIsParentConfirmWithFutureExpiryAndPositiveMinutes() {
        let pool = DemoChorePool.seeded()
        XCTAssertFalse(pool.isEmpty)
        for item in pool {
            XCTAssertEqual(item.verificationMode, .parentConfirm)
            XCTAssertGreaterThan(item.expiry, Date())
            XCTAssertGreaterThan(item.unlockMinutes, 0)
            XCTAssertFalse(item.chore.isEmpty)
        }
    }

    // MARK: - ShieldManager grant uses the chore's stated minutes

    private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
        private let lock = NSLock()
        private var uptime: TimeInterval = 1_000
        var nowUptime: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return uptime
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
                throw NSError(domain: "ChoreTradeTests", code: 1)
            }
            self.window = window
        }
        func clearUnlockWindow() throws {
            lock.lock()
            defer { lock.unlock() }
            window = nil
        }
    }

    private func makeManager() -> ShieldManager {
        let game = AppRef(id: "com.example.game")
        let games = AppCategoryRef(id: "games")
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [game],
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
                apps: [EnumeratedApp(app: game, category: games)],
                categories: [games]
            ),
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    func testGrantChoreTradeUnlockUsesStatedMinutes() {
        let manager = makeManager()
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertTrue(manager.grantChoreTradeUnlock(minutes: 10))
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 10 * 60, accuracy: 0.001)
    }

    func testGrantChoreTradeUnlockRejectsNonPositiveMinutes() {
        let manager = makeManager()
        XCTAssertFalse(manager.grantChoreTradeUnlock(minutes: 0))
        XCTAssertFalse(manager.grantChoreTradeUnlock(minutes: -5))
        XCTAssertFalse(manager.isUnlockActive)
    }

    func testEmptyEnumerationCannotGrantEvenWithUnblockablePolicy() {
        // Mechanism behind fix round 2 finding 1:
        // `grantUnlockForAllChallengeUnlockable` grants only over
        // `enumeration.apps`, so `.empty` always yields no apps and
        // returns false even when the policy lists unblockable apps.
        let game = AppRef(id: "com.example.game")
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: .empty,
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        XCTAssertFalse(manager.grantChoreTradeUnlock(minutes: 10))
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 0)
    }

    func testNoShieldUnlockExistsBetweenDoneAndParentConfirm() {
        let manager = makeManager()
        var session = ChoreTradeSession(pool: [entry("Wash the car", minutes: 10)])

        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertTrue(session.acceptOffer(at: Self.now))
        XCTAssertTrue(session.markDone(at: Self.now))

        // Done tapped, parent has not confirmed: no unlock anywhere.
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertFalse(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 0)

        // Parent confirms: the record's minutes drive the ShieldManager grant.
        let record = session.parentConfirm(at: Self.now)
        XCTAssertNotNil(record)
        XCTAssertTrue(manager.grantChoreTradeUnlock(
            minutes: record?.grantedUnlockMinutes ?? 0
        ))
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 10 * 60, accuracy: 0.001)
    }

    // MARK: - Demo shield fixture (fix round 2, finding 1)

    func testDemoPolicyKeepsDefaultDenyShape() {
        let policy = ChoreTradeDemoShield.demoPolicy(chorePool: DemoChorePool.seeded())
        XCTAssertEqual(policy.alwaysAllowed, Policy.defaultPolicy.alwaysAllowed)
        XCTAssertEqual(policy.unblockable, [ChoreTradeDemoShield.demoApp])
        XCTAssertTrue(policy.neverUnlockableOverrides.isEmpty)
        XCTAssertTrue(policy.isChallengeUnlockable(ChoreTradeDemoShield.demoApp))
        XCTAssertTrue(ChoreTradeDemoShield.demoEnumeration().apps.contains(
            EnumeratedApp(
                app: ChoreTradeDemoShield.demoApp,
                category: ChoreTradeDemoShield.demoCategory)))
    }

    func testDemoFixtureConfirmFlowGrantsSimulatedUnlock() {
        // The pair the demo UI confirms against: isolated demo policy
        // plus matching enumeration. The full offer -> accept -> done
        // -> confirm flow grants the promised minutes as a simulated
        // unlock.
        let pool = DemoChorePool.seeded()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(
            policyStore.apply(ChoreTradeDemoShield.demoPolicy(chorePool: pool)),
            .applied
        )
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ChoreTradeDemoShield.demoEnumeration(),
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        var session = ChoreTradeSession(pool: pool)
        let offer = session.makeOffer(at: Self.now)
        XCTAssertNotNil(offer)
        XCTAssertTrue(session.acceptOffer(at: Self.now))
        XCTAssertTrue(session.markDone(at: Self.now))
        XCTAssertFalse(manager.isUnlockActive)

        let record = session.parentConfirmWithGrant(at: Self.now) { record in
            manager.grantChoreTradeUnlock(minutes: record.grantedUnlockMinutes)
        }

        XCTAssertNotNil(record)
        XCTAssertTrue(session.hasGrantedUnlock)
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertEqual(
            manager.remainingUnlockTime,
            TimeInterval((offer?.entry.unlockMinutes ?? 0) * 60),
            accuracy: 0.001
        )
    }

    func testSyncedPolicyEnumerationGrantsWhenUnblockablePresent() {
        let game = AppRef(id: "com.example.game")
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ChoreTradeDemoShield.enumeration(
                for: policyStore.currentPolicy),
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        XCTAssertTrue(manager.grantChoreTradeUnlock(minutes: 10))
        XCTAssertTrue(manager.isUnlockActive)
    }

    func testDefaultDenyStillGrantsNothing() {
        // The fixture work weakens nothing: the default policy keeps
        // its empty unblockable list and grants nothing through the
        // derived enumeration.
        XCTAssertTrue(Policy.defaultPolicy.unblockable.isEmpty)
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.currentPolicy, Policy.defaultPolicy)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ChoreTradeDemoShield.enumeration(
                for: policyStore.currentPolicy),
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        XCTAssertFalse(manager.grantChoreTradeUnlock(minutes: 10))
        XCTAssertFalse(manager.isUnlockActive)
    }

    // MARK: - Commit granted phase only on grant success (fix round 2, finding 2)

    private func makeManagerWithStore(_ store: any UnlockWindowStore) -> ShieldManager {
        let game = AppRef(id: "com.example.game")
        let games = AppCategoryRef(id: "games")
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [game],
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
                apps: [EnumeratedApp(app: game, category: games)],
                categories: [games]
            ),
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: store
        )
    }

    func testFailedGrantLeavesConfirmationRetryable() {
        let store = FlakyUnlockStore()
        store.failSaves = true
        let manager = makeManagerWithStore(store)
        var session = ChoreTradeSession(pool: [entry("Wash the car", minutes: 10)])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertTrue(session.acceptOffer(at: Self.now))
        XCTAssertTrue(session.markDone(at: Self.now))

        let failed = session.parentConfirmWithGrant(at: Self.now) { record in
            manager.grantChoreTradeUnlock(minutes: record.grantedUnlockMinutes)
        }

        // Failed grant: no granted phase (so no "Unlock granted" UI,
        // which renders only from .granted), no unlock.
        XCTAssertNil(failed)
        guard case .doneAwaitingConfirm = session.phase else {
            return XCTFail(
                "failed grant must not commit .granted, got \(session.phase)")
        }
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertFalse(manager.isUnlockActive)

        // Retryable: once persistence works, confirming again grants.
        store.failSaves = false
        let record = session.parentConfirmWithGrant(at: Self.now) { record in
            manager.grantChoreTradeUnlock(minutes: record.grantedUnlockMinutes)
        }
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.grantedUnlockMinutes, 10)
        XCTAssertTrue(session.hasGrantedUnlock)
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertEqual(manager.remainingUnlockTime, 10 * 60, accuracy: 0.001)
    }

    func testSuccessfulGrantCommitsGrantedPhaseAsBefore() {
        let store = FlakyUnlockStore()
        store.failSaves = false
        let manager = makeManagerWithStore(store)
        var session = ChoreTradeSession(pool: [entry("Wash the car", minutes: 10)])
        XCTAssertNotNil(session.makeOffer(at: Self.now))
        XCTAssertTrue(session.acceptOffer(at: Self.now))
        XCTAssertTrue(session.markDone(at: Self.now))

        let record = session.parentConfirmWithGrant(at: Self.now) { record in
            manager.grantChoreTradeUnlock(minutes: record.grantedUnlockMinutes)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.grantedUnlockMinutes, 10)
        XCTAssertTrue(session.hasGrantedUnlock)
        XCTAssertTrue(manager.isUnlockActive)
        // Still one grant per trade: a second confirm returns nil and
        // never re-runs the grant.
        var secondCalls = 0
        XCTAssertNil(session.parentConfirmWithGrant(at: Self.now) { _ in
            secondCalls += 1
            return true
        })
        XCTAssertEqual(secondCalls, 0)
    }

    func testParentConfirmWithGrantCallsGrantOnlyFromDoneAwaitingConfirm() {
        // The grant never runs from idle, offered, or accepted: the
        // strict order is unchanged.
        var calls = 0
        var idle = ChoreTradeSession(pool: neutralPool())
        XCTAssertNil(idle.parentConfirmWithGrant(at: Self.now) { _ in
            calls += 1
            return true
        })
        var offered = ChoreTradeSession(pool: neutralPool())
        XCTAssertNotNil(offered.makeOffer(at: Self.now))
        XCTAssertNil(offered.parentConfirmWithGrant(at: Self.now) { _ in
            calls += 1
            return true
        })
        var accepted = ChoreTradeSession(pool: neutralPool())
        XCTAssertNotNil(accepted.makeOffer(at: Self.now))
        XCTAssertTrue(accepted.acceptOffer(at: Self.now))
        XCTAssertNil(accepted.parentConfirmWithGrant(at: Self.now) { _ in
            calls += 1
            return true
        })
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(idle.hasGrantedUnlock)
        XCTAssertFalse(offered.hasGrantedUnlock)
        XCTAssertFalse(accepted.hasGrantedUnlock)
    }
}
