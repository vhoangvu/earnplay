/// Known-limits note shown next to the running version in the admin
/// app (LLD section 10.3). Every line states a limit verified against
/// this repository's current state — traced in
/// `Docs/VersioningAndRollback.md`. Update these lines in the same
/// change that removes a limit; a stale note here is a product bug.
public enum VersionKnownLimits {
    public static let notes: [String] = [
        "Inference is validated on the iOS simulator only (CPU backend); physical-device speed is not yet measured.",
        "The runtime runs on the CPU backend with a 2048-token context; no Metal backend is in use.",
        "CI does not run real inference: without the fetched model and framework, the inference tests skip instead of passing.",
        "The prompt set is the 5-prompt T0.2 spike set; the full tutor prompt structure and output validation (design doc section 10) are not built yet.",
        "Rollback selects an already-installed previous bundle; it cannot re-download older model files.",
    ]

    /// The full note as one display string, one limit per line.
    public static func noteText() -> String {
        notes.joined(separator: "\n")
    }
}
