import Combine
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
/// Pairing note (issue #65): the persisted gate key
/// (`earnplay.pairing.child.v1`) and display name match the debug view's
/// previous standalone values, so an already-paired device keeps its
/// trusted pairing and reconnects automatically once started. The
/// controller is the SOLE owner of the pairing-request surface: it sets
/// `transport.onPairingRequest` (and `onPairingFailure`) in `init` and
/// publishes the pending request for the production confirmation UI in
/// `ContentView`, which must interrupt from any app state. No view sets
/// its own pairing handlers — opening the debug view must not clobber
/// the production handler. Previously the controller set no handler and
/// the only confirmation UI lived in the unreachable debug view, so a
/// fresh install could not pair in production (the transport refuses
/// untrusted invitations while no handler is set).
final class ChildSyncController: ObservableObject {
    let policyStore: PolicyStore
    let sessionQueue: SessionLogQueue
    // Persisted installation identity, pairing, and secret — the same
    // device across relaunches. Key/displayName unchanged from the
    // debug view's standalone gate so trusted pairing survives.
    let pairing: SyncPairingGate
    let transport: MultipeerSyncTransport
    let service: ChildSyncService
    private var started = false
    /// File name for the best-effort retention of failed-enqueue logs
    /// (round 3 item 3), beside the queue's `pending-session-logs.json`.
    static let failedLogRetentionFileName = "pending-failed-logs.json"
    /// Finalized logs whose enqueue failed, handed off from the practice
    /// engine (round 2 item 2). Retained here — the app-scoped owner —
    /// so discarding the practice view does not lose them. Retried
    /// through the shared `sessionQueue` (never a second writer).
    private(set) var pendingFailedLogs: [SessionLog] = []
    /// Fired after a retained failed log drains (round 2 item 2 test
    /// hook; production delivery is `service.notifySessionEnqueued()`).
    var onSessionEnqueued: (() -> Void)?
    /// Fired on the main thread after the sync service accepts a policy
    /// update (issue #87 fix round 3). The app wires this to the setup
    /// model's `refreshInstalledPolicyFromDisk()`, so the installed
    /// manager, cached shield flows, and completion UI refresh without
    /// a relaunch. Nil unless the host sets it; stale versions and
    /// persistence failures fire nothing.
    var onPolicyUpdate: (() -> Void)?
    /// Directory holding the retained-log file (round 3 item 3). Defaults
    /// to the shared app directory (the default queue's directory in
    /// production); tests inject an isolated directory.
    private let retentionDirectory: URL
    /// Pending untrusted pairing request (issue #65): the peer asking to
    /// pair, or nil when none is pending. Set from
    /// `transport.onPairingRequest`; trusted peers never appear here (the
    /// transport accepts their invitations without surfacing a request).
    /// Always mutated on the main queue (transport callbacks arrive off
    /// the main thread — the old Finding 3 rule from `SyncDebugView`).
    @Published private(set) var pendingPairingPeer: PeerIdentity?
    /// User-facing pairing status for the confirmation surfaces: the
    /// out-of-band comparison instructions while a request is pending,
    /// the corrected-code retry text after a verification failure, nil
    /// when no pairing message applies.
    @Published private(set) var pairingStatusMessage: String?
    /// Pre-invite pairing code (fix round 1, finding 1): this device's
    /// local code, published for a reachable production surface while
    /// unpaired — the admin reads it off the child's screen BEFORE
    /// inviting (invitations require an entered code). Nil once paired
    /// (no longer needed). Displaying this pairs NOTHING: the
    /// confirmation sheet plus the challenge-response handshake still
    /// gate every pairing.
    @Published private(set) var preInvitePairingCode: String?
    /// Sheet headline (fix round 1, finding 2): names the requesting
    /// peer independently of the status message, so a code-retry
    /// failure — which replaces the message with generic retry text —
    /// never hides which peer is being accepted. Nil when no request
    /// is pending.
    var pairingRequestHeadline: String? {
        pendingPairingPeer.map { "Pairing request from \($0.displayName)" }
    }
    init(policyStore: PolicyStore = PolicyStore(),
         sessionQueue: SessionLogQueue = SessionLogQueue(),
         pairing: SyncPairingGate? = nil,
         retentionDirectory: URL = PolicyStore.defaultDirectory()) {
        self.policyStore = policyStore
        self.sessionQueue = sessionQueue
        self.retentionDirectory = retentionDirectory
        self.pendingFailedLogs = Self.loadRetainedFailedLogs(directory: retentionDirectory)
        self.pairing = pairing ?? SyncPairingStore.loadOrCreateGate(
            displayName: "EarnPlay-Child", key: "earnplay.pairing.child.v1")
        self.transport = MultipeerSyncTransport(
            role: .advertiser, displayName: "EarnPlay-Child", pairing: self.pairing)
        self.service = ChildSyncService(
            policyStore: self.policyStore, sessionQueue: self.sessionQueue,
            transport: self.transport, pairing: self.pairing)
        // Sole ownership (issue #65): the production confirmation UI
        // observes this controller, so the handlers live here — never
        // in a view that may appear later and clobber them.
        self.transport.onPairingRequest = { [weak self] peer in
            self?.publishOnMain { self?.handlePairingRequest(peer) }
        }
        self.transport.onPairingFailure = { [weak self] _ in
            self?.publishOnMain { self?.handlePairingFailure() }
        }
        // Issue #87 fix round 3: accepted sync updates refresh the
        // setup model's installed state. The service fires on the
        // transport's receive thread; re-publish on main like the
        // pairing handlers above.
        self.service.onPolicyApplied = { [weak self] _ in
            self?.publishOnMain { self?.onPolicyUpdate?() }
        }
        // Fix round 1 (finding 1): publish the pre-invite code while
        // unpaired, cleared on pairing. Chained AFTER the store's
        // persistence handler (set at gate creation) so persistence
        // keeps working; gate callbacks may arrive off the main
        // thread, hence publishOnMain.
        self.preInvitePairingCode = self.pairing.isPaired ? nil : self.pairing.localCode
        let previousStateChange = self.pairing.onStateChange
        self.pairing.onStateChange = { [weak self] in
            previousStateChange?()
            guard let self else { return }
            // Fix round 2: read gate state INSIDE the main-queue block.
            // Capturing before the hop left a stale window — a state
            // change between capture and block execution published the
            // old value (a stale nil hid the pre-invite code).
            self.publishOnMain {
                self.preInvitePairingCode = self.pairing.isPaired ? nil : self.pairing.localCode
            }
        }
    }

