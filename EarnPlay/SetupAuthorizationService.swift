import Foundation
import FamilyControls

/// Screen Time authorization state for setup, in framework-free terms.
public enum SetupAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case approved
}

/// Requests and reports FamilyControls authorization for the T2.3 setup
/// flow.
///
/// The real implementation (`FamilyControlsSetupAuthorizationService`)
/// talks to `AuthorizationCenter`. The simulated implementation
/// (`SimulatedSetupAuthorizationService`) is the seam that lets the Demo
/// verify the flow without the entitlement (T2.4's simulated path); it is
/// never real authorization and must never be presented as such.
///
/// Honesty: the FamilyControls distribution entitlement is NOT filed, so
/// real authorization cannot be granted on device. The simulator has no
/// Screen Time authorization at all: requesting there fails and the UI
/// must say so instead of claiming progress.
public protocol SetupAuthorizationService: Sendable {
    func currentStatus() -> SetupAuthorizationState
    /// Requests authorization; true only when the resulting status is
    /// approved. Never throws: any failure reports false.
    func requestAuthorization() async -> Bool
}

/// Real authorization via `AuthorizationCenter` (child's device, Screen
/// Time). Works when authorized — which requires the entitlement (v1).
public final class FamilyControlsSetupAuthorizationService: SetupAuthorizationService, Sendable {
    public init() {}

    public func currentStatus() -> SetupAuthorizationState {
        Self.map(AuthorizationCenter.shared.authorizationStatus)
    }

    public func requestAuthorization() async -> Bool {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            return false
        }
        return currentStatus() == .approved
    }

    /// Maps the system status using ONLY `AuthorizationStatus` cases present
    /// in the CI SDK (runner-default older Xcode / pre-26.4 SDK: `.approved`
    /// / `.denied` / `.notDetermined`).
    ///
    /// Do NOT reference `.approvedWithDataAccess` (introduced iOS 26.4) here,
    /// not even behind `#available`: the symbol does not exist in the CI SDK,
    /// so any reference fails CI compilation (a runtime guard cannot declare
    /// a missing symbol). The Demo has no FamilyControls entitlement, so the
    /// 26.4 data-access distinction is never load-bearing; unknown future
    /// cases conservatively map to `.denied` (not authorized), keeping the
    /// state machine's acceptance behavior identical on all SDKs.
    static func map(_ status: AuthorizationStatus) -> SetupAuthorizationState {
        switch status {
        case .approved:
            return .approved
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}

/// Simulated authorization for the Demo verification path (T2.4).
///
/// Starts unapproved; `requestAuthorization()` approves when
/// `grantsOnRequest` is true. This exercises the setup state machine
/// without Screen Time — it never authorizes anything real.
public final class SimulatedSetupAuthorizationService: SetupAuthorizationService, @unchecked Sendable {
    private let lock = NSLock()
    private var approved: Bool
    /// Whether a request flips the state to approved.
    public var grantsOnRequest: Bool

    public init(approved: Bool = false, grantsOnRequest: Bool = true) {
        self.approved = approved
        self.grantsOnRequest = grantsOnRequest
    }

    public func currentStatus() -> SetupAuthorizationState {
        lock.lock()
        defer { lock.unlock() }
        return approved ? .approved : .notDetermined
    }

    public func requestAuthorization() async -> Bool {
        lock.lock()
        if grantsOnRequest { approved = true }
        let result = approved
        lock.unlock()
        return result
    }
}
