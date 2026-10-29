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

Manual test: (1) edit+save a policy in admin with both apps open →
child Sync section shows the new version/practice minutes in seconds;
(2) child → "Run demo session" → admin Sessions tab lists it;
(3) Airplane Mode on child, run a session, Airplane Mode off with
both apps open → queued session arrives once in the admin list.
