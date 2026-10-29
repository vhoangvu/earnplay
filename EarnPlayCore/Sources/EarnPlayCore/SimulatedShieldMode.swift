import Foundation

/// Feature flag forcing simulated shields (T2.4).
///
/// Any one of these forces simulated mode:
/// - the `-EarnPlaySimulatedShields` launch argument (tests, demos),
/// - the `EARNPLAY_SIMULATED_SHIELDS=1` (or `true`) environment value,
/// - the `earnplay.simulatedShieldsForced` UserDefaults key (the
///   in-app debug-settings toggle writes this key).
///
/// The resolver is pure over its inputs so tests pin the contract
/// without touching global state; the app calls it with live values.
public enum SimulatedShieldMode: Sendable {
    /// UserDefaults key the debug toggle writes.
    public static let forceUserDefaultsKey = "earnplay.simulatedShieldsForced"
    /// Environment variable forcing simulated mode.
    public static let forceEnvironmentKey = "EARNPLAY_SIMULATED_SHIELDS"
    /// Launch argument forcing simulated mode.
    public static let forceArgument = "-EarnPlaySimulatedShields"

    /// True when any forcing input is set.
    public static func isForced(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if arguments.contains(forceArgument) { return true }
        if let value = environment[forceEnvironmentKey]?.lowercased(),
           value == "1" || value == "true" {
            return true
        }
        return userDefaults.bool(forKey: forceUserDefaultsKey)
    }

    /// Writes the debug-toggle value (the UserDefaults forcing input).
    public static func setForced(_ forced: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(forced, forKey: forceUserDefaultsKey)
    }
}
