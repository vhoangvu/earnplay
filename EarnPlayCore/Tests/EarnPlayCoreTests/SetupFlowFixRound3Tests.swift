import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.3 fix round 3 — regression tests for Copilot review findings 3–6.
///
/// Each test pins the corrected SetupFlow contract. Pre-fix repro (all
/// failed before the fix; observed via `swift test --filter
/// SetupFlowFixRound3Tests`):
/// - finding 3: revoked auth at launch restored `.complete` with shields
///   applied (protection claimed without access).
/// - finding 4: completing setup over an existing policy wiped its
///   overrides, chore pool, and custom durations/caps/settings.
/// - finding 5: a failed policy write left the new enumeration on disk, so
///   relaunch restored the failed setup as complete.
/// - finding 6: abandoning after enumeration left picked apps unshielded
///   (`.none`), contradicting the default-deny acceptance criterion.
final class SetupFlowFixRound3Tests: XCTestCase {
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
    private static let newSocial = AppRef(id: "com.example.new-social")
    private static let overriddenApp = AppRef(id: "com.example.overridden")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowFixRound3Tests-\(UUID().uuidString)", isDirectory: true)
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

    private func runToGuidance(_ flow: SetupFlow, allowlist: Set<AppRef> = []) {
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: allowlist, unblockable: [Self.game]))
        XCTAssertEqual(flow.currentStep, .preventDeletingGuidance)
    }

    // MARK: - Finding 3: revoked authorization at launch restores no protection

    func testRevokedAuthorizationAtLaunchDoesNotRestoreActiveProtection() {
        let (flow, _, _, _) = makeSetup()
        runToGuidance(flow, allowlist: [Self.allowedApp])
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        // Relaunch equivalent with Screen Time access revoked.
        let (relaunched, store, manager, backend) = makeSetup(authorized: false)
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
    }

    // MARK: - Finding 4: completing setup preserves existing policy fields

    func testCompletingSetupPreservesExistingPolicyFields() {
        let customChore = ChorePoolEntry(
            chore: "Tidy desk",
            unlockMinutes: 10,
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            weeklyCap: 2,
            verificationMode: .parentConfirm
        )
        let existing = Policy(
            version: 1,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf],
            unblockable: [],
            neverUnlockableOverrides: [Self.overriddenApp],
            unlockDurations: UnlockDurations(practiceMinutes: 45, tradeMinutes: 20),
            effortFloorSettings: EffortFloorSettings(
                minGenuineAttempts: 3, minHintOrFollowUpInteractions: 2
            ),
            tradeCaps: TradeCaps(
                maxTradesPerSession: 2, weeklyMaxMovementTrades: 1, weeklyMaxChoreTrades: 4
            ),
            chorePool: [customChore],
            movementSettings: MovementSettings(
                allowedActivities: [.squats], maxReps: 10, tradeUnlockDurationMinutes: 5
            )
        )
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(existing), .applied)

        // A policy with no enumeration restores as an incomplete flow the
        // parent can complete; the commit must keep the existing fields.
        let (flow, _, _, _) = makeSetup(policyStore: store)
        XCTAssertEqual(flow.currentStep, .authorization)
        runToGuidance(flow, allowlist: [Self.allowedApp])
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        let committed = store.currentPolicy
        XCTAssertEqual(committed.version, 2)
        // Setup selections are applied.
        XCTAssertEqual(
            Set(committed.alwaysAllowed),
            [.phone, .messages, .earnPlaySelf, Self.allowedApp]
        )
        XCTAssertEqual(Set(committed.unblockable), [Self.game])
        // Everything else is preserved, not reset to defaults.
        XCTAssertEqual(committed.neverUnlockableOverrides, [Self.overriddenApp])
        XCTAssertEqual(committed.chorePool, [customChore])
        XCTAssertEqual(committed.unlockDurations, UnlockDurations(practiceMinutes: 45, tradeMinutes: 20))
        XCTAssertEqual(
            committed.effortFloorSettings,
            EffortFloorSettings(minGenuineAttempts: 3, minHintOrFollowUpInteractions: 2)
        )
        XCTAssertEqual(
            committed.tradeCaps,
            TradeCaps(maxTradesPerSession: 2, weeklyMaxMovementTrades: 1, weeklyMaxChoreTrades: 4)
        )
        XCTAssertEqual(
            committed.movementSettings,
            MovementSettings(
                allowedActivities: [.squats], maxReps: 10, tradeUnlockDurationMinutes: 5
            )
        )
    }

    // MARK: - Finding 5: failed policy write leaves no committable pair

    func testPolicyWriteFailureLeavesNoOrphanEnumeration() {
        let failingStore = PolicyStore(
            directory: directory,
            dataWriter: { _, _ in
                throw NSError(domain: "SetupFlowFixRound3Tests", code: 1)
            }
        )
        let (flow, _, _, _) = makeSetup(policyStore: failingStore)
        runToGuidance(flow)
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .persistenceFailed)

        // No orphan completion enumeration may survive the failed commit.
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())

        // Relaunch restores as incomplete, never as the failed setup.
        let (relaunched, _, _, backend) = makeSetup(authorized: true)
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        // Fix round 4 (finding 2): the accepted enumeration was persisted
        // at submit time as the incomplete restrictive record, so the
        // relaunch restores the picked apps' shields while staying
        // incomplete — the old `.none` expectation encoded the finding-2
        // bug (accepted enumeration lost on termination).
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedCategories,
            [Self.games, Self.social]
        )
    }

    func testPolicyWriteFailureOverExistingPolicyDoesNotRestoreAsComplete() {
        // A stored policy with no enumeration (e.g. synced before setup
        // completed): the failed re-commit must not pair the old policy
        // with the new enumeration.
        let seed = PolicyStore(directory: directory)
        XCTAssertEqual(seed.apply(Policy.defaultPolicy.withVersion(1)), .applied)

        let failingStore = PolicyStore(
            directory: directory,
            dataWriter: { _, _ in
                throw NSError(domain: "SetupFlowFixRound3Tests", code: 2)
            }
        )
        XCTAssertEqual(failingStore.storedVersion, 1)
        let (flow, _, _, _) = makeSetup(policyStore: failingStore)
        XCTAssertEqual(flow.currentStep, .authorization)
        runToGuidance(flow)
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .persistenceFailed)

        let (relaunched, store, _, backend) = makeSetup(authorized: true)
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
    }

    // MARK: - Finding 6: abandoned setup shields picked apps (default-deny)

    func testAbandonAfterEnumerationShieldsPickedAppsAndStaysIncomplete() {
        let (flow, store, manager, backend) = makeSetup()
        runToGuidance(flow)
        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        // No full policy is committed by abandoning.
        XCTAssertEqual(store.storedVersion, 0)

        // Restrictive configuration: every picked app shielded, with the
        // category backstop — default-deny, never half-open.
        let config = backend.currentShieldConfiguration
        XCTAssertEqual(
            config.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
        XCTAssertEqual(config.shieldedCategories, [Self.games, Self.social])
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))

        // Relaunch: still incomplete, picked apps still shielded.
        let (relaunched, relaunchStore, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(relaunchStore.storedVersion, 0)
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
        XCTAssertTrue(relaunchManager.isShielded(app: Self.game, category: Self.games))
    }

    func testAbandonBeforeEnumerationWritesNothing() {
        let (flow, store, _, backend) = makeSetup()
        flow.recordAuthorization(granted: true)
        XCTAssertEqual(flow.currentStep, .enumeration)
        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
    }

    // MARK: - Finding 3: reauthorization restores the committed setup

    func testReauthorizationOfferedAndGrantRestoresCompletion() {
        let (flow, _, _, _) = makeSetup()
        runToGuidance(flow, allowlist: [Self.allowedApp])
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        let (relaunched, _, manager, backend) = makeSetup(authorized: false)
        XCTAssertTrue(relaunched.needsReauthorization)

        // A denial keeps waiting; it must not start a fresh run.
        relaunched.recordAuthorization(granted: false)
        XCTAssertTrue(relaunched.needsReauthorization)
        XCTAssertEqual(relaunched.currentStep, .authorization)

        // A re-grant restores completion without re-running the picker.
        relaunched.recordAuthorization(granted: true)
        XCTAssertEqual(relaunched.currentStep, .complete)
        XCTAssertTrue(relaunched.isComplete)
        XCTAssertTrue(relaunched.claimsProtection)
        XCTAssertFalse(relaunched.needsReauthorization)
        XCTAssertEqual(relaunched.pendingEnumeration, sampleEnumeration())
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.allowedApp, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp]
        )
    }

    func testAbandonDuringReauthorizationPreservesCommittedPair() {
        let (flow, _, _, _) = makeSetup()
        runToGuidance(flow, allowlist: [Self.allowedApp])
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        let (relaunched, _, _, backend) = makeSetup(authorized: false)
        XCTAssertTrue(relaunched.needsReauthorization)
        relaunched.abandon()

        // The pair and the reauthorization path survive abandoning.
        XCTAssertTrue(relaunched.needsReauthorization)
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)

        // The pair is intact on disk: an authorized relaunch completes, and
        // a re-grant on this instance does too.
        let (authorizedRelaunch, _, _, _) = makeSetup(authorized: true)
        XCTAssertEqual(authorizedRelaunch.currentStep, .complete)
        relaunched.recordAuthorization(granted: true)
        XCTAssertEqual(relaunched.currentStep, .complete)
    }

    // MARK: - Finding 5: failed commit restores the previous enumeration

    func testPolicyWriteFailureRestoresPreviousRestrictiveRecord() throws {
        // An abandoned run leaves a restrictive record on disk …
        let abandonedApps = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.socialApp, category: Self.social)],
            categories: [Self.social]
        )
        try FileSetupEnumerationStore(directory: directory).saveEnumeration(abandonedApps)

        // … then a setup run commits with a different enumeration and the
        // policy write fails: the failed write's enumeration must be rolled
        // back to the previous record, not left as an orphan and not
        // cleared (which would drop the default-deny record).
        let failingStore = PolicyStore(
            directory: directory,
            dataWriter: { _, _ in
                throw NSError(domain: "SetupFlowFixRound3Tests", code: 3)
            }
        )
        let (flow, _, _, backend) = makeSetup(policyStore: failingStore)
        XCTAssertEqual(flow.currentStep, .authorization)
        runToGuidance(flow)
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .persistenceFailed)

        XCTAssertEqual(
            FileSetupEnumerationStore(directory: directory).loadEnumeration(),
            abandonedApps
        )
        let (relaunched, _, manager, _) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        // The failed commit touched no shields: the pre-existing
        // restrictive record's shields (applied at init) are untouched.
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.socialApp]
        )
        // The restored restrictive record still shields its app on relaunch.
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
    }

    // MARK: - Finding 6: abandoning over a stored policy forges no pair

    func testAbandonOverStoredPolicyDoesNotForgeCompletedPair() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)

        let (flow, _, manager, backend) = makeSetup(policyStore: store)
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        // The current run shields the picked apps (default-deny) …
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.isEmpty)
        // … and the merged restrictions are persisted to the
        // distinctly-incomplete record despite the stored policy — which
        // cannot forge completion: no completion file exists.
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
        XCTAssertNotNil(
            FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration()
        )
        let (relaunched, relaunchStore, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(relaunchStore.storedVersion, 1)
        // Fix round 5 (finding 3): relaunch stays incomplete WITH the
        // picked apps still shielded — the old `.none` expectation
        // encoded the dropped-restrictions bug.
        XCTAssertTrue(relaunchManager.isShielded(app: Self.game, category: Self.games))
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp, Self.allowedApp]
        )
    }
}
