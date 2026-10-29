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
/// `EffortSessionRecorder`, `EffortScorer` decides, and only a granted
/// score calls `grantUnlock`. Correctness is never an input (per the
/// `EffortScoring` contract): any non-blank submitted answer is a
/// genuine attempt.
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
    private let scorer: EffortScorer
    private let recorder: EffortSessionRecorder

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
    /// The most recent challenge score, if the challenge was finished.
    @Published public private(set) var lastScore: EffortScore?
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
        isSimulatedMode: Bool
    ) {
        self.manager = manager
        self.backend = backend
        self.app = app
        self.category = category
        self.scorer = scorer
        self.recorder = recorder
        self.unlockDuration = unlockDuration
        self.isSimulatedMode = isSimulatedMode
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

    /// Finishes the challenge: scores the recorded session with the real
    /// `EffortScorer` and, only on a granted score, opens the timed
    /// unlock window through `ShieldManager`, dismissing the shield. A
    /// denied score — or a grant the manager refuses — leaves the shield
    /// presented. Returns the score for the result narration.
    @discardableResult
    public func finishChallenge() -> EffortScore {
        let score = scorer.evaluate(recorder.signals())
        lastScore = score
        if score.decision == .granted {
            manager.grantUnlock(for: app, category: category, duration: unlockDuration)
        }
        remainingUnlockTime = manager.remainingUnlockTime
        updatePresentation()
        return score
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
    }

    private static let fallbackPrompt =
        "A farmer packs 7 eggs in each carton. She fills 8 cartons for the market. How many eggs did she pack in all?"
    private static let demoHint =
        "Try counting by 7s, one carton at a time: 7, 14, 21…"
}
