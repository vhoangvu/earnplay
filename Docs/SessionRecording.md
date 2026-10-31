# Session recording — child-side practice pipeline (issue #63)

Owner modules: `PracticeSessionRecorder` (EarnPlayCore) plus the recording
hooks in the child app's `DemoTutorEngine`. This is the production
`SessionLog` producer that closes the "Known gap" in `Docs/Dashboard.md`:
practice detail now flows from the child practice session to the admin
dashboard. The pre-existing child sync-debug demo session remains a
decisions-only debug path; it is not the producer.

## Producer

- `PracticeSessionRecorder` (EarnPlayCore): one per practice session. It
  owns the T1.4 `EffortSessionRecorder` for the same session, so the
  effort snapshot always equals the T1.4 evaluation of the recorded
  events. Per question it tracks: question start/end, interaction dates,
  hints shown, and the last graded solver verdict.
- `DemoTutorEngine` (child app): when constructed with
  `PracticeRecordingDependencies`, `startSession` starts a recorder,
  `submitAnswer`/`requestHint` feed it from the verified path, and the
  last correct answer (or an explicit `finishRecordingSession`) builds
  the log and enqueues it. Nil dependencies disable recording with no
  filesystem writes (existing demo behavior, used by older tests).
- Production wiring lives in `EarnPlayApp` (`productionDefault`: real
  `DecisionLogger`/`SessionLogQueue`/`PolicyStore`, one `EffortScorer`
  draw per session, UUID session ids, live clock). Tests inject isolated
  temp directories, a fixed scorer threshold, a fixed session id, and a
  fake clock.

Per-question facts, all from recorded sources only:

- `questionId`: the verified question's id (`demo-q1`, …).
- `skill`: the verified question's `skill` string verbatim (e.g.
  `multiplicationFacts`). Never mapped or invented.
- `correct`: the final solver verdict for the question — true only for
  `.correct`, false for `.incorrect`/`.invalid`. Probe replies are
  explanations, never graded, and never change correctness.
- `activeMs`: idle-paused engaged milliseconds on the question. Anchors
  are the question start, each recorded interaction on that question
  (hint shown, hint listened, graded answer, probe reply, composer
  activity), and the question end; each gap contributes at most 20
  seconds (`ActiveTimeTracker` default). Time beyond the pause with no
  interaction never counts. Not wall-clock.
- `hintsUsed`: count of `HintLadder.requestHint()` successes for the
  question (exhausted taps record nothing), equal to
  `ladder.events.count`.
- `errorType`: carried only for incorrect answers when the caller
  supplies a recorded classification source, else nil. No classifier
  exists on this branch, so the child pipeline always records nil —
  never invented. `SessionQuestionRecord` trims, drops blank-to-nil,
  and drops any error type on a correct answer.

Session effort snapshot: at session end the recorder evaluates the
owned T1.4 stream with the session's `EffortScorer` and stores
`(score, threshold)` as a `SessionEffortRecord`. When the session
produced no score (no scorer, or no practised question), `effort` stays
nil — never zero-filled. Sessions without practice produce no
`questionRecords` (presentation alone never creates one) and nil
effort.

Decisions: the pipeline never constructs `Decision` values. The log is
built via `SessionLog.make` with the caller's `DecisionLogger`, so the
decisions carried are exactly the ones logged through T1.6 during the
session (possibly none). The unlock convenience
`logUnlockAndMakeSessionLog` routes through the session-decision
boundary `EffortSessionRecorder.evaluateAndLog` (score + persist before
returning); an empty session logs nothing and returns nil score/decision
with nil effort. No sync-transport, pairing, shield, dashboard, or
auditor-field changes.

## Wire fields

`SessionQuestionRecord` (per question): `questionId`, `skill`,
`correct`, `activeMs` (>= 0, clamped), `hintsUsed` (>= 0, clamped),
`errorType?` (incorrect-only, trimmed, blank-to-nil). Decoding
normalizes through the same initializer, so decoded records satisfy the
same invariants.

`SessionEffortRecord` (per session): `score`, `threshold`.

`SessionLog` additions (both `decodeIfPresent`, defaulting to empty):

- `questionRecords: [SessionQuestionRecord]` (default `[]`).
- `effort: SessionEffortRecord?` (default nil).

