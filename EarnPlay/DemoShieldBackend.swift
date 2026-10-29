import EarnPlayCore
import Foundation

/// Demo in-app shield backend (T3.2).
///
/// Records the last applied configuration so the chore-trade UI can
/// report unlock status textually. The demo has no FamilyControls
/// entitlement and enforces nothing on device; T2.4 (simulated shields)
/// and v1 (real ManagedSettings backend) substitute behind the same
/// `ShieldBackend` protocol without changing callers.
final class DemoShieldBackend: ShieldBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: ShieldConfiguration = .none

    func applyShieldConfiguration(_ configuration: ShieldConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    var currentShieldConfiguration: ShieldConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }
}
