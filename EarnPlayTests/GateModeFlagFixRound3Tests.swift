import Foundation
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #87 fix round 3 — Copilot re-review findings on PR #88 (903a717):
///
/// 1. MEDIUM — Child sync updates didn't reach the installed manager's
///    policy store: `ChildSyncController` holds its own default
///    `PolicyStore`, while `SetupFlowViewModel.makeDefault` shared one
///    store across its ShieldManager/SetupFlow/view model — so an
///    accepted sync update advanced the sync store's cache and the
///    disk, while the setup store kept serving its stale cache until
///    relaunch. Fix: production shares the sync controller's store
///    (`makeDefault(policyStore:)`), and `refreshInstalledPolicyFromDisk()`
///    propagates a cross-instance update (reload + manager refresh +
///    cached-flow reconcile + summary/UI refresh) without a relaunch.
/// 2. MEDIUM — Cached app flows retained outdated policy settings:
///    `installedShieldFlows` is keyed by app id, a cache hit returned
///    the flow untouched, and selection only ticked it — so floor and
///    unlock duration changes never reached an already-cached flow.
///    (The blocked-gate-before-cache-lookup from round 2 already
///    handles blocking changes.) Fix: lookups reconcile the cache
///    against the installed policy version, rebuilding flows whose
///    settings went stale; an untouched policy keeps its cache hits.
final class GateModeFlagFixRound3Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateModeFlagFixRound3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    @MainActor
    private func makeViewModel(
        authService: any SetupAuthorizationService,
        backend: any ShieldBackend,
        authorized: Bool = false
    ) -> SetupFlowViewModel {
        let store = PolicyStore(directory: directory)
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
        return SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: authService,
            tokenStore: SetupTokenStore(directory: directory)
        )
    }

    /// Completes a forced-mode setup over isolated stores with the given
    /// simulated picks, returning the completed view model + backend.
    @MainActor
    private func completeForcedSetup(
        appIDs: Set<String> = Set(SimulatedSetupCatalog.apps.map(\.id)),
        categoryIDs: Set<String> = [SimulatedSetupCatalog.games.id],
        choice: SetupFlowViewModel.AppChoice = .unblockable,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> (viewModel: SetupFlowViewModel, backend: SimulatedShieldBackend) {
        let backend = SimulatedShieldBackend()
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: backend
        )
        XCTAssertEqual(viewModel.step, .authorization, file: file, line: line)
        await viewModel.requestAuthorization()
        XCTAssertEqual(viewModel.step, .enumeration, file: file, line: line)
        viewModel.simulatedAppIDs = appIDs
        viewModel.simulatedCategoryIDs = categoryIDs
        viewModel.continueFromEnumeration()
        XCTAssertNil(viewModel.progressError, file: file, line: line)
        XCTAssertEqual(viewModel.step, .selection, file: file, line: line)
        viewModel.setAllChoices(choice)
        viewModel.continueFromSelection()
        XCTAssertEqual(viewModel.step, .preventDeletingGuidance, file: file, line: line)
        viewModel.finishSetup()
        XCTAssertEqual(viewModel.step, .complete, file: file, line: line)
        XCTAssertNotNil(viewModel.summary, file: file, line: line)
        return (viewModel, backend)
    }

    // MARK: - Finding 1: cross-instance updates propagate without relaunch

    @MainActor
    func testCrossInstanceBlockingUpdateReachesGateWithoutRelaunch() async {
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .unblockable
        )
        XCTAssertFalse(viewModel.isInstalledShieldBlocked(game.ref))
        // Cache an installed flow under the committed policy.
        XCTAssertNotNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))
        let committedVersion = viewModel.summary?.policyVersion

        // A sync update accepted through a SECOND store instance over
        // the same directory (the sync controller's shape): the admin
        // blocks the app via a never-unlockable override.
        let syncStore = PolicyStore(directory: directory)
        var updated = syncStore.currentPolicy
        updated.version += 1
        updated.neverUnlockableOverrides = [game.ref]
        XCTAssertEqual(syncStore.apply(updated), .applied)

        // Sanity: propagation is explicit — the setup store still serves
        // its pre-update cache until refreshed.
        XCTAssertFalse(
            viewModel.isInstalledShieldBlocked(game.ref),
            "setup store must still be stale before propagation runs"
        )

        // Propagate without relaunching: the blocked gate, the
        // installed flows, the manager, and the summary all observe it.
        viewModel.refreshInstalledPolicyFromDisk()

        XCTAssertTrue(viewModel.isInstalledShieldBlocked(game.ref))
        XCTAssertNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))
        XCTAssertNil(viewModel.selectInstalledShieldApp(game.id))
        XCTAssertEqual(viewModel.summary?.policyVersion, (committedVersion ?? 0) + 1)
        XCTAssertFalse(
            viewModel.flow.installedShieldManager.grantUnlock(
                for: game.ref, category: game.category.ref, duration: 60
            ),
            "the installed manager must refuse grants under the reloaded policy"
        )
    }

    @MainActor
    func testMakeDefaultSharesInjectedPolicyStore() {
        // The production composition: sync updates applied to the
        // injected store are immediately visible to the view model
        // (same instance — no propagation step needed).
        let store = PolicyStore(directory: directory)
        let viewModel = SetupFlowViewModel.makeDefault(
            simulatedMode: true,
            policyStore: store
        )
        var policy = Policy.defaultPolicy
        policy.version = 1
        policy.neverUnlockableOverrides = [SimulatedSetupCatalog.apps[0].ref]
        XCTAssertEqual(store.apply(policy), .applied)
        XCTAssertTrue(viewModel.isInstalledShieldBlocked(SimulatedSetupCatalog.apps[0].ref))
    }

    // MARK: - Finding 2: cached flows refresh floor/duration on policy change

    @MainActor
    func testCachedFlowRefreshesFloorAndDurationOnPolicyChange() async {
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .unblockable
        )
        let first = try? XCTUnwrap(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref)
        )
        // Committed policy carries the defaults: 30 practice minutes.
        XCTAssertEqual(first?.unlockDuration ?? -1, 30 * 60, accuracy: 0.001)
        // An untouched policy keeps its cache hits.
        XCTAssertTrue(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref) === first,
            "no policy change must keep serving the cached flow"
        )

        // Policy change through a sibling store: a stronger floor and
        // a shorter unlock window.
        let syncStore = PolicyStore(directory: directory)
        var updated = syncStore.currentPolicy
        updated.version += 1
        updated.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 4, minHintOrFollowUpInteractions: 1
        )
        updated.unlockDurations = UnlockDurations(practiceMinutes: 5, tradeMinutes: 15)
        XCTAssertEqual(syncStore.apply(updated), .applied)
        viewModel.refreshInstalledPolicyFromDisk()

        // The cached flow is rebuilt under the new settings.
        let second = try? XCTUnwrap(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref)
        )
        XCTAssertFalse(second === first, "a policy change must evict the cached flow")
        XCTAssertEqual(second?.unlockDuration ?? -1, 5 * 60, accuracy: 0.001)
        XCTAssertEqual(second?.decisionDurationMinutes, 5)

        // ... and enforces the new floor: 2 attempts + 5 hints scores
        // 14 (2*2 + 5*2, no active minutes), which always meets the
        // 8...14 threshold — so the decision isolates the floor.
        second?.submitAttempt(answer: "7")
        second?.submitAttempt(answer: "14")
        for _ in 0..<5 { second?.useHint() }
        let score = second?.finishChallenge()
        XCTAssertEqual(score?.score, 14)
        XCTAssertEqual(score?.floorMet, false)
        XCTAssertEqual(score?.decision, .denied)

        // The selection path serves the same refreshed flow.
        XCTAssertTrue(viewModel.selectInstalledShieldApp(game.id) === second)
    }
}
