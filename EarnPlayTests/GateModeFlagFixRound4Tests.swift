import Foundation
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #87 fix round 4 — Copilot re-review HIGH on PR #88 (4126244):
///
/// HIGH — Retained challenge grants under stale policy at finish:
/// `SimulatedShieldFlow.finishChallenge` evaluated effort with the flow's
/// RETAINED scorer (built at flow creation with the then-current floor)
/// and granted with the flow's RETAINED unlock duration, while
/// `ShieldManager.grantUnlock` rechecks only duration > 0 and
/// `isChallengeUnlockable` — never the effort floor. Round 3's cache
/// reconcile evicts cached flows on a policy version move, but it cannot
/// touch an already-returned flow object — so a stricter policy arriving
/// before a retained challenge finishes still granted under the old
/// floor and old duration. Fix: the installed-flow finish path
/// revalidates the CURRENT policy at the finish boundary (current
/// effort floor for scoring, current practice minutes for the grant and
/// the logged Decision); explicitly injected scorers/durations still
/// win (fix round 2 contract).
final class GateModeFlagFixRound4Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateModeFlagFixRound4Tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Applies a stricter policy through a sibling store (the sync
    /// shape) and propagates it without relaunching.
    @MainActor
    private func applyStricterPolicy(
        viewModel: SetupFlowViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let syncStore = PolicyStore(directory: directory)
        var updated = syncStore.currentPolicy
        updated.version += 1
        updated.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 4, minHintOrFollowUpInteractions: 1
        )
        updated.unlockDurations = UnlockDurations(practiceMinutes: 5, tradeMinutes: 15)
        XCTAssertEqual(syncStore.apply(updated), .applied, file: file, line: line)
        viewModel.refreshInstalledPolicyFromDisk()
    }

    // MARK: - Retained flow finishes under the current policy

    @MainActor
    func testRetainedFlowDeniesUnderStricterFloorAfterPolicyUpdate() async {
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .unblockable
        )
        // The retained challenge: built under the committed (default
        // 1+1 floor, 30-minute) policy, with effort recorded before
        // the stricter policy arrives.
        let retained = try? XCTUnwrap(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref)
        )
        XCTAssertEqual(retained?.unlockDuration ?? -1, 30 * 60, accuracy: 0.001)
        // 2 attempts + 5 hints scores 14 (2*2 + 5*2, no active
        // minutes), which always meets the 8...14 threshold — so the
        // decision isolates the floor. Passes the old 1+1 floor, fails
        // the new 4-attempt floor.
        retained?.submitAttempt(answer: "7")
        retained?.submitAttempt(answer: "14")
        for _ in 0..<5 { retained?.useHint() }

        applyStricterPolicy(viewModel: viewModel)

        // The cache evicted the stale entry — the held reference is
        // the already-returned object the reconcile cannot touch.
        XCTAssertFalse(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref) === retained,
            "a policy change must evict the cached flow; the held ref is the retained object"
        )

        // Finishing the RETAINED flow must enforce the CURRENT floor:
        // denied, shield stays up, no unlock opens.
        let score = retained?.finishChallenge()
        XCTAssertEqual(score?.score, 14)
        XCTAssertEqual(score?.floorMet, false)
        XCTAssertEqual(score?.decision, .denied)
        XCTAssertTrue(
            retained?.isShieldPresented ?? false,
            "a below-current-floor session must not open the installed unlock"
        )
        XCTAssertEqual(retained?.remainingUnlockTime ?? -1, 0)
        XCTAssertEqual(retained?.challengeDecisionText, SimulatedShieldFlow.unlockDeniedText)
        XCTAssertTrue(
            retained?.lastDecision?.reasoning.contains("need at least 4") ?? false,
            "the persisted Decision must name the current floor, not the retained one"
        )
    }

    @MainActor
    func testRetainedFlowGrantsWithNewDurationAfterPolicyUpdate() async {
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .unblockable
        )
        // The retained challenge, built under the 30-minute policy.
        let retained = try? XCTUnwrap(
            viewModel.installedShieldFlow(for: game.ref, category: game.category.ref)
        )
        XCTAssertEqual(retained?.unlockDuration ?? -1, 30 * 60, accuracy: 0.001)

        applyStricterPolicy(viewModel: viewModel)

        // Effort passing the CURRENT floor too: 5 attempts (10 pts) +
        // 3 hints (6 pts) = 16 clears any 8...14 threshold draw, with
        // 5 >= 4 attempts and 3 >= 1 hint interactions.
        for _ in 0..<5 { retained?.submitAttempt(answer: "fresh try") }
        for _ in 0..<3 { retained?.useHint() }
        let score = retained?.finishChallenge()
        XCTAssertEqual(score?.decision, .granted)
        XCTAssertFalse(retained?.isShieldPresented ?? true)
        XCTAssertEqual(
            retained?.challengeDecisionText,
            SimulatedShieldFlow.unlockGrantedText
        )
        // The grant uses the CURRENT 5-minute window — not the
        // retained 30-minute one.
        XCTAssertEqual(retained?.remainingUnlockTime ?? -1, 5 * 60, accuracy: 2)
        XCTAssertTrue(
            retained?.lastDecision?.outcome.contains("for 5 minutes") ?? false,
            "the persisted Decision must record the current window, not the retained one"
        )
    }
}
