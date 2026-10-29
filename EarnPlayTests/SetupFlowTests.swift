import Foundation
import XCTest
import EarnPlayCore

/// T2.3 — SetupFlow exercised from the child app target (simulator gate),
/// against a simulated shield backend.
///
/// Mirrors the package suite's acceptance checks: no step can be skipped
/// (advancing without authorization leaves shields inactive and the flow
/// incomplete), and completing picker enumeration/selection writes a
/// non-empty policy that shields every enumerated app except the
/// allowlist, with the category backstop. Real authorization and shield
/// enforcement (FamilyControls entitlement, v1) are not verified here.
final class SetupFlowAppTests: XCTestCase {
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

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeSetup() -> (flow: SetupFlow, store: PolicyStore, manager: ShieldManager, backend: SimulatedShieldBackend) {
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
            enumerationStore: FileSetupEnumerationStore(directory: directory)
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

    func testSkippingWithoutAuthorizationLeavesFlowIncompleteAndShieldsInactive() {
        let (flow, store, manager, backend) = makeSetup()

        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertFalse(flow.submitSelections(allowlist: [Self.allowedApp], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testCompletedSetupShieldsEveryEnumeratedAppExceptAllowlist() {
        let (flow, store, manager, backend) = makeSetup()

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(
            allowlist: [Self.allowedApp],
            unblockable: [Self.game]
        ))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        XCTAssertTrue(flow.isComplete)
        XCTAssertTrue(flow.claimsProtection)
        XCTAssertEqual(store.storedVersion, 1)

        let config = backend.currentShieldConfiguration
        XCTAssertEqual(config.shieldedApplications, [Self.game, Self.socialApp])
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.allowedApp, category: Self.games))
        // Category backstop catches a newly installed, unenumerated app.
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
    }

    func testAbandonedSetupClaimsNoProtection() {
        let (flow, store, _, backend) = makeSetup()

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
    }
}
