import Foundation
import SwiftUI
import UIKit
import Vision
import XCTest
import FamilyControls
import ManagedSettings
import EarnPlayCore
@testable import EarnPlay

/// Issue #87 fix round 1 — Copilot review findings on PR #88:
///
/// 1. Forced-mode setup stalls at enumeration (the system picker cannot
///    produce tokens without real authorization): the forced path now
///    enumerates from `SimulatedSetupCatalog` through the same
///    submission; the unforced path keeps the real picker exactly as-is.
/// 2. The simulate toggle is unreachable when model-ready + setup
///    incomplete: a setup-wide About/Demo toolbar entry now covers
///    every setup step (restart requirement + caption unchanged).
/// 3. No simulated shield flow is reachable from the main experience:
///    the completion screen now drives lock/unlock over the installed
///    composition (same manager/policy/enumeration/simulated backend)
///    with the honesty badge retained.
///
/// Rendered-UI pins use the UIHostingController + Vision OCR pattern
/// from `ThemeContrastFix2Tests` (no UI-test target).
final class GateModeFlagFixRound1Tests: XCTestCase {
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
            .appendingPathComponent("GateModeFlagFixRound1Tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Picker tokens have no public initializer, but `Token<T>` is Codable
    /// as `{"data":"<base64>"}` (same fabrication as
    /// `SetupFlowViewModelFixRound4Tests`).
    private func appToken(_ tag: String) throws -> ApplicationToken {
        let base64 = Data(tag.utf8).base64EncodedString()
        return try JSONDecoder().decode(
            ApplicationToken.self,
            from: Data("{\"data\":\"\(base64)\"}".utf8)
        )
    }

    @MainActor
    private func themes() -> ThemeStore {
        ThemeStore(defaults: UserDefaults(
            suiteName: "earnplay.GateModeFlagFixRound1Tests.\(UUID().uuidString)"
        )!)
    }

    /// Hosts a view in a tall window and returns its OCR'd visible text
    /// (the `ThemeContrastFix2Tests` pattern: SwiftUI text draws into
    /// layers rather than UIViews, so hierarchy walks see nothing). The
    /// window is taller than any asserted content so nothing under test
    /// is clipped by a scroll view.
    @MainActor
    private func renderedText<Content: View>(for view: Content) -> String {
        let host = UIHostingController(rootView: view)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1500))
        win.rootViewController = host
        win.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        return (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    // MARK: - Finding 1: simulated enumeration when forced, real picker when unforced

    @MainActor
    func testSimulatedEnumerationGatingFollowsMode() {
        XCTAssertTrue(
            SetupFlowViewModel.makeDefault(simulatedMode: true).usesSimulatedEnumeration,
            "forced mode must enumerate from the simulated catalog"
        )
        XCTAssertFalse(
            SetupFlowViewModel.makeDefault(simulatedMode: false).usesSimulatedEnumeration,
            "unforced mode must keep the real picker"
        )
    }

    @MainActor
    func testForcedSetupCompletesEndToEndWithSimulatedPicksOnly() async {
        let (viewModel, backend) = await completeForcedSetup()

        // No FamilyControls token anywhere: the run completed on
        // simulated input alone through the same submission path.
        XCTAssertTrue(viewModel.selection.applicationTokens.isEmpty)
        XCTAssertTrue(viewModel.selection.categoryTokens.isEmpty)
        XCTAssertTrue(viewModel.pickedApps.isEmpty)
        XCTAssertEqual(viewModel.pickedSimulatedApps.count, 3)

        // The installed simulated backend records the picked apps
        // shielded; the known catalog categories join the backstop.
        let config = backend.currentShieldConfiguration
        XCTAssertEqual(
            config.shieldedApplications,
            Set(SimulatedSetupCatalog.apps.map(\.ref))
        )
        XCTAssertEqual(
            config.shieldedCategories,
            Set(SimulatedSetupCatalog.apps.map(\.category.ref))
        )

        // The completion summary reports the simulated setup honestly.
        let summary = try? XCTUnwrap(viewModel.summary)
        XCTAssertEqual(summary?.policyVersion, 1)
        XCTAssertEqual(summary?.shieldedCount, 3)
        XCTAssertEqual(summary?.unblockableCount, 3)
        XCTAssertEqual(summary?.allowedExtraCount, 0)
        XCTAssertEqual(summary?.backstopCount, 3)
    }

    @MainActor
    func testForcedEnumerationWithNoInputStaysPut() async {
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: SimulatedShieldBackend()
        )
        await viewModel.requestAuthorization()
        XCTAssertEqual(viewModel.step, .enumeration)

        XCTAssertFalse(viewModel.hasEnumerationInput)
        viewModel.continueFromEnumeration()

        XCTAssertEqual(viewModel.step, .enumeration)
        XCTAssertNotNil(viewModel.progressError)
    }

