import Foundation
#if canImport(Combine)
import Combine
#endif

/// Presentation transitions of the simulated shield screen, in order.
/// A re-presented shield is a second `.presented`: the required
/// present/dismiss/re-present sequence asserts as
/// `[.presented, .dismissed, .presented]`.
public enum SimulatedShieldPresentationEvent: String, Equatable, Sendable {
    case presented
    case dismissed
}

/// Simulated shield flow (T2.4) — drives the in-app shield screen that
/// stands in for real ManagedSettings shields when the distribution
/// entitlement is unavailable.
///
/// The flow builds on the T2.2 interface without duplicating it:
/// shielding and the timed unlock window come from `ShieldManager`
/// (fronting a `SimulatedShieldBackend`), and the challenge gate is the
/// real Epic 1 path — attempts and hint interactions record into an
/// `EffortSessionRecorder`, the session-decision boundary
/// `EffortSessionRecorder.evaluateAndLog` persists the grant/deny
/// Decision, and only a granted score calls `grantUnlock`. Correctness
/// is never an input (per the `EffortScoring` contract): any non-blank
/// submitted answer is a genuine attempt.
///
/// Log-before-effect: the Decision is persisted before the unlock is
/// applied. When the log write fails, no score returns, no unlock is
/// applied, and the shield stays up with a retryable error — the same
/// keep-effort-for-retry behavior as a denial or a refused grant.
///
/// Presentation rule: the shield is presented if and only if simulated
/// mode is forced on AND the manager reports the app shielded. Expiry
/// re-presents through `tick()`, which the view calls on a timer; tests
/// call it directly after advancing a fake clock.
///
/// Honesty: consumers must render `simulatedBadgeText` while presented
/// so a demo audience is never misled into thinking a real system
/// shield fired. This flow makes zero ManagedSettings calls (see
/// `managedSettingsCallCount`); real-shield enforcement needs the T0.4
/// entitlement (v1, not filed).
@MainActor
public final class SimulatedShieldFlow: ObservableObject {
    /// On-screen label, rendered by the shield view while presented.
    public nonisolated static let simulatedBadgeText = "SIMULATED SHIELD — DEMO ONLY, NOT REAL ENFORCEMENT"

    private let manager: ShieldManager
    private let backend: SimulatedShieldBackend
    private var scorer: EffortScorer
    private var recorder: EffortSessionRecorder
    /// Demo-scoped decision log: the same isolated directory as the
    /// demo policy/window store (never production logging).
    private let decisionLogger: DecisionLogger

    /// The demo app this flow guards.
    public let app: AppRef
    public let category: AppCategoryRef?
    /// Unlock seconds granted by a passed challenge (short in tests).
    public let unlockDuration: TimeInterval
    /// The forced-simulated-mode flag value this flow runs under.
    public let isSimulatedMode: Bool
    /// The practice prompt shown on the shield screen. Served from the
    /// pre-verified fallback bank, which only holds solver-verified
    /// entries; the fallback is the same hand-written text.
    public let challengePrompt: String
    /// Static hint revealed by the shield screen's hint button.
    public let challengeHint: String

