import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.3 fix round 6 — regression tests for the Copilot review finding
/// "Clarify submission failure when incomplete record cannot be saved"
/// (SetupFlow side; the view-model message mapping is covered by
/// `SetupFlowViewModelFixRound6Tests` in the child app).
///
/// `submitEnumeration(_:)` returned false for several distinct causes
/// (wrong step, not authorized, empty enumeration, AND the incomplete
/// persist throwing), so the UI blamed authorization even when storage
/// was the real problem. The result variant must distinguish a
/// persistence failure from missing prerequisites.
///
/// Pre-fix state (verified from code before the fix): no result variant
/// existed — every submit failure collapsed to `false`, and the view
/// model mapped every `false` to "Complete the authorization step
/// first.", which cannot resolve a storage failure.
final class SetupFlowFixRound6Tests: XCTestCase {
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
            throw NSError(domain: "SetupFlowFixRound6Tests", code: 1)
        }
        func clearIncompleteEnumeration() throws {
            try wrapped.clearIncompleteEnumeration()
        }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "com.example.game")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowFixRound6Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeSetup(
        enumerationStore: (any SetupEnumerationStore)? = nil,
        authorized: Bool = false
    ) -> (flow: SetupFlow, backend: SimulatedShieldBackend) {
        let store = PolicyStore(directory: directory)
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
            enumerationStore: enumerationStore ?? FileSetupEnumerationStore(directory: directory),
            authorized: authorized
        )
        return (flow, backend)
    }

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )
    }

    // MARK: - Persistence failure is distinguished from missing prerequisites

    func testSubmitEnumerationResultReportsPersistenceFailedOnStorageFailure() {
        let (flow, _) = makeSetup(
            enumerationStore: FailingIncompleteStore(directory: directory)
        )
        flow.recordAuthorization(granted: true)
        XCTAssertEqual(flow.currentStep, .enumeration)

        XCTAssertEqual(
            flow.submitEnumerationResult(sampleEnumeration()),
            .persistenceFailed
        )
        XCTAssertEqual(flow.currentStep, .enumeration)
        XCTAssertNil(flow.pendingEnumeration)
    }

    func testSubmitEnumerationBoolWrapperStillFailsOnStorageFailure() {
        let (flow, _) = makeSetup(
            enumerationStore: FailingIncompleteStore(directory: directory)
        )
        flow.recordAuthorization(granted: true)

        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertEqual(flow.currentStep, .enumeration)
        XCTAssertNil(flow.pendingEnumeration)
    }

    func testSubmitEnumerationResultReportsNotReadyForMissingPrerequisites() {
        // Wrong step (still at authorization).
        let (wrongStep, _) = makeSetup(authorized: true)
        XCTAssertEqual(
            wrongStep.submitEnumerationResult(sampleEnumeration()),
            .notReady
        )

        // Not authorized.
        let (unauthorized, _) = makeSetup()
        unauthorized.recordAuthorization(granted: false)
        XCTAssertEqual(
            unauthorized.submitEnumerationResult(sampleEnumeration()),
            .notReady
        )

        // Empty enumeration on the right step with authorization.
        let (empty, _) = makeSetup()
        empty.recordAuthorization(granted: true)
        XCTAssertEqual(empty.currentStep, .enumeration)
        XCTAssertEqual(empty.submitEnumerationResult(.empty), .notReady)
        XCTAssertEqual(empty.currentStep, .enumeration)
    }

    func testSubmitEnumerationResultReportsSubmittedOnSuccess() {
        let (flow, _) = makeSetup()
        flow.recordAuthorization(granted: true)

        XCTAssertEqual(
            flow.submitEnumerationResult(sampleEnumeration()),
            .submitted
        )
        XCTAssertEqual(flow.currentStep, .selection)
    }
}
