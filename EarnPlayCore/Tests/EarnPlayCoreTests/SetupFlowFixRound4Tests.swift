import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.3 fix round 4 — regression tests for Copilot review findings 2–4
/// (SetupFlow side; findings 1 and 5 are view-model side, covered in the
/// child-app target).
///
/// - Finding 2: an accepted enumeration must survive terminating the app
///   before setup finishes — relaunch restores the picked apps' shields
///   while staying incomplete, and the incomplete record must never
///   restore as a completed setup.
/// - Finding 3: the commit must version its update from the snapshot it
///   edits (`version += 1`), so a racing admin sync wins over a stale
///   commit instead of being overwritten by it.
/// - Finding 4: an aborted retry must never loosen prior restrictions —
///   abandoning merges previously protected apps/categories forward until
///   a successful commit replaces them.
///
/// Pre-fix repro (observed via `swift test --filter
/// SetupFlowFixRound4Tests` before the fix):
/// - finding 2: relaunch after accepting an enumeration restored `.none`
///   (picked apps unshielded); same with a synced policy present.
/// - finding 3: not deterministically triggerable through SetupFlow's API
///   (the race window between the two store reads is nanoseconds wide and
///   PolicyStore is final, so no seam can inject the interleaving). The
///   deterministic repro is the /tmp/f3probe arithmetic replay against the
///   real PolicyStore: old arithmetic ACCEPTS the stale snapshot as v3 and
///   destroys the synced v2's fields; new arithmetic is REJECTED as stale
///   and preserves v2. The maintained tests below pin the post-fix
///   invariant (a racing commit never tears the stored policy) plus the
///   sequential sync-preservation contract.
/// - finding 4: abandon(A) → retry(B) → abandon left A unshielded
///   (persisted-enumeration overwrite + applied-shield replacement).
final class SetupFlowFixRound4Tests: XCTestCase {
    private var directory: URL!

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
    private static let social = AppCategoryRef(id: "social")

