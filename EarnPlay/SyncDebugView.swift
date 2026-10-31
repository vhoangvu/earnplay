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
/// snapshot observer to the shared service on appear; starting is the
/// app's job.
/// Issue #65: the controller is the SOLE owner of the pairing-request
/// surface (it sets the transport's pairing handlers in `init`). This
/// view sets NO pairing handlers — opening it must not clobber the
/// production handler. Its code-entry/Accept row observes the
/// controller's pending state and acts through the controller's
/// accept/decline actions; the production confirmation sheet in
/// `ContentView` is the same state from any app state.
struct SyncDebugView: View {
    @ObservedObject var controller: ChildSyncController
    @StateObject private var ui = ChildSyncUIState(snapshot: ChildSyncSnapshot(
        policyVersion: 0, practiceMinutes: 0, pendingUploads: 0, isPaired: false))
    @State private var logger = DecisionLogger()
    @State private var status = "Sync not started"
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
            if let pendingPeer = controller.pendingPairingPeer {
                // Out-of-band confirmation row, driven by the
                // controller's pending state (issue #65): the same
                // request the production sheet shows.
                Text(controller.pairingStatusMessage ?? "Pairing request from \(pendingPeer.displayName).")
                    .font(.caption)
                HStack {
                    TextField("Code shown on admin", text: $peerCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Accept pairing") {
                        if controller.acceptPairingRequest(enteredCode: peerCode) {
                            status = "Verifying with \(pendingPeer.displayName)…"
                        }
                    }
                    .disabled(peerCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reject", role: .destructive) {
                        controller.declinePairingRequest()
                    }
                }
            }
            Text(controller.pairingStatusMessage ?? status).font(.caption).foregroundStyle(.secondary)
            Button("Run demo session (log decision + queue for sync)") { runDemoSession() }
            Button("Retry sync now") { controller.service.handleReconnect() }
            Button("Reset / Unpair", role: .destructive) {
                controller.unpair()
                peerCode = ""
                status = "Unpaired — pair again from the admin device."
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { attachSync() }
    }

    /// Attaches this view's snapshot observer to the shared service.
    /// Internal (not private) so tests can verify that attaching the
    /// debug view does not replace the controller's pairing handlers
    /// (issue #65: single ownership — the controller sets them in
    /// `init`, and this method must never assign them).
    func attachSync() {
        // The app owns starting; attaching is idempotent (re-appear
        // only rebinds this view's observers to the same service).
        controller.startIfNeeded()
        let s = controller.service
        // Finding 3: transport callbacks arrive off the main thread;
        // dispatch SwiftUI state updates to the main queue.
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