Pre-T4.2 decisions-only logs (no new keys) and T4.5 auditor-only logs
(auditor keys, no dashboard keys) still decode unchanged, with empty
dashboard detail.

## Naming: why `questionRecords`, not `questions`

The pre-merge T4.2 branch named the dashboard detail `questions`. At the
T4.2/T4.5 merge that collided with the auditor's `questions`
(`[AuditorQuestionRecord]`: `questionId`, `form`, `difficulty`,
`answerMatched?`), so the dashboard detail was renamed to
`questionRecords` and the auditor kept `questions` (see the `SessionLog`
header comment and `Docs/Dashboard.md`). The two lists are independent:
auditor records describe question quality/difficulty for the checks;
dashboard records describe practice outcomes (correctness, active time,
hints, error type) for the aggregates. The pipeline writes only the
dashboard pair and never touches the auditor fields.

## End-to-end path

1. Practice: `DemoTutorEngine.startSession` → child answers/hints/probe
   replies → last correct answer reports `sessionComplete` (or tests
   finish an incomplete session explicitly for a final incorrect).
2. Finish: `PracticeSessionRecorder.finishSession` builds
   `questionRecords` + `effort`; `makeSessionLog` combines them with
   `logger.decisions(for: sessionId)` via `SessionLog.make`.
3. Queue: `SessionLogQueue.enqueue` persists the log in the child
   outbox (`pending-session-logs.json`).
4. Sync: the existing `ChildSyncService` drains the queue
   (`pending` → send → admin ack → `removeDelivered`); transport,
   pairing, and retry are unchanged.
5. Admin store: `SessionLogStore.storeResult` persists by `sessionId`
   (exactly-once; duplicates acked, failures not acked).
6. Read: `Dashboard.compute` aggregates `questionRecords`/`effort` plus
   `.offerTrade` decisions; the admin debug/session view shows the log
   with detail.

Manual verification (run by a human, not CI): complete a known practice
session on the child device (record accuracy/hints by hand), sync, open
the admin store/debug view and the Progress tab, and compare the synced
detail and aggregates to the hand record. Expected: exact match; empty
sessions show "not yet" states, never zeroes. No score, timer,
countdown, or pass/fail language is user-visible anywhere on this path,
and production code carries no sample or hard-coded data (fixtures live
in tests only).

## Failed-enqueue retention (round 2 handoff, round 3 quit survival)

When a session log's queue enqueue fails, the engine hands the finalized
log to the app-scoped `ChildSyncController` (`onEnqueueFailed`, wired in
`EarnPlayApp`), which retains it by sessionId and retries through the
shared `SessionLogQueue` on lifecycle triggers (controller start,
foreground) — the same queue instance, the same sessionId dedupe, the
same `notifySessionEnqueued` delivery kick. Retention is also persisted
best-effort to `pending-failed-logs.json` beside the queue, loaded on
controller init and re-persisted on every retain and drain, so a retained
log survives app quit.

Residual limitation: the retention write is only as reliable as the disk.
When the enqueue failure is disk-full, the retention write fails the same
way and retention stays memory-only — a quit before any retry trigger
then loses the log. This is accepted as a bounded residue (no second
storage subsystem); the in-memory list is always retained regardless.

## Pairing confirmation: production surface (issue #65, closes the known gap)

First-time (untrusted) pairing previously had no reachable confirmation
surface: `ChildSyncController` set no `onPairingRequest` handler, and the
only confirmation UI lived in `SyncDebugView` inside the unreachable
`previewHarnesses` — so a fresh install could not pair in production (the
transport refuses untrusted invitations while no handler is set).

The controller is now the sole owner of the pairing-request surface: it
sets `transport.onPairingRequest` (and `onPairingFailure`) in `init` and
publishes the pending request (peer, instructions, pending flag) plus
accept/decline actions. `ContentView` presents the confirmation sheet
whenever a request is pending, from any app state (including
mid-practice-chat) — never gated behind setup or settings. The sheet
shows the peer name, this device's local code, an admin-code entry
field, Accept, and Decline; Accept records the entered code and proceeds
through the existing challenge-response handshake, Decline rejects the
invitation. `SyncDebugView` sets no pairing handlers (opening it cannot
clobber the production handler); its code-entry/Accept row observes the
same controller state. Trusted reconnect stays automatic (no UI), and a
failed attempt restores the request for a corrected-code retry. No
handshake, transport, or cryptography changes.