    private static let game = AppRef(id: "com.example.game")
    private static let socialApp = AppRef(id: "com.example.social")
    private static let allowedApp = AppRef(id: "com.example.allowed")
    private static let retryApp = AppRef(id: "com.example.retry")
    private static let overriddenApp = AppRef(id: "com.example.overridden")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowFixRound4Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeSetup(
        policyStore: PolicyStore? = nil,
        authorized: Bool = false
    ) -> (flow: SetupFlow, store: PolicyStore, manager: ShieldManager, backend: SimulatedShieldBackend) {
        let store = policyStore ?? PolicyStore(directory: directory)
        let backend = SimulatedShieldBackend()
        let manager = ShieldManager(
            policyStore: store,
            enumeration: .empty,
            backend: backend,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        let flow = SetupFlow(
            policyStore: store,
            shieldManager: manager,
            enumerationStore: FileSetupEnumerationStore(directory: directory),
            authorized: authorized
        )
        return (flow, store, manager, backend)
    }

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.socialApp, category: Self.social),
                EnumeratedApp(app: Self.allowedApp, category: Self.games),
            ],
            categories: [Self.games, Self.social]
        )
    }

    // MARK: - Finding 2: accepted enumeration survives termination

    func testAcceptedEnumerationSurvivesTerminateBeforeFinish() {
        let (flow, _, _, _) = makeSetup()
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: [], unblockable: [Self.game]))
        XCTAssertEqual(flow.currentStep, .preventDeletingGuidance)

        // Terminate before finishing: drop everything; relaunch fresh.
        let (relaunched, store, manager, backend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(store.storedVersion, 0)
        // The completion record is untouched: no policy/enumeration pair
        // was forged, so this cannot restore as a completed setup.
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
        // But the accepted picks stay shielded restrictively.
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedCategories,
            [Self.games, Self.social]
        )
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testIncompleteRecordNeverRestoresAsComplete() {
        let (flow, _, _, _) = makeSetup()
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))

        // An admin sync lands before setup finishes.
        var synced = Policy.defaultPolicy.withVersion(1)
        synced.chorePool = [ChorePoolEntry(
            chore: "Synced chore", unlockMinutes: 10,
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            weeklyCap: 2, verificationMode: .parentConfirm
        )]
        XCTAssertEqual(PolicyStore(directory: directory).apply(synced), .applied)

        // Terminate + relaunch with Screen Time access still approved: the
        // incomplete record plus a stored policy must NOT read as a
        // completed setup.
        let (relaunched, store, manager, backend) = makeSetup(authorized: true)
        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertFalse(relaunched.needsReauthorization)
        // The accepted picks still stay shielded restrictively.
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }

    // MARK: - Finding 3: version the update from the edited snapshot

    func testCommitAfterSyncPreservesNewerPolicyFields() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)
        let (flow, _, manager, _) = makeSetup(policyStore: store)

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(
            allowlist: [Self.allowedApp], unblockable: [Self.game]
        ))

        // A newer policy syncs after the run's selections were staged but
        // before the commit: the commit must build on it, not overwrite
        // its fields with the older snapshot's.
        var newer = Policy.defaultPolicy.withVersion(2)
        newer.neverUnlockableOverrides = [Self.overriddenApp]
        newer.unlockDurations = UnlockDurations(practiceMinutes: 111, tradeMinutes: 22)
        newer.chorePool = [ChorePoolEntry(
            chore: "Synced chore", unlockMinutes: 10,
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            weeklyCap: 2, verificationMode: .parentConfirm
        )]
        XCTAssertEqual(store.apply(newer), .applied)

        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)
        let committed = store.currentPolicy
        XCTAssertEqual(committed.version, 3)
        XCTAssertEqual(committed.neverUnlockableOverrides, [Self.overriddenApp])
        XCTAssertEqual(
            committed.unlockDurations, UnlockDurations(practiceMinutes: 111, tradeMinutes: 22)
        )
        XCTAssertEqual(committed.chorePool, newer.chorePool)
        XCTAssertEqual(
            Set(committed.alwaysAllowed),
            [.phone, .messages, .earnPlaySelf, Self.allowedApp]
        )
        XCTAssertEqual(Set(committed.unblockable), [Self.game])
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testConcurrentSyncNeverTearsCommittedPolicy() {
        // Races a commit against an admin sync applying v2. Exactly one of
        // the two v2 candidates can land (PolicyStore accepts only a
        // strictly newer version); the commit then either wins outright,
        // builds on the synced v2 as v3, or is rejected as stale — but the
        // stored policy is never a torn mix (stale settings at a newer
        // version). Post-fix this holds on every iteration by
        // construction; pre-fix the torn outcome is possible (though the
        // nanosecond race window makes it unlikely per iteration — the
        // deterministic repro is the /tmp/f3probe arithmetic replay).
        for iteration in 0..<25 {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SetupFlowFixRound4Tests-race-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = PolicyStore(directory: dir)
            XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)
            let backend = SimulatedShieldBackend()
            let manager = ShieldManager(
                policyStore: store,
                enumeration: .empty,
                backend: backend,
                unlockStore: FileUnlockWindowStore(directory: dir)
            )
            let flow = SetupFlow(
                policyStore: store,
                shieldManager: manager,
                enumerationStore: FileSetupEnumerationStore(directory: dir)
            )
            flow.recordAuthorization(granted: true)
            XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
            XCTAssertTrue(flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))

            var friendV2 = Policy.defaultPolicy.withVersion(2)
            friendV2.chorePool = [ChorePoolEntry(
                chore: "friend-\(iteration)", unlockMinutes: 10,
                expiry: Date(timeIntervalSince1970: 1_800_000_000),
                weeklyCap: 2, verificationMode: .parentConfirm
            )]

            final class FinishBox: @unchecked Sendable {
                var result: SetupFinishResult?
            }
            let box = FinishBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                box.result = flow.acknowledgePreventDeletingGuidance()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                _ = store.apply(friendV2)
                group.leave()
            }
            group.wait()

            let result = box.result
            XCTAssertNotNil(result, "iteration \(iteration)")
            XCTAssertNotEqual(result, .notReady, "iteration \(iteration)")
            XCTAssertEqual(
                flow.currentStep == .complete, result == .finished,
                "iteration \(iteration)"
            )

            let stored = store.currentPolicy
            XCTAssertTrue(stored.version == 2 || stored.version == 3, "iteration \(iteration)")
            let hasFriendFields = stored.chorePool.contains(where: {
                $0.chore == "friend-\(iteration)"
            })
            let hasCommitSelections = Set(stored.unblockable) == [Self.game]
                && Set(stored.alwaysAllowed).contains(Self.allowedApp)
            if stored.version == 2 {
                XCTAssertTrue(
                    hasFriendFields != hasCommitSelections,
                    "iteration \(iteration): v2 must be exactly one of the friend sync or the commit"
                )
            } else {
                XCTAssertTrue(
                    hasFriendFields && hasCommitSelections,
                    "iteration \(iteration): v3 must carry the synced v2 fields plus the commit selections (torn write otherwise)"
                )
            }
        }
    }

    // MARK: - Finding 4: aborted retries preserve prior restrictions

    func testAbandonedRetryPreservesPriorRestrictions() {
        let enumerationA = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.socialApp, category: Self.social)],
            categories: [Self.social]
        )
        let enumerationB = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.retryApp, category: Self.games)],
            categories: [Self.games]
        )

        let (first, _, _, _) = makeSetup()
        first.recordAuthorization(granted: true)
        XCTAssertTrue(first.submitEnumeration(enumerationA))
        first.abandon()

        // Retry with only app B, then abandon again: A must stay
        // protected alongside B.
        let (retry, store, manager, backend) = makeSetup()
        XCTAssertEqual(retry.currentStep, .authorization)
        retry.recordAuthorization(granted: true)
        XCTAssertTrue(retry.submitEnumeration(enumerationB))
        retry.abandon()

        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertFalse(retry.isComplete)
        XCTAssertFalse(retry.claimsProtection)
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.retryApp, category: Self.games))
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.socialApp, Self.retryApp]
        )
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedCategories,
            [Self.social, Self.games]
        )

        // Relaunch: still incomplete, both apps still shielded.
        let (relaunched, relaunchStore, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(relaunchStore.storedVersion, 0)
        XCTAssertTrue(relaunchManager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertTrue(relaunchManager.isShielded(app: Self.retryApp, category: Self.games))
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.socialApp, Self.retryApp]
        )
    }

    func testSuccessfulCommitReplacesMergedRestrictions() {
        let enumerationA = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.socialApp, category: Self.social)],
            categories: [Self.social]
        )
        let enumerationB = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.retryApp, category: Self.games)],
            categories: [Self.games]
        )

        let (first, _, _, _) = makeSetup()
        first.recordAuthorization(granted: true)
        XCTAssertTrue(first.submitEnumeration(enumerationA))
        first.abandon()

        // A successful commit with B only replaces the merged
        // restrictions as intended — the merge ends at commit.
        let (retry, store, manager, backend) = makeSetup()
        retry.recordAuthorization(granted: true)
        XCTAssertTrue(retry.submitEnumeration(enumerationB))
        XCTAssertTrue(retry.submitSelections(allowlist: [], unblockable: []))
        XCTAssertEqual(retry.acknowledgePreventDeletingGuidance(), .finished)

        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.retryApp]
        )
        // T2.5: setup completed and its policy is active, so the
        // now-unclassified socialApp (dropped by the replacing commit)
        // is shielded by the default-deny fallback until a policy sync
        // classifies it — the backend set above stays [retryApp] only,
        // but the launch gate denies the unknown app.
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.retryApp, category: Self.games))

        let (relaunched, _, relaunchManager, relaunchBackend) = makeSetup(authorized: true)
        XCTAssertEqual(relaunched.currentStep, .complete)
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.retryApp]
        )
        // T2.5, as above: the relaunched completed setup's policy is
        // active, so unclassified socialApp stays shielded at the gate.
        XCTAssertTrue(relaunchManager.isShielded(app: Self.socialApp, category: Self.social))
    }

    // MARK: - Incomplete record store semantics

    func testIncompleteStoreRoundTripsAndMissesAsNil() throws {
        let store = FileSetupEnumerationStore(directory: directory)
        XCTAssertNil(store.loadIncompleteEnumeration())
        try store.saveIncompleteEnumeration(sampleEnumeration())
        XCTAssertEqual(store.loadIncompleteEnumeration(), sampleEnumeration())
        // The completion record is a separate file, untouched.
        XCTAssertNil(store.loadEnumeration())
        try store.clearIncompleteEnumeration()
        XCTAssertNil(store.loadIncompleteEnumeration())
        // Clearing a missing file counts as success.
        XCTAssertNoThrow(try store.clearIncompleteEnumeration())
    }

    func testCorruptIncompleteRecordLoadsAsNil() throws {
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(
                FileSetupEnumerationStore.incompleteEnumerationFileName
            )
        )
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration())
        // A corrupt incomplete record restores as incomplete with nothing
        // applied — never as completed protection.
        let (flow, _, _, backend) = makeSetup()
        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
    }

    func testCommitClearsIncompleteRecord() {
        let (flow, _, _, _) = makeSetup()
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertEqual(
            FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration(),
            sampleEnumeration()
        )
        XCTAssertTrue(flow.submitSelections(allowlist: [Self.allowedApp], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        // The staged enumeration replaces the merge: the completion file
        // holds exactly it, and the incomplete record is gone.
        XCTAssertEqual(
            FileSetupEnumerationStore(directory: directory).loadEnumeration(),
            sampleEnumeration()
        )
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration())
    }

    func testSubmitOverStoredPolicyPersistsNoIncompleteRecord() {
        // The fix-3 rule survives: persisting over a stored policy is
        // refused, so no incomplete record is written — while the staged
        // submission itself still succeeds in memory.
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)
        let (flow, _, _, _) = makeSetup(policyStore: store)
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration())
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
    }
}
