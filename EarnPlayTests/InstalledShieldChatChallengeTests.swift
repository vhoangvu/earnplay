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

    /// Hosts a view in a window and returns its OCR'd visible text
    /// (the `ThemeContrastFix2Tests` pattern). Defaults to the tall
    /// portrait window; the short-height test passes phone landscape
    /// dimensions with a compact vertical class (the challenge reads
    /// the size class, not the height, so the class is set explicitly
    /// rather than inherited from the portrait simulator).
    @MainActor
    private func renderedText<Content: View>(
        for view: Content,
        width: CGFloat = 390,
        height: CGFloat = 1500,
        verticalSizeClass: UserInterfaceSizeClass = .regular
    ) -> String {
        let host = UIHostingController(
            rootView: view.environment(\.verticalSizeClass, verticalSizeClass))
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        win.rootViewController = host
        win.makeKeyAndVisible()
        return ocrText(of: host.view)
    }

    /// OCR'd visible text of an already-mounted view (round 3): the
    /// portrait-keyboard test snapshots its live window — with the
    /// composer focused and across resizes — rather than a fresh one.
    @MainActor
    private func ocrText(of view: UIView) -> String {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
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

    // MARK: - Flow replacement mid-challenge (PR #92 fix round 1)

    @MainActor
    private func makeSetupViewModel(backend: SimulatedShieldBackend) -> SetupFlowViewModel {
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
            authorized: false
        )
        return SetupFlowViewModel(
            flow: flow,
            policyStore: store,
            backend: backend,
            authService: SimulatedSetupAuthorizationService(),
            tokenStore: SetupTokenStore(directory: directory)
        )
    }

    @MainActor
    private func completeForcedSetup(
        appIDs: Set<String>,
        choice: SetupFlowViewModel.AppChoice = .unblockable
    ) async -> SetupFlowViewModel {
        let viewModel = makeSetupViewModel(backend: SimulatedShieldBackend())
        await viewModel.requestAuthorization()
        viewModel.simulatedAppIDs = appIDs
        viewModel.simulatedCategoryIDs = []
        viewModel.continueFromEnumeration()
        viewModel.setAllChoices(choice)
        viewModel.continueFromSelection()
        viewModel.finishSetup()
        XCTAssertEqual(viewModel.step, .complete)
        return viewModel
    }

    // MARK: - Mounted flow replacement (PR #92 fix round 2, finding 2)
    //
    // Round 3, finding 2: the earlier `testFlowReplacedMidChallengeScoresReplacementSession`
    // built fresh chat models via `makeChallenge(flow:)` for both flows and never mounted the
    // cover, so it could not catch the stale-@StateObject regression. It was removed because
    // `testMountedFlowReplacementRoutesEffortToReplacement` covers every assertion it made —
    // pre-swap 1 attempt in the old session; post-swap 5 attempts + 3 hints = 16 in the
    // replacement; old denies on finish; replacement grants, opens the window (`isShieldPresented`
    // asserted explicitly post-swap), and shows the granted decision text — all submitted and
    // finished through the same mounted cover surface.

    /// Holder so the test can swap the mounted cover host's flow
    /// mid-challenge, mirroring the production panel re-reading
    /// `installedShieldFlow` after a policy refresh.
    private final class MountedFlowHolder: ObservableObject {
        @Published var flow: SimulatedShieldFlow
        init(_ flow: SimulatedShieldFlow) { self.flow = flow }
    }

    private struct MountedSwapRoot: View {
        @ObservedObject var holder: MountedFlowHolder
        var makeEngine: (SimulatedShieldFlow) -> any ChatTutorEngine
        var onMount: (ChatConversationViewModel, SimulatedShieldFlow) -> Void

        var body: some View {
            InstalledShieldChatCoverHost(
                flow: holder.flow,
                makeEngine: makeEngine,
                onChatModelMount: onMount
            )
        }
    }

    /// Spins the runloop until `condition` holds or `timeout` lapses.
    @MainActor
    private func spinUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
    }

    @MainActor
    private func pumpCover(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        view.layoutIfNeeded()
    }

    /// The mounted challenge's composer field (the round-2 probe proved
    /// `insertText` on this rendered field drives the live model's draft
    /// binding). Rendered SwiftUI buttons materialize no tappable views
    /// in this host (probed census: no `UIControl`, no accessibility
    /// elements), so submits, hints, and Finish go through the mounted
    /// surface's own live model and flow — the exact methods its Send,
    /// Hint, and Finish buttons call, on the exact instances they own.
    @MainActor
    private func mountedComposerField(in root: UIView) -> UITextView? {
        var found: [UITextView] = []
        func walk(_ v: UIView) {
            if let field = v as? UITextView { found.append(field) }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard found.count == 1 else { return nil }
        return found.first
    }

    /// Types one answer through the RENDERED composer field of the
    /// mounted surface and submits it through the surface's live model
    /// (`submitDraft`, Send's own action). Returns false when the cover
    /// or field is missing, or the draft binding never lands.
    @MainActor
    private func submitAnswerThroughSurface(
        _ text: String,
        host: UIHostingController<MountedSwapRoot>,
        model: ChatConversationViewModel
    ) -> Bool {
        guard let cover = host.presentedViewController?.view else { return false }
        pumpCover(cover)
        guard let field = mountedComposerField(in: cover) else { return false }
        field.selectAll(nil)
        field.insertText(text)
        guard spinUntil(timeout: 3, { model.draft == text }) else { return false }
        model.submitDraft()
        pumpCover(cover)
        return true
    }

    /// The cover stays presented while its flow is replaced; post-
    /// replacement chat effort submitted through the mounted surface
    /// records ONLY into the replacement session, and finishing
    /// through the surface grants and opens the unlock window on the
    /// replacement. Fails when the `.id(ObjectIdentifier(flow))`
    /// keying is removed: the stale model keeps recording into the
    /// discarded session, so the replacement stays empty and denies.
    @MainActor
    func testMountedFlowReplacementRoutesEffortToReplacement() async {
        let game = SimulatedSetupCatalog.apps[0]
        let viewModel = await completeForcedSetup(appIDs: [game.id])
        guard let oldFlow = viewModel.installedShieldFlow(
            for: game.ref, category: game.category.ref
        ) else {
            return XCTFail("expected a cached installed flow for the picked app")
        }
        XCTAssertTrue(oldFlow.isShieldPresented)

        // One fake-backed engine per flow, first wins: the challenge
        // view `init` (and so the factory) also runs for identities
        // whose `@StateObject` is then discarded, but the mounted
        // identity always keeps the first-built engine.
        var fakesByFlow: [ObjectIdentifier: FakeChatEngine] = [:]
        let factory: (SimulatedShieldFlow) -> any ChatTutorEngine = { flow in
            let id = ObjectIdentifier(flow)
            if let existing = fakesByFlow[id] {
                return InstalledShieldChatEngine(inner: existing, flow: flow)
            }
            let fake = FakeChatEngine()
            fakesByFlow[id] = fake
            return InstalledShieldChatEngine(inner: fake, flow: flow)
        }
        // Mount-time reports only: these always name the identity the
        // surface actually uses — never a discarded speculative init.
        var mounts: [(model: ChatConversationViewModel, flow: SimulatedShieldFlow)] = []
        let holder = MountedFlowHolder(oldFlow)
        let root = MountedSwapRoot(holder: holder, makeEngine: factory) { model, flow in
            if mounts.last?.model !== model {
                mounts.append((model, flow))
            }
        }
        let host = UIHostingController(rootView: root)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = host
        win.makeKeyAndVisible()
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }

        guard spinUntil(timeout: 5, { mounts.count >= 1 }) else {
            return XCTFail("the mounted challenge never reported its live model")
        }
        guard let firstMount = mounts.first, firstMount.flow === oldFlow else {
            return XCTFail("the mounted challenge must start bound to the presented flow")
        }
        guard spinUntil(timeout: 5, { firstMount.model.messages.count >= 1 }) else {
            return XCTFail("the mounted chat never started its session")
        }

        // Pre-replacement effort through the mounted surface: one
        // answer recorded into the OLD session.
        XCTAssertTrue(
            submitAnswerThroughSurface("54", host: host, model: firstMount.model),
            "typing + submitting through the mounted surface must work")
        XCTAssertEqual(oldFlow.currentEffortSignals().genuineAttempts, 1)
        XCTAssertEqual(fakesByFlow[ObjectIdentifier(oldFlow)]?.submitted, ["54"])

        // Policy refresh mid-challenge: version moves, the cache is
        // reconciled, and the next lookup builds a replacement flow —
        // which the mounted surface adopts with its cover still up.
        let syncStore = PolicyStore(directory: directory)
        var updated = syncStore.currentPolicy
        updated.version += 1
        XCTAssertEqual(syncStore.apply(updated), .applied)
        viewModel.refreshInstalledPolicyFromDisk()
        guard let newFlow = viewModel.installedShieldFlow(
            for: game.ref, category: game.category.ref
        ) else {
            return XCTFail("expected a replacement installed flow after the refresh")
        }
        XCTAssertFalse(
            newFlow === oldFlow,
            "a policy version move must replace the cached installed flow")
        XCTAssertTrue(
            newFlow.isShieldPresented,
            "the cover stays up over the replacement flow")
        XCTAssertEqual(newFlow.currentEffortSignals().genuineAttempts, 0)
        XCTAssertEqual(newFlow.currentEffortSignals().hintInteractions, 0)
        holder.flow = newFlow
        XCTAssertNotNil(
            host.presentedViewController,
            "the cover must stay presented across the flow replacement")

        // The `.id` keying remounts the challenge onto the replacement.
        // Without it this is the stale pre-replacement model — and the
        // effort assertions below fail (the mutation check) — so the
        // test proceeds with the surface's CURRENT model either way.
        // Each spin iteration also lays out the host and cover, as a
        // real screen does every frame: in this headless window the
        // presentation update only commits on a layout pass.
        let remounted = spinUntil(timeout: 5) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            host.presentedViewController?.view.setNeedsLayout()
            host.presentedViewController?.view.layoutIfNeeded()
            return mounts.contains { $0.flow === newFlow }
        }
        XCTAssertTrue(
            remounted,
            "replacing the flow must remount the mounted challenge (the `.id` keying)")
        guard let live = mounts.last else {
            return XCTFail("the mounted challenge lost its live model")
        }
        guard spinUntil(timeout: 5, { live.model.messages.count >= 1 }) else {
            return XCTFail("the remounted chat never started its session")
        }

        // Post-replacement effort through the mounted surface: 5
        // answers + 3 hints = 16, clearing any 8...14 threshold draw.
        for answer in ["7", "14", "21", "28", "35"] {
            XCTAssertTrue(
                submitAnswerThroughSurface(answer, host: host, model: live.model),
                "typing + submitting through the remounted surface must work")
        }
        live.model.requestHint()
        live.model.requestHint()
        live.model.requestHint()

        // ONLY the replacement session receives the new effort.
        XCTAssertEqual(newFlow.currentEffortSignals().genuineAttempts, 5)
        XCTAssertEqual(newFlow.currentEffortSignals().hintInteractions, 3)
        XCTAssertEqual(
            fakesByFlow[ObjectIdentifier(newFlow)]?.submitted,
            ["7", "14", "21", "28", "35"])
        XCTAssertEqual(oldFlow.currentEffortSignals().genuineAttempts, 1)
        XCTAssertEqual(oldFlow.currentEffortSignals().hintInteractions, 0)
        XCTAssertEqual(fakesByFlow[ObjectIdentifier(oldFlow)]?.submitted, ["54"])

        // Finishing through the mounted surface (its live flow, the
        // Finish button's own target) grants ONLY the replacement
        // session and opens its unlock window.
        let score = live.flow.finishChallenge()
        XCTAssertEqual(score?.decision, .granted)
        XCTAssertEqual(score?.score, 16)
        XCTAssertTrue(score?.floorMet ?? false)
        XCTAssertFalse(newFlow.isShieldPresented)
        XCTAssertGreaterThan(newFlow.remainingUnlockTime, 0)
        XCTAssertEqual(
            newFlow.challengeDecisionText,
            SimulatedShieldFlow.unlockGrantedText)
        XCTAssertTrue(
            oldFlow.isShieldPresented,
            "the discarded session must not open an unlock window")
        XCTAssertEqual(oldFlow.remainingUnlockTime, 0)

        // The discarded session keeps only its own effort: finishing it
        // denies (one attempt, no hint leg).
        XCTAssertEqual(oldFlow.finishChallenge()?.decision, .denied)

        // The grant dismisses the mounted cover. Yield via Task.sleep
        // (letting the main actor process the dismissal) rather than
        // spinning the runloop, which starves it in this headless host.
        var dismissed = false
        for _ in 0..<50 where !dismissed {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if host.presentedViewController == nil {
                dismissed = true
            } else {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        XCTAssertTrue(dismissed, "the grant must dismiss the mounted challenge cover")
    }

    // MARK: - Challenge surface

    @MainActor
    func testChallengeSurfaceShowsSimulatedBadgeAndChat() {
        let (flow, _) = makeFlow()
        let view = InstalledShieldChatChallengeView(
            flow: flow,
            theme: DesignSystem.defaultTheme,
            makeEngine: { flow in InstalledShieldChatEngine(inner: FakeChatEngine(), flow: flow) })

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

    // MARK: - Short-height layout (PR #92 fix round 2, finding 1)

    /// Short landscape phones: at 844×390 with the PRODUCTION engine
    /// (whose first question renders the three-row number pad), the
    /// simulated badge and the Finish action stay visible — reachable
    /// with no scrolling in the non-dismissible challenge.
    @MainActor
    func testShortLandscapeKeepsBadgeAndFinishVisible() {
        let (flow, _) = makeFlow()
        let view = InstalledShieldChatChallengeView(
            flow: flow, theme: DesignSystem.defaultTheme)

        let rendered = renderedText(
            for: view, width: 844, height: 390, verticalSizeClass: .compact)
        XCTAssertTrue(
            rendered.contains("SIMULATED SHIELD"),
            "badge must stay visible at short heights; rendered:\n\(rendered)")
        XCTAssertTrue(
            rendered.contains("Finish"),
            "Finish must stay reachable at short heights; rendered:\n\(rendered)")
        XCTAssertTrue(
            rendered.contains("Hint") && rendered.contains("Send"),
            "chat composer must stay usable at short heights; rendered:\n\(rendered)")
    }

    /// Portrait behavior is unchanged: at the exact 390×844 phone
    /// portrait size the badge, chat, and Finish action all render.
    @MainActor
    func testPortraitKeepsBadgeChatAndFinish() {
        let (flow, _) = makeFlow()
        let view = InstalledShieldChatChallengeView(
            flow: flow, theme: DesignSystem.defaultTheme)

        let rendered = renderedText(for: view, width: 390, height: 844)
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

    // MARK: - Portrait keyboard (PR #92 fix round 3, finding 1)

    /// Portrait phone with the software keyboard open: at 390x844 with
    /// the PRODUCTION engine, focusing the composer keeps the regular
    /// stacked layout — badge, chat, and Finish stay reachable — and
    /// the composer keeps focus and identity. Shrinking the hosted
    /// view to a keyboard-reduced height below 500pt (the finding's
    /// premise: the keyboard steals the space; the window stays
    /// full-size, as with a real keyboard window) must STILL stay
    /// regular — no 280pt sidebar on a 390pt phone — with the focused
    /// composer subtree surviving; restoring the height (keyboard
    /// closed) keeps the same composer. Fails on the round-2 layout,
    /// which flips to compact below 500pt and replaces the composer
    /// (focus lost, the field instance replaced).
    @MainActor
    func testPortraitKeyboardKeepsLayoutAndComposerFocus() {
        let (flow, _) = makeFlow()
        var liveModel: ChatConversationViewModel?
        let view = InstalledShieldChatChallengeView(
            flow: flow,
            theme: DesignSystem.defaultTheme,
            onChatModelMount: { model, _ in liveModel = model })
            .environment(\.verticalSizeClass, .regular)
        let host = UIHostingController(rootView: view)
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.rootViewController = host
        win.makeKeyAndVisible()
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }

        let composerAppeared = spinUntil(timeout: 5) {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return mountedComposerField(in: host.view) != nil
        }
        guard composerAppeared else {
            return XCTFail("the mounted portrait challenge never rendered its composer")
        }
        guard let field = mountedComposerField(in: host.view) else {
            return XCTFail("the mounted portrait challenge lost its composer")
        }
        guard let model = liveModel else {
            return XCTFail("the mounted challenge never reported its live model")
        }
        guard spinUntil(timeout: 5, { model.messages.count >= 1 }) else {
            return XCTFail("the mounted chat never started its session")
        }

        // Open the portrait keyboard: focus the rendered composer.
        XCTAssertTrue(field.becomeFirstResponder(), "focusing the composer must work")
        XCTAssertTrue(
            spinUntil(timeout: 5, { field.isFirstResponder }),
            "the composer must hold focus with the portrait keyboard open")

        // Typing through the focused field drives the live model's draft.
        field.selectAll(nil)
        field.insertText("56")
        XCTAssertTrue(
            spinUntil(timeout: 3, { model.draft == "56" }),
            "the focused composer must stay bound to the live model")

        // Badge, chat, and Finish stay reachable with the keyboard open.
        let open = ocrText(of: host.view)
        XCTAssertTrue(
            open.contains("SIMULATED SHIELD"),
            "badge must stay visible with the keyboard open; rendered:\n\(open)")
        XCTAssertTrue(
            open.contains("Hint") && open.contains("Send"),
            "chat composer must stay usable with the keyboard open; rendered:\n\(open)")
        XCTAssertTrue(
            open.contains("Finish"),
            "Finish must stay reachable with the keyboard open; rendered:\n\(open)")

        // Keyboard-reduced container height (below 500pt on the 390pt
        // phone): the layout must stay regular and the focused
        // composer must survive with its draft binding intact.
        host.view.autoresizingMask = []
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 499)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.view.layoutIfNeeded()

        guard let sameField = mountedComposerField(in: host.view) else {
            return XCTFail("the keyboard-reduced height removed the composer")
        }
        XCTAssertTrue(
            sameField === field,
            "the composer subtree must survive a keyboard-driven height change (no subtree replacement)")
        // Shrinking the hosted view transiently resigns first responder
        // (UIKit re-seats the field on geometry changes even though the
        // instance survives — the identity assertion above proves no
        // subtree replacement happened). A real keyboard never resizes
        // the hosted view, so production keeps focus; here the same
        // field simply refocuses.
        XCTAssertTrue(
            field.becomeFirstResponder(),
            "the surviving composer must refocus after the height change")
        XCTAssertTrue(
            spinUntil(timeout: 3, { field.isFirstResponder }),
            "the surviving composer must hold focus after refocusing")
        field.selectAll(nil)
        field.insertText("42")
        XCTAssertTrue(
            spinUntil(timeout: 3, { model.draft == "42" }),
            "the composer draft binding must survive a keyboard-driven height change")

        // The badge stays rendered at the reduced height. (The Hint/Send
        // row cannot fit a 499pt window in ANY stacked layout — the
        // fixed chrome exceeds it — so it is not asserted here;
        // production keeps the full 844pt window with the keyboard
        // avoiding over it, and the open phase above proves badge, chat,
        // and Finish all reachable with the keyboard open at full size.)
        let reduced = ocrText(of: host.view)
        XCTAssertTrue(
            reduced.contains("SIMULATED SHIELD"),
            "badge must stay visible at the keyboard-reduced height; rendered:\n\(reduced)")

        // Keyboard closed (full height restored): the regular layout
        // and the same composer survive the round trip.
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        host.view.layoutIfNeeded()

        XCTAssertTrue(
            mountedComposerField(in: host.view) === field,
            "the composer subtree must survive the keyboard open/close round trip")
        field.selectAll(nil)
        field.insertText("7")
        XCTAssertTrue(
            spinUntil(timeout: 3, { model.draft == "7" }),
            "the composer draft binding must survive the keyboard open/close round trip")

        let closed = ocrText(of: host.view)
        XCTAssertTrue(
            closed.contains("SIMULATED SHIELD"),
            "badge must stay visible after the keyboard closes; rendered:\n\(closed)")
        XCTAssertTrue(
            closed.contains("Hint") && closed.contains("Send"),
            "chat composer must stay usable after the keyboard closes; rendered:\n\(closed)")
        XCTAssertTrue(
            closed.contains("Finish"),
            "Finish must stay reachable after the keyboard closes; rendered:\n\(closed)")
    }

    /// Decision table: compact only with a compact vertical class AND
    /// enough width. The table takes NO height — a 390pt-wide portrait
    /// phone never takes the 280pt sidebar, however short a
    /// keyboard-reduced height gets; short landscape keeps the round-2
    /// sidebar; regular-class layouts (portrait, iPad) stay stacked.
    @MainActor
    func testCompactLayoutDecisionTable() {
        // Regular vertical class (portrait phones, all iPads): regular
        // at every width — height never enters the decision.
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .regular, width: 390))
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .regular, width: 844))
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .regular, width: 1024))
        // Unset class: regular (fail closed, never the sidebar).
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: nil, width: 844))
        // Short landscape phones: compact (round-2 behavior kept).
        XCTAssertTrue(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .compact, width: 844))
        XCTAssertTrue(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .compact, width: 667))
        // Width gate: narrow containers never take the sidebar, even
        // with a compact vertical class.
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .compact, width: 390))
        XCTAssertFalse(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .compact, width: 599))
        XCTAssertTrue(InstalledShieldChatChallengeView.useCompactLayout(
            verticalSizeClass: .compact, width: 600))
    }
}
