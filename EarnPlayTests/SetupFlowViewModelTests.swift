import Foundation
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// T2.3 fix round 3 — view-model regression tests for Copilot review
/// findings 2 (recheck authorization before committing setup) and 7 (keep
/// the completion summary visible until dismissed).
///
/// Pre-fix repro (observed via the child-app gate before the fix):
/// - finding 2: with authorization revoked at finish time, `finishSetup()`
///   still saved the policy and reported completion (it trusted the
///   authorization Boolean cached earlier in the flow).
/// - finding 7: `ContentView` showed the main screen as soon as
///   `step == .complete`, so the summary (including the
///   category-backstop-disabled warning) was never visible.
final class SetupFlowViewModelTests: XCTestCase {
    private var directory: URL!

    /// Mutable authorization double: the simulator has no Screen Time
    /// authorization, so tests flip approval directly instead.
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

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")
    private static let allowedApp = AppRef(id: "com.example.allowed")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    @MainActor
    private func makeViewModel(
        authService: MutableAuthorizationService
    ) -> (viewModel: SetupFlowViewModel, store: PolicyStore) {
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
            enumerationStore: FileSetupEnumerationStore(directory: directory)
        )
        let viewModel = SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: authService,
            tokenStore: SetupTokenStore(directory: directory)
        )
        return (viewModel, store)
    }

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.allowedApp, category: Self.games),
            ],
            categories: [Self.games]
        )
    }

    // MARK: - Finding 2: recheck authorization before committing setup

    func testFinishSetupWithRevokedAuthorizationSavesNothingAndReturnsToAuthorization() async {
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        // Drive the flow to the guidance step on the earlier grant …
        await MainActor.run {
            viewModel.flow.recordAuthorization(granted: true)
            XCTAssertTrue(viewModel.flow.submitEnumeration(self.sampleEnumeration()))
            XCTAssertTrue(viewModel.flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))
            // Read the flow directly: driving it bypasses the view model,
            // so the published step stays stale until the view model acts.
            XCTAssertEqual(viewModel.flow.currentStep, .preventDeletingGuidance)
        }
        // … then access is revoked while the user is in Settings.
        auth.status = .denied

        await MainActor.run {
            viewModel.finishSetup()

            XCTAssertEqual(store.storedVersion, 0)
            XCTAssertEqual(viewModel.step, .authorization)
            XCTAssertFalse(viewModel.flow.isComplete)
            XCTAssertNotNil(viewModel.authorizationError)
        }
    }

    func testFinishSetupWithCurrentAuthorizationCommits() async {
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.flow.recordAuthorization(granted: true)
            XCTAssertTrue(viewModel.flow.submitEnumeration(self.sampleEnumeration()))
            XCTAssertTrue(viewModel.flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))
            viewModel.finishSetup()

            XCTAssertEqual(store.storedVersion, 1)
            XCTAssertEqual(viewModel.step, .complete)
            XCTAssertNil(viewModel.authorizationError)
        }
    }

    // MARK: - Finding 7: completion summary visible until dismissed

    func testCompletionSummaryStaysVisibleUntilDismissed() async {
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            XCTAssertFalse(viewModel.summaryDismissed)
            viewModel.flow.recordAuthorization(granted: true)
            XCTAssertTrue(viewModel.flow.submitEnumeration(self.sampleEnumeration()))
            XCTAssertTrue(viewModel.flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))
            viewModel.finishSetup()

            // Completing setup shows the summary …
            XCTAssertEqual(viewModel.step, .complete)
            XCTAssertNotNil(viewModel.summary)
            XCTAssertEqual(viewModel.summary?.policyVersion, 1)
            XCTAssertFalse(viewModel.summaryDismissed)

            // … until the explicit Continue action.
            viewModel.dismissSummary()
            XCTAssertTrue(viewModel.summaryDismissed)
            XCTAssertEqual(viewModel.step, .complete)
            XCTAssertNotNil(viewModel.summary)
        }
    }

    func testCompletionSummaryReportsBackstopDisabledWarningCondition() async {
        // Real-device path: per-app categories are unknown (nil), so an
        // allowlisted app disables the category backstop and the summary
        // must carry the warning condition (backstopCount == 0) until
        // dismissed.
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        let unknownCategoryEnumeration = ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: nil),
                EnumeratedApp(app: Self.allowedApp, category: nil),
            ],
            categories: [Self.games]
        )
        await MainActor.run {
            viewModel.flow.recordAuthorization(granted: true)
            XCTAssertTrue(viewModel.flow.submitEnumeration(unknownCategoryEnumeration))
            XCTAssertTrue(viewModel.flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))
            viewModel.finishSetup()

            XCTAssertEqual(viewModel.step, .complete)
            XCTAssertEqual(viewModel.summary?.backstopCount, 0)
            XCTAssertEqual(viewModel.summary?.shieldedCount, 1)
            XCTAssertFalse(viewModel.summaryDismissed)
            viewModel.dismissSummary()
            XCTAssertTrue(viewModel.summaryDismissed)
        }
    }

    // MARK: - Finding 3 (view model): reauthorization path

    func testReauthorizationRestoresCompletionWithoutRepicking() async {
        let auth = MutableAuthorizationService(status: .approved)
        await MainActor.run {
            let (viewModel, _) = self.makeViewModel(authService: auth)
            viewModel.flow.recordAuthorization(granted: true)
            XCTAssertTrue(viewModel.flow.submitEnumeration(self.sampleEnumeration()))
            XCTAssertTrue(viewModel.flow.submitSelections(
                allowlist: [Self.allowedApp], unblockable: [Self.game]
            ))
            viewModel.finishSetup()
            XCTAssertEqual(viewModel.step, .complete)
        }

        // Relaunch with access revoked: the wizard returns to authorization
        // and offers reauthorization instead of restoring protection.
        let revokedAuth = MutableAuthorizationService(status: .denied)
        let (relaunched, _) = await MainActor.run {
            self.makeViewModel(authService: revokedAuth)
        }
        await MainActor.run {
            XCTAssertEqual(relaunched.step, .authorization)
            XCTAssertTrue(relaunched.needsReauthorization)
            XCTAssertNil(relaunched.summary)
        }

        // Re-granting restores completion without re-running the picker.
        revokedAuth.status = .approved
        await MainActor.run {
            relaunched.refreshAuthorizationStatus()
            XCTAssertEqual(relaunched.step, .complete)
            XCTAssertFalse(relaunched.needsReauthorization)
            XCTAssertNotNil(relaunched.summary)
            XCTAssertFalse(relaunched.summaryDismissed)
        }
    }
}