    @MainActor
    func testUnforcedEnumerationIgnoresSimulatedPicks() {
        // The merge is gated: simulated picks can never leak into an
        // unforced enumeration, whose Continue behaves exactly as before.
        let viewModel = makeViewModel(
            authService: MutableAuthorizationService(status: .approved),
            backend: NonEnforcingShieldBackend()
        )
        viewModel.refreshAuthorizationStatus()
        XCTAssertEqual(viewModel.step, .enumeration)

        viewModel.simulatedAppIDs = Set(SimulatedSetupCatalog.apps.map(\.id))
        XCTAssertFalse(viewModel.hasEnumerationInput)
        viewModel.continueFromEnumeration()

        XCTAssertEqual(viewModel.step, .enumeration)
        XCTAssertNotNil(viewModel.progressError)
    }

    @MainActor
    func testSimulatedPicksRestoreAfterRelaunch() async {
        let appIDs: Set<String> = [
            SimulatedSetupCatalog.apps[0].id,
            SimulatedSetupCatalog.apps[1].id,
        ]
        let categoryIDs: Set<String> = [SimulatedSetupCatalog.games.id]
        _ = await completeForcedSetup(appIDs: appIDs, categoryIDs: categoryIDs)

        // Relaunch: a fresh view model over the same stores, seeded
        // authorized, restores completion AND the simulated picks.
        let relaunched = makeViewModel(
            authService: SimulatedSetupAuthorizationService(approved: true),
            backend: SimulatedShieldBackend(),
            authorized: true
        )
        XCTAssertEqual(relaunched.step, .complete)
        XCTAssertEqual(Set(relaunched.pickedSimulatedApps.map(\.id)), appIDs)
        XCTAssertEqual(Set(relaunched.pickedSimulatedCategories.map(\.id)), categoryIDs)
        XCTAssertNotNil(relaunched.summary)
    }

    @MainActor
    func testInstalledShieldTargetResolvesTokenAndSimulatedPicks() async throws {
        // Mixed state (a restored token pick plus a simulated pick):
        // tokens resolve with an unknown category, simulated picks with
        // their known catalog category.
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: SimulatedShieldBackend()
        )
        await viewModel.requestAuthorization()
        viewModel.selection.applicationTokens = [try appToken("mixed-token")]

        viewModel.simulatedAppIDs = [SimulatedSetupCatalog.apps[0].id]
        viewModel.continueFromEnumeration()
        XCTAssertEqual(viewModel.step, .selection)
        XCTAssertEqual(viewModel.pickedApps.count, 1)

