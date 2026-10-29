/// EarnPlayCore — shared, deterministic logic for EarnPlay.
///
/// Design rule (from the Source of Truth): the tutor model is never trusted
/// alone. Every safety-critical decision — effort scoring, the floor rule,
/// unlock — lives here in deterministic code, never in the model.
public enum EarnPlayCore {
    public static let version = "0.1.0"
}

/// Effort scoring lives in `EffortScoring.swift` (`EffortScorer`,
/// `EffortSignals`, `EffortScore`, `EffortSessionRecorder`).
/// Stalling probes live in `StallingDetection.swift` (`StallingDetector`,
/// `StallProbe`, `StallProbeSession`).
