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
    /// Directory holding the retained-log file (round 3 item 3). Defaults
    /// to the shared app directory (the default queue's directory in
    /// production); tests inject an isolated directory.
    private let retentionDirectory: URL
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
    func unpair() {
        transport.unpair()
        service.flushPending()
    }
}
