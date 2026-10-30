import SwiftUI
import EarnPlayCore

/// T4.6 admin sync surface: sessions received from the child, stored
/// exactly once. The sync service itself is app-scoped (started by
/// EarnPlayAdminApp regardless of the selected tab, finding 6); this
/// view only renders the published snapshot (finding 5).
struct SessionsView: View {
    let controller: AdminSyncController
    @StateObject private var ui = AdminSyncUIState(snapshot: AdminSyncSnapshot(
        storedSessionCount: 0, sessionIDs: [], pendingPolicies: 0, isPaired: false))
    @State private var peerCode = ""
    @State private var status = "Sync starting…"

    var body: some View {
        NavigationStack {
            List {
                Section("Sync (Bluetooth)") {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Text("Paired: \(ui.snapshot.isPaired ? "yes" : "no") · Policy updates pending delivery: \(ui.snapshot.pendingPolicies)")
                        .font(.caption)
                    Text("This device pairing code: \(controller.pairing.localCode)")
                        .font(.caption.monospaced())
                    HStack {
                        TextField("Code shown on child", text: $peerCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Pair") { pair() }
                            .disabled(peerCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Retry sync now") { controller.service.handleReconnect() }
                    Button("Reset / Unpair", role: .destructive) {
                        controller.unpair()
                        peerCode = ""
                        status = "Unpaired — enter the code shown on the child to pair again."
                    }
                }
                Section("Sessions from child (\(ui.snapshot.storedSessionCount))") {
                    if controller.sessionStore.allLogs.isEmpty {
                        Text("No sessions yet").foregroundStyle(.secondary)
                    }
                    ForEach(controller.sessionStore.allLogs, id: \.sessionId) { log in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.sessionId).font(.body.monospaced())
                            Text("\(log.decisions.count) decision(s) · policy v\(log.policyVersion)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .onAppear {
                // Finding 4: deliver snapshot assignments on the main queue.
                controller.service.onSnapshotChange = { snap in DispatchQueue.main.async { ui.snapshot = snap } }
                // Round 4 (M6): a failed verification resets both
                // sides; surface a retryable status here.
                controller.transport.onPairingFailure = { _ in
                    DispatchQueue.main.async { status = "Codes didn't match — re-enter the code shown on the child and tap Pair." }
                }
                ui.snapshot = controller.service.snapshot
                status = controller.service.isPaired
                    ? "Sync started — paired" : "Sync started — enter the code shown on the child to pair"
            }
        }
    }

    private func pair() {
        if controller.pairing.preparePairing(enteredCode: peerCode) {
            status = "Pairing code saved — looking for child nearby… Confirm on the child when asked."
            // Finding 5: Pair retries the invitation itself (clears
            // failed/timed-out state, re-invites retained peers).
            controller.service.retryPairing()
        } else {
            status = "Enter the 6-digit code shown on the child."
        }
    }
}
