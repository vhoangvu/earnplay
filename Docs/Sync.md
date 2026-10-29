# Sync (T4.6)

Bluetooth/local peer-to-peer only via MultipeerConnectivity
(`earnplay-sync`, encrypted). No account, no server, no internet.

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
(3) Airplane Mode on child, run a session, Airplane Mode off with
both apps open → queued session arrives once in the admin list
(the trusted child reconnects automatically, no re-pairing);
(4) pairing: admin enters the code shown on the child and taps Pair
(retries the invitation even if the child was found before the code
was entered), child enters the code shown on the admin and taps
Accept → both show paired, then (1)/(2) flow.

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
  (admin: Sessions tab; child: pairing-request row). That entry is
  each side's local confirmation; the entered code is stored
  locally and never transmitted.
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
