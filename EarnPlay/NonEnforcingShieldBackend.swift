import Foundation
import EarnPlayCore

/// Placeholder `ShieldBackend` for the child app until T2.4 / v1.
///
/// Records the last configuration `ShieldManager` applied so the setup
/// completion screen can report what WOULD be shielded, and answers
/// effective shielding from it exactly like the simulated test backend.
/// It applies nothing to the system: no ManagedSettings store is touched,
/// so no app is actually restricted.
///
/// T2.4 replaces this with the simulated-shield backend behind the same
/// protocol, and v1 replaces that with the real ManagedSettings backend;
/// `ShieldManager` callers do not change. Never claim enforcement while
/// this backend is installed.
public final class NonEnforcingShieldBackend: ShieldBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: ShieldConfiguration = .none

    public init() {}

    public func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    public var currentShieldConfiguration: ShieldConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }
}
