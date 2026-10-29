import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.3 fix round 5 — regression tests for Copilot review findings 2–3
/// (SetupFlow side; findings 1 and 4 are view-model side).
///
/// - Finding 2: submitEnumeration must surface incomplete-record
///   persistence failures and NOT advance to selection until the
///   restrictive record is durable.
/// - Finding 3: abandon() must save the merged incomplete record
///   REGARDLESS of policy version; the incomplete file can never restore
///   as complete.
///
/// Pre-fix repro (observed via `swift test --filter
/// SetupFlowFixRound5Tests` before the fix):
/// - finding 2: failing enumeration store → submit returned true and step
///   advanced to .selection despite no durable record.
/// - finding 3: abandon over stored policy → relaunch restored `.none`
///   (newly picked apps lost) instead of retained restrictions.
final class SetupFlowFixRound5Tests: XCTestCase {
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
            throw NSError(domain: "SetupFlowFixRound5Tests", code: 1)
        }
        func clearIncompleteEnumeration() throws {
            try wrapped.clearIncompleteEnumeration()
        }
    }

    private static let games = AppCategoryRef(id: "games")
    private static let social = AppCategoryRef(id: "social")

    private static let game = AppRef(id: "com.example.game")
    private static let socialApp = AppRef(id: "com.example.social")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowFixRound5Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeSetup(
        policyStore: PolicyStore? = nil,
        enumerationStore: (any SetupEnumerationStore)? = nil,
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
            enumerationStore: enumerationStore ?? FileSetupEnumerationStore(directory: directory),
            authorized: authorized
        )
        return (flow, store, manager, backend)
    }

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.socialApp, category: Self.social),
            ],
            categories: [Self.games, Self.social]
        )
    }

    // MARK: - Finding 2: incomplete-record failure fails the submit

    func testSubmitEnumerationFailsWhenIncompletePersistFails() {
        let (flow, store, _, backend) = makeSetup(
            enumerationStore: FailingIncompleteStore(directory: directory)
        )
        flow.recordAuthorization(granted: true)
        XCTAssertEqual(flow.currentStep, .enumeration)

        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertEqual(flow.currentStep, .enumeration)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertNil(flow.pendingEnumeration)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)

        // Termination + relaunch claims no restored restrictions: neither
        // a policy nor a persisted enumeration exists.
        let (relaunched, relaunchStore, _, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(relaunchStore.storedVersion, 0)
        XCTAssertEqual(relaunchBackend.currentShieldConfiguration, .none)
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration())
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
    }

    // MARK: - Finding 3: abandon retains restrictions over stored policy

    func testAbandonOverStoredPolicyRetainsRestrictionsAfterRelaunch() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)

        let (flow, _, manager, backend) = makeSetup(policyStore: store)
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        // Current run shields the picked apps (default-deny).
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.isEmpty)

        // The incomplete record is persisted despite the stored policy —
        // but it cannot forge completion: no completion file exists.
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
        let incomplete = FileSetupEnumerationStore(directory: directory).loadIncompleteEnumeration()
        XCTAssertNotNil(incomplete)
        if let incomplete {
            XCTAssertEqual(Set(incomplete.apps.map(\.app)), [Self.game, Self.socialApp])
        }

        // Relaunch stays incomplete with the picked apps still shielded.
        let (relaunched, relaunchStore, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertFalse(relaunched.needsReauthorization)
        XCTAssertEqual(relaunchStore.storedVersion, 1)
        XCTAssertTrue(relaunchManager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(relaunchManager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp]
        )
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedCategories,
            [Self.games, Self.social]
        )
    }

    func testAbandonedRetryOverStoredPolicyPreservesPriorRestrictions() {
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)

        let enumerationA = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.game, category: Self.games)],
            categories: [Self.games]
        )
        let enumerationB = ShieldEnumeration(
            apps: [EnumeratedApp(app: Self.socialApp, category: Self.social)],
            categories: [Self.social]
        )

        let (first, _, _, _) = makeSetup(policyStore: store)
        first.recordAuthorization(granted: true)
        XCTAssertTrue(first.submitEnumeration(enumerationA))
        first.abandon()

        // Retry with only app B, then abandon again: A must stay
        // protected alongside B even with a stored policy present.
        let retryStore = PolicyStore(directory: directory)
        let (retry, _, retryManager, retryBackend) = makeSetup(policyStore: retryStore)
        XCTAssertEqual(retry.currentStep, .authorization)
        retry.recordAuthorization(granted: true)
        XCTAssertTrue(retry.submitEnumeration(enumerationB))
        retry.abandon()

        XCTAssertTrue(retryManager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(retryManager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertEqual(
            retryBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp]
        )

        // Relaunch: still incomplete, both apps still shielded.
        let (relaunched, relaunchStore, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertEqual(relaunchStore.storedVersion, 1)
        XCTAssertTrue(relaunchManager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(relaunchManager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.socialApp]
        )
    }
}
