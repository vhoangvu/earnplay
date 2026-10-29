import SwiftUI
import EarnPlayCore

/// T4.6 child sync debug view (manual-test surface): shows the policy
/// this device has applied, sync/peer state, and pending uploads.
/// Displayed values come from the published sync snapshot (finding 4),
/// so a policy applied or an ack received refreshes them automatically.
struct SyncDebugView: View {
    @State private var policyStore = PolicyStore()
    @State private var sessionQueue = SessionLogQueue()
    @State private var pairing = SyncPairingGate()
    @State private var transport: MultipeerSyncTransport?
    @State private var service: ChildSyncService?
    @StateObject private var ui = ChildSyncUIState(snapshot: ChildSyncSnapshot(
        policyVersion: 0, practiceMinutes: 0, pendingUploads: 0, isPaired: false))
    @State private var logger = DecisionLogger()
    @State private var status = "Sync not started"
    @State private var pendingPeer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync (T4.6, Bluetooth)").font(.headline)
            Text("Applied policy version: \(ui.snapshot.policyVersion)")
                .font(.body.monospacedDigit())
            Text("Practice unlock: \(ui.snapshot.practiceMinutes) min")
                .font(.body.monospacedDigit())
            Text("Pending session uploads: \(ui.snapshot.pendingUploads)")
                .font(.body.monospacedDigit())
            Text("Paired: \(ui.snapshot.isPaired ? "yes" : "no") · Pairing code (show to admin): \(pairing.localCode)")
                .font(.caption.monospaced())
            if let pendingPeer {
                Text("Pairing request from \(pendingPeer) — codes must match on both devices.")
                    .font(.caption)
                HStack {
                    Button("Accept pairing") {
                        if transport?.acceptPendingInvitation() == true {
                            status = "Paired with \(pendingPeer)"
                        }
                        self.pendingPeer = nil
                    }
                    Button("Reject", role: .destructive) {
                        transport?.rejectPendingInvitation()
                        self.pendingPeer = nil
                    }
                }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("Run demo session (log decision + queue for sync)") { runDemoSession() }
            Button("Retry sync now") { service?.handleReconnect() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startSync() }
    }

    private func startSync() {
        guard service == nil else { return }
        let t = MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child", pairing: pairing)
        t.onPairingRequest = { peer in pendingPeer = peer; status = "Pairing request — confirm the code matches, then Accept" }
        let s = ChildSyncService(policyStore: policyStore, sessionQueue: sessionQueue,
                                 transport: t, pairing: pairing)
        s.onSnapshotChange = { ui.snapshot = $0 }
        transport = t; service = s; s.start()
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
                                      logger: logger, policyVersion: policyStore.storedVersion)
            try service?.sendSessionLog(log)
            status = "Queued \(sessionId)"
        } catch { status = "Demo session failed: \(error)" }
    }
}
