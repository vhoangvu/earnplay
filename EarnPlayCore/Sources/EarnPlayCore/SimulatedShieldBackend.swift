import Foundation

/// Simulated shield backend (T2.4) — the formalized fallback behind the
/// T2.2 `ShieldBackend` interface for use when the distribution
/// entitlement is unavailable.
///
/// Behaviour is identical to the test double T2.2's Demo verification
/// ran against: it records the last applied configuration and answers
/// effective shielding from the shared `ShieldConfiguration.isShielded`
/// contract (per-app shield OR category shield; no exemption semantics).
/// `ShieldManager` is unchanged — this backend substitutes behind the
/// same protocol.
///
/// Honesty: this backend never touches ManagedSettings or FamilyControls
/// (neither framework is imported anywhere in this package).
/// `managedSettingsCallCount` exists so tests can assert that zero, and
/// it is always zero. Verification via this backend is verification of
/// the simulated interface only; real-shield enforcement needs the T0.4
/// entitlement (v1, not filed).
public final class SimulatedShieldBackend: ShieldBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: ShieldConfiguration = .none
    private var applications: Int = 0

    public init() {}

    public func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
        lock.lock()
        self.configuration = configuration
        applications += 1
        lock.unlock()
    }

    public var currentShieldConfiguration: ShieldConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    /// Number of applied configurations so far (simulated applies only).
    public var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return applications
    }

    /// Real ManagedSettings calls made through this backend. Always zero:
    /// the simulated path has no ManagedSettings code to call.
    public var managedSettingsCallCount: Int { 0 }
}
