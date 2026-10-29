import Foundation
import XCTest
import FamilyControls
import ManagedSettings
import EarnPlayCore
@testable import EarnPlay

/// T2.3 fix round 5 — view-model regression tests for Copilot review
/// findings 1 and 4.
///
/// - Finding 1: re-picking a deselected app must reuse its original AppRef
///   (durable token-to-ref registry), so an admin override for that ref
///   stays effective and `isChallengeUnlockable` cannot flip true.
/// - Finding 4: the completion summary must count only effectively
///   earnable apps (`isChallengeUnlockable`), not every `unblockable`
///   entry — override-covered apps show Blocked and count zero.
///
/// Picker tokens have no public initializer; fabricated through the Codable
/// `{"data":"<base64>"}` format like the fix-round-4 suite.
///
/// Pre-fix repro (observed via the child-app gate before the fix):
/// - finding 1: pick → deselect → re-pick minted a NEW AppRef, so a policy
///   with unblockable=[new] + overrides=[old] reported unlockable=true.
/// - finding 4: override scenario showed Blocked yet reported one earnable
///   app (`unblockableCount == 1`).
final class SetupFlowViewModelFixRound5Tests: XCTestCase {
    private var directory: URL!

    private final class MutableAuthorizationService: SetupAuthorizationService, @unchecked Sendable {
        var status: SetupAuthorizationState
        var grantsOnRequest: Bool

        init(status: SetupAuthorizationState = .notDetermined, grantsOnRequest: Bool = true) {
            self.status = status
            self.grantsOnRequest = grantsOnRequest
        }

        func currentStatus() -> SetupAuthorizationState { status }

        func requestAuthorization() async -> Bool {
            if grantsOnRequest { status = .approved }
            return status == .approved
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowViewModelFixRound5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func appToken(_ tag: String) throws -> ApplicationToken {
        let base64 = Data(tag.utf8).base64EncodedString()
        return try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data("{\"data\":\"\(base64)\"}".utf8)
        )
    }

    @MainActor
    private func makeViewModel(
        authService: MutableAuthorizationService,
        authorized: Bool = false
    ) -> (viewModel: SetupFlowViewModel, store: PolicyStore, backend: NonEnforcingShieldBackend) {
        let store = PolicyStore(directory: directory)
        let backend = NonEnforcingShieldBackend()
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
        let viewModel = SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: authService,
            tokenStore: SetupTokenStore(directory: directory)
        )
        return (viewModel, store, backend)
    }

    // MARK: - Finding 1: stable app references across reselection

    func testReselectedAppKeepsStableRefAndOverride() async throws {
        let token = try appToken("finding-1-stable-app")
        let other = try appToken("finding-1-stable-other")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, _, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            XCTAssertEqual(viewModel.step, .enumeration)

            // Pick the app: mints its policy identity.
            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)
            XCTAssertEqual(viewModel.pickedApps.count, 1)
            guard let original = viewModel.pickedApps.first(where: { $0.token == token }) else {
                XCTFail("picked app missing after first pick")
                return
            }
            let originalRef = original.ref

            // An admin override for the original ref.
            var policy = Policy.defaultPolicy.withVersion(1)
            policy.unblockable = [originalRef]
            policy.neverUnlockableOverrides = [originalRef]
            XCTAssertFalse(policy.isChallengeUnlockable(originalRef))

            // Deselect (re-pick with the token removed prunes the current
            // selection) then re-pick the same token.
            viewModel.restartEnumeration()
            XCTAssertEqual(viewModel.step, .enumeration)
            viewModel.selection.applicationTokens = [other]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)

            viewModel.restartEnumeration()
            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)
            guard let reselected = viewModel.pickedApps.first(where: { $0.token == token }) else {
                XCTFail("picked app missing after re-pick")
                return
            }

            // Same AppRef: re-picking can never change policy identity or
            // orphan the retained override.
            XCTAssertEqual(reselected.ref, originalRef)

            // The override is still effective for the re-picked ref: even
            // selecting Earn (unblockable) cannot make it unlockable.
            var earned = Policy.defaultPolicy.withVersion(1)
            earned.unblockable = [reselected.ref]
            earned.neverUnlockableOverrides = [originalRef]
            XCTAssertFalse(earned.isChallengeUnlockable(reselected.ref))
        }
    }

    func testReselectedAppAfterEmptyDeselectKeepsStableRef() async throws {
        let token = try appToken("finding-1-empty-deselect")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, _, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()
            guard let original = viewModel.pickedApps.first(where: { $0.token == token }) else {
                XCTFail("picked app missing after first pick")
                return
            }
            let originalRef = original.ref

            // Deselect to empty (rebuild prunes the selection even though
            // the empty submit itself is refused) then re-pick.
            viewModel.restartEnumeration()
            viewModel.selection.applicationTokens = []
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .enumeration)

            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)
            guard let reselected = viewModel.pickedApps.first(where: { $0.token == token }) else {
                XCTFail("picked app missing after re-pick")
                return
            }
            XCTAssertEqual(reselected.ref, originalRef)
        }
    }

    // MARK: - Finding 4: count only effectively earnable apps

    func testSummaryCountsOnlyEffectivelyEarnableApps() async throws {
        let earnToken = try appToken("finding-4-earn")
        let otherToken = try appToken("finding-4-other")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            viewModel.selection.applicationTokens = [earnToken, otherToken]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.pickedApps.count, 2)
            var earnID = ""
            for app in viewModel.pickedApps where app.token == earnToken {
                earnID = app.id
            }
            XCTAssertFalse(earnID.isEmpty)
            let earnRef = AppRef(id: earnID)

            // A preserved admin override covers the Earn app.
            let seeded = Policy(
                version: 1,
                alwaysAllowed: [.phone, .messages, .earnPlaySelf],
                unblockable: [],
                neverUnlockableOverrides: [earnRef],
                unlockDurations: .default,
                effortFloorSettings: .default,
                tradeCaps: .default,
                chorePool: [],
                movementSettings: .default
            )
            XCTAssertEqual(store.apply(seeded), .applied)

            for app in viewModel.pickedApps {
                viewModel.choices[app.id] = (app.token == earnToken) ? .unblockable : .blocked
            }
            viewModel.continueFromSelection()
            viewModel.finishSetup()
            XCTAssertEqual(viewModel.step, .complete)

            // The override-covered app shows Blocked …
            XCTAssertEqual(viewModel.choices[earnID], .blocked)
            // … AND the summary reports zero earnable apps.
            XCTAssertEqual(viewModel.summary?.unblockableCount, 0)
        }
    }
}