    /// True while the shield screen must block the app view.
    @Published public private(set) var isShieldPresented: Bool = false
    /// Remaining unlock seconds on the manager's monotonic clock.
    @Published public private(set) var remainingUnlockTime: TimeInterval = 0
    /// The most recent challenge score, if the last finish logged a decision.
    @Published public private(set) var lastScore: EffortScore?
    /// The persisted Decision for the most recent finished challenge, if logged.
    @Published public private(set) var lastDecision: Decision?
    /// The log-write failure from the most recent finish, if logging failed.
    /// Set only when no Decision was persisted (and no unlock applied);
    /// cleared by the next logged finish or a fresh challenge session.
    @Published public private(set) var lastLogError: DecisionLogError?
    /// Live policy source for finish-time revalidation (issue #87 fix
    /// round 4): when set with `followsLiveFloor` / `followsLiveDuration`,
    /// `finishChallenge` scores against the CURRENT effort floor and
    /// grants with the CURRENT practice duration instead of the
    /// retained construction-time settings — so a stricter policy
    /// arriving before a retained challenge finishes cannot grant under
    /// superseded settings. Nil keeps the legacy retained behavior
    /// (demo flows, unit-test fixtures with injected short windows).
    private let policyStore: PolicyStore?
    /// True when scoring follows the live policy floor (the installed
    /// default scorer); an explicitly injected scorer keeps its own
    /// floor (fix round 2 contract).
    private let followsLiveFloor: Bool
    /// True when the grant follows the live policy duration (the
    /// installed default window); an explicitly injected duration is
    /// kept as-is.
    private let followsLiveDuration: Bool
    /// Demo session context for the decision log: rotated on every fresh
    /// challenge session, kept across denied/refused/failed retries.
    public private(set) var decisionSessionId: String
    /// Unlock minutes recorded in the Decision outcome. Defaults from
    /// `unlockDuration` (rounded up, minimum 1); the demo passes the
    /// policy practice minutes explicitly so the record matches the window.
    public let decisionDurationMinutes: Int
    /// Decision lines rendered by the shield screen.
    public nonisolated static let unlockGrantedText = "Granted — unlock window open (simulated)."
    public nonisolated static let unlockGrantFailedText = "Effort passed but the unlock failed — try again."
    public nonisolated static let unlockDeniedText = "Denied — keep practicing to earn the unlock."
    public nonisolated static let unlockLogFailedText = "Couldn't save the unlock decision — try again."

    /// The decision line for the shield screen, or nil before the first
    /// finish. A log-write failure reports a retryable error (no score
    /// exists to report). Otherwise a granted score reports an open
    /// window only when the shield actually dismissed; a granted score
    /// with the shield still up (the manager refused the grant) reports
    /// a retryable failure instead of claiming an open window.
    public var challengeDecisionText: String? {
        if lastLogError != nil { return Self.unlockLogFailedText }
        guard let score = lastScore else { return nil }
        switch score.decision {
        case .granted:
            return isShieldPresented ? Self.unlockGrantFailedText : Self.unlockGrantedText
        case .denied:
            return Self.unlockDeniedText
        }
    }
    /// Presentation transitions in order (see `SimulatedShieldPresentationEvent`).
    public private(set) var presentationEvents: [SimulatedShieldPresentationEvent] = []

    /// Real ManagedSettings calls made on this flow's path. Always zero.
    public var managedSettingsCallCount: Int { backend.managedSettingsCallCount }

    public init(
        manager: ShieldManager,
        backend: SimulatedShieldBackend,
        app: AppRef,
        category: AppCategoryRef? = nil,
        scorer: EffortScorer,
        recorder: EffortSessionRecorder,
        unlockDuration: TimeInterval,
        isSimulatedMode: Bool,
        decisionLogger: DecisionLogger,
        decisionSessionId: String = UUID().uuidString,
        decisionDurationMinutes: Int? = nil,
        policyStore: PolicyStore? = nil,
        followsLiveFloor: Bool = false,
        followsLiveDuration: Bool = false
    ) {
        self.manager = manager
        self.backend = backend
        self.app = app
        self.category = category
        self.scorer = scorer
        self.recorder = recorder
        self.unlockDuration = unlockDuration
        self.isSimulatedMode = isSimulatedMode
        self.decisionLogger = decisionLogger
        self.policyStore = policyStore
        self.followsLiveFloor = followsLiveFloor
        self.followsLiveDuration = followsLiveDuration
        self.decisionSessionId = decisionSessionId
        self.decisionDurationMinutes = decisionDurationMinutes
            ?? max(1, Int(ceil(unlockDuration / 60)))
        let bankPrompt = FallbackQuestionBank.demo.proposal(
            for: .multiplicationFacts, rotationIndex: 0
        )?.promptText
        self.challengePrompt = bankPrompt ?? Self.fallbackPrompt
        self.challengeHint = Self.demoHint
        manager.refresh()
        let presented = isSimulatedMode && manager.isShielded(app: app, category: category)
        self.isShieldPresented = presented
        self.remainingUnlockTime = manager.remainingUnlockTime
        if presented { presentationEvents = [.presented] }
    }

