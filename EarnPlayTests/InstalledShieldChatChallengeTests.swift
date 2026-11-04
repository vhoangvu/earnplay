import Foundation
import SwiftUI
import UIKit
import Vision
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #91 — the installed shield challenge is the chat tutor.
///
/// The installed path (`SetupCompleteView` → installed shield entry) presents
/// the chat tutor with the simulated badge; chat interactions record into the
/// SAME `SimulatedShieldFlow` effort session `finishChallenge` scores, and
/// finishing runs the existing boundary unchanged (same floor rule, same
/// threshold math, same decision logging). Blocked targets still offer no
/// challenge. The one-question `SimulatedShieldDemoView` surface is untouched,
/// as is the main practice chat's SessionLog recording (pinned by the
/// existing session-recording suites staying green).
@MainActor
final class InstalledShieldChatChallengeTests: XCTestCase {
    private var directory: URL!

    private static let games = AppCategoryRef(id: "games")
    private static let game = AppRef(id: "earnplay.demo.game")

    /// Scripted inner engine: pre-scripted tutor turns with call tracking.
    private final class FakeChatEngine: ChatTutorEngine {
        private(set) var submitted: [String] = []
        private(set) var hintTaps = 0
        private(set) var composerActivityCount = 0
        /// The 1-based submit count that draws a probe turn (0 = never).
        var probeOnSubmit: Int = 0
        /// The 1-based submit counts labelled revisions.
        var revisionOnSubmit: Set<Int> = []
        /// Delivered hints left before the ladder exhausts.
        var hintsRemaining: Int = Int.max
        private var messageSequence = 0

        func startSession() -> ChatEngineUpdate {
            ChatEngineUpdate(
                turns: [.tutor(TutorMessage(
                    id: "q1", text: "What is 7 times 8?", kind: .question))],
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 0),
                composer: .text)
        }

        func submitAnswer(_ plainText: String) -> ChatEngineUpdate {
            submitted.append(plainText)
            let count = submitted.count
            var turns: [ChatTurn] = [.tutor(TutorMessage(
                id: "e\(count)", text: "Good trying.", kind: .encouragement))]
            if probeOnSubmit == count {
                turns.append(.tutor(TutorMessage(
                    id: "p\(count)",
                    text: "Show me one step: what did you try first?",
                    kind: .probe)))
            }
            return ChatEngineUpdate(
                turns: turns,
                progress: ChatProgress(totalQuestions: 1, attemptedQuestions: 1),
                composer: .text,
                submittedTurnIsRevision: revisionOnSubmit.contains(count))
        }

        func requestHint() -> ChatEngineUpdate {
            hintTaps += 1
            guard hintsRemaining > 0 else { return ChatEngineUpdate() }
            hintsRemaining -= 1
            messageSequence += 1
            return ChatEngineUpdate(turns: [.tutor(TutorMessage(
                id: "h\(messageSequence)", text: "Try counting by 7s.",
                kind: .hint))])
        }