        let tokenTarget = try XCTUnwrap(
            viewModel.installedShieldTarget(for: viewModel.pickedApps[0].id)
        )
        XCTAssertNil(tokenTarget.category)
        let simulatedTarget = try XCTUnwrap(
            viewModel.installedShieldTarget(for: SimulatedSetupCatalog.apps[0].id)
        )
        XCTAssertEqual(simulatedTarget.ref, SimulatedSetupCatalog.apps[0].ref)
        XCTAssertEqual(simulatedTarget.category, SimulatedSetupCatalog.games.ref)
        XCTAssertNil(viewModel.installedShieldTarget(for: "no.such.app"))
    }

    // MARK: - Enumeration picker UI branches

    @MainActor
    func testEnumerationRendersSimulatedPickerWhenForced() {
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(approved: true),
            backend: SimulatedShieldBackend()
        )
        viewModel.refreshAuthorizationStatus()
        XCTAssertEqual(viewModel.step, .enumeration)

        let rendered = renderedText(
            for: SetupFlowView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("Demo Game"),
            "forced enumeration must render the simulated app picks; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("Demo categories"),
            "forced enumeration must render the simulated category picks; rendered:\n\(rendered)"
        )
        XCTAssertFalse(
            rendered.contains("Select apps and categories"),
            "forced enumeration must not offer the system picker; rendered:\n\(rendered)"
        )
    }

    @MainActor
    func testEnumerationRendersRealPickerWhenUnforced() {
        let viewModel = makeViewModel(
            authService: MutableAuthorizationService(status: .approved),
            backend: NonEnforcingShieldBackend()
        )
        viewModel.refreshAuthorizationStatus()
        XCTAssertEqual(viewModel.step, .enumeration)

        let rendered = renderedText(
            for: SetupFlowView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("Select apps and categories"),
            "unforced enumeration must keep the real picker; rendered:\n\(rendered)"
        )
        XCTAssertFalse(
            rendered.contains("Demo Game"),
            "unforced enumeration must not render simulated picks; rendered:\n\(rendered)"
        )
    }

    // MARK: - Finding 2: setup-wide About/Demo entry

    @MainActor
    func testAboutEntryRendersInEveryIncompleteSetupState() async {
        // SetupFlowView is what the model-ready app renders while setup
        // is incomplete; the About/Demo entry must exist at EVERY step.
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: SimulatedShieldBackend()
        )
        assertAboutEntryRenders(for: viewModel)

        await viewModel.requestAuthorization()
        XCTAssertEqual(viewModel.step, .enumeration)
        assertAboutEntryRenders(for: viewModel)

        viewModel.simulatedAppIDs = [SimulatedSetupCatalog.apps[0].id]
        viewModel.continueFromEnumeration()
        XCTAssertEqual(viewModel.step, .selection)
        assertAboutEntryRenders(for: viewModel)

        viewModel.continueFromSelection()
        XCTAssertEqual(viewModel.step, .preventDeletingGuidance)
        assertAboutEntryRenders(for: viewModel)
    }

    @MainActor
    private func assertAboutEntryRenders(
        for viewModel: SetupFlowViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // "About" appears on setup steps only in the toolbar entry, so
        // its presence pins the entry without depending on OCR's
        // reading of the "& demo" suffix.
        let rendered = renderedText(
            for: SetupFlowView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("About"),
            "About/Demo entry missing at step \(viewModel.step); rendered:\n\(rendered)",
            file: file,
            line: line
        )
    }

    @MainActor
    func testSetupFlowViewRetainsAppScopeThemeStore() {
        // Same-store binding as the completion screen: the view retains
        // the exact instance, so the sheet's picker drives the live app
        // theme.
        let viewModel = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: SimulatedShieldBackend()
        )
        let store = themes()
        let view = SetupFlowView(viewModel: viewModel, themes: store)
        let mirror = Mirror(reflecting: view)
        let kept = (mirror.descendant("_themes") as? ObservedObject<ThemeStore>)?.wrappedValue
        XCTAssertTrue(
            kept === store,
            "SetupFlowView must retain the passed app-scope ThemeStore instance"
        )
    }

    @MainActor
    func testAboutViewKeepsSimulateToggleWithRestartCaption() {
        // The toggle keeps its restart requirement and its caption; only
        // its reachability changed.
        let rendered = renderedText(for: AboutView(themes: themes()))
        XCTAssertTrue(
            rendered.contains("Simulate shields"),
            "About must carry the simulate toggle; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("restart the app"),
            "About must keep the restart caption; rendered:\n\(rendered)"
        )
    }

    // MARK: - Finding 3: installed simulated shields in the main flow

    @MainActor
    func testInstalledShieldSupportGating() {
        XCTAssertTrue(
            SetupFlowViewModel.makeDefault(simulatedMode: true).supportsInstalledSimulatedShields,
            "forced mode installs the simulated backend, so shield flows are supported"
        )
        XCTAssertFalse(
            SetupFlowViewModel.makeDefault(simulatedMode: false).supportsInstalledSimulatedShields,
            "unforced mode keeps the non-enforcing backend: no shield flows"
        )
        XCTAssertFalse(
            SetupFlowViewModel.makeDefault(
                authService: SimulatedSetupAuthorizationService(),
                simulatedMode: false
            ).supportsInstalledSimulatedShields,
            "simulated auth without the simulated backend cannot drive shield flows"
        )
    }

    @MainActor
    func testInstalledShieldFlowGrantsThroughInstalledComposition() async {
        let (viewModel, backend) = await completeForcedSetup()
        let game = SimulatedSetupCatalog.apps[0]
        let video = SimulatedSetupCatalog.apps[1]

        let flow = viewModel.makeInstalledSimulatedShieldFlow(
            for: game.ref,
            category: game.category.ref,
            decisionLogger: DecisionLogger(directory: directory),
            unlockDuration: 120,
            scorer: EffortScorer(threshold: 8)
        )
        let shieldFlow = try? XCTUnwrap(flow)
        XCTAssertTrue(shieldFlow?.isShieldPresented ?? false)
        XCTAssertEqual(shieldFlow?.presentationEvents, [.presented])

        // Passing effort through the real Epic 1 path: 2 genuine
        // attempts (4 pts) + 2 hints (4 pts) = 8.
        shieldFlow?.submitAttempt(answer: "7")
        shieldFlow?.submitAttempt(answer: "14")
        shieldFlow?.useHint()
        shieldFlow?.useHint()
        XCTAssertEqual(shieldFlow?.finishChallenge()?.decision, .granted)
        XCTAssertFalse(shieldFlow?.isShieldPresented ?? true)
        XCTAssertEqual(
            shieldFlow?.challengeDecisionText,
            SimulatedShieldFlow.unlockGrantedText
        )

        // The grant flowed through the INSTALLED manager into the
        // INSTALLED backend: only the unlocked app opened.
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.contains(game.ref))
        XCTAssertTrue(backend.currentShieldConfiguration.shieldedApplications.contains(video.ref))
        XCTAssertGreaterThan(
            viewModel.flow.installedShieldManager.remainingUnlockTime, 0
        )
        XCTAssertEqual(backend.managedSettingsCallCount, 0)
        XCTAssertTrue(SimulatedShieldFlow.simulatedBadgeText.contains("SIMULATED"))
    }

    @MainActor
    func testInstalledShieldFlowIsNilWhenUnforced() {
        let viewModel = makeViewModel(
            authService: MutableAuthorizationService(status: .approved),
            backend: NonEnforcingShieldBackend()
        )
        XCTAssertNil(viewModel.makeInstalledSimulatedShieldFlow(for: SimulatedSetupCatalog.apps[0].ref))
        XCTAssertNil(viewModel.installedShieldFlow(for: SimulatedSetupCatalog.apps[0].ref))
        XCTAssertNil(viewModel.selectInstalledShieldApp(SimulatedSetupCatalog.apps[0].id))
    }

    @MainActor
    func testSetupCompleteRendersInstalledShieldEntriesWhenForced() async {
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [SimulatedSetupCatalog.apps[0].id],
            categoryIDs: []
        )
        let rendered = renderedText(
            for: SetupCompleteView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("Simulated shield"),
            "forced completion must render installed shield entries; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("Demo Game"),
            "forced completion must name the picked demo app; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("SIMULATED SHIELD"),
            "the honesty badge stays with the shield panel; rendered:\n\(rendered)"
        )
    }

    @MainActor
    func testSetupCompleteHidesInstalledShieldEntriesWhenUnforced() {
        // Unforced completion (driven through the plain flow, no tokens):
        // no simulated backend installed, so no shield panel.
        let auth = MutableAuthorizationService(status: .approved)
        let viewModel = makeViewModel(
            authService: auth,
            backend: NonEnforcingShieldBackend()
        )
        viewModel.flow.recordAuthorization(granted: true)
        XCTAssertTrue(viewModel.flow.submitEnumeration(ShieldEnumeration(
            apps: [EnumeratedApp(app: AppRef(id: "com.example.game"))],
            categories: []
        )))
        XCTAssertTrue(viewModel.flow.submitSelections(
            allowlist: [],
            unblockable: [AppRef(id: "com.example.game")]
        ))
        viewModel.finishSetup()
        XCTAssertEqual(viewModel.step, .complete)

        let rendered = renderedText(
            for: SetupCompleteView(viewModel: viewModel, themes: themes())
        )
        XCTAssertFalse(
            rendered.contains("Simulated shield"),
            "unforced completion must not render shield entries; rendered:\n\(rendered)"
        )
    }
}
