# Policy editor (T4.1)

Parent-facing editor for every LLD §2.1 policy field, in the admin app's
**Policy** tab (`EarnPlayAdmin/PolicyEditorView.swift`). Saving stamps
`current version + 1` and queues the full-record `PolicyUpdate` for T4.6
sync. The save pipeline (`EarnPlayCore`: `PolicyUpdate.swift`,
`PolicyUpdateQueue.swift`) edits a full `Policy` value as its draft, so
no field can be silently dropped on save.

## Field checklist (LLD §2.1 — every field has an editor control)

| LLD field | Editor control |
| --- | --- |
| `version` | Read-only line: current version, version the next save creates, queued-update count |
| `alwaysAllowed` | App-ID list with add / swipe-to-delete |
| `unblockable` | App-ID list with add / swipe-to-delete |
| `neverUnlockableOverrides` | App-ID list with add / swipe-to-delete |
| `unlockDurations.practiceMinutes` | Stepper (minutes) |
| `unlockDurations.tradeMinutes` | Stepper (minutes) |
| `effortFloorSettings.minGenuineAttempts` | Stepper |
| `effortFloorSettings.minHintOrFollowUpInteractions` | Stepper |
| `tradeCaps.maxTradesPerSession` | Stepper |
| `tradeCaps.weeklyMaxMovementTrades` | Stepper |
| `tradeCaps.weeklyMaxChoreTrades` | Stepper |
| `chorePool[].chore` | Text field per chore entry |
| `chorePool[].unlockMinutes` | Stepper per entry |
| `chorePool[].expiry` | Date picker per entry |
| `chorePool[].weeklyCap` | Stepper per entry |
| `chorePool[].verificationMode` | Picker per entry: Parent confirms / Photo proof (async) |
| `movementSettings.allowedActivities` | One toggle per activity (all four `MovementActivity` cases) |
| `movementSettings.maxReps` | Stepper |
| `movementSettings.tradeUnlockDurationMinutes` | Stepper (minutes) |

Chore entries are added with **Add chore** and removed with
swipe-to-delete. **Save** persists the admin's copy (reopening the
editor shows the saved values) and appends the new version to the
pending queue (`pending-policy-updates.json`, creation order) that
T4.6's SyncService will drain via `pendingUpdates()` /
`removeDelivered(upToVersion:)`. **Discard changes** reloads the last
saved policy.

Durability: each save journals a save-intent file before touching the
admin store, requires the store write to report `.applied` before
queueing (a stale or failed write throws and queues nothing), and
recovers on relaunch — a version saved to the store but never queued
is re-merged into the queue without another manual save. Queue
writes re-read under a cross-instance file lock, so concurrent queue
owners cannot lose each other's updates.

## Manual test (human verifier)

Simulator for this task: iPhone 17 "EarnPlay-T41"
(`4301ED0E-5BD8-4605-A6A9-44CDE2C4EE6E`).

1. Open the admin app → **Policy** tab. Check every row of the table
   above is present.
2. Change an unlock duration and add a chore with minutes and expiry →
   **Save**. Expected: the version line increments by 1 and the status
   reads `Saved version N — queued for sync (M pending)`.
3. Sync to the child device — the child debug policy view shows the new
   duration and chore. **Cannot run end-to-end: T4.6 sync is not built
   yet.** Saving only queues the update locally; nothing is delivered.
4. Reopen the editor (switch tabs and back, or relaunch the app).
   Expected: all saved values persist.

## Automated coverage

`EarnPlayCoreTests/PolicyEditorTests.swift`: `testSaveCarriesEveryFieldWithBumpedVersion`
edits each of the 20 field leaves in a fixture policy, saves, and
asserts the serialized `PolicyUpdate` contains the new value with
`version == old + 1`, plus a raw-JSON key check that no LLD field is
absent from the serialized output. Queue tests cover creation order,
persistence across re-open, delivery removal, and corrupt-file
behaviour.
