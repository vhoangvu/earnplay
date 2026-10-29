import Foundation
import XCTest
@testable import EarnPlayCore

/// T2.3 — SetupFlow: the ordered, no-skip first-run state machine.
///
/// Demo verification runs against a simulated backend (a test double for
/// the `ShieldBackend` interface T2.4 will implement): the completed flow
/// must shield every enumerated app except the allowlist, with the picked
/// categories as the backstop. Real shield enforcement (ManagedSettings,
/// v1, entitlement-gated) is NOT verified by these tests and is never
/// claimed as verified here.
final class SetupFlowTests: XCTestCase {
    private var directory: URL!

    // MARK: - Test doubles

    /// Simulated shield backend for T2.4's interface: records the last
    /// applied configuration and answers effective shielding from it.
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

    // MARK: - Fixtures

    private static let games = AppCategoryRef(id: "games")
    private static let social = AppCategoryRef(id: "social")
    private static let entertainment = AppCategoryRef(id: "entertainment")

    private static let game = AppRef(id: "com.example.game")
    private static let video = AppRef(id: "com.example.video")
    private static let socialApp = AppRef(id: "com.example.social")
    private static let allowedGame = AppRef(id: "com.example.allowed-game")
    private static let newSocial = AppRef(id: "com.example.new-social")

    private func sampleEnumeration() -> ShieldEnumeration {
        ShieldEnumeration(
            apps: [
                EnumeratedApp(app: Self.game, category: Self.games),
                EnumeratedApp(app: Self.video, category: Self.entertainment),
                EnumeratedApp(app: Self.socialApp, category: Self.social),
                EnumeratedApp(app: Self.allowedGame, category: Self.games),
            ],
            categories: [Self.games, Self.social, Self.entertainment]
        )
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupFlowTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - No-skip: nothing advances without authorization

    func testAdvancingWithoutAuthorizationLeavesShieldsInactiveAndFlowIncomplete() {
        let (flow, store, manager, backend) = makeSetup()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isAuthorized)
        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertFalse(flow.submitSelections(allowlist: [Self.allowedGame], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
    }

    func testDeniedAuthorizationCannotProceed() {
        let (flow, store, _, backend) = makeSetup()

        flow.recordAuthorization(granted: false)

        XCTAssertFalse(flow.isAuthorized)
        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(store.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
    }

    // MARK: - No-skip: each step requires its predecessor

    func testEachStepCannotBeSkipped() {
        let (flow, _, _, backend) = makeSetup()

        // Selections and finish are refused before authorization.
        XCTAssertFalse(flow.submitSelections(allowlist: [], unblockable: []))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.isAuthorized)
        XCTAssertEqual(flow.currentStep, .enumeration)

        // Selections and finish are refused before enumeration.
        XCTAssertFalse(flow.submitSelections(allowlist: [], unblockable: []))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)
        XCTAssertEqual(flow.currentStep, .enumeration)

        // An empty pick shields nothing, so it cannot complete setup.
        XCTAssertFalse(flow.submitEnumeration(.empty))
        XCTAssertFalse(flow.submitEnumeration(ShieldEnumeration(apps: [], categories: [])))
        XCTAssertEqual(flow.currentStep, .enumeration)

        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertEqual(flow.currentStep, .selection)

        // Finish is refused before selections; late re-enumeration is refused.
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)
        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertEqual(flow.currentStep, .selection)

        XCTAssertTrue(flow.submitSelections(allowlist: [Self.allowedGame], unblockable: [Self.game]))
        XCTAssertEqual(flow.currentStep, .preventDeletingGuidance)

        // Late re-submission of earlier steps is refused.
        XCTAssertFalse(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertFalse(flow.submitSelections(allowlist: [], unblockable: []))

        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)
        XCTAssertEqual(flow.currentStep, .complete)
        XCTAssertTrue(flow.isComplete)
        XCTAssertTrue(flow.claimsProtection)

        // A completed flow ignores further input; shields stay as applied.
        let applied = backend.currentShieldConfiguration
        XCTAssertNotEqual(applied, .none)
        flow.recordAuthorization(granted: false)
        flow.abandon()
        XCTAssertEqual(flow.currentStep, .complete)
        XCTAssertEqual(backend.currentShieldConfiguration, applied)
    }

