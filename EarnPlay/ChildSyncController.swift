import Foundation
import EarnPlayCore

/// App-scope child sync (issue #63 fix 3): owned and started by the app,
/// mirroring the admin `AdminSyncController`, independently of any view,
/// and retained for the app's life. Previously the only start site was
/// `SyncDebugView.onAppear`, which is unreachable in production (it lives
/// in the dead `previewHarnesses`), so completed logs sat in the outbox.
///
/// Single shared instance: the debug view reuses this controller's
/// service rather than draining the same outbox from a second service —
/// `SessionLogQueue` serializes only per-instance (`NSLock`), so two
/// services over the same directory could clobber each other's
/// read-modify-write persists. Sharing also keeps one pairing gate and
/// one transport (one advertiser identity).
///
/// Pairing note: the persisted gate key (`earnplay.pairing.child.v1`)
/// and display name match the debug view's previous standalone values,
/// so an already-paired device keeps its trusted pairing and
/// reconnects automatically once started; first-time (untrusted)
/// pairing still needs a confirmation surface (see `SyncDebugView`).
/// The controller itself sets no `onPairingRequest` handler, so while
/// no confirmation UI is attached the transport refuses untrusted
/// invitations instead of holding them unanswerable.
final class ChildSyncController {
    let policyStore = PolicyStore()
    let sessionQueue = SessionLogQueue()
    // Persisted installation identity, pairing, and secret — the same
    // device across relaunches. Key/displayName unchanged from the
    // debug view's standalone gate so trusted pairing survives.
    let pairing = SyncPairingStore.loadOrCreateGate(displayName: "EarnPlay-Child",
                                                    key: "earnplay.pairing.child.v1")
    let transport: MultipeerSyncTransport
    let service: ChildSyncService
    private var started = false
    init() {
        transport = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: pairing)
        service = ChildSyncService(policyStore: policyStore, sessionQueue: sessionQueue,
                                   transport: transport, pairing: pairing)
    }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        service.start()
    }
    /// Reset/Unpair: clears pairing + secret on both the gate
    /// (persisted) and the live transport session, then republish.
    func unpair() {
        transport.unpair()
        service.flushPending()
    }
}
