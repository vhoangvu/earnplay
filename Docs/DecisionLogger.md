# T1.6 — Decision logger

Owner module in EarnPlayCore: `DecisionLogger`
(`DecisionLogger.swift`). Append-only, persisted, sync-ready. Deterministic
code only; the tutor model never writes decisions directly.

## Schema (LLD §2.6, exact)

`Decision`: `decisionId`, `sessionId`, `type`, `outcome`,
`evidenceSummary`, `reasoning`, `alternativeConsidered`, `confidence`
(0...1), `timestamp`. `DecisionType` raw values: `grant-unlock`,
`deny-unlock`, `offer-trade`, `difficulty-change`, `session-judgment`.
T4.5 (auditor) and T4.6 (sync) build on these keys unchanged.

## Store

- File: `decisions.json` (+ `decisions-backup.json`) in Application Support
  `EarnPlay/` — same directory as `PolicyStore`, different file. Atomic
  write; primary → backup → empty fallback on load.
- Append-only: no update/delete/clear API. `decisions` (append order),
  `decisions(for:)`, `reloadFromDisk()`.
- Every append validates: all justification strings non-blank, confidence
  finite 0...1, `decisionId` unique. Failure throws `DecisionLogError` and
  appends nothing — the caller must not apply the decision's effect.
- Sync: `encodedForSync()` returns the JSON payload T4.6 copies into the
  SessionLog. No networking here.

## Live wiring (this stage)

Only the T1.4 unlock path is live:

- `logUnlock(evaluation:floorSettings:sessionId:appId:durationMinutes:...)`
  maps `EffortScore.decision` to grant/deny and builds the justification
  from the actual signals (`unlockJustification(for:...)` — pure,
  deterministic). Evidence names active time, attempts, hint/follow-up use,
  revisions, explanations, score vs threshold, floor state. Grant and deny
  texts are distinct.
- `evaluateAndLog(signals:scorer:...)` scores and logs atomically. Apply the
  unlock effect only when it returns; on throw, no record exists.

## Test-only seams (no live callers yet)

- `logDifficultyChange(...)` — TutorEngine calls this when it lands.
- `logTradeOffer(...)` — T3.x managers call this when they land. No trade
  code is invented here.
- `logSessionJudgment(...)` — session-judgment decisions when defined.
- `logUnlockGrant` / `logUnlockDeny` — caller-built unlock justifications.

The automated test drives grant + deny through `evaluateAndLog` and
difficulty through its seam, asserting 3/3 complete records with correct
types and ordered timestamps.

## Routine actions

`routineReason(_:)` normalizes to a single line. Routine reasons are never
`Decision` records and never touch this log.

## Manual-only (not verified here)

The debug log viewer steps from the task breakdown (earn an unlock live,
open the viewer, read the grant/deny entries) are manual-only: no viewer
exists in the child app yet, so they are noted, not claimed verified.