    func testRestartEnumerationReturnsToPickerWithoutSkipping() {
        let (flow, store, _, backend) = makeSetup()

        // Refused before authorization and on the wrong steps.
        XCTAssertFalse(flow.restartEnumeration())
        flow.recordAuthorization(granted: true)
        XCTAssertFalse(flow.restartEnumeration())
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))

        XCTAssertTrue(flow.restartEnumeration())
        XCTAssertEqual(flow.currentStep, .enumeration)
        XCTAssertTrue(flow.isAuthorized)
        XCTAssertNil(flow.pendingEnumeration)

        // The flow still passes through every later step before it can
        // complete: finish is refused until enumeration and selections
        // are submitted again.
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .notReady)
        XCTAssertFalse(flow.submitSelections(allowlist: [], unblockable: []))
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: [], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)
        XCTAssertEqual(store.storedVersion, 1)
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.video, Self.socialApp, Self.allowedGame]
        )
    }

    // MARK: - Completion: non-empty policy, enumeration-first shields

    func testCompletingWritesNonEmptyPolicyShieldingEveryEnumeratedAppExceptAllowlist() {
        let (flow, store, manager, backend) = makeSetup()

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(
            allowlist: [Self.allowedGame],
            unblockable: [Self.game, Self.video]
        ))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        // Non-empty initial policy: version 1, defaults plus the staged
        // allowlist, the staged unblockable set, no overrides yet.
        let policy = store.currentPolicy
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(
            Set(policy.alwaysAllowed),
            [.phone, .messages, .earnPlaySelf, Self.allowedGame]
        )
        XCTAssertEqual(Set(policy.unblockable), [Self.game, Self.video])
        XCTAssertTrue(policy.neverUnlockableOverrides.isEmpty)

        // Enumeration-first: every enumerated app except the allowlist is
        // shielded individually; the allowlist is not.
        let config = backend.currentShieldConfiguration
        XCTAssertEqual(
            config.shieldedApplications,
            [Self.game, Self.video, Self.socialApp]
        )
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))
        XCTAssertTrue(manager.isShielded(app: Self.socialApp, category: Self.social))
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: .phone))

        // Category backstop: a newly installed, unenumerated app is
        // shielded through its picked category.
        XCTAssertTrue(config.shieldedCategories.contains(Self.social))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
    }

    func testAllowlistTakesPrecedenceOverUnblockable() {
        let (flow, store, manager, _) = makeSetup()

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(
            allowlist: [Self.game],
            unblockable: [Self.game, Self.video]
        ))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        let policy = store.currentPolicy
        XCTAssertTrue(policy.alwaysAllowed.contains(Self.game))
        XCTAssertFalse(policy.unblockable.contains(Self.game))
        XCTAssertTrue(policy.unblockable.contains(Self.video))
        XCTAssertFalse(policy.isChallengeUnlockable(Self.game))
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.video, category: Self.entertainment))
    }

    // MARK: - Abandonment: never half-open

    func testAbandoningMidFlowShieldsPickedAppsAndStaysIncomplete() {
        // Fix round 3 (finding 6): abandoning no longer leaves picked apps
        // unshielded — issue #14's acceptance requires default-deny on
        // abandon ("never in a half-open state"), so the old `.none`
        // expectations encoded the bug. Abandoning still commits no policy
        // and claims no completed protection.
        let (flow, store, manager, backend) = makeSetup()

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: [Self.allowedGame], unblockable: [Self.game]))
        XCTAssertEqual(flow.currentStep, .preventDeletingGuidance)

        flow.abandon()

        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isAuthorized)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertNil(flow.pendingEnumeration)
        XCTAssertEqual(store.storedVersion, 0)
        // Restrictive incomplete-setup configuration: every picked app
        // shielded, with the category backstop — default-deny.
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.video, Self.socialApp, Self.allowedGame]
        )
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))

        // A fresh flow over the same directory is incomplete too, with the
        // picked apps still shielded: the restrictive record survives
        // relaunch without ever reading as a completed setup.
        let (relaunched, _, relaunchManager, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertFalse(relaunched.claimsProtection)
        XCTAssertTrue(relaunchManager.isShielded(app: Self.game, category: Self.games))
        XCTAssertEqual(
            relaunchBackend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.video, Self.socialApp, Self.allowedGame]
        )
    }

    // MARK: - Persistence failures stay incomplete

    func testPersistenceFailureLeavesFlowIncomplete() {
        let failingStore = PolicyStore(
            directory: directory,
            dataWriter: { _, _ in
                throw NSError(domain: "SetupFlowTests", code: 1)
            }
        )
        let (flow, _, manager, backend) = makeSetup(policyStore: failingStore)

        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: [], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .persistenceFailed)

        XCTAssertEqual(flow.currentStep, .preventDeletingGuidance)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(failingStore.storedVersion, 0)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
        XCTAssertFalse(manager.isShielded(app: Self.game, category: Self.games))

        // Fix round 3 (finding 5): the failed commit leaves no orphan
        // enumeration behind, so a relaunch cannot mistake it for a
        // completed setup.
        XCTAssertNil(FileSetupEnumerationStore(directory: directory).loadEnumeration())
        let (relaunched, _, _, relaunchBackend) = makeSetup()
        XCTAssertEqual(relaunched.currentStep, .authorization)
        XCTAssertFalse(relaunched.isComplete)
        XCTAssertEqual(relaunchBackend.currentShieldConfiguration, .none)
    }

    // MARK: - Restore across relaunch

    func testCompletedSetupRestoresAfterRelaunch() {
        let (flow, _, _, _) = makeSetup()
        flow.recordAuthorization(granted: true)
        XCTAssertTrue(flow.submitEnumeration(sampleEnumeration()))
        XCTAssertTrue(flow.submitSelections(allowlist: [Self.allowedGame], unblockable: [Self.game]))
        XCTAssertEqual(flow.acknowledgePreventDeletingGuidance(), .finished)

        // Relaunch equivalent: new instances over the same directory,
        // with Screen Time access still approved (fix round 3, finding 3:
        // restoring active protection requires current authorization).
        let (relaunched, store, manager, backend) = makeSetup(authorized: true)
        XCTAssertEqual(relaunched.currentStep, .complete)
        XCTAssertTrue(relaunched.isComplete)
        XCTAssertTrue(relaunched.claimsProtection)
        XCTAssertEqual(relaunched.pendingEnumeration, sampleEnumeration())
        XCTAssertEqual(store.storedVersion, 1)

        // Shields are active again without re-running the picker.
        XCTAssertTrue(manager.isShielded(app: Self.game, category: Self.games))
        XCTAssertFalse(manager.isShielded(app: Self.allowedGame, category: Self.games))
        XCTAssertTrue(manager.isShielded(app: Self.newSocial, category: Self.social))
        XCTAssertEqual(
            backend.currentShieldConfiguration.shieldedApplications,
            [Self.game, Self.video, Self.socialApp]
        )
    }

    func testPolicyWithoutEnumerationRestoresAsIncomplete() {
        // A policy with no persisted enumeration (e.g. synced before setup
        // ever completed) must not restore as a completed setup.
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(
            store.apply(Policy.defaultPolicy.withVersion(1)),
            .applied
        )
        let (flow, _, _, backend) = makeSetup(policyStore: store)
        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
    }

    // MARK: - Enumeration store

    func testEnumerationStoreRoundTripsAndMissesAsNil() throws {
        let store = FileSetupEnumerationStore(directory: directory)
        XCTAssertNil(store.loadEnumeration())
        try store.saveEnumeration(sampleEnumeration())
        XCTAssertEqual(store.loadEnumeration(), sampleEnumeration())
        try store.clearEnumeration()
        XCTAssertNil(store.loadEnumeration())
        // Clearing a missing file counts as success.
        XCTAssertNoThrow(try store.clearEnumeration())
    }

    func testCorruptEnumerationRestoresAsIncomplete() throws {
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(FileSetupEnumerationStore.enumerationFileName)
        )
        let store = PolicyStore(directory: directory)
        XCTAssertEqual(store.apply(Policy.defaultPolicy.withVersion(1)), .applied)
        let (flow, _, _, backend) = makeSetup(policyStore: store)
        XCTAssertEqual(flow.currentStep, .authorization)
        XCTAssertFalse(flow.isComplete)
        XCTAssertFalse(flow.claimsProtection)
        XCTAssertEqual(backend.currentShieldConfiguration, .none)
    }
}
