import Foundation
import XCTest
import EarnPlayCore

/// T3.2 — Chore trade exercised from the child app target (simulator
/// gate): the full state-machine flow plus the ShieldManager grant for
/// the chore's stated minutes, against a simulated shield backend.
///
/// Mirrors the package suite's explicit check: Done alone grants
/// nothing — the ShieldManager unlock appears only after parent
/// confirmation. Real shield enforcement (ManagedSettings, v1) is not
/// verified here.
final class ChoreTradeAppTests: XCTestCase {
    private var directory: URL!

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

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChoreTradeAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeManager() -> ShieldManager {
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
            backend: SimulatedShieldBackend(),
            clock: FakeMonotonicClock(),
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
    }

    private func pool() -> [ChorePoolEntry] {
        DemoChorePool.seeded()
    }

    func testFullFlowGrantsStatedMinutesOnlyAfterParentConfirm() {
        let manager = makeManager()
        var session = ChoreTradeSession(pool: pool())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let offer = session.makeOffer(at: now)
        XCTAssertNotNil(offer)
        XCTAssertTrue(session.acceptOffer(at: now))
        XCTAssertTrue(session.markDone(at: now))

        // Done tapped, parent has not confirmed: no unlock anywhere.
        XCTAssertFalse(session.hasGrantedUnlock)
        XCTAssertFalse(manager.isUnlockActive)

        let record = session.parentConfirm(at: now)
        XCTAssertNotNil(record)
        XCTAssertTrue(manager.grantChoreTradeUnlock(
            minutes: record?.grantedUnlockMinutes ?? 0
        ))
        XCTAssertTrue(manager.isUnlockActive)
        XCTAssertEqual(
            manager.remainingUnlockTime,
            TimeInterval(record!.grantedUnlockMinutes * 60),
            accuracy: 0.001
        )
    }

    func testDeclinedChoreIsNotReofferedInSession() {
        var session = ChoreTradeSession(pool: pool())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let first = session.makeOffer(at: now)?.entry.chore
        XCTAssertNotNil(first)
        XCTAssertTrue(session.declineOffer())

        let second = session.makeOffer(at: now)?.entry.chore
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
    }

    func testExpiredChoreIsNeverOffered() {
        var pool = pool()
        pool.append(ChorePoolEntry(
            chore: "Expired chore",
            unlockMinutes: 30,
            expiry: Date(timeIntervalSince1970: 1_600_000_000),
            weeklyCap: 3,
            verificationMode: .parentConfirm
        ))
        var session = ChoreTradeSession(pool: pool)
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        // Drain the session: decline everything offered. The expired
        // chore must never surface.
        var offered: [String] = []
        while let offer = session.makeOffer(at: now) {
            offered.append(offer.entry.chore)
            XCTAssertTrue(session.declineOffer())
        }
        XCTAssertFalse(offered.isEmpty)
        XCTAssertFalse(offered.contains("Expired chore"))
    }
}