    /// Runs a `@Published` mutation on the main queue: inline when the
    /// caller is already on it (production MPC callbacks arrive off the
    /// main thread; synchronous test drivers run on it), async otherwise.
    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread { update() }
        else { DispatchQueue.main.async(execute: update) }
    }

    private func handlePairingRequest(_ peer: PeerIdentity) {
        // Fix round 3: recheck at execution time, on main. This
        // handler runs via `publishOnMain` from the transport's
        // `onPairingRequest` callback, which arrives off the main
        // thread — so it can sit queued while main-thread code
        // (Decline/unpair) clears the transport's pending request,
        // then run and reopen the sheet for a request that no longer
        // exists (a dead sheet Accept cannot complete). Every firing
        // site sets pending state BEFORE firing, so an empty pending
        // slot here means this notification is stale: drop it without
        // publishing either the peer or the message.
        guard transport.hasPendingPairingRequest else { return }
        pendingPairingPeer = peer
        pairingStatusMessage = "Pairing request from \(peer.displayName) — compare codes out-of-band: this device shows \(pairing.localCode); enter the code shown on the admin device, then Accept. Acceptance alone proves nothing; both devices verify by challenge-response before any data flows."
    }

    private func handlePairingFailure() {
        pairingStatusMessage = "Codes didn't match — re-enter the admin code and Accept, or ask the admin to tap Pair again."
        // Round-5 behavior (kept from the debug view): the transport
        // restores the manual request on failure, so the pending row
        // stays for a corrected-code retry whenever one is still
        // pending instead of hiding the only way to retry.
        if !transport.hasPendingPairingRequest { pendingPairingPeer = nil }
    }

    /// Accepts the pending request through the EXISTING confirmation
    /// path: records the admin code the user read off the admin screen
    /// (out-of-band, never transmitted), then accepts the pending
    /// invitation (or restarts the handshake on the live session for a
    /// corrected-code retry). Mutual challenge-response still gates all
    /// data — this never becomes accept-without-code: a blank entry is
    /// refused and the request stays pending.
    /// - Returns: whether an invitation/handshake was actually accepted.
    @discardableResult
    func acceptPairingRequest(enteredCode: String) -> Bool {
        guard !enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        _ = pairing.preparePairing(enteredCode: enteredCode)
        guard transport.acceptPendingInvitation() else { return false }
        pendingPairingPeer = nil
        pairingStatusMessage = nil
        return true
    }

    /// Declines the pending request: rejects the invitation and clears
    /// the confirmation UI.
    func declinePairingRequest() {
        transport.rejectPendingInvitation()
        pendingPairingPeer = nil
        pairingStatusMessage = nil
    }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        service.start()
        retryPendingFailedLogs()
    }
    /// Retains a finalized log whose enqueue failed (round 2 item 2
    /// handoff from the practice engine). Deduplicated by sessionId, so
    /// a repeated handoff of the same session replaces rather than
    /// duplicates. Survives discarding the practice view/engine; the
    /// app-scoped controller outlives both. Also persisted best-effort
    /// (round 3 item 3) so retention survives app quit; memory always
    /// retains regardless of the write.
    func handleFailedEnqueue(_ log: SessionLog) {
        if let index = pendingFailedLogs.firstIndex(where: { $0.sessionId == log.sessionId }) {
            pendingFailedLogs[index] = log
        } else {
            pendingFailedLogs.append(log)
        }
        persistRetainedFailedLogs()
    }
    /// Retries retained failed logs through the SHARED `sessionQueue`
    /// (never a second writer over the same directory). Each drained log
    /// kicks delivery via `service.notifySessionEnqueued()` and the
    /// `onSessionEnqueued` hook. Called on app-lifecycle triggers
    /// (controller start, foreground via the app's scenePhase observer) —
    /// never on a timer. Failures stay retained for the next trigger.
    func retryPendingFailedLogs() {
        var drained: [String] = []
        for log in pendingFailedLogs {
            do {
                try sessionQueue.enqueue(log)
                drained.append(log.sessionId)
            } catch {
                // Still failing: keep for the next lifecycle trigger.
            }
        }
        guard !drained.isEmpty else { return }
        pendingFailedLogs.removeAll { drained.contains($0.sessionId) }
        // Delete-on-drain: persist the shrunken list (round 3 item 3).
        persistRetainedFailedLogs()
        service.notifySessionEnqueued()
        onSessionEnqueued?()
    }
    /// Persists the retained list best-effort (round 3 item 3). When the
    /// enqueue failure is disk-full, this write fails the same way and
    /// retention stays memory-only — a quit before any retry then loses
    /// the log (documented in `Docs/SessionRecording.md`). Never throws:
    /// the in-memory list is always retained.
    private func persistRetainedFailedLogs() {
        do {
            try FileManager.default.createDirectory(
                at: retentionDirectory, withIntermediateDirectories: true)
            try SessionLogCodec.encode(pendingFailedLogs).write(
                to: retentionDirectory.appendingPathComponent(
                    Self.failedLogRetentionFileName), options: [.atomic])
        } catch {
            // Best-effort only: keep memory retention, drop the write.
        }
    }
    /// Loads logs retained by a previous controller instance (round 3 item
    /// 3). A missing or corrupt file loads as empty — never a failure.
    private static func loadRetainedFailedLogs(directory: URL) -> [SessionLog] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(
            failedLogRetentionFileName)) else { return [] }
        return (try? SessionLogCodec.decodeList(data)) ?? []
    }
    /// Reset/Unpair: clears pairing + secret on both the gate
    /// (persisted) and the live transport session, then republish.
    /// Also clears any pending confirmation UI (unpair rejects a
    /// pending invitation on the transport).
    func unpair() {
        transport.unpair()
        service.flushPending()
        pendingPairingPeer = nil
        pairingStatusMessage = nil
    }
}
