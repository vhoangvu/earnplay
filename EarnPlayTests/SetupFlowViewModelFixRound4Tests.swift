import Foundation
import XCTest
import FamilyControls
import ManagedSettings
import EarnPlayCore
@testable import EarnPlay

/// T2.3 fix round 4 — view-model regression tests for Copilot review
/// findings 1 and 5.
///
/// - Finding 1: abandoning setup from the picker step must first submit
///   the staged picker selection, so the picked apps end up shielded via
///   the restrictive abandonment path instead of abandoned unshielded.
/// - Finding 5: the completion summary must restore each picked app's
///   choice from the effective policy (alwaysAllowed → Allowed, else
///   challenge-unlockable → Earn, else Blocked), so a relaunch shows the
///   saved choices instead of Blocked-for-all.
///
/// Picker tokens have no public initializer, but `Token<T>` is Codable as
/// `{"data":"<base64>"}` (probed on the simulator; the format must stay
/// stable across OS upgrades since apps persist tokens). The helpers below
/// fabricate distinct tokens through that format; fabrication failure is a
/// loud test failure, never a skip.
///
/// Pre-fix repro (observed via the child-app gate before the fix):
/// - finding 1: pick apps, tap Start over before Continue → backend
///   `.none` (picked apps unshielded); same after Re-pick apps.
/// - finding 5: complete with Allowed + Earn + blocked apps, relaunch →
///   `choices` empty (every app renders Blocked); a preserved
///   never-unlockable override keeps showing Earn on a fresh completion.
final class SetupFlowViewModelFixRound4Tests: XCTestCase {
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

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowViewModelFixRound4Tests-\(UUID().uuidString)", isDirectory: true)
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

    private func categoryToken(_ tag: String) throws -> ActivityCategoryToken {
        let base64 = Data(tag.utf8).base64EncodedString()
        return try JSONDecoder().decode(
            ActivityCategoryToken.self,
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

    // MARK: - Finding 1: abandoning from the picker submits the selection

    func testAbandonBeforeContinueShieldsPickedApps() async throws {
        let first = try appToken("finding-1-app-1")
        let second = try appToken("finding-1-app-2")
        let category = try categoryToken("finding-1-category")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store, backend) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            XCTAssertEqual(viewModel.step, .enumeration)

            // Pick apps, then tap Start over WITHOUT tapping Continue.
            viewModel.selection.applicationTokens = [first, second]
            viewModel.selection.categoryTokens = [category]
            viewModel.abandonSetup()

            XCTAssertEqual(viewModel.step, .authorization)
            XCTAssertEqual(store.storedVersion, 0)
            XCTAssertFalse(viewModel.flow.isComplete)
            XCTAssertFalse(viewModel.flow.claimsProtection)

            // The picked apps end up shielded via the restrictive
            // abandonment path (default-deny), not abandoned unshielded.
            let pickedRefs = Set(viewModel.pickedApps.map(\.ref))
            XCTAssertEqual(pickedRefs.count, 2)
            XCTAssertEqual(
                backend.currentShieldConfiguration.shieldedApplications,
                pickedRefs
            )
            XCTAssertEqual(
                backend.currentShieldConfiguration.shieldedCategories,
                Set(viewModel.pickedCategories.map(\.ref))
            )
            XCTAssertEqual(viewModel.pickedCategories.count, 1)
            // The token mapping is saved, so the relaunch renders labels.
            XCTAssertNotNil(SetupTokenStore(directory: self.directory).loadMapping())
        }
    }

