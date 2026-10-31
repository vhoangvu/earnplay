# Sync (T4.6)

Local peer-to-peer only via MultipeerConnectivity (`earnplay-sync`,
encrypted). No account, no server, no internet.

**Actual bearer (round 5, item 8):** MultipeerConnectivity has no
public Bluetooth-only mode. MPC automatically uses Bluetooth plus
peer-to-peer (infrastructure-less) Wi-Fi as its bearer. Both are
offline-capable: pairing and sync work with internet disabled on
both devices (no account, server, or uplink involved), as long as
the device radios are on. So "Bluetooth only" in the original
requirement is realized as "offline MPC" — the honest reading of
the requirement this implementation satisfies.

- **Down (admin → child):** `PolicyUpdate` (full versioned `Policy`).
  The T4.1 `PolicyUpdateQueue` holds updates until the child acks the
  version; `PolicyStore.apply` enforces newer-wins (stale/replayed
  discarded but acked; persistence failure not acked → retried).
- **Up (child → admin):** `SessionLog` (T1.6 `Decision`s verbatim).
  The child `SessionLogQueue` holds logs until the admin acks the
  sessionId; the admin `SessionLogStore` deduplicates by sessionId,
  so a lost ack + redelivery stores the session exactly once.
- **Offline:** sends fail while disconnected, queues persist on disk,
  and `handleReconnect` / peer-connect drains them with no re-run.
  Unacked items retry indefinitely: the retry *delay* is capped with
  exponential backoff, attempts cycle instead of expiring, a
  transient send failure schedules the next retry (continuation is
  based on the item still being pending), and a retry is cancelled
  only after the acked removal has persisted.

Manual test: (1) edit+save a policy in admin with both apps open →
child Sync section shows the new version/practice minutes in seconds;
(2) child → "Run demo session" → admin Sessions tab lists it;
(3) internet disabled on BOTH devices (e.g. Wi-Fi uplink off / no
SIM route — MPC's Bluetooth + peer-to-peer Wi-Fi bearer needs no
internet), run a session on the child with the admin closed, then
open both apps → queued session arrives once in the admin list
(the trusted child reconnects automatically, no re-pairing); also
verifiable as: Airplane Mode on child, run a session, Airplane Mode
off with both apps open → same result;
(4) pairing: the unpaired child shows its pairing code on its main
screen before any invitation arrives — the admin reads it off the
child's screen, enters it, and taps Pair (retries the invitation
even if the child was found before the code was entered); the child
confirmation sheet appears over whatever the child is doing
(including mid-practice-chat) showing the admin's name, this
device's code, and an admin-code entry field — child enters the
code shown on the admin and taps Accept (Decline rejects) → both show
paired (the child's pre-invite code row hides), then (1)/(2) flow.
A mismatched code restores the sheet for a corrected-code retry;
trusted reconnects show no sheet.

## Pairing protocol & threat model (fix round 3)

- **Identity:** each device owns a stable `PeerIdentity`
  (`stableID`, generated once per app install instance) plus a
  display name. Display names are *not* identity — every admin is
  "EarnPlay-Admin" — so admission, pairing, send filtering, and
  receive filtering compare `stableID` throughout. A second admin
  with the same display name but a different `stableID` is refused
  pairing, routing, and acks while paired.
- **No secret in the invitation:** the browser's invitation context
  carries only `PairingInvitation { inviter: PeerIdentity }`. It
  never contains a pairing code, so a nearby advertiser that
  receives (or a browser that receives an acceptance of) an
  invitation learns nothing replayable. Acceptance alone proves
  nothing and grants no paired state and no data.
- **Out-of-band comparison:** each device displays its own 6-digit
  code. Each user enters the *peer's* code on their own device
  (admin: Sessions tab; child: production pairing-confirmation sheet
  in `ContentView`, presented from any app state whenever the shared
  `ChildSyncController` — the sole owner of the pairing-request
  surface — holds a pending request; the debug view's code-entry row
  observes that same state and sets no handlers of its own). The
  child's own code is additionally shown on its main screen while
  unpaired (fix round 1, finding 1), before any invitation, so the
  admin can read it to start pairing; that display alone pairs
  nothing. That entry is each side's local confirmation; the entered
  code is stored locally and never transmitted.
- **Mutual challenge-response:** after the MPC session connects,
  each side sends a fresh per-session challenge (UUID nonce) over
  the encrypted session. Each side replies with
  `SHA-256(challenge | prover stableID | verifier stableID | entered peer code)`.
  Each side verifies the reply against its *own* displayed code.
  Pairing (`markPaired`) completes only on successful verification;
  until then `send` throws `notPaired` and inbound data is dropped.
  A rogue advertiser that accepts any invitation cannot answer the
  admin's challenge (it never saw the admin's code — it was not in
  the invitation), so it gains no paired state and no session logs;
  symmetrically for a rogue browser against the child.
