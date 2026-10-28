import XCTest
import EarnPlayCore

/// T2.1 — PolicyStore exercised from the child app target (simulator gate).
///
/// Mirrors the acceptance checks of the package suite against the real
/// store: round-trip across a relaunch-equivalent reload, the
/// admin-newer-wins version rule, and the corrupt-file fallback. The full
/// per-element CRUD matrix lives in EarnPlayCoreTests.
final class PolicyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PolicyStoreAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func samplePolicy(version: Int) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf],
            unblockable: [AppRef(id: "com.example.game")],
            neverUnlockableOverrides: [AppRef(id: "com.example.browser")],
            unlockDurations: UnlockDurations(practiceMinutes: 15, tradeMinutes: 15),
            effortFloorSettings: EffortFloorSettings(
                minGenuineAttempts: 1, minHintOrFollowUpInteractions: 1
            ),
            tradeCaps: TradeCaps(
                maxTradesPerSession: 1, weeklyMaxMovementTrades: 3, weeklyMaxChoreTrades: 2
            ),
            chorePool: [
                ChorePoolEntry(
                    chore: "Tidy the bedroom",
                    unlockMinutes: 10,
                    expiry: Date(timeIntervalSince1970: 1_800_000_000),
                    weeklyCap: 2,
                    verificationMode: .parentConfirm
                )
            ],
            movementSettings: MovementSettings(
                allowedActivities: [.jumpingJacks],
                maxReps: 20,
                tradeUnlockDurationMinutes: 15
            )
        )
    }

    func testPolicySurvivesRelaunchEquivalentReload() {
        let policy = samplePolicy(version: 1)
        XCTAssertEqual(PolicyStore(directory: directory).apply(policy), .applied)
        XCTAssertEqual(PolicyStore(directory: directory).currentPolicy, policy)
    }

    func testNewerVersionWinsAndOlderIsRejected() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)
        XCTAssertEqual(store.apply(samplePolicy(version: 2)), .applied)
        XCTAssertEqual(
            store.apply(samplePolicy(version: 1)),
            .rejectedStaleVersion(currentVersion: 2)
        )
        XCTAssertEqual(store.storedVersion, 2)
        XCTAssertEqual(PolicyStore(directory: directory).storedVersion, 2)
    }

    func testTruncatedFileFallsBackToLastGoodPolicy() throws {
        let good = samplePolicy(version: 1)
        XCTAssertEqual(PolicyStore(directory: directory).apply(good), .applied)

        let primary = directory.appendingPathComponent(PolicyStore.policyFileName)
        let data = try Data(contentsOf: primary)
        try Data(data.prefix(4)).write(to: primary)

        XCTAssertEqual(PolicyStore(directory: directory).currentPolicy, good)
    }

    func testFreshInstallDefaultsToDefaultDeny() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.currentPolicy, .defaultPolicy)
        XCTAssertTrue(store.currentPolicy.unblockable.isEmpty)
    }
}