    /// Submits one answer. A non-blank answer records a genuine attempt;
    /// a blank submit records only an interaction (never effort).
    public func submitAttempt(answer: String) {
        let genuine = !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        recorder.recordAttempt(isGenuine: genuine)
    }

    /// Records one hint interaction (the view reveals `challengeHint`).
    public func useHint() {
        recorder.recordHintInteraction()
    }

    /// Records an answer-field edit as interaction only — the same
    /// recorder path as a blank submit. Typing keeps active time
    /// running but never scores as an attempt. A blank edit records
    /// nothing, so clearing the field grants no effort.
    public func recordAnswerEdit(answer: String) {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recorder.recordInteraction()
    }

    /// Records one follow-up interaction from the chat challenge (the
    /// child's reply to a tutor probe). One explicit recorder call per
    /// chat interaction type (issue #91): the challenge wrapper calls
    /// this, never the recorder directly.
    public func recordFollowUpInteraction(at date: Date? = nil) {
        recorder.recordFollowUpInteraction(at: date)
    }

    /// Records one answer revision from the chat challenge (a submission
    /// the engine labels a revision of an earlier answer).
    public func recordAnswerRevision(at date: Date? = nil) {
        recorder.recordAnswerRevision(at: date)
    }

    /// Records one verbal explanation from the chat challenge (a
    /// substantive probe reply explains the child's thinking).
    public func recordExplanation(at date: Date? = nil) {
        recorder.recordExplanation(at: date)
    }

    /// Records a timing-only interaction from the chat challenge
    /// (composer activity, a non-substantive probe reply): an active-time
    /// anchor that never scores as an attempt, hint, or any other count.
    public func recordInteraction(at date: Date? = nil) {
        recorder.recordInteraction(at: date)
    }

    /// Hint-listen entry for the chat challenge: a hint read aloud is a
    /// hint interaction on the scored session — the same
    /// recorded-hint-interaction interface the main practice chat records
    /// through. A plain method (not a `HintListenEventSink` conformance,
    /// which is nonisolated): the challenge engine's sink forwards here.
    public func recordHintListen(_ event: HintListenEvent) {
        recorder.recordHintListen(event)
    }

    /// The effort signals recorded so far in the current challenge
    /// session: a read-only view over the same session `finishChallenge`
    /// scores. The chat mapping tests assert through this.
    public func currentEffortSignals(at date: Date? = nil) -> EffortSignals {
        recorder.signals(at: date)
    }

    /// Finishes the challenge: scores the recorded session through the
    /// session-decision boundary (`EffortSessionRecorder.evaluateAndLog`,
    /// which persists the grant/deny Decision) and, only on a granted
    /// score, opens the timed unlock window through `ShieldManager`,
    /// dismissing the shield. The Decision is persisted before the
    /// unlock is applied; when logging throws, nothing returns, no
    /// unlock is applied, and the shield stays up with a retryable
    /// error — the same keep-effort-for-retry behavior as a denied
    /// score or a grant the manager refuses. When a previous unlock has
    /// ended since the last tick, the shield re-presents and a fresh
    /// session starts BEFORE scoring, so stale passing effort can never
    /// grant a free window. Flows following the live policy (the
    /// installed default) revalidate the CURRENT floor and duration at
    /// this boundary, so a retained challenge finishing after a policy
    /// change is scored and granted under current settings, never
    /// superseded ones. Returns the score for the result narration,
    /// or nil when the log write failed.
    @discardableResult
    public func finishChallenge() -> EffortScore? {
        manager.refresh()
        remainingUnlockTime = manager.remainingUnlockTime
        updatePresentation()
        revalidateScorerFloor()
        let grantDuration = currentUnlockDuration
        let logMinutes = currentDurationMinutes
        let logged: (score: EffortScore, decision: Decision)
        do {
            logged = try recorder.evaluateAndLog(
                scorer,
                logger: decisionLogger,
                sessionId: decisionSessionId,
                appId: app.id,
                durationMinutes: logMinutes
            )
        } catch let error as DecisionLogError {
            lastScore = nil
            lastDecision = nil
            lastLogError = error
            remainingUnlockTime = manager.remainingUnlockTime
            updatePresentation()
            return nil
        } catch {
            lastScore = nil
            lastDecision = nil
            lastLogError = .persistenceFailed
            remainingUnlockTime = manager.remainingUnlockTime
            updatePresentation()
            return nil
        }
        lastScore = logged.score
        lastDecision = logged.decision
        lastLogError = nil
        if logged.score.decision == .granted {
            manager.grantUnlock(for: app, category: category, duration: grantDuration)
        }
        remainingUnlockTime = manager.remainingUnlockTime
        updatePresentation()
        return logged.score
    }

