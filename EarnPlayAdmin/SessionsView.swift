import SwiftUI
import EarnPlayCore

/// T4.6 admin sync surface (manual-test surface): sessions received
/// from the child, stored exactly once. Running a session on the child
/// makes it appear here after sync; a queued offline session arrives
/// on reconnect, once, without re-running anything.
struct SessionsView: View {
    @State private var sessionStore = SessionLogStore()
    @State private var policyQueue = PolicyUpdateQueue()
    @State private var service: AdminSyncService?
    @State private var status = "Sync not started"

    var body: some View {
        NavigationStack {
            List {
                Section("Sync (Bluetooth)") {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Text("Policy updates pending delivery: \(policyQueue.pendingUpdates().count)")
                        .font(.caption)
                    Button("Retry sync now") { service?.handleReconnect(); status = "Retried — \(sessionStore.allLogs.count) session(s) stored" }
                }
                Section("Sessions from child (\(sessionStore.allLogs.count))") {
                    if sessionStore.allLogs.isEmpty {
                        Text("No sessions yet").foregroundStyle(.secondary)
                    }
                    ForEach(sessionStore.allLogs, id: \.sessionId) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.sessionId).font(.body.monospaced())
                            Text("\(log.decisions.count) decision(s) · policy v\(log.policyVersion)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .onAppear { startSync() }
        }
    }

    private func startSync() {
        guard service == nil else { return }
        let s = AdminSyncService(
            policyQueue: policyQueue, sessionStore: sessionStore,
            transport: MultipeerSyncTransport(role: .browser, displayName: "EarnPlay-Admin"))
        service = s; s.start(); status = "Sync started — looking for child nearby…"
    }
}
