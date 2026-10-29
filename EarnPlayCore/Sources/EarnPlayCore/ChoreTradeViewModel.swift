import Combine
import Foundation

/// View model behind the child app's `ChoreTradeView`: owns the
/// `ChoreTradeSession` state machine and calls `ShieldManager` exactly
/// once, on parent confirm. Done never touches the shield manager.
///
/// Lives in EarnPlayCore (not the app target) so both gates test the real
/// confirm/grant/status path: the app module builds without
/// `-enable-testing`, so app-target view-model tests cannot link (fix
/// round 2 finding). The view stays thin: pool-source resolution,
/// failure text, and status refresh all come from here.
@MainActor
public final class ChoreTradeViewModel: ObservableObject {
    @Published public private(set) var session: ChoreTradeSession
    @Published public private(set) var lastTriggerFoundNone = false
    @Published public private(set) var shieldStatus = ""
    @Published public private(set) var grantSucceeded: Bool?
    public let poolSourceCaption: String

    private let shieldManager: ShieldManager
    private let effortRecorder: EffortSessionRecorder?

    public init(
        pool: [ChorePoolEntry],
        poolSourceCaption: String,
        shieldManager: ShieldManager,
        effortRecorder: EffortSessionRecorder? = nil
    ) {
        self.session = ChoreTradeSession(pool: pool)
        self.poolSourceCaption = poolSourceCaption
        self.shieldManager = shieldManager
        self.effortRecorder = effortRecorder
    }

    public var declinedCount: Int { session.declinedChores.count }

    /// Failure text for the awaiting-confirm state after a failed grant
    /// (persistence failure, or a policy with no unlockable apps), or nil
    /// otherwise. The session stays in `doneAwaitingConfirm`, so the same
    /// Confirm button retries the grant — the failure must be shown where
    /// the retry lives, not only on the granted screen.
    public var confirmationFailureText: String? {
        guard case .doneAwaitingConfirm = session.phase, grantSucceeded == false else {
            return nil
        }
        return "Unlock could not be granted — retry the parent confirmation."
    }

    public func triggerOffer() {
        let offer = session.makeOffer(at: Date())
        lastTriggerFoundNone = (offer == nil && session.currentOffer == nil && !session.hasGrantedUnlock)
        effortRecorder?.recordInteraction()
    }

    public func accept() {
        session.acceptOffer(at: Date())
        effortRecorder?.recordInteraction()
    }

    public func decline() {
        session.declineOffer()
        effortRecorder?.recordInteraction()
    }

    public func markDone() {
        session.markDone(at: Date())
        effortRecorder?.recordInteraction()
    }

    public func parentConfirm() {
        // Commit-on-success (fix round 2): the session replaces itself
        // with the confirmed copy only when the shield grant succeeds,
        // so a failed grant leaves confirmation retryable instead of
        // stranding the session in .granted with no unlock.
        var grantAttempted: Bool?
        let record = session.parentConfirmWithGrant(at: Date()) { record in
            let ok = shieldManager.grantChoreTradeUnlock(
                minutes: record.grantedUnlockMinutes)
            grantAttempted = ok
            return ok
        }
        guard record != nil else {
            if grantAttempted == false {
                grantSucceeded = false
                effortRecorder?.recordInteraction()
                refreshShieldStatus()
            }
            return
        }
        grantSucceeded = true
        effortRecorder?.recordInteraction()
        startStatusUpdates()
    }

    /// Re-reads the shield manager and republishes `shieldStatus`: the
    /// live countdown while the window is open, the expired state once it
    /// ends. Safe to call in any phase; a no-op textually outside the
    /// granted flow. The granted screen calls this on appear and on every
    /// status tick (and tests call it after advancing a fake clock).
    public func refreshGrantedStatus() {
        shieldManager.refresh()
        refreshShieldStatus()
    }

    /// Starts expiry monitoring plus the status baseline: the shield
    /// manager re-locks on expiry, and `shieldStatus` reflects the grant.
    /// Called on a successful confirm and when the granted screen appears
    /// (both are idempotent). The view's status ticker drives the periodic
    /// `refreshGrantedStatus()` calls; `stopStatusUpdates()` ends
    /// monitoring when the granted screen disappears.
    public func startStatusUpdates(pollInterval: TimeInterval = 1) {
        shieldManager.startExpiryMonitoring(pollInterval: pollInterval)
        refreshShieldStatus()
    }

    /// Stops expiry monitoring when the granted screen disappears.
    public func stopStatusUpdates() {
        shieldManager.stopExpiryMonitoring()
    }

    private func refreshShieldStatus() {
        if shieldManager.isUnlockActive {
            let remaining = Int(shieldManager.remainingUnlockTime.rounded(.down))
            shieldStatus = "Device unlock active, \(remaining) seconds left."
        } else if grantSucceeded == false {
            shieldStatus = "Device shields unchanged (unlock not granted)."
        } else if session.hasGrantedUnlock {
            // The granted window ended while the screen was open: the
            // refresh above already re-applied shields, so say so instead
            // of leaving a frozen countdown on screen.
            shieldStatus = "Unlock expired — device is shielded again."
        } else {
            shieldStatus = ""
        }
    }
}