    /// Re-evaluates expiry and presentation. The view calls this on a
    /// timer so the countdown stays live and expiry re-presents; tests
    /// call it after advancing the clock.
    public func tick() {
        manager.refresh()
        remainingUnlockTime = manager.remainingUnlockTime
        updatePresentation()
    }

    private func updatePresentation() {
        let shouldPresent = isSimulatedMode && manager.isShielded(app: app, category: category)
        guard shouldPresent != isShieldPresented else { return }
        isShieldPresented = shouldPresent
        presentationEvents.append(shouldPresent ? .presented : .dismissed)
        if shouldPresent { resetChallengeSession() }
    }

    /// Starts a fresh challenge session — a new recorder, a new
    /// per-session scorer draw, a new decision session id, and the
    /// previous result cleared. Runs only when the shield re-presents
    /// after an unlock ends (expiry or a replaced window), so a denied
    /// challenge, a refused grant, or a failed log write keeps its
    /// recorded effort for a retry. The new draw uses the current
    /// policy floor when this flow follows the live policy.
    private func resetChallengeSession() {
        recorder = EffortSessionRecorder(startedAt: Date())
        scorer = EffortScorer(floorSettings: currentFloorSettings, weights: scorer.weights)
        decisionSessionId = UUID().uuidString
        lastScore = nil
        lastDecision = nil
        lastLogError = nil
    }

    /// The effort floor to score against: the live policy's floor when
    /// this flow follows it, else the scorer's retained floor.
    private var currentFloorSettings: EffortFloorSettings {
        guard followsLiveFloor, let policyStore else { return scorer.floorSettings }
        return policyStore.currentPolicy.effortFloorSettings
    }

    /// The unlock seconds a grant opens: the live policy's practice
    /// window when this flow follows it, else the retained duration.
    private var currentUnlockDuration: TimeInterval {
        guard followsLiveDuration, let policyStore else { return unlockDuration }
        return TimeInterval(policyStore.currentPolicy.unlockDurations.practiceMinutes) * 60
    }

    /// The unlock minutes recorded in the Decision: the live policy's
    /// practice minutes when this flow follows it, else the retained
    /// construction-time value.
    private var currentDurationMinutes: Int {
        guard followsLiveDuration, let policyStore else { return decisionDurationMinutes }
        return policyStore.currentPolicy.unlockDurations.practiceMinutes
    }

    /// Rebuilds the scorer under the current floor when this flow
    /// follows the live policy, preserving the per-session threshold
    /// draw and weights. A no-op when the floor is unchanged or the
    /// flow keeps retained settings.
    private func revalidateScorerFloor() {
        let current = currentFloorSettings
        guard current != scorer.floorSettings else { return }
        scorer = EffortScorer(
            threshold: scorer.threshold, floorSettings: current, weights: scorer.weights
        )
    }

    private static let fallbackPrompt =
        "A farmer packs 7 eggs in each carton. She fills 8 cartons for the market. How many eggs did she pack in all?"
    private static let demoHint =
        "Try counting by 7s, one carton at a time: 7, 14, 21…"
}
