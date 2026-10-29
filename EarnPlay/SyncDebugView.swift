import SwiftUI
import EarnPlayCore

/// T4.6 child sync debug view (manual-test surface): shows the policy
/// this device has applied, sync/peer state, and pending uploads.
/// A policy change in the admin app appears here within seconds when
/// both apps are open nearby (Bluetooth, no account/server/internet).
struct SyncDebugView: View {
    @State private var policyStore = PolicyStore()
    @State private var sessionQueue = SessionLogQueue()
    @State private var service: ChildSyncService?
    @State private var logger = DecisionLogger()
    @State private var status = "Sync not started"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync (T4.6, Bluetooth)").font(.headline)
            Text("Applied policy version: \(policyStore.storedVersion)")
                .font(.body.monospacedDigit())
            Text("Practice unlock: \(policyStore.currentPolicy.unlockDurations.practiceMinutes) min")
                .font(.body.monospacedDigit())
            Text("Pending session uploads: \(sessionQueue.pending().count)")
                .font(.body.monospacedDigit())
            Text(status).font(.caption).foregroundStyle(.secondary)
            Button("Run demo session (log decision + queue for sync)") { runDemoSession() }
            Button("Retry sync now") { service?.handleReconnect(); refresh() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startSync() }
    }

    private func startSync() {
        guard service == nil else { return }
        let s = ChildSyncService(
            policyStore: policyStore, sessionQueue: sessionQueue,
            transport: MultipeerSyncTransport(role: .advertiser, displayName: "EarnPlay-Child"))
        service = s; s.start(); status = "Sync started — waiting for admin nearby…"
    }

    private func refresh() {
        policyStore.reloadFromDisk()
        status = "Policy v\(policyStore.storedVersion), \(sessionQueue.pending().count) pending"
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
            status = "Queued \(sessionId) (\(sessionQueue.pending().count) pending)"
        } catch { status = "Demo session failed: \(error)" }
    }
}
