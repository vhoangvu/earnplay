import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.1 fix round 3 — regression tests for the Oct 28 10:21 PM review.
///
/// - Finding 1 (High, carried forward — refuted, not rewritten): the
///   shared save-transaction lock genuinely spans the whole save, so
///   the A/B interleaving cannot lose an intent. Pinned directly
///   below; the racing-saves outcome stays pinned by
///   `testConcurrentSavesSerializeVersionAllocationAndJournaling`.
/// - Finding 2 (Medium): editor state after a failed save.
/// - Finding 3 (Medium): long-lived reader discovery.
/// - Finding 4 (Medium): cache consistency after failed writes.
final class PolicyEditorFixRound3Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PolicyEditorFixRound3Tests-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func fixturePolicy(version: Int) -> Policy {
        Policy.defaultPolicy.withVersion(version)
    }

    // MARK: - Finding 1 (High): shared transaction lock exclusion

    func testSaveTransactionExcludesOverlappingBodiesAcrossInstances() {
        // While one instance holds the save transaction, a second
        // instance over the same directory cannot enter it — so B can
        // neither stamp the same version as A nor overwrite/clear A's
        // journal mid-save, and A's durable policy always keeps either
        // its queued update or its recovery intent.
        let queueDir = directory.appendingPathComponent("pending-queue")
        let queueA = PolicyUpdateQueue(directory: queueDir)
        let queueB = PolicyUpdateQueue(directory: queueDir)
        let enteredA = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let startedB = DispatchSemaphore(value: 0)
        let enteredB = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? queueA.withSaveTransaction {
                enteredA.signal()
                releaseA.wait()
            }
        }
        XCTAssertEqual(
            enteredA.wait(timeout: .now() + 10), .success,
            "first instance must enter the transaction"
        )
        DispatchQueue.global().async {
            startedB.signal()
            _ = try? queueB.withSaveTransaction {
                enteredB.signal()
            }
        }
        XCTAssertEqual(
            startedB.wait(timeout: .now() + 10), .success,
            "second instance's attempt must start"
        )
        XCTAssertEqual(
            enteredB.wait(timeout: .now() + 0.5), .timedOut,
            "second instance must stay blocked while the transaction is held"
        )
        releaseA.signal()
        XCTAssertEqual(
            enteredB.wait(timeout: .now() + 10), .success,
            "second instance must enter once the transaction is released"
        )
    }

    // MARK: - Finding 2 (Medium): editor state after a failed save

    func testFailedSaveRefreshesCommittedVersionAndPendingCountKeepingDraft() throws {
        // Store at v9 with an empty queue at load; another instance
        // then durably enqueues v9, so a stale pending count is
        // observably wrong.
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let setupQueue = PolicyUpdateQueue(directory: queueDir)
        var state = PolicyEditorState()
        state.reload(adminStore: store, queue: setupQueue)
        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.baseVersion, 9)
        XCTAssertEqual(state.pendingCount, 0)
        try setupQueue.enqueue(fixturePolicy(version: 9))

        // Queue-file writes now fail (intent-file writes still work),
        // and a previous save left a success status behind.
        let failingQueue = PolicyUpdateQueue(
            directory: queueDir,
            dataWriter: { data, url in
                if url.lastPathComponent == PolicyUpdateQueue.queueFileName {
                    throw NSError(domain: "PolicyEditorFixRound3Tests", code: 1)
                }
                try data.write(to: url, options: [.atomic])
            }
        )
        state.statusText = "Saved version 9 — queued for sync (0 pending)."
        state.draft.movementSettings.maxReps = 50
        let draftBefore = state.draft

        // v10 persists to the store, then enqueueing throws.
        state.save(adminStore: store, queue: failingQueue)

        XCTAssertFalse(state.errorText.isEmpty, "failed save must report an error")
        XCTAssertEqual(
            state.baseVersion, 10,
            "committed version refreshes to durable v10, not stale v9"
        )
        XCTAssertEqual(
            state.pendingCount, 1,
            "pending count refreshes from the durable queue"
        )
        XCTAssertEqual(state.statusText, "", "previous success status clears on failure")
        XCTAssertEqual(state.draft, draftBefore, "draft is kept for the retry, not discarded")

        // The retry recovers v10 first, then lands v11 — which is why
        // the editor must show 10 (next: 11), never promise 10 again.
        let healedQueue = PolicyUpdateQueue(directory: queueDir)
        state.save(adminStore: store, queue: healedQueue)
        XCTAssertTrue(state.errorText.isEmpty)
        XCTAssertEqual(state.baseVersion, 11)
        XCTAssertEqual(state.pendingCount, 3)
        XCTAssertEqual(healedQueue.pendingUpdates().map(\.version), [9, 10, 11])
    }

    func testSaveSuccessUpdatesEditorState() throws {
        let storeDir = directory.appendingPathComponent("admin-store")
        let queueDir = directory.appendingPathComponent("pending-queue")
        let store = PolicyStore(directory: storeDir)
        XCTAssertEqual(store.apply(fixturePolicy(version: 9)), .applied)
        let queue = PolicyUpdateQueue(directory: queueDir)
        var state = PolicyEditorState()
        state.reload(adminStore: store, queue: queue)
        state.draft.movementSettings.maxReps = 50

        state.save(adminStore: store, queue: queue)

        XCTAssertTrue(state.errorText.isEmpty)
        XCTAssertEqual(state.baseVersion, 10)
        XCTAssertEqual(state.draft.version, 10)
        XCTAssertEqual(state.draft.movementSettings.maxReps, 50)
        XCTAssertEqual(state.pendingCount, 1)
        XCTAssertEqual(state.statusText, "Saved version 10 — queued for sync (1 pending).")
    }

    // MARK: - Finding 3 (Medium): long-lived reader discovery

    func testLongLivedReaderDiscoversAnotherInstancesSave() throws {
        let queueDir = directory.appendingPathComponent("pending-queue")
        let reader = PolicyUpdateQueue(directory: queueDir)
        XCTAssertTrue(reader.isEmpty)

        let writer = PolicyUpdateQueue(directory: queueDir)
        try writer.enqueue(fixturePolicy(version: 1))

        XCTAssertEqual(
            reader.pendingUpdates().map(\.version), [1],
            "long-lived reader must discover another instance's save"
        )
        XCTAssertFalse(reader.isEmpty)
        XCTAssertEqual(reader.latestPendingVersion, 1)

        try writer.removeDelivered(upToVersion: 1)
        XCTAssertTrue(
            reader.pendingUpdates().isEmpty,
            "reader must also discover removals"
        )
        XCTAssertTrue(reader.isEmpty)
    }

    // MARK: - Finding 4 (Medium): cache consistency after failed writes

    func testFailedEnqueueLeavesNoPhantomEntry() throws {
        let queueDir = directory.appendingPathComponent("pending-queue")
        let setup = PolicyUpdateQueue(directory: queueDir)
        try setup.enqueue(fixturePolicy(version: 1))
        let failing = PolicyUpdateQueue(directory: queueDir, dataWriter: { _, _ in
            throw NSError(domain: "PolicyEditorFixRound3Tests", code: 2)
        })
        XCTAssertThrowsError(try failing.enqueue(fixturePolicy(version: 2)))
        XCTAssertEqual(
            failing.pendingUpdates().map(\.version), [1],
            "failed enqueue must not report the unpersisted entry"
        )
        XCTAssertEqual(
            PolicyUpdateQueue(directory: queueDir).pendingUpdates().map(\.version), [1],
            "disk truth is unchanged by the failed enqueue"
        )
    }

    func testFailedRemoveDeliveredKeepsDiskEntriesVisible() throws {
        let queueDir = directory.appendingPathComponent("pending-queue")
        let setup = PolicyUpdateQueue(directory: queueDir)
        try setup.enqueue(fixturePolicy(version: 1))
        try setup.enqueue(fixturePolicy(version: 2))
        let failing = PolicyUpdateQueue(directory: queueDir, dataWriter: { _, _ in
            throw NSError(domain: "PolicyEditorFixRound3Tests", code: 3)
        })
        XCTAssertThrowsError(try failing.removeDelivered(upToVersion: 2))
        XCTAssertEqual(
            failing.pendingUpdates().map(\.version), [1, 2],
            "failed removal must not hide entries still on disk"
        )
        XCTAssertEqual(
            PolicyUpdateQueue(directory: queueDir).pendingUpdates().map(\.version), [1, 2],
            "disk truth is unchanged by the failed removal"
        )
    }
}
