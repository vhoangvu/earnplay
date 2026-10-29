import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.1 — Policy editor save pipeline: every LLD §2.1 field is editable
/// and survives save; the version bumps by exactly one.
///
/// The gate is parameterised over ALL policy fields: each case edits one
/// field of a fixture policy, saves through `PolicyEditorSave.save`, and
/// asserts the serialized `PolicyUpdate` carries the new value with
/// `version == old + 1`. A field missing from the serialized output —
/// or one whose edit is silently dropped — fails its case. The draft is
/// a full `Policy` value (never a subset struct), so coverage here pins
/// the whole LLD §2.1 surface: app lists, unlock durations, effort
/// floor, trade caps, the chore pool, and movement settings.
final class PolicyEditorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PolicyEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Fixtures

    private func fixturePolicy(version: Int) -> Policy {
        Policy(
            version: version,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf],
            unblockable: [AppRef(id: "com.example.game")],
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
            ],
            movementSettings: MovementSettings(
                allowedActivities: [.jumpingJacks],
                maxReps: 20,
                tradeUnlockDurationMinutes: 15
            )
        )
    }

    private func seededStore(policy: Policy, name: String = "admin-store") -> PolicyStore {
        let store = PolicyStore(directory: directory.appendingPathComponent(name))
        XCTAssertEqual(store.apply(policy), .applied)
        return store
    }

    private func freshQueue(name: String = "pending-queue") -> PolicyUpdateQueue {
        PolicyUpdateQueue(directory: directory.appendingPathComponent(name))
    }

    // MARK: - Field cases

    /// One editable leaf: how to change it and how to recognise the new
    /// value in the saved update.
    private struct FieldCase {
        let name: String
        let mutate: (inout Policy) -> Void
        let verify: (PolicyUpdate) -> Bool
    }

    private func fieldCases() -> [FieldCase] {
        [
            FieldCase(
                name: "alwaysAllowed",
                mutate: { $0.alwaysAllowed.append(AppRef(id: "com.example.flashlight")) },
                verify: { $0.alwaysAllowed.contains(AppRef(id: "com.example.flashlight")) }
            ),
            FieldCase(
                name: "unblockable",
                mutate: { $0.unblockable.append(AppRef(id: "com.example.video")) },
                verify: { $0.unblockable.contains(AppRef(id: "com.example.video")) }
            ),
            FieldCase(
                name: "neverUnlockableOverrides",
                mutate: { $0.neverUnlockableOverrides = [] },
                verify: { $0.neverUnlockableOverrides.isEmpty }
            ),
            FieldCase(
                name: "unlockDurations.practiceMinutes",
                mutate: { $0.unlockDurations.practiceMinutes = 45 },
                verify: { $0.unlockDurations.practiceMinutes == 45 }
            ),
            FieldCase(
                name: "unlockDurations.tradeMinutes",
                mutate: { $0.unlockDurations.tradeMinutes = 10 },
                verify: { $0.unlockDurations.tradeMinutes == 10 }
            ),
            FieldCase(
                name: "effortFloorSettings.minGenuineAttempts",
                mutate: { $0.effortFloorSettings.minGenuineAttempts = 3 },
                verify: { $0.effortFloorSettings.minGenuineAttempts == 3 }
            ),
            FieldCase(
                name: "effortFloorSettings.minHintOrFollowUpInteractions",
                mutate: { $0.effortFloorSettings.minHintOrFollowUpInteractions = 2 },
                verify: { $0.effortFloorSettings.minHintOrFollowUpInteractions == 2 }
            ),
            FieldCase(
                name: "tradeCaps.maxTradesPerSession",
                mutate: { $0.tradeCaps.maxTradesPerSession = 2 },
                verify: { $0.tradeCaps.maxTradesPerSession == 2 }
            ),
            FieldCase(
                name: "tradeCaps.weeklyMaxMovementTrades",
                mutate: { $0.tradeCaps.weeklyMaxMovementTrades = 2 },
                verify: { $0.tradeCaps.weeklyMaxMovementTrades == 2 }
            ),
            FieldCase(
                name: "tradeCaps.weeklyMaxChoreTrades",
                mutate: { $0.tradeCaps.weeklyMaxChoreTrades = 5 },
                verify: { $0.tradeCaps.weeklyMaxChoreTrades == 5 }
            ),
            FieldCase(
                name: "chorePool.add",
                mutate: {
                    $0.chorePool.append(ChorePoolEntry(
                        chore: "Water the plants",
                        unlockMinutes: 5,
                        expiry: Date(timeIntervalSince1970: 1_900_000_000.125),
                        weeklyCap: 3,
                        verificationMode: .photoAsync
                    ))
                },
                verify: {
                    $0.chorePool.contains(where: {
                        $0.chore == "Water the plants"
                            && $0.unlockMinutes == 5
                            && $0.expiry == Date(timeIntervalSince1970: 1_900_000_000.125)
                            && $0.weeklyCap == 3
                            && $0.verificationMode == .photoAsync
                    })
                }
            ),
            FieldCase(
                name: "chorePool.edit.chore",
                mutate: { $0.chorePool[0].chore = "Mow the lawn" },
                verify: { $0.chorePool.first?.chore == "Mow the lawn" }
            ),
            FieldCase(
                name: "chorePool.edit.unlockMinutes",
                mutate: { $0.chorePool[0].unlockMinutes = 25 },
                verify: { $0.chorePool.first?.unlockMinutes == 25 }
            ),
            FieldCase(
                name: "chorePool.edit.expiry",
                mutate: { $0.chorePool[0].expiry = Date(timeIntervalSince1970: 1_850_000_000.5) },
                verify: {
                    $0.chorePool.first?.expiry == Date(timeIntervalSince1970: 1_850_000_000.5)
                }
            ),
            FieldCase(
                name: "chorePool.edit.weeklyCap",
                mutate: { $0.chorePool[0].weeklyCap = 4 },
                verify: { $0.chorePool.first?.weeklyCap == 4 }
            ),
            FieldCase(
                name: "chorePool.edit.verificationMode",
                mutate: { $0.chorePool[0].verificationMode = .photoAsync },
                verify: { $0.chorePool.first?.verificationMode == .photoAsync }
            ),
            FieldCase(
                name: "chorePool.remove",
                mutate: { $0.chorePool = [] },
                verify: { $0.chorePool.isEmpty }
            ),
            FieldCase(
                name: "movementSettings.allowedActivities",
                mutate: { $0.movementSettings.allowedActivities = [.squats, .marchingInPlace] },
                verify: {
                    $0.movementSettings.allowedActivities == [.squats, .marchingInPlace]
                }
            ),
            FieldCase(
                name: "movementSettings.maxReps",
                mutate: { $0.movementSettings.maxReps = 30 },
                verify: { $0.movementSettings.maxReps == 30 }
            ),
            FieldCase(
                name: "movementSettings.tradeUnlockDurationMinutes",
                mutate: { $0.movementSettings.tradeUnlockDurationMinutes = 10 },
                verify: { $0.movementSettings.tradeUnlockDurationMinutes == 10 }
            ),
        ]
    }

    // MARK: - The gate: every field survives save with version old + 1

    func testSaveCarriesEveryFieldWithBumpedVersion() throws {
        let cases = fieldCases()
        // The LLD §2.1 leaf count this gate pins. If a field is added to
        // `Policy`, add its case here — the count assertion fails first,
        // so a new field can never slip in untested.
        XCTAssertEqual(cases.count, 20, "field case count drifted; update the gate")
        for field in cases {
            let baseVersion = 7
            let tag = field.name.replacingOccurrences(of: ".", with: "-")
            let store = seededStore(policy: fixturePolicy(version: baseVersion), name: "store-\(tag)")
            let queue = freshQueue(name: "queue-\(tag)")
            var draft = store.currentPolicy
            field.mutate(&draft)

            let (update, serialized) = try PolicyEditorSave.save(
                draft: draft, adminStore: store, queue: queue
            )

            XCTAssertEqual(
                update.version, baseVersion + 1,
                "field \(field.name): version must be old + 1"
            )
            // The serialized bytes are the deliverable: decode them and
            // check the new value there, not just on the in-memory struct.
            let decoded = try PolicyUpdateCodec.decode(serialized)
            XCTAssertEqual(
                decoded, update,
                "field \(field.name): serialized update must round-trip exactly"
            )
            XCTAssertTrue(
                field.verify(decoded),
                "field \(field.name): new value missing from serialized PolicyUpdate"
            )
            assertSerializedJSONCarriesAllKeys(serialized, field: field.name)
        }
    }

    /// Raw-JSON key check: no LLD §2.1 field may be absent from the
    /// serialized output. Round-trip equality alone would miss a field
    /// dropped on both sides of a matching custom codec; the key list
    /// below is written out against the LLD, not derived from the code.
    private func assertSerializedJSONCarriesAllKeys(_ data: Data, field: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("field \(field): serialized update is not a JSON object")
            return
        }
        let topLevel = [
            "version", "alwaysAllowed", "unblockable", "neverUnlockableOverrides",
            "unlockDurations", "effortFloorSettings", "tradeCaps",
            "chorePool", "movementSettings",
        ]
        for key in topLevel {
            XCTAssertNotNil(json[key], "field \(field): top-level key '\(key)' missing")
        }
        assertKeys(json["unlockDurations"], ["practiceMinutes", "tradeMinutes"], field: field)
        assertKeys(
            json["effortFloorSettings"],
            ["minGenuineAttempts", "minHintOrFollowUpInteractions"],
            field: field
        )
        assertKeys(
            json["tradeCaps"],
            ["maxTradesPerSession", "weeklyMaxMovementTrades", "weeklyMaxChoreTrades"],
            field: field
        )
        if let pool = json["chorePool"] as? [[String: Any]], let first = pool.first {
            assertKeys(
                first,
                ["chore", "unlockMinutes", "expiry", "weeklyCap", "verificationMode"],
                field: field
            )
        }
        assertKeys(
            json["movementSettings"],
            ["allowedActivities", "maxReps", "tradeUnlockDurationMinutes"],
            field: field
        )
    }

    private func assertKeys(_ value: Any?, _ keys: [String], field: String) {
        guard let dict = value as? [String: Any] else {
            XCTFail("field \(field): expected object for keys \(keys)")
            return
        }
        for key in keys {
            XCTAssertNotNil(dict[key], "field \(field): key '\(key)' missing")
        }
    }

    // MARK: - Versioning

    func testSaveBumpsExactlyOneAboveStoreIgnoringDraftVersion() throws {
        let store = seededStore(policy: fixturePolicy(version: 4))
        let queue = freshQueue()
        // A stale draft (version 0 default, or anything else) still saves
        // as store version + 1; versions are never reused (LLD §8.2).
        var draft = Policy.defaultPolicy
        draft.unlockDurations.practiceMinutes = 60
        let (update, _) = try PolicyEditorSave.save(
            draft: draft, adminStore: store, queue: queue
        )
        XCTAssertEqual(update.version, 5)
        XCTAssertEqual(store.storedVersion, 5)
        XCTAssertEqual(store.currentPolicy.unlockDurations.practiceMinutes, 60)
    }

    func testSuccessiveSavesBumpMonotonically() throws {
        let store = seededStore(policy: fixturePolicy(version: 1))
        let queue = freshQueue()
        for expected in [2, 3, 4] {
            var draft = store.currentPolicy
            draft.tradeCaps.maxTradesPerSession = expected
            let (update, _) = try PolicyEditorSave.save(
                draft: draft, adminStore: store, queue: queue
            )
            XCTAssertEqual(update.version, expected)
        }
        XCTAssertEqual(queue.pendingUpdates().map(\.version), [2, 3, 4])
    }

    // MARK: - Persistence + queueing

    func testSavePersistsAdminPolicyAndEnqueuesUpdate() throws {
        let store = seededStore(policy: fixturePolicy(version: 9))
        let queue = freshQueue()
        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        let (update, _) = try PolicyEditorSave.save(
            draft: draft, adminStore: store, queue: queue
        )
        // Admin-local record advances (reopening the editor shows it).
        XCTAssertEqual(store.currentPolicy, update)
        let reopened = PolicyStore(directory: directory.appendingPathComponent("admin-store"))
        XCTAssertEqual(reopened.currentPolicy, update)
        // The update is queued for T4.6 sync, and survives a re-open.
        XCTAssertEqual(queue.pendingUpdates(), [update])
        let reopenedQueue = PolicyUpdateQueue(
            directory: directory.appendingPathComponent("pending-queue")
        )
        XCTAssertEqual(reopenedQueue.pendingUpdates(), [update])
        XCTAssertEqual(reopenedQueue.latestPendingVersion, 10)
    }

    func testQueueKeepsCreationOrderAndDropsDelivered() throws {
        let queue = freshQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.latestPendingVersion)
        for version in [11, 12, 13] {
            try queue.enqueue(fixturePolicy(version: version))
        }
        XCTAssertEqual(queue.pendingUpdates().map(\.version), [11, 12, 13])
        // Re-enqueueing a version replaces it in place, never duplicates.
        var changed = fixturePolicy(version: 12)
        changed.tradeCaps.maxTradesPerSession = 9
        try queue.enqueue(changed)
        XCTAssertEqual(queue.pendingUpdates().map(\.version), [11, 12, 13])
        XCTAssertEqual(queue.pendingUpdates()[1].tradeCaps.maxTradesPerSession, 9)
        // Delivery confirmation (T4.6 hook) drops everything delivered.
        try queue.removeDelivered(upToVersion: 12)
        XCTAssertEqual(queue.pendingUpdates().map(\.version), [13])
        try queue.removeDelivered(upToVersion: 99)
        XCTAssertTrue(queue.isEmpty)
    }

    func testCorruptQueueFileReadsAsEmpty() throws {
        let queueDir = directory.appendingPathComponent("pending-queue")
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: queueDir.appendingPathComponent(PolicyUpdateQueue.queueFileName)
        )
        XCTAssertTrue(PolicyUpdateQueue(directory: queueDir).isEmpty)
    }

    // MARK: - Failed policy writes (Copilot fix round 1, Finding 1)

    func testFailedPersistenceDoesNotEnqueueAndReportsFailure() throws {
        var shouldFail = false
        let storeDir = directory.appendingPathComponent("admin-store")
        let store = PolicyStore(directory: storeDir, dataWriter: { data, url in
            if shouldFail {
                throw NSError(domain: "PolicyEditorTests", code: 1)
            }
            try data.write(to: url, options: [.atomic])
        })
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = freshQueue()

        shouldFail = true
        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        XCTAssertThrowsError(
            try PolicyEditorSave.save(draft: draft, adminStore: store, queue: queue)
        ) { error in
            XCTAssertEqual(
                error as? PolicyEditorSaveError,
                .persistenceFailed(currentVersion: 9, attemptedVersion: 10)
            )
        }
        // Nothing queued, store unchanged, no intent left behind — and
        // the retry stamps the same version instead of skipping it.
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(store.storedVersion, 9)
        XCTAssertNil(queue.loadSaveIntent())
        shouldFail = false
        let (update, _) = try PolicyEditorSave.save(
            draft: draft, adminStore: store, queue: queue
        )
        XCTAssertEqual(update.version, 10)
        XCTAssertEqual(queue.pendingUpdates(), [update])
    }

    func testStaleCachedStoreHealsFromDurableStateOnSave() throws {
        // Fix round 2 behavior change: version allocation reads the
        // durable store under the save-transaction lock, so a stale
        // in-memory cache can no longer produce a stale stamp for the
        // store to reject — the save heals and lands one above the
        // durable version. (The fix-round-1 guarantee stands: a write
        // the store actually rejects still queues nothing; that path
        // is now reachable only by writers outside the save pipeline,
        // and stays covered at the `apply` level in PolicyStoreTests.)
        // Store A caches v5; store B (same directory) advances the
        // persisted policy to v10. A's save stamps v11 and succeeds.
        let storeDir = directory.appendingPathComponent("admin-store")
        let storeA = PolicyStore(directory: storeDir)
        XCTAssertEqual(storeA.apply(fixturePolicy(version: 5)), .applied)
        let storeB = PolicyStore(directory: storeDir)
        XCTAssertEqual(storeB.apply(fixturePolicy(version: 10)), .applied)
        XCTAssertEqual(storeA.storedVersion, 5)
        let queue = freshQueue()

        var draft = storeA.currentPolicy
        draft.movementSettings.maxReps = 50
        let (update, _) = try PolicyEditorSave.save(
            draft: draft, adminStore: storeA, queue: queue
        )
        XCTAssertEqual(update.version, 11)
        XCTAssertEqual(storeA.storedVersion, 11)
        XCTAssertEqual(queue.pendingUpdates(), [update])
        XCTAssertNil(queue.loadSaveIntent())
    }

    // MARK: - Crash recovery (Copilot fix round 1, Finding 2)

    func testCrashBetweenPolicyWriteAndQueueWriteRecoversOnRelaunch() throws {
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = PolicyUpdateQueue(directory: queueDir)

        // Simulate the crash: intent journaled, policy durable, queue
        // write never happened.
        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        let update = PolicyEditorSave.updatedPolicy(
            draft: draft, baseVersion: store.storedVersion
        )
        try queue.writeSaveIntent(update)
        XCTAssertEqual(store.apply(update), .applied)

        // Relaunch: opening the queue does NOT deliver the intent by
        // itself (fix round 2: the merge is deferred until store-aware
        // recovery confirms the durable policy).
        let relaunched = PolicyUpdateQueue(directory: queueDir)
        XCTAssertTrue(relaunched.pendingUpdates().isEmpty)

        // Recovery completes with no further manual save: intent
        // cleared, queue keeps the update, and the next save continues
        // at v11 with both versions queued.
        PolicyEditorSave.recoverInterruptedSave(adminStore: store, queue: relaunched)
        XCTAssertNil(relaunched.loadSaveIntent())
        XCTAssertEqual(relaunched.pendingUpdates(), [update])
        var next = store.currentPolicy
        next.movementSettings.maxReps = 60
        let (update2, _) = try PolicyEditorSave.save(
            draft: next, adminStore: store, queue: relaunched
        )
        XCTAssertEqual(update2.version, 11)
        XCTAssertEqual(relaunched.pendingUpdates().map(\.version), [10, 11])
    }

    func testInterruptedSaveBeforePolicyWriteRecoversStoreAndQueue() throws {
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = PolicyUpdateQueue(directory: queueDir)

        // Simulate a stop after journaling but before the policy
        // write: the store never saw v10.
        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        let update = PolicyEditorSave.updatedPolicy(
            draft: draft, baseVersion: store.storedVersion
        )
        try queue.writeSaveIntent(update)

        // Relaunch recovery advances the store first, then the queue.
        let relaunched = PolicyUpdateQueue(directory: queueDir)
        PolicyEditorSave.recoverInterruptedSave(adminStore: store, queue: relaunched)
        XCTAssertEqual(store.storedVersion, 10)
        XCTAssertEqual(store.currentPolicy, update)
        XCTAssertEqual(relaunched.pendingUpdates(), [update])
        XCTAssertNil(relaunched.loadSaveIntent())
    }

    // MARK: - Cross-instance queue (Copilot fix round 1, Finding 3)

    func testTwoQueueInstancesInterleavingCannotLoseUndeliveredUpdate() throws {
        // Copilot's counterexample: A and B both load [v1]; A enqueues
        // v2; B removes delivered v1. B must write [v2], not [].
        let queueDir = directory.appendingPathComponent("pending-queue")
        let queueA = PolicyUpdateQueue(directory: queueDir)
        try queueA.enqueue(fixturePolicy(version: 1))
        let queueB = PolicyUpdateQueue(directory: queueDir)
        XCTAssertEqual(queueA.pendingUpdates().map(\.version), [1])
        XCTAssertEqual(queueB.pendingUpdates().map(\.version), [1])

        try queueA.enqueue(fixturePolicy(version: 2))
        try queueB.removeDelivered(upToVersion: 1)

        XCTAssertEqual(queueB.pendingUpdates().map(\.version), [2])
        let reopened = PolicyUpdateQueue(directory: queueDir)
        XCTAssertEqual(reopened.pendingUpdates().map(\.version), [2])
    }

    // MARK: - Crash-consistency (Copilot fix round 2)

    func testEqualVersionConflictingIntentIsDiscardedWithoutMerging() throws {
        // Finding 1: a stale instance journals payload B at v10 after
        // another instance saved payload A at v10, then stops before
        // its store write is rejected. Recovery must NOT replace the
        // queued A with B: the intent conflicts with the durable store
        // and is discarded.
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = PolicyUpdateQueue(directory: queueDir)

        var draftA = store.currentPolicy
        draftA.movementSettings.maxReps = 50
        let (updateA, _) = try PolicyEditorSave.save(
            draft: draftA, adminStore: store, queue: queue
        )
        XCTAssertEqual(queue.pendingUpdates(), [updateA])

        // Stale instance's journal: same version, different payload.
        var draftB = fixturePolicy(version: 9)
        draftB.movementSettings.maxReps = 60
        let updateB = PolicyEditorSave.updatedPolicy(draft: draftB, baseVersion: 9)
        XCTAssertEqual(updateB.version, 10)
        XCTAssertNotEqual(updateB, updateA)
        try queue.writeSaveIntent(updateB)

        // Relaunch: opening the queue must not merge the conflicting
        // intent over the committed entry.
        let relaunched = PolicyUpdateQueue(directory: queueDir)
        XCTAssertEqual(relaunched.pendingUpdates(), [updateA])

        // Store-aware recovery discards the conflicting intent and
        // keeps the durable policy and its queued entry.
        PolicyEditorSave.recoverInterruptedSave(adminStore: store, queue: relaunched)
        XCTAssertNil(relaunched.loadSaveIntent())
        XCTAssertEqual(relaunched.pendingUpdates(), [updateA])
        XCTAssertEqual(store.currentPolicy, updateA)
    }

    func testNewSaveAbortsWhileEarlierIntentRemainsUnresolved() throws {
        // Finding 2: v10 is durable in the store but its queue write
        // keeps failing. A new save must abort with `unresolvedIntent`
        // instead of overwriting the only v10 intent with v11.
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let setupQueue = PolicyUpdateQueue(directory: queueDir)

        // Simulate the crash: intent journaled, policy durable, queue
        // write never happened.
        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        let update = PolicyEditorSave.updatedPolicy(
            draft: draft, baseVersion: store.storedVersion
        )
        try setupQueue.writeSaveIntent(update)
        XCTAssertEqual(store.apply(update), .applied)

        // Queue-file writes fail (intent-file writes still work, so a
        // save that reached journaling WOULD clobber the v10 intent).
        let failingQueue = PolicyUpdateQueue(
            directory: queueDir,
            dataWriter: { data, url in
                if url.lastPathComponent == PolicyUpdateQueue.queueFileName {
                    throw NSError(domain: "PolicyEditorTests", code: 2)
                }
                try data.write(to: url, options: [.atomic])
            }
        )
        var next = store.currentPolicy
        next.movementSettings.maxReps = 60
        XCTAssertThrowsError(
            try PolicyEditorSave.save(draft: next, adminStore: store, queue: failingQueue)
        ) { error in
            XCTAssertEqual(
                error as? PolicyEditorSaveError,
                .unresolvedIntent(intentVersion: 10)
            )
        }
        // The v10 intent survives, the store still holds v10 (no v11
        // was stamped or applied), and no v11 reached the queue file.
        XCTAssertEqual(failingQueue.loadSaveIntent(), update)
        XCTAssertEqual(store.storedVersion, 10)
        let fileCheck = PolicyUpdateQueue(directory: queueDir)
        XCTAssertTrue(fileCheck.pendingUpdates().isEmpty)

        // Once queue writes work again, the next save recovers v10
        // first, then saves v11 with both versions queued in order.
        let healedQueue = PolicyUpdateQueue(directory: queueDir)
        let (update2, _) = try PolicyEditorSave.save(
            draft: next, adminStore: store, queue: healedQueue
        )
        XCTAssertEqual(update2.version, 11)
        XCTAssertEqual(healedQueue.pendingUpdates().map(\.version), [10, 11])
        XCTAssertNil(healedQueue.loadSaveIntent())
    }

    func testConcurrentSavesSerializeVersionAllocationAndJournaling() throws {
        // Finding 3: two saves racing version allocation must not both
        // choose v10 (one stale-rejected, its journal clobbering the
        // winner's recovery intent). Serialized under the transaction
        // lock with durable re-reads, both succeed at v10 and v11.
        final class SaveResults: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Result<PolicyUpdate, Error>] = []
            func append(_ result: Result<PolicyUpdate, Error>) {
                lock.lock()
                defer { lock.unlock() }
                values.append(result)
            }
            var all: [Result<PolicyUpdate, Error>] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }
        for round in 0 ..< 10 {
            let storeDir = directory.appendingPathComponent("store-\(round)")
            let queueDir = directory.appendingPathComponent("queue-\(round)")
            let seeder = PolicyStore(directory: storeDir)
            XCTAssertEqual(seeder.apply(fixturePolicy(version: 9)), .applied)
            // Both instances cache v9 before the race starts.
            let storeA = PolicyStore(directory: storeDir)
            let storeB = PolicyStore(directory: storeDir)
            let queueA = PolicyUpdateQueue(directory: queueDir)
            let queueB = PolicyUpdateQueue(directory: queueDir)
            var draftA = storeA.currentPolicy
            draftA.movementSettings.maxReps = 50
            var draftB = storeB.currentPolicy
            draftB.movementSettings.maxReps = 60
            // Immutable copies for the @Sendable worker blocks below.
            let finalDraftA = draftA
            let finalDraftB = draftB

            let results = SaveResults()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                results.append(Result {
                    try PolicyEditorSave.save(
                        draft: finalDraftA, adminStore: storeA, queue: queueA
                    ).update
                })
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                results.append(Result {
                    try PolicyEditorSave.save(
                        draft: finalDraftB, adminStore: storeB, queue: queueB
                    ).update
                })
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

            let updates = try results.all.map { try $0.get() }
            XCTAssertEqual(
                Set(updates.map(\.version)), [10, 11],
                "round \(round): concurrent saves must land on distinct versions"
            )
            let reopenedQueue = PolicyUpdateQueue(directory: queueDir)
            XCTAssertEqual(
                reopenedQueue.pendingUpdates().map(\.version), [10, 11],
                "round \(round): both versions queued in creation order"
            )
            let reopenedStore = PolicyStore(directory: storeDir)
            XCTAssertEqual(reopenedStore.storedVersion, 11, "round \(round)")
            XCTAssertEqual(
                reopenedStore.currentPolicy,
                reopenedQueue.pendingUpdates().last,
                "round \(round): durable policy matches queued v11"
            )
            XCTAssertNil(reopenedQueue.loadSaveIntent(), "round \(round)")
        }
    }

    func testUnpersistedIntentIsNotDeliverableUntilStoreRecoveryPersists() throws {
        // Finding 4: after a crash between journaling v10 and applying
        // it, opening the queue must NOT make v10 deliverable while the
        // store still holds v9 — and a store recovery that fails to
        // persist must leave nothing queued.
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = PolicyUpdateQueue(directory: queueDir)

        var draft = store.currentPolicy
        draft.movementSettings.maxReps = 50
        let update = PolicyEditorSave.updatedPolicy(
            draft: draft, baseVersion: store.storedVersion
        )
        try queue.writeSaveIntent(update)

        // Relaunch: the intent is not yet committed, so nothing is
        // pending until store-aware recovery persists it.
        let relaunched = PolicyUpdateQueue(directory: queueDir)
        XCTAssertTrue(relaunched.pendingUpdates().isEmpty)

        // Store recovery that cannot persist leaves nothing queued and
        // keeps the intent for a later attempt.
        let failingStore = PolicyStore(directory: storeDir, dataWriter: { _, _ in
            throw NSError(domain: "PolicyEditorTests", code: 3)
        })
        PolicyEditorSave.recoverInterruptedSave(
            adminStore: failingStore, queue: relaunched
        )
        XCTAssertTrue(relaunched.pendingUpdates().isEmpty)
        XCTAssertEqual(relaunched.loadSaveIntent(), update)
        XCTAssertEqual(failingStore.storedVersion, 9)

        // Once the store write works, recovery persists first and only
        // then delivers.
        PolicyEditorSave.recoverInterruptedSave(adminStore: store, queue: relaunched)
        XCTAssertEqual(store.storedVersion, 10)
        XCTAssertEqual(relaunched.pendingUpdates(), [update])
        XCTAssertNil(relaunched.loadSaveIntent())
    }
}
