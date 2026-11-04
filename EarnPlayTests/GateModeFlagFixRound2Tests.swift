import Foundation
import SwiftUI
import UIKit
import Vision
import XCTest
import FamilyControls
import ManagedSettings
import EarnPlayCore
@testable import EarnPlay

/// Issue #87 fix round 2 — Copilot re-review findings on PR #88 (f7ee85f):
///
/// 1. HIGH — Blocked installed targets opened a non-dismissible
///    challenge: the panel rendered the challenge host with no
///    unlockability gate, but the manager refuses unlocks for blocked
///    (default Blocked choice, including never-unlockable overrides)
///    regardless of effort. Fix: blocked targets show an informational
///    status instead of the host; the unlockable challenge path is
///    unchanged.
/// 2. HIGH — The installed flow ignored the saved policy's effort
///    floor: the default scorer was the 1-attempt/1-hint floor while
///    the policy could require more. Fix: the default scorer reads
///    the installed policy's floor; an explicitly injected scorer
///    still wins.
/// 3. MEDIUM — Simulated picks were lost after forced-mode
///    reauthorization: restoration was initializer-only, so a re-grant
///    restored completion with no picks behind still-active shields.
///    Fix: the staged enumeration re-syncs the picks on every
///    transition to `.complete`, before the summary rebuild.
///
/// Rendered-UI pins use the UIHostingController + Vision OCR pattern
/// from `ThemeContrastFix2Tests` (no UI-test target).
final class GateModeFlagFixRound2Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateModeFlagFixRound2Tests-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    private func themes() -> ThemeStore {
        ThemeStore(defaults: UserDefaults(
            suiteName: "earnplay.GateModeFlagFixRound2Tests.\(UUID().uuidString)"
        )!)
    }

    /// Hosts a view in a tall window and returns its OCR'd visible text
    /// (the `ThemeContrastFix2Tests` pattern).
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

    // MARK: - Finding 1: blocked targets show status, never the challenge host

    @MainActor
    func testBlockedChoiceShowsBlockedStatusNeverChallengeHost() async {
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .blocked
        )

        // The view-model gate: blocked means no flow to host.
        XCTAssertTrue(viewModel.isInstalledShieldBlocked(game.ref))
        XCTAssertNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))
        XCTAssertNil(viewModel.selectInstalledShieldApp(game.id))

        // The panel renders the entry plus the informational status.
        let rendered = renderedText(
            for: SetupCompleteView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("Simulated shield"),
            "blocked completion must still list the shield entry; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("Blocked (simulated)") && rendered.contains("no challenge offered"),
            "blocked target must show the informational status; rendered:\n\(rendered)"
        )
    }

    @MainActor
    func testNeverUnlockableOverrideShowsBlockedStatus() async {
        // Pre-apply an override for one app: setup preserves overrides,
        // so even an Earn pick for it commits as blocked.
        let game = SimulatedSetupCatalog.apps[0]
        let video = SimulatedSetupCatalog.apps[1]
        var pre = Policy.defaultPolicy
        pre.version = 1
        pre.neverUnlockableOverrides = [game.ref]
        XCTAssertEqual(PolicyStore(directory: directory).apply(pre), .applied)

        let (viewModel, _) = await completeForcedSetup(choice: .unblockable)

        XCTAssertTrue(
            viewModel.isInstalledShieldBlocked(game.ref),
            "override-covered app must report blocked even when picked as Earn"
        )
        XCTAssertNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))
        XCTAssertNil(viewModel.selectInstalledShieldApp(game.id))
        XCTAssertFalse(viewModel.isInstalledShieldBlocked(video.ref))
        XCTAssertNotNil(viewModel.installedShieldFlow(for: video.ref, category: video.category.ref))
        XCTAssertNotNil(viewModel.selectInstalledShieldApp(video.id))
        XCTAssertEqual(viewModel.choices[game.id], .blocked)
    }

    @MainActor
    func testAllowedTargetKeepsHostPath() async {
        // Allowed is not blocked: it keeps the host path (which renders
        // unlocked — never a trap), not the blocked status.
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .allowed
        )

        XCTAssertFalse(viewModel.isInstalledShieldBlocked(game.ref))
        XCTAssertNotNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))

        let rendered = renderedText(
            for: SetupCompleteView(viewModel: viewModel, themes: themes())
        )
        XCTAssertFalse(
            rendered.contains("no challenge offered"),
            "allowed target must not show the blocked status; rendered:\n\(rendered)"
        )
    }

    @MainActor
    func testUnlockableChallengePathKeepsWorking() async {
        // The challenge path for unlockable targets is unchanged: a
        // cached flow exists, selection ticks it, and the entry renders
        // with no blocked status.
        let game = SimulatedSetupCatalog.apps[0]
        let (viewModel, _) = await completeForcedSetup(
            appIDs: [game.id],
            categoryIDs: [],
            choice: .unblockable
        )

        XCTAssertFalse(viewModel.isInstalledShieldBlocked(game.ref))
        let flow = viewModel.installedShieldFlow(for: game.ref, category: game.category.ref)
        XCTAssertNotNil(flow)
        XCTAssertTrue(flow?.isShieldPresented ?? false)
        XCTAssertNotNil(viewModel.selectInstalledShieldApp(game.id))

        let rendered = renderedText(
            for: SetupCompleteView(viewModel: viewModel, themes: themes())
        )
        XCTAssertTrue(
            rendered.contains("Simulated shield"),
            "unlockable completion must render the shield entry; rendered:\n\(rendered)"
        )
        XCTAssertFalse(
            rendered.contains("no challenge offered"),
            "unlockable target must not show the blocked status; rendered:\n\(rendered)"
        )
    }

    @MainActor
    func testBlockedStatusLabelCopy() {
        // Pins the informational copy without driving panel taps.
        let rendered = renderedText(
            for: InstalledBlockedStatusLabel(appID: SimulatedSetupCatalog.apps[0].id)
        )
        XCTAssertTrue(
            rendered.contains("Blocked (simulated)"),
            "blocked status must name the simulated scope; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("no challenge offered"),
            "blocked status must say no challenge is offered; rendered:\n\(rendered)"
        )
        XCTAssertTrue(
            rendered.contains("stays shielded"),
            "blocked status must say the app stays shielded; rendered:\n\(rendered)"
        )
    }

    // MARK: - Finding 2: default scorer follows the installed policy floor

    @MainActor
    func testDefaultInstalledScorerUsesPolicyEffortFloor() async {
        // A policy requiring four attempts: 2 attempts + 5 hints scores
        // 14 (2*2 + 5*2, no active minutes), which always meets the
        // 8...14 threshold — so the decision isolates the floor.
        var pre = Policy.defaultPolicy
        pre.version = 1
        pre.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 4, minHintOrFollowUpInteractions: 1
        )
        XCTAssertEqual(PolicyStore(directory: directory).apply(pre), .applied)

        let (viewModel, _) = await completeForcedSetup(
            appIDs: [SimulatedSetupCatalog.apps[0].id],
            categoryIDs: [],
            choice: .unblockable
        )
        let game = SimulatedSetupCatalog.apps[0]

        // Default scorer (nil injection): must enforce the 4-attempt floor.
        let defaultFlow = viewModel.makeInstalledSimulatedShieldFlow(
            for: game.ref,
            category: game.category.ref,
            decisionLogger: DecisionLogger(directory: directory),
            unlockDuration: 120,
            scorer: nil
        )
        let flow = try? XCTUnwrap(defaultFlow)
        XCTAssertTrue(flow?.isShieldPresented ?? false)
        flow?.submitAttempt(answer: "7")
        flow?.submitAttempt(answer: "14")
        for _ in 0..<5 { flow?.useHint() }
        let score = flow?.finishChallenge()
        XCTAssertEqual(score?.score, 14)
        XCTAssertEqual(score?.floorMet, false)
        XCTAssertEqual(score?.decision, .denied)
        XCTAssertTrue(
            flow?.isShieldPresented ?? false,
            "a below-floor session must not open the installed unlock"
        )
        XCTAssertEqual(flow?.challengeDecisionText, SimulatedShieldFlow.unlockDeniedText)
    }

    @MainActor
    func testExplicitScorerInjectionStillWins() async {
        // Same strong-floor policy, but an explicitly injected default
        // scorer: the same 2-attempt/5-hint session must grant,
        // proving the passed scorer wins over the policy floor.
        var pre = Policy.defaultPolicy
        pre.version = 1
        pre.effortFloorSettings = EffortFloorSettings(
            minGenuineAttempts: 4, minHintOrFollowUpInteractions: 1
        )
        XCTAssertEqual(PolicyStore(directory: directory).apply(pre), .applied)

        let (viewModel, _) = await completeForcedSetup(
            appIDs: [SimulatedSetupCatalog.apps[0].id],
            categoryIDs: [],
            choice: .unblockable
        )
        let game = SimulatedSetupCatalog.apps[0]

        let flow = viewModel.makeInstalledSimulatedShieldFlow(
            for: game.ref,
            category: game.category.ref,
            decisionLogger: DecisionLogger(directory: directory),
            unlockDuration: 120,
            scorer: EffortScorer(threshold: 8, floorSettings: .default)
        )
        let shieldFlow = try? XCTUnwrap(flow)
        shieldFlow?.submitAttempt(answer: "7")
        shieldFlow?.submitAttempt(answer: "14")
        for _ in 0..<5 { shieldFlow?.useHint() }
        XCTAssertEqual(shieldFlow?.finishChallenge()?.decision, .granted)
        XCTAssertFalse(shieldFlow?.isShieldPresented ?? true)
        XCTAssertEqual(
            shieldFlow?.challengeDecisionText,
            SimulatedShieldFlow.unlockGrantedText
        )
    }

    // MARK: - Finding 3: simulated picks survive reauthorization

    @MainActor
    func testSimulatedPicksSurviveReauthorizationViaRequest() async {
        let appIDs: Set<String> = [
            SimulatedSetupCatalog.apps[0].id,
            SimulatedSetupCatalog.apps[1].id,
        ]
        let categoryIDs: Set<String> = [SimulatedSetupCatalog.games.id]
        _ = await completeForcedSetup(appIDs: appIDs, categoryIDs: categoryIDs)

        // Relaunch with access revoked: the wizard returns to
        // authorization with the committed pair pending.
        let relaunched = makeViewModel(
            authService: SimulatedSetupAuthorizationService(),
            backend: SimulatedShieldBackend(),
            authorized: false
        )
        XCTAssertEqual(relaunched.step, .authorization)
        XCTAssertTrue(relaunched.needsReauthorization)
        XCTAssertTrue(
            relaunched.pickedSimulatedApps.isEmpty,
            "pre-grant picks are empty: nothing is staged until reauthorization"
        )

        // Re-granting restores completion AND the simulated picks, so
        // demo state matches the user's selections.
        await relaunched.requestAuthorization()
        XCTAssertEqual(relaunched.step, .complete)
        XCTAssertFalse(relaunched.needsReauthorization)
        XCTAssertEqual(Set(relaunched.pickedSimulatedApps.map(\.id)), appIDs)
        XCTAssertEqual(Set(relaunched.pickedSimulatedCategories.map(\.id)), categoryIDs)
        XCTAssertNotNil(relaunched.summary)
        XCTAssertNotNil(relaunched.installedShieldTarget(for: SimulatedSetupCatalog.apps[0].id))

        // The restored shields cover the restored picks.
        let backend = relaunched.backend as? SimulatedShieldBackend
        let config = backend?.currentShieldConfiguration
        XCTAssertEqual(
            config?.shieldedApplications,
            Set(SimulatedSetupCatalog.apps.filter { appIDs.contains($0.id) }.map(\.ref))
        )
    }

    @MainActor
    func testSimulatedPicksSurviveReauthorizationViaRefresh() async {
        let appIDs: Set<String> = [SimulatedSetupCatalog.apps[2].id]
        let categoryIDs: Set<String> = [SimulatedSetupCatalog.social.id]
        _ = await completeForcedSetup(appIDs: appIDs, categoryIDs: categoryIDs)

        // Same pending shape, but the service already reports approved
        // (the onAppear `refreshAuthorizationStatus()` path).
        let relaunched = makeViewModel(
            authService: SimulatedSetupAuthorizationService(approved: true),
            backend: SimulatedShieldBackend(),
            authorized: false
        )
        XCTAssertTrue(relaunched.needsReauthorization)

        relaunched.refreshAuthorizationStatus()
        XCTAssertEqual(relaunched.step, .complete)
        XCTAssertEqual(Set(relaunched.pickedSimulatedApps.map(\.id)), appIDs)
        XCTAssertEqual(Set(relaunched.pickedSimulatedCategories.map(\.id)), categoryIDs)
        XCTAssertNotNil(relaunched.summary)
    }
}