        func recordComposerActivity() {
            composerActivityCount += 1
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InstalledShieldChatChallengeTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    @MainActor
    private func makeFlow(threshold: Int = 8) -> (flow: SimulatedShieldFlow, backend: SimulatedShieldBackend) {
        let backend = SimulatedShieldBackend()
        let policyStore = PolicyStore(directory: directory)
        XCTAssertEqual(policyStore.apply(Policy(
            version: 1,
            alwaysAllowed: [.phone],
            unblockable: [Self.game],
            neverUnlockableOverrides: [],
            unlockDurations: .default,
            effortFloorSettings: .default,
            tradeCaps: .default,
            chorePool: [],
            movementSettings: .default
        )), .applied)
        let manager = ShieldManager(
            policyStore: policyStore,
            enumeration: ShieldEnumeration(
                apps: [EnumeratedApp(app: Self.game, category: Self.games)],
                categories: [Self.games]
            ),
            backend: backend,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        let flow = SimulatedShieldFlow(
            manager: manager,
            backend: backend,
            app: Self.game,
            category: Self.games,
            scorer: EffortScorer(threshold: threshold),
            recorder: EffortSessionRecorder(startedAt: Date()),
            unlockDuration: 120,
            isSimulatedMode: true,
            decisionLogger: DecisionLogger(directory: directory)
        )
        return (flow, backend)
    }

    @MainActor
    private func makeChallenge(
        flow: SimulatedShieldFlow,
        fake: FakeChatEngine = FakeChatEngine()
    ) -> (fake: FakeChatEngine, engine: InstalledShieldChatEngine, viewModel: ChatConversationViewModel) {
        let engine = InstalledShieldChatEngine(inner: fake, flow: flow)
        let viewModel = ChatConversationViewModel(
            engine: engine,
            speech: ReadAloudService(band: GradeBand(grade: "4")))
        return (fake, engine, viewModel)
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

    // MARK: - Decision boundary through chat effort

    @MainActor
    func testChatEffortWithHintLegGrantsThroughExistingBoundary() {
        let (flow, _) = makeFlow()
        let (_, _, viewModel) = makeChallenge(flow: flow)
        XCTAssertTrue(flow.isShieldPresented)

        // Full chat path through the real view model: 2 answers (4 pts) +
        // 2 delivered hints (4 pts) = 8, meeting threshold 8 and the floor.
        viewModel.startIfNeeded()
        viewModel.draft = "54"
        viewModel.submitDraft()
        viewModel.draft = "56"
        viewModel.submitDraft()
        viewModel.requestHint()
        viewModel.requestHint()

        let score = flow.finishChallenge()
        XCTAssertEqual(score?.decision, .granted)
        XCTAssertEqual(score?.score, 8)
        XCTAssertEqual(score?.threshold, 8)
        XCTAssertTrue(score?.floorMet ?? false)
        // The existing boundary logged the decision.
        XCTAssertNotNil(flow.lastDecision)
        XCTAssertEqual(flow.lastDecision?.type, .grantUnlock)
        XCTAssertEqual(
            flow.challengeDecisionText,
            SimulatedShieldFlow.unlockGrantedText)
    }

    @MainActor
    func testZeroHintsDeniesRegardlessOfAttempts() {
        let (flow, _) = makeFlow()
        let (_, _, viewModel) = makeChallenge(flow: flow)

        // 5 genuine attempts (10 pts) but no hint leg: the floor denies.
        viewModel.startIfNeeded()
        for answer in ["1", "2", "3", "4", "5"] {
            viewModel.draft = answer
            viewModel.submitDraft()
        }

        let score = flow.finishChallenge()
        XCTAssertEqual(score?.decision, .denied)
        XCTAssertFalse(score?.floorMet ?? true)
        XCTAssertEqual(
            flow.challengeDecisionText,
            SimulatedShieldFlow.unlockDeniedText)
    }

    @MainActor
    func testBelowThresholdDenies() {
        let (flow, _) = makeFlow()
        let (_, _, viewModel) = makeChallenge(flow: flow)

        // Floor met (1 attempt + 1 hint) but 4 pts < threshold 8: denied.
        viewModel.startIfNeeded()
        viewModel.draft = "54"
        viewModel.submitDraft()
        viewModel.requestHint()

        let score = flow.finishChallenge()
        XCTAssertEqual(score?.decision, .denied)
        XCTAssertTrue(score?.floorMet ?? false)
        // The result narration still shows on a denial.
        XCTAssertNotNil(flow.lastScore?.narration)
        XCTAssertFalse(flow.lastScore?.narration.isEmpty ?? true)
    }

    @MainActor
    func testGrantOpensWindowAndDismissesChallenge() {
        let (flow, backend) = makeFlow()
        let (_, _, viewModel) = makeChallenge(flow: flow)
        XCTAssertEqual(flow.presentationEvents, [.presented])

        viewModel.startIfNeeded()
        viewModel.draft = "54"
        viewModel.submitDraft()
        viewModel.draft = "56"
        viewModel.submitDraft()
        viewModel.requestHint()
        viewModel.requestHint()
        XCTAssertEqual(flow.finishChallenge()?.decision, .granted)

        // The timed window opened through the manager and dismissed the
        // challenge, exactly as the one-question surface does.
        XCTAssertFalse(flow.isShieldPresented)
        XCTAssertEqual(flow.presentationEvents, [.presented, .dismissed])
        XCTAssertGreaterThan(flow.remainingUnlockTime, 0)
        XCTAssertFalse(backend.currentShieldConfiguration.shieldedApplications.contains(Self.game))
        XCTAssertEqual(backend.managedSettingsCallCount, 0)
    }

    @MainActor
    func testDeniedRetryKeepsEffort() {
        let (flow, _) = makeFlow()
        let (_, _, viewModel) = makeChallenge(flow: flow)

        viewModel.startIfNeeded()
        viewModel.draft = "54"
        viewModel.submitDraft()
        XCTAssertEqual(flow.finishChallenge()?.decision, .denied)

        // The denial kept the recorded effort in the same session.
        let sessionId = flow.decisionSessionId
        XCTAssertEqual(flow.currentEffortSignals().genuineAttempts, 1)
        XCTAssertEqual(flow.currentEffortSignals().hintInteractions, 0)

        // Retry builds on the kept effort: one more attempt + 2 hints.
        viewModel.draft = "56"
        viewModel.submitDraft()
        viewModel.requestHint()
        viewModel.requestHint()
        XCTAssertEqual(flow.finishChallenge()?.decision, .granted)
        XCTAssertEqual(flow.decisionSessionId, sessionId)
        XCTAssertFalse(flow.isShieldPresented)
    }

    // MARK: - Blocked targets

    @MainActor
    func testBlockedTargetOpensNoChallenge() async {
        let store = PolicyStore(directory: directory)
        let backend = SimulatedShieldBackend()
        let manager = ShieldManager(
            policyStore: store,
            enumeration: .empty,
            backend: backend,
            unlockStore: FileUnlockWindowStore(directory: directory)
        )
        let setupFlow = SetupFlow(
            policyStore: store,
            shieldManager: manager,
            enumerationStore: FileSetupEnumerationStore(directory: directory),
            authorized: false
        )
        let viewModel = SetupFlowViewModel(
            flow: setupFlow,
            policyStore: store,
            backend: backend,
            authService: SimulatedSetupAuthorizationService(),
            tokenStore: SetupTokenStore(directory: directory)
        )
        await viewModel.requestAuthorization()
        viewModel.simulatedAppIDs = [SimulatedSetupCatalog.apps[0].id]
        viewModel.continueFromEnumeration()
        viewModel.setAllChoices(.blocked)
        viewModel.continueFromSelection()
        viewModel.finishSetup()
        XCTAssertEqual(viewModel.step, .complete)

        // The default Blocked choice offers no challenge on any entry path.
        let game = SimulatedSetupCatalog.apps[0]
        XCTAssertTrue(viewModel.isInstalledShieldBlocked(game.ref))
        XCTAssertNil(viewModel.installedShieldFlow(for: game.ref, category: game.category.ref))
        XCTAssertNil(viewModel.selectInstalledShieldApp(game.id))
    }

    // MARK: - One recorder call per interaction type

    @MainActor
    func testAnswerRecordsGenuineAttempt() {
        let (flow, _) = makeFlow()
        let (fake, engine, _) = makeChallenge(flow: flow)

        _ = engine.startSession()
        _ = engine.submitAnswer("54")

        XCTAssertEqual(fake.submitted, ["54"])
        let signals = flow.currentEffortSignals()
        XCTAssertEqual(signals.genuineAttempts, 1)
        XCTAssertEqual(signals.hintInteractions, 0)
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.answerRevisions, 0)
        XCTAssertEqual(signals.explanations, 0)
    }

    @MainActor
    func testDeliveredHintRecordsHintInteraction() {
        let (flow, _) = makeFlow()
        let (fake, engine, _) = makeChallenge(flow: flow)

        _ = engine.startSession()
        _ = engine.requestHint()

        XCTAssertEqual(fake.hintTaps, 1)
        XCTAssertEqual(flow.currentEffortSignals().hintInteractions, 1)
        XCTAssertEqual(flow.currentEffortSignals().genuineAttempts, 0)
    }

    @MainActor
    func testExhaustedHintRecordsNothing() {
        let (flow, _) = makeFlow()
        let fake = FakeChatEngine()
        fake.hintsRemaining = 0
        let engine = InstalledShieldChatEngine(inner: fake, flow: flow)

        _ = engine.startSession()
        let update = engine.requestHint()

        XCTAssertEqual(fake.hintTaps, 1)
        XCTAssertTrue(update.turns.isEmpty)
        XCTAssertEqual(flow.currentEffortSignals().hintInteractions, 0)
    }

    @MainActor
    func testHintListenRecordsHintInteraction() {
        let (flow, _) = makeFlow()
        let (_, engine, _) = makeChallenge(flow: flow)

        let sink = try? XCTUnwrap(engine.currentHintListenSink)
        sink?.recordHintListen(HintListenEvent(
            messageID: "h1", messageText: "Try counting by 7s.",
            emittedAt: Date()))

        XCTAssertEqual(flow.currentEffortSignals().hintInteractions, 1)
        XCTAssertEqual(flow.currentEffortSignals().genuineAttempts, 0)
    }

    @MainActor
    func testProbeReplyRecordsFollowUpAndExplanation() {
        let (flow, _) = makeFlow()
        let fake = FakeChatEngine()
        fake.probeOnSubmit = 1
        let engine = InstalledShieldChatEngine(inner: fake, flow: flow)

        _ = engine.startSession()
        _ = engine.submitAnswer("54")
        // The probe reply is a follow-up + explanation, never an attempt.
        _ = engine.submitAnswer("I multiplied 7 by 8 step by step")

        let signals = flow.currentEffortSignals()
        XCTAssertEqual(signals.genuineAttempts, 1)
        XCTAssertEqual(signals.followUpInteractions, 1)
        XCTAssertEqual(signals.explanations, 1)
        XCTAssertEqual(signals.answerRevisions, 0)
    }

    @MainActor
    func testNonSubstantiveProbeReplyRecordsTimingOnly() {
        let (flow, _) = makeFlow()
        let fake = FakeChatEngine()
        fake.probeOnSubmit = 1
        let engine = InstalledShieldChatEngine(inner: fake, flow: flow)

        _ = engine.startSession()
        _ = engine.submitAnswer("54")
        _ = engine.submitAnswer("...")

        // Punctuation-only: no follow-up, no explanation, no attempt.
        let signals = flow.currentEffortSignals()
        XCTAssertEqual(signals.genuineAttempts, 1)
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.explanations, 0)
    }

    @MainActor
    func testRevisionSubmitRecordsRevision() {
        let (flow, _) = makeFlow()
        let fake = FakeChatEngine()
        fake.revisionOnSubmit = [2]
        let engine = InstalledShieldChatEngine(inner: fake, flow: flow)

        _ = engine.startSession()
        _ = engine.submitAnswer("54")
        _ = engine.submitAnswer("56")

        let signals = flow.currentEffortSignals()
        XCTAssertEqual(signals.genuineAttempts, 2)
        XCTAssertEqual(signals.answerRevisions, 1)
    }

    @MainActor
    func testComposerActivityRecordsTimingOnly() {
        let (flow, _) = makeFlow()
        let (fake, engine, _) = makeChallenge(flow: flow)

        _ = engine.startSession()
        engine.recordComposerActivity()
        engine.recordComposerActivity()
        engine.recordComposerActivity()

        // Forwarded to the inner engine; no countable effort anywhere.
        XCTAssertEqual(fake.composerActivityCount, 3)
        let signals = flow.currentEffortSignals()
        XCTAssertEqual(signals.genuineAttempts, 0)
        XCTAssertEqual(signals.hintInteractions, 0)
        XCTAssertEqual(signals.followUpInteractions, 0)
        XCTAssertEqual(signals.answerRevisions, 0)
        XCTAssertEqual(signals.explanations, 0)
    }

    @MainActor
    func testInteractionAnchorsActiveTime() {
        let (flow, _) = makeFlow()

        // Four anchors 20s apart: 3 full idle-pause windows = 1 minute.
        let base = Date()
        for step in 0..<4 {
            flow.recordInteraction(at: base.addingTimeInterval(TimeInterval(step) * 20))
        }

        XCTAssertEqual(
            flow.currentEffortSignals(at: base.addingTimeInterval(60)).activeMinutes, 1)
    }

    // MARK: - Challenge surface

    @MainActor
    func testChallengeSurfaceShowsSimulatedBadgeAndChat() {
        let (flow, _) = makeFlow()
        let view = InstalledShieldChatChallengeView(
            flow: flow,
            theme: DesignSystem.defaultTheme,
            engine: InstalledShieldChatEngine(inner: FakeChatEngine(), flow: flow))

        let rendered = renderedText(for: view)
        XCTAssertTrue(
            rendered.contains("SIMULATED SHIELD"),
            "challenge must carry the simulated badge; rendered:\n\(rendered)")
        XCTAssertTrue(
            rendered.contains("Hint") && rendered.contains("Send"),
            "challenge must present the chat composer; rendered:\n\(rendered)")
        XCTAssertTrue(
            rendered.contains("Finish"),
            "challenge must offer the finish boundary; rendered:\n\(rendered)")
    }
}
