/// EarnPlayCore — shared, deterministic logic for EarnPlay.
///
/// Design rule (from the Source of Truth): the tutor model is never trusted
/// alone. Every safety-critical decision — effort scoring, the floor rule,
/// unlock — lives here in deterministic code, never in the model.
public enum EarnPlayCore {
    public static let version = "0.1.0"
}

/// Minimal deterministic effort scorer (placeholder shape for T-scoring tasks).
///
/// Points = whole active minutes + attempts. The real scorer adds hint
/// interactions, revisions and explanations, applies the floor rule
/// (>= 1 genuine attempt + >= 1 real hint/follow-up interaction) and a
/// variable threshold in the 8-14 point range. That logic must stay
/// deterministic and unit-tested here — never delegated to a model.
public struct EffortScorer {
    public init() {}

    public func points(activeSeconds: Int, attempts: Int) -> Int {
        guard activeSeconds > 0 || attempts > 0 else { return 0 }
        return max(0, activeSeconds) / 60 + max(0, attempts)
    }
}
