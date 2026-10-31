import SwiftUI
import EarnPlayCore

/// T4.6 child sync debug view (manual-test surface): shows the policy
/// this device has applied, sync/peer state, and pending uploads.
/// Displayed values come from the published sync snapshot (finding 4),
/// so a policy applied or an ack received refreshes them automatically.
///
/// Issue #63 fix 3: this view reuses the app's shared `ChildSyncController`
/// service instead of starting a second service over the same outbox
/// directory — two services are NOT safe (dedupe + removeDelivered are
/// per-instance-locked read-modify-write persists with no cross-instance
/// lock, so concurrent writers can clobber). The view only attaches its
/// confirmation UI (pairing request/failure handlers, snapshot observer)
/// to the shared transport/service on appear; starting is the app's job.
/// First-time (untrusted) pairing is confirmed here via the shared gate:
/// record the admin's shown code, then accept the pending invitation.
struct SyncDebugView: View {
    let controller: ChildSyncController
    @StateObject private var ui = ChildSyncUIState(snapshot: ChildSyncSnapshot(
        policyVersion: 0, practiceMinutes: 0, pendingUploads: 0, isPaired: false))
    @State private var logger = DecisionLogger()
    @State private var status = "Sync not started"
    @State private var pendingPeer: PeerIdentity?
    @State private var peerCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync (T4.6, Bluetooth)").font(.headline)
            Text("Applied policy version: \(ui.snapshot.policyVersion)")
                .font(.body.monospacedDigit())
            Text("Practice unlock: \(ui.snapshot.practiceMinutes) min")
                .font(.body.monospacedDigit())
            Text("Pending session uploads: \(ui.snapshot.pendingUploads)")
                .font(.body.monospacedDigit())
            Text("Paired: \(ui.snapshot.isPaired ? "yes" : "no") · Pairing code (show to admin): \(controller.pairing.localCode)")
                .font(.caption.monospaced())
            if let pendingPeer {
                Text("Pairing request from \(pendingPeer.displayName) — compare codes out-of-band: this device shows \(controller.pairing.localCode); enter the code shown on the admin device, then Accept. Acceptance alone proves nothing; both devices verify by challenge-response before any data flows.")
                    .font(.caption)
                HStack {
                    TextField("Code shown on admin", text: $peerCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Accept pairing") {
                        // Out-of-band confirmation: record the admin's
                        // code as shown on the admin screen (F2).
                        _ = controller.pairing.preparePairing(enteredCode: peerCode)
                        if controller.transport.acceptPendingInvitation() {
                            status = "Verifying with \(pendingPeer.displayName)…"
                        }
                        self.pendingPeer = nil
                    }
                    .disabled(peerCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reject", role: .destructive) {
                        controller.transport.rejectPendingInvitation()
                        self.pendingPeer = nil
                    }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("Run demo session (log decision + queue for sync)") { runDemoSession() }
            Button("Retry sync now") { controller.service.handleReconnect() }
            Button("Reset / Unpair", role: .destructive) {
                controller.unpair()
                pendingPeer = nil; peerCode = ""
                status = "Unpaired — pair again from the admin device."
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { attachSync() }
    }

    private func attachSync() {
        // The app owns starting; attaching is idempotent (re-appear
        // only rebinds this view's observers to the same service).
        controller.startIfNeeded()
        let t = controller.transport
        // Finding 3: transport callbacks arrive off the main thread;
        // dispatch SwiftUI state updates to the main queue.
        t.onPairingRequest = { peer in
            DispatchQueue.main.async { pendingPeer = peer; status = "Pairing request — compare codes out-of-band, enter the admin code, then Accept" }
        }
        // Round 4 (M6): verification failure resets both sides;
        // surface a retryable status and allow corrected entry.
        // Round 5 (item 6): the transport restores the manual request
        // on failure, so keep the code-entry row whenever one is
        // pending instead of hiding the only way to retry.
        t.onPairingFailure = { _ in
            DispatchQueue.main.async {
                status = "Codes didn't match — re-enter the admin code and Accept, or ask the admin to tap Pair again."
                if !t.hasPendingPairingRequest { pendingPeer = nil }
            }
        }
        let s = controller.service
        s.onSnapshotChange = { snap in DispatchQueue.main.async { ui.snapshot = snap } }
        ui.snapshot = s.snapshot
        status = "Sync started — waiting for admin nearby…"
    }

    /// Logs the decision FIRST via T1.6 DecisionLogger (no unlogged
    /// path), then queues the SessionLog built from that log.
    private func runDemoSession() {
        let sessionId = "session-\(UUID().uuidString.prefix(8))"
        do {
            _ = try logger.logSessionJudgment(
                sessionId: sessionId, outcome: "Demo session completed",
                evidenceSummary: "Demo session run from sync debug view",
                reasoning: "Session finished; log queued for admin sync",
                alternativeConsidered: "Discard session; rejected — admin audit needs it",
                confidence: 0.9)
            let log = SessionLog.make(sessionId: sessionId, startedAt: Date(), endedAt: Date(),
                                      logger: logger, policyVersion: controller.policyStore.storedVersion)
            try controller.service.sendSessionLog(log)
            status = "Queued \(sessionId)"
        } catch { status = "Demo session failed: \(error)" }
    }
}
