import XCTest
@testable import EarnPlayCore

/// T2.1 — PolicyStore: versioned policy cache on the child device.
///
/// Every test exercises the real store against a real temporary directory
/// (no mocks, no in-memory substitute): persistence, per-element CRUD via
/// successive versions, the admin-newer-wins conflict rule, and the
/// corrupt-file fallback required by the T2.1 acceptance criteria.
final class PolicyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PolicyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Fixtures

    private func samplePolicy(version: Int) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf, AppRef(id: "com.example.flashlight")],
            unblockable: [AppRef(id: "com.example.game"), AppRef(id: "com.example.video")],
            neverUnlockableOverrides: [AppRef(id: "com.example.browser")],
            unlockDurations: UnlockDurations(practiceMinutes: 30, tradeMinutes: 15),
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
                ),
                ChorePoolEntry(
                    chore: "Water the plants",
                    unlockMinutes: 5,
                    expiry: Date(timeIntervalSince1970: 1_900_000_000),
                    weeklyCap: 3,
                    verificationMode: .photoAsync
                ),
            ],
            movementSettings: MovementSettings(
                allowedActivities: [.jumpingJacks, .runningInPlace],
                maxReps: 20,
                tradeUnlockDurationMinutes: 15
            )
        )
    }

    // MARK: - Default-deny before first sync

    func testEmptyStoreVendsDefaultDenyPolicy() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(store.currentPolicy, .defaultPolicy)
        // Default-deny (LLD new-install): only built-in defaults allowed.
        XCTAssertEqual(
            store.currentPolicy.alwaysAllowed, [.phone, .messages, .earnPlaySelf]
        )
        XCTAssertTrue(store.currentPolicy.unblockable.isEmpty)
        XCTAssertTrue(store.currentPolicy.chorePool.isEmpty)
    }

    // MARK: - Cache round-trip (save, relaunch-equivalent reload, identical)

    func testCacheRoundTripSurvivesRelaunchEquivalentReload() {
        let policy = samplePolicy(version: 1)
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(policy), .applied)

        // A fresh instance over the same directory is the relaunch equivalent.
        let relaunched = PolicyStore(directory: directory)
        XCTAssertEqual(relaunched.currentPolicy, policy)
        XCTAssertEqual(relaunched.storedVersion, 1)

        // Explicit reload on the original instance agrees too.
        XCTAssertEqual(store.reloadFromDisk(), policy)
    }

    func testEveryPolicyElementRoundTripsIdentically() {
        let policy = samplePolicy(version: 3)
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(policy), .applied)

        let readBack = PolicyStore(directory: directory).currentPolicy
        XCTAssertEqual(readBack.version, 3)
        XCTAssertEqual(readBack.alwaysAllowed, policy.alwaysAllowed)
        XCTAssertEqual(readBack.unblockable, policy.unblockable)
        XCTAssertEqual(readBack.neverUnlockableOverrides, policy.neverUnlockableOverrides)
        XCTAssertEqual(readBack.unlockDurations, policy.unlockDurations)
        XCTAssertEqual(readBack.effortFloorSettings, policy.effortFloorSettings)
        XCTAssertEqual(readBack.tradeCaps, policy.tradeCaps)
        XCTAssertEqual(readBack.chorePool, policy.chorePool)
        XCTAssertEqual(readBack.movementSettings, policy.movementSettings)
        XCTAssertEqual(readBack, policy)
    }

    func testFractionalSecondChoreExpiryRoundTripsExactly() {
        var policy = samplePolicy(version: 1)
        policy.chorePool[0].expiry = Date(timeIntervalSince1970: 1_800_000_000.125)
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(policy), .applied)
        let readBack = PolicyStore(directory: directory).currentPolicy
        XCTAssertEqual(readBack.chorePool[0].expiry.timeIntervalSince1970, 1_800_000_000.125)
        XCTAssertEqual(readBack, policy)
    }

    func testPersistenceFailureDoesNotAdvanceVersionAndAllowsRetry() {
        // Injected writer throws until the test clears the failure,
        // simulating a full disk that later frees space.
        var shouldFail = true
        let store = PolicyStore(directory: directory, dataWriter: { data, url in
            if shouldFail {
                throw NSError(domain: "PolicyStoreTests", code: 1)
            }
            try data.write(to: url, options: [.atomic])
        })
        let policy = samplePolicy(version: 1)
        XCTAssertEqual(store.apply(policy), .persistenceFailed(currentVersion: 0))
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(store.currentPolicy, .defaultPolicy)
        XCTAssertEqual(PolicyStore(directory: directory).currentPolicy, .defaultPolicy)

        // Retry of the same version succeeds once writing works: it must
        // not be rejected as stale.
        shouldFail = false
        XCTAssertEqual(store.apply(policy), .applied)
        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(PolicyStore(directory: directory).currentPolicy, policy)

        // A later failure likewise leaves the last persisted version cached.
        shouldFail = true
        XCTAssertEqual(
            store.apply(samplePolicy(version: 2)),
            .persistenceFailed(currentVersion: 1)
        )
        XCTAssertEqual(store.storedVersion, 1)
        shouldFail = false
        XCTAssertEqual(store.apply(samplePolicy(version: 2)), .applied)
        XCTAssertEqual(store.storedVersion, 2)
    }

    // MARK: - Per-element CRUD via successive versions

    func testAlwaysAllowedCRUD() {
        let store = PolicyStore(directory: directory)
        var v1 = samplePolicy(version: 1)
        XCTAssertEqual(store.apply(v1), .applied)
        XCTAssertTrue(store.currentPolicy.alwaysAllowed.contains(AppRef(id: "com.example.flashlight")))

        // Create + delete expressed as the next admin version.
        v1.alwaysAllowed.append(AppRef(id: "com.example.dictionary"))
        v1.alwaysAllowed.removeAll { $0.id == "com.example.flashlight" }
        let v2 = v1.withVersion(2)
        XCTAssertEqual(store.apply(v2), .applied)
        XCTAssertTrue(store.currentPolicy.alwaysAllowed.contains(AppRef(id: "com.example.dictionary")))
        XCTAssertFalse(store.currentPolicy.alwaysAllowed.contains(AppRef(id: "com.example.flashlight")))
    }

    func testUnblockableAndNeverUnlockableCRUD() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)
        XCTAssertEqual(store.currentPolicy.unblockable.count, 2)

        var next = store.currentPolicy
        next.unblockable.removeAll { $0.id == "com.example.video" }
        next.neverUnlockableOverrides.append(AppRef(id: "com.example.game"))
        XCTAssertEqual(store.apply(next.withVersion(2)), .applied)

        XCTAssertEqual(store.currentPolicy.unblockable, [AppRef(id: "com.example.game")])
        XCTAssertTrue(
            store.currentPolicy.neverUnlockableOverrides.contains(AppRef(id: "com.example.game"))
        )
    }

    func testUnlockDurationsAndCapsCRUD() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)
        XCTAssertEqual(store.currentPolicy.unlockDurations.practiceMinutes, 30)
        XCTAssertEqual(store.currentPolicy.unlockDurations.tradeMinutes, 15)
        XCTAssertEqual(store.currentPolicy.tradeCaps.weeklyMaxMovementTrades, 3)

        var next = store.currentPolicy
        next.unlockDurations = UnlockDurations(practiceMinutes: 45, tradeMinutes: 10)
        next.tradeCaps = TradeCaps(
            maxTradesPerSession: 2, weeklyMaxMovementTrades: 2, weeklyMaxChoreTrades: 4
        )
        next.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 2, minHintOrFollowUpInteractions: 1
        )
        XCTAssertEqual(store.apply(next.withVersion(2)), .applied)

        XCTAssertEqual(store.currentPolicy.unlockDurations.practiceMinutes, 45)
        XCTAssertEqual(store.currentPolicy.unlockDurations.tradeMinutes, 10)
        XCTAssertEqual(store.currentPolicy.tradeCaps.maxTradesPerSession, 2)
        XCTAssertEqual(store.currentPolicy.tradeCaps.weeklyMaxChoreTrades, 4)
        XCTAssertEqual(store.currentPolicy.effortFloorSettings.minGenuineAttempts, 2)
    }

    func testChorePoolCRUD() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)
        XCTAssertEqual(store.currentPolicy.chorePool.count, 2)
        XCTAssertEqual(store.currentPolicy.chorePool[0].verificationMode, .parentConfirm)
        XCTAssertEqual(store.currentPolicy.chorePool[1].verificationMode, .photoAsync)

        // Update one entry, delete the other, add a new one — as version 2.
        var next = store.currentPolicy
        next.chorePool[0].unlockMinutes = 20
        next.chorePool.removeAll { $0.chore == "Water the plants" }
        next.chorePool.append(
            ChorePoolEntry(
                chore: "Feed the cat",
                unlockMinutes: 8,
                expiry: Date(timeIntervalSince1970: 2_000_000_000),
                weeklyCap: 7,
                verificationMode: .parentConfirm
            )
        )
        XCTAssertEqual(store.apply(next.withVersion(2)), .applied)

        let pool = PolicyStore(directory: directory).currentPolicy.chorePool
        XCTAssertEqual(pool.count, 2)
        XCTAssertEqual(pool.first { $0.chore == "Tidy the bedroom" }?.unlockMinutes, 20)
        XCTAssertNil(pool.first { $0.chore == "Water the plants" })
        XCTAssertEqual(pool.first { $0.chore == "Feed the cat" }?.weeklyCap, 7)
    }

    func testMovementSettingsCRUD() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)

        var next = store.currentPolicy
        next.movementSettings = MovementSettings(
            allowedActivities: [.squats], maxReps: 10, tradeUnlockDurationMinutes: 12
        )
        XCTAssertEqual(store.apply(next.withVersion(2)), .applied)
        XCTAssertEqual(store.currentPolicy.movementSettings.allowedActivities, [.squats])
        XCTAssertEqual(store.currentPolicy.movementSettings.maxReps, 10)
        XCTAssertEqual(store.currentPolicy.movementSettings.tradeUnlockDurationMinutes, 12)
    }

    // MARK: - Version conflict: admin's newer version wins

    func testNewerVersionReplacesOlder() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)
        XCTAssertEqual(store.apply(samplePolicy(version: 2)), .applied)
        XCTAssertEqual(store.storedVersion, 2)
        XCTAssertEqual(PolicyStore(directory: directory).storedVersion, 2)
    }

    func testOlderVersionIsRejectedAndCacheUnchanged() {
        let store = PolicyStore(directory: directory)
        let newer = samplePolicy(version: 5)
        XCTAssertEqual(store.apply(newer), .applied)

        let stale = samplePolicy(version: 4)
        XCTAssertEqual(store.apply(stale), .rejectedStaleVersion(currentVersion: 5))
        XCTAssertEqual(store.currentPolicy, newer)
        // The rejection must not touch disk either.
        XCTAssertEqual(PolicyStore(directory: directory).currentPolicy, newer)
    }

    func testEqualVersionIsRejected() {
        // LLD 8.2: versions are monotonic; lower *or equal* is discarded.
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 2)), .applied)
        var sameVersionDifferentContent = samplePolicy(version: 2)
        sameVersionDifferentContent.unlockDurations = UnlockDurations(
            practiceMinutes: 99, tradeMinutes: 99
        )
        XCTAssertEqual(
            store.apply(sameVersionDifferentContent),
            .rejectedStaleVersion(currentVersion: 2)
        )
        XCTAssertEqual(store.currentPolicy.unlockDurations.practiceMinutes, 30)
    }

    func testVersionZeroPolicyCannotOverwriteDefault() {
        // The built-in default is version 0, so a version-0 update is equal
        // and must be discarded like any other non-newer version.
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(
            store.apply(samplePolicy(version: 0)),
            .rejectedStaleVersion(currentVersion: 0)
        )
        XCTAssertEqual(store.currentPolicy, .defaultPolicy)
    }

    // MARK: - Corrupt / partial file fallback (T2.1 acceptance)

    func testTruncatedPrimaryFileFallsBackToLastGoodPolicy() throws {
        let good = samplePolicy(version: 1)
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(good), .applied)

        // Inject a truncated (partial-write / corrupt) policy file.
        let primary = directory.appendingPathComponent(PolicyStore.policyFileName)
        let data = try Data(contentsOf: primary)
        try Data(data.prefix(data.count / 2)).write(to: primary)

        let relaunched = PolicyStore(directory: directory)
        XCTAssertEqual(relaunched.currentPolicy, good)
        XCTAssertEqual(relaunched.storedVersion, 1)
    }

    func testFullyCorruptStoreFallsBackToDefaultDenyWithoutCrashing() throws {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(samplePolicy(version: 1)), .applied)

        // Corrupt both the primary and the last-good backup.
        for name in [PolicyStore.policyFileName, PolicyStore.backupFileName] {
            try Data("not json".utf8).write(to: directory.appendingPathComponent(name))
        }

        let relaunched = PolicyStore(directory: directory)
        XCTAssertEqual(relaunched.currentPolicy, .defaultPolicy)
        // Safe default-deny: never "unlock everything" on corruption.
        XCTAssertEqual(
            relaunched.currentPolicy.alwaysAllowed, [.phone, .messages, .earnPlaySelf]
        )
        XCTAssertTrue(relaunched.currentPolicy.unblockable.isEmpty)
    }
}