    func testRepickThenAbandonShieldsPickedApps() async throws {
        let first = try appToken("finding-1-repick-app")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store, backend) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            viewModel.selection.applicationTokens = [first]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)

            // Re-pick returns to the picker with the staged enumeration
            // cleared; Start over from there must behave the same.
            viewModel.restartEnumeration()
            XCTAssertEqual(viewModel.step, .enumeration)
            viewModel.abandonSetup()

            XCTAssertEqual(viewModel.step, .authorization)
            XCTAssertEqual(store.storedVersion, 0)
            XCTAssertFalse(viewModel.flow.isComplete)
            let pickedRefs = Set(viewModel.pickedApps.map(\.ref))
            XCTAssertEqual(pickedRefs.count, 1)
            XCTAssertEqual(
                backend.currentShieldConfiguration.shieldedApplications,
                pickedRefs
            )
        }
    }

    // MARK: - Finding 5: completion summary restores choices from policy

    func testCompletionSummaryRestoresChoicesFromEffectivePolicy() async throws {
        let allowedToken = try appToken("finding-5-allowed")
        let earnToken = try appToken("finding-5-earn")
        let blockedToken = try appToken("finding-5-blocked")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, _, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        let expected: [String: SetupFlowViewModel.AppChoice] = await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            viewModel.selection.applicationTokens = [allowedToken, earnToken, blockedToken]
            viewModel.continueFromEnumeration()
            XCTAssertEqual(viewModel.step, .selection)
            XCTAssertEqual(viewModel.pickedApps.count, 3)

            var expected: [String: SetupFlowViewModel.AppChoice] = [:]
            for app in viewModel.pickedApps {
                if app.token == allowedToken {
                    viewModel.choices[app.id] = .allowed
                    expected[app.id] = .allowed
                } else if app.token == earnToken {
                    viewModel.choices[app.id] = .unblockable
                    expected[app.id] = .unblockable
                } else {
                    viewModel.choices[app.id] = .blocked
                    expected[app.id] = .blocked
                }
            }
            viewModel.continueFromSelection()
            viewModel.finishSetup()
            XCTAssertEqual(viewModel.step, .complete)
            return expected
        }
        XCTAssertEqual(expected.count, 3)

        // Relaunch: the summary must show each app's saved choice — never
        // Blocked-for-all.
        let (relaunched, _, _) = await MainActor.run {
            self.makeViewModel(authService: auth, authorized: true)
        }
        await MainActor.run {
            XCTAssertEqual(relaunched.step, .complete)
            XCTAssertNotNil(relaunched.summary)
            XCTAssertEqual(relaunched.pickedApps.count, 3)
            for (id, choice) in expected {
                XCTAssertEqual(relaunched.choices[id], choice, "app \(id)")
            }
        }
    }

    func testNeverUnlockableOverrideDoesNotShowEarn() async throws {
        let earnToken = try appToken("finding-5-override-earn")
        let otherToken = try appToken("finding-5-override-other")
        let auth = MutableAuthorizationService(status: .approved)
        let (viewModel, store, _) = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        let earnID: String = await MainActor.run {
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

            // A preserved admin override covers the Earn app: it can never
            // be challenge-opened, so it must not show Earn.
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

            // Even on the fresh completion the summary matches the saved
            // policy: the override-covered app shows Blocked, not Earn.
            XCTAssertEqual(viewModel.choices[earnID], .blocked)
            return earnID
        }

        let (relaunched, _, _) = await MainActor.run {
            self.makeViewModel(authService: auth, authorized: true)
        }
        await MainActor.run {
            XCTAssertEqual(relaunched.step, .complete)
            XCTAssertEqual(relaunched.choices[earnID], .blocked)
        }
    }

    // MARK: - Choice derivation rule (token-free)

    func testChoiceDerivationFromEffectivePolicy() {
        let allowed = AppRef(id: "choice.allowed")
        let earn = AppRef(id: "choice.earn")
        let blocked = AppRef(id: "choice.blocked")
        let overridden = AppRef(id: "choice.overridden")
        let both = AppRef(id: "choice.both")
        let policy = Policy(
            version: 1,
            alwaysAllowed: [.phone, .messages, .earnPlaySelf, allowed, both],
            unblockable: [earn, overridden, both],
            neverUnlockableOverrides: [overridden],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )
        XCTAssertEqual(SetupFlowViewModel.choice(for: allowed, in: policy), .allowed)
        XCTAssertEqual(SetupFlowViewModel.choice(for: earn, in: policy), .unblockable)
        // Unlisted apps default to Blocked (fail closed).
        XCTAssertEqual(SetupFlowViewModel.choice(for: blocked, in: policy), .blocked)
        // A never-unlockable override never shows Earn, even when the app
        // is also listed as unblockable.
        XCTAssertEqual(SetupFlowViewModel.choice(for: overridden, in: policy), .blocked)
        // The allowlist takes precedence over the unblockable list,
        // matching submitSelections sanitization + ShieldManager.
        XCTAssertEqual(SetupFlowViewModel.choice(for: both, in: policy), .allowed)
    }
}