- **Single peer & reconnection:** while a peer is live or trusted-
  paired, every other identity is refused invites, accepts, sends,
  and receives. After a drop, the trusted identity may be
  re-invited and reuses its verified pairing without another
  manual confirmation; other identities remain refused.
- **Provisional pairing (fix round 4, M6):** pairing completes
  only when both sides have verified each other and exchanged
  confirmations. A one-sided verification stays provisional; a
  failed verification notifies the peer so both sides reset the
  attempt, show a retryable "codes didn't match" status, and
  accept corrected codes with a fresh handshake.
- **Session binding (fix round 5, items 1-2):** the data plane is
  bound to the exact MPC session instance that authenticated.
  A second instance claiming the same stable identity is held
  unauthenticated: its policies/acks are not accepted and it is
  excluded from sends. Pairing-secret establishment is accepted
  only on a session that completed fresh mutual code
  authentication, so a claimant cannot replace the retained secret
  during unauthenticated reconnection and then answer trusted
  challenges with its own secret. One invitation and one handshake
  are outstanding at a time (item 5); unpairing rejects any pending
  invitation (item 4); after a code mismatch the child restores its
  manual request and acceptance restarts both challenge directions
  on the live session (item 6); the child Reset/Unpair control
  republishes its sync snapshot immediately (item 3).
- **Trusted reconnect proof (fix round 4, H3):** authenticated
  pairing establishes a random per-peer secret, shared once over
  the encrypted session and never equal to a user-entered code or
  the broadcast stableID. A retained pairing reconnects only
  after the peer proves possession of that secret against a
  fresh nonce; with no secret (or a failed proof) both sides drop
  the retained pairing and fall back to full manual re-pairing —
  never silent trust. Identity resolution binds each live peer
  instance to its stable identity (never its display name), and
  transport state is serialized with a lock held only around
  state access, never across sends or service callbacks (H1/H2).
- **Reconnect (fix round 4, H4):** rediscovery revives a failed
  trusted candidate, and a dropped trusted session schedules
  re-invitations with capped exponential backoff even without a
  new discovery event, still under the single-peer rules.
- **Persistence (fix round 4, M7):** the installation identity,
  its code, the paired peer, and the pairing secret persist in
  UserDefaults (`SyncPairingStore`), so a one-sided relaunch
  reconnects as the same device and queued delivery resumes.
  Reset/Unpair controls in the admin Sessions tab and the child
  sync view clear the pairing and secret (identity is kept).
- **Known limitation — active relay (fix round 6, item 2):**
  pairing proofs (`PairingAuthenticator`, fix round 3) authenticate
  the advertised stable identities and the entered codes, but they
  are not bound to the encrypted MPC channel itself. A nearby
  attacker admitted as a peer in two separate MPC sessions (one
  with each victim, impersonating the other device's stable
  identity in each) could forward challenges, responses, and
  confirmations unchanged; both victims' users would see the
  expected pairing-request and code screens — the codes are read
  from the genuine devices in the same room — so both sides would
  authorize the relay's session handle and send it the pairing
  secret and payloads, without the relay ever learning either
  displayed code. This cannot be closed with the APIs this
  implementation uses: the session is created with
  `securityIdentity: nil`, MultipeerConnectivity exposes no
  exported channel/session key or peer channel fingerprint to the
  app that the digests could be bound to, and supplying a
  verifiable `SecIdentity` would be a transport/identity rewrite
  beyond Demo scope. Accepted Demo limitation (same standing as
  the H5 deferral): the relay must be an admitted nearby peer in
  both sessions, and Demo pairing happens between two known
  devices held in the same room — pair only with the expected
  device in hand, and treat an unexpected second pairing request
  as a stop signal.
- **Limits:** this is demo/local scope. The 6-digit code is a
  human-compared short secret, not a credential; MPC transport
  encryption (`encryptionPreference: .required`) protects the
  digest exchange, and the digest binds both stable identities and
  the per-session nonce so a response cannot be replayed to a
  different peer or session. A nearby attacker who can *see both
  screens* during pairing can read the codes — pairing should be
  done with the devices in hand, as in the manual test above.
- **Durable acks:** a session is acked only after durable persistence
  (or as an already-persisted duplicate); unacked sends retry with
  capped-delay backoff. The admin service starts at app scope.
