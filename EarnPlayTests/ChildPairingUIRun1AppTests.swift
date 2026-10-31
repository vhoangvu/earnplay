import MultipeerConnectivity
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #65 run 1 — the `ChildSyncController` is the sole owner of the
/// child pairing-request surface: it sets `transport.onPairingRequest`
/// (and `onPairingFailure`) in `init`, publishes the pending request for
/// the production confirmation sheet in `ContentView`, and accepts
/// through the existing `preparePairing` + `acceptPendingInvitation`
/// handshake path. The debug view observes this state and must never
/// replace the handlers.
///
/// All peers, codes, and stores here are fixtures (never production
/// sample data). Invitations and handshake messages are driven through
/// the REAL `MultipeerSyncTransport` delegate entry points (no network:
/// the tests supply the invitation handler and handshake data, as the
/// `SyncFixRound5Tests` transport-driven tests do), so accept/decline
/// exercise the production paths, including the held invitation handler.
final class ChildPairingUIRun1AppTests: XCTestCase {
    private let admin = PeerIdentity(stableID: "test-admin-65", displayName: "EarnPlay-Admin")

    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-ui-65-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func testGate(_ tag: String) -> SyncPairingGate? {
        let suite = "pairing-ui-65-\(tag)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SyncPairingStore.loadOrCreateGate(
            displayName: "EarnPlay-Child", defaults: defaults, key: "test-key")
    }

    private func controller(_ tag: String) -> ChildSyncController? {
        guard let gate = testGate(tag) else { return nil }
        return ChildSyncController(
            policyStore: PolicyStore(directory: tempDir("store-\(tag)")),
            sessionQueue: SessionLogQueue(directory: tempDir("queue-\(tag)")),
            pairing: gate,
            retentionDirectory: tempDir("retention-\(tag)"))
    }

    private final class VerdictBox {
        var verdicts: [Bool] = []
    }

    /// Drives an untrusted invitation through the transport's advertiser
    /// delegate, collecting the invitation-handler verdicts in the box
    /// so tests can assert held vs answered invitations.
    @discardableResult
    private func invite(_ controller: ChildSyncController, from peer: PeerIdentity,
                        verdicts box: VerdictBox) throws -> VerdictBox {
        let advertiser = MCNearbyServiceAdvertiser(
            peer: MCPeerID(displayName: "EarnPlay-Child"),
            discoveryInfo: nil, serviceType: MultipeerSyncTransport.serviceType)
        let context = try PairingInvitation.encode(PairingInvitation(inviter: peer))
        controller.transport.advertiser(
            advertiser,
            didReceiveInvitationFromPeer: MCPeerID(displayName: peer.displayName),
            withContext: context) { ok, _ in box.verdicts.append(ok) }
        return box
    }

    private func handshakeData(_ json: String) -> Data {
        var d = Data("EarnPlayPairing/1:".utf8)
        d.append(Data(json.utf8))
        return d
    }

    /// An untrusted invitation surfaces pending state on the controller
    /// (peer + instructions) and the invitation is HELD for the user —
    /// not answered until Accept/Decline.
    func testUntrustedInviteSurfacesPendingState() throws {
        guard let controller = controller("surface") else {
            return XCTFail("test defaults unavailable")
        }
        XCTAssertNil(controller.pendingPairingPeer)
        XCTAssertNil(controller.pairingStatusMessage)
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertEqual(controller.pendingPairingPeer, admin)
        XCTAssertNotNil(controller.pairingStatusMessage)
        XCTAssertTrue(box.verdicts.isEmpty,
                      "invitation must be held for UI confirmation, not pre-answered")
        XCTAssertTrue(controller.transport.hasPendingPairingRequest)
    }

    /// Accept records the entered admin code (`preparePairing`) and
    /// answers the held invitation (`acceptPendingInvitation`), then
    /// clears the confirmation UI.
    func testAcceptProceedsThroughHandshakePath() throws {
        guard let controller = controller("accept") else {
            return XCTFail("test defaults unavailable")
        }
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertTrue(controller.acceptPairingRequest(enteredCode: "482916"))
        XCTAssertEqual(controller.pairing.expectedPeerCode, "482916",
                       "accept must record the out-of-band admin code")
        XCTAssertEqual(box.verdicts, [true], "accept must answer the held invitation")
        XCTAssertNil(controller.pendingPairingPeer)
        XCTAssertNil(controller.pairingStatusMessage)
        XCTAssertFalse(controller.transport.hasPendingPairingRequest)
    }

    /// A blank code entry is refused: nothing is recorded, the held
    /// invitation stays held, and the request stays pending — Accept
    /// can never become accept-without-code.
    func testAcceptWithBlankCodeKeepsPending() throws {
        guard let controller = controller("blank") else {
            return XCTFail("test defaults unavailable")
        }
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertFalse(controller.acceptPairingRequest(enteredCode: "   "))
        XCTAssertNil(controller.pairing.expectedPeerCode)
        XCTAssertTrue(box.verdicts.isEmpty, "blank accept must not answer the invitation")
        XCTAssertEqual(controller.pendingPairingPeer, admin)
        XCTAssertTrue(controller.transport.hasPendingPairingRequest)
    }

    /// Decline rejects the held invitation and clears the UI.
    func testDeclineRejectsInvitation() throws {
        guard let controller = controller("decline") else {
            return XCTFail("test defaults unavailable")
        }
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        controller.declinePairingRequest()
        XCTAssertEqual(box.verdicts, [false], "decline must reject the held invitation")
        XCTAssertNil(controller.pendingPairingPeer)
        XCTAssertNil(controller.pairingStatusMessage)
        XCTAssertFalse(controller.transport.hasPendingPairingRequest)
    }

    /// A trusted (already-paired) peer's invitation is accepted by the
    /// transport without surfacing any request — no UI for reconnects.
    func testTrustedPeerShowsNoUI() throws {
        guard let controller = controller("trusted") else {
            return XCTFail("test defaults unavailable")
        }
        XCTAssertTrue(controller.pairing.markPaired(peer: admin))
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertEqual(box.verdicts, [true],
                       "trusted invitation must be accepted without UI")
        XCTAssertNil(controller.pendingPairingPeer,
                     "trusted reconnect must not surface a pairing request")
        XCTAssertNil(controller.pairingStatusMessage)
    }

    /// Attaching the debug view (the same `attachSync()` its `onAppear`
    /// calls) must not replace the controller's pairing handler: a
    /// later invitation still surfaces on the controller.
    func testAttachDebugViewDoesNotReplaceControllerHandler() throws {
        guard let controller = controller("attach") else {
            return XCTFail("test defaults unavailable")
        }
        SyncDebugView(controller: controller).attachSync()
        addTeardownBlock { controller.transport.stop() }
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertEqual(controller.pendingPairingPeer, admin,
                       "attaching the debug view must not clobber the production handler")
        XCTAssertNotNil(controller.pairingStatusMessage)
        XCTAssertTrue(box.verdicts.isEmpty, "invitation must still be held for UI confirmation")
    }

    /// A failed attempt restores pending state for a corrected-code
    /// retry: after accept + mismatch, the transport's failure sequence
    /// (manual request restored, then failure) leaves the request
    /// pending with retry guidance, and accepting with the corrected
    /// code restarts the handshake on the live session.
    func testFailedAttemptRestoresPendingForCorrectedCodeRetry() throws {
        guard let controller = controller("retry") else {
            return XCTFail("test defaults unavailable")
        }
        let box = try invite(controller, from: admin, verdicts: VerdictBox())
        XCTAssertTrue(controller.acceptPairingRequest(enteredCode: "000000"))
        XCTAssertEqual(box.verdicts, [true], "first accept must answer the held invitation")

        // Simulate the mismatch aftermath exactly as `failHandshake`
        // leaves it: entered code cleared, then the admin's next
        // challenge restores the child's manual request (round-5 item 6;
        // same driver shape as `testR5_6`), then the failure callback.
        controller.pairing.failProvisionalAttempt(peer: admin)
        let session = MCSession(peer: MCPeerID(displayName: "probe"),
                                securityIdentity: nil, encryptionPreference: .required)
        let challenge = "{\"challenge\":{\"nonce\":\"retry-nonce\",\"from\":{\"stableID\":\"\(admin.stableID)\",\"displayName\":\"\(admin.displayName)\"}}}"
        controller.transport.session(
            session, didReceive: handshakeData(challenge),
            fromPeer: MCPeerID(displayName: admin.displayName))
        controller.transport.onPairingFailure?(admin)
        XCTAssertEqual(controller.pendingPairingPeer, admin,
                       "failed attempt must restore the request for retry")
        XCTAssertNotNil(controller.pairingStatusMessage)
        XCTAssertTrue(controller.transport.hasPendingPairingRequest)

        // Corrected-code retry proceeds through the manual handshake
        // branch of the existing accept path.
        XCTAssertTrue(controller.acceptPairingRequest(enteredCode: "482916"))
        XCTAssertEqual(controller.pairing.expectedPeerCode, "482916")
        XCTAssertNil(controller.pendingPairingPeer)
    }
}
