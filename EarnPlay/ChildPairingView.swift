import SwiftUI
import EarnPlayCore

/// Production child pairing-confirmation sheet (issue #65): presented by
/// `ContentView` whenever the shared `ChildSyncController` holds a pending
/// untrusted pairing request, from any app state (including
/// mid-practice-chat) — invitations arrive asynchronously and must
/// interrupt wherever the child is, never gated behind setup or settings
/// navigation. Shows the requesting peer, this device's local code (the
/// admin reads it off this screen), an admin-code entry field, Accept,
/// and Decline. Accept records the entered code and proceeds through the
/// existing challenge-response handshake; Decline rejects the invitation.
/// Trusted reconnects never surface here (the transport accepts those
/// without a request). No scores, timers, countdowns, or pass/fail
/// language (Demo rules).
struct ChildPairingRequestSheet: View {
    @ObservedObject var controller: ChildSyncController
    let peer: PeerIdentity
    @State private var peerCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Fix round 1 (finding 2): the headline names the peer
            // independently of the status message, so a code-retry
            // failure (generic retry text) never hides who is accepted.
            Text(controller.pairingRequestHeadline ?? "Pairing request from \(peer.displayName)")
                .font(.headline)
            Text("This device's code (show to admin): \(controller.pairing.localCode)")
                .font(.body.monospacedDigit())
            if let message = controller.pairingStatusMessage {
                Text(message)
                    .font(.callout)
            }
            TextField("Code shown on admin", text: $peerCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.numberPad)
#endif
            HStack {
                Button("Accept pairing") {
                    controller.acceptPairingRequest(enteredCode: peerCode)
                }
                .disabled(peerCode.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Decline", role: .destructive) {
                    controller.declinePairingRequest()
                }
            }
        }
        .padding()
    }
}
