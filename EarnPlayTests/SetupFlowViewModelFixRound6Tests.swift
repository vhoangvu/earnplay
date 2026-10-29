import Foundation
import XCTest
import FamilyControls
import ManagedSettings
import EarnPlayCore
@testable import EarnPlay

/// T2.3 fix round 6 — view-model regression test for the Copilot review
/// finding "Clarify submission failure when incomplete record cannot be
/// saved" (the SetupFlow result distinction is covered by
/// `SetupFlowFixRound6Tests` in EarnPlayCore).
///
/// `submitEnumeration()` returned false for several distinct causes, and
/// `continueFromEnumeration()` mapped every false to "Complete the
/// authorization step first." — so an already-authorized user hitting a
/// STORAGE failure was told to complete authorization, which cannot
/// resolve it. A persistence failure must surface a storage message
/// instead.
///
/// Picker tokens have no public initializer; fabricated through the Codable
/// `{"data":"<base64>"}` format like the fix-round-4/5 suites.
///
/// Pre-fix state (verified from code before the fix): with authorization
/// approved, on the enumeration step, with apps picked, a throwing
/// incomplete-record store produced "Setup is not ready for enumeration
/// yet. Complete the authorization step first."
final class SetupFlowViewModelFixRound6Tests: XCTestCase {
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

    /// Enumeration store double that fails incomplete-record writes.
    private final class FailingIncompleteStore: SetupEnumerationStore, @unchecked Sendable {
        private let wrapped: FileSetupEnumerationStore

        init(directory: URL) {
            self.wrapped = FileSetupEnumerationStore(directory: directory)
        }

        func loadEnumeration() -> ShieldEnumeration? { wrapped.loadEnumeration() }
        func saveEnumeration(_ enumeration: ShieldEnumeration) throws {
            try wrapped.saveEnumeration(enumeration)
        }
        func clearEnumeration() throws { try wrapped.clearEnumeration() }
        func loadIncompleteEnumeration() -> ShieldEnumeration? {
            wrapped.loadIncompleteEnumeration()
        }
        func saveIncompleteEnumeration(_ enumeration: ShieldEnumeration) throws {
            throw NSError(domain: "SetupFlowViewModelFixRound6Tests", code: 1)
        }
        func clearIncompleteEnumeration() throws {
            try wrapped.clearIncompleteEnumeration()
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowViewModelFixRound6Tests-\(UUID().uuidString)", isDirectory: true)
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
        enumerationStore: (any SetupEnumerationStore)? = nil
    ) -> SetupFlowViewModel {
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
            enumerationStore: enumerationStore ?? FileSetupEnumerationStore(directory: directory),
            authorized: false
        )
        return SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: authService,
            tokenStore: SetupTokenStore(directory: directory)
        )
    }

    // MARK: - Storage failure surfaces a storage message, not authorization-first

    func testStorageFailureWithAuthorizationApprovedMentionsStorage() async throws {
        let token = try appToken("finding-round6-storage")
        let auth = MutableAuthorizationService(status: .approved)
        let viewModel = await MainActor.run {
            self.makeViewModel(
                authService: auth,
                enumerationStore: FailingIncompleteStore(directory: self.directory)
            )
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            XCTAssertEqual(viewModel.step, .enumeration)

            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()

            XCTAssertEqual(viewModel.step, .enumeration)
            guard let error = viewModel.progressError else {
                XCTFail("expected a progress error on storage failure")
                return
            }
            XCTAssertTrue(
                error.localizedCaseInsensitiveContains("storage"),
                "storage failure must mention storage, got: \(error)"
            )
            XCTAssertFalse(
                error.localizedCaseInsensitiveContains("authorization"),
                "storage failure must not blame authorization, got: \(error)"
            )
        }
    }

    func testNotReadyStillShowsAuthorizationFirstMessage() async throws {
        let token = try appToken("finding-round6-notready")
        // Not approved: the flow never leaves the authorization step, so
        // the submit fails on prerequisites, not storage.
        let auth = MutableAuthorizationService(status: .notDetermined, grantsOnRequest: false)
        let viewModel = await MainActor.run {
            self.makeViewModel(authService: auth)
        }
        await MainActor.run {
            viewModel.refreshAuthorizationStatus()
            XCTAssertEqual(viewModel.step, .authorization)

            viewModel.selection.applicationTokens = [token]
            viewModel.continueFromEnumeration()

            XCTAssertEqual(viewModel.step, .authorization)
            guard let error = viewModel.progressError else {
                XCTFail("expected a progress error when not authorized")
                return
            }
            XCTAssertTrue(
                error.localizedCaseInsensitiveContains("authorization"),
                "prerequisite failure must still direct to authorization, got: \(error)"
            )
        }
    }
}
