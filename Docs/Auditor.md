# T4.5 — Auditor engine

Owner module in EarnPlayCore: `AuditorEngine` (`AuditorEngine.swift`),
with `AuditFlagManager` for the parent-driven flag lifecycle. Admin UI:
`EarnPlayAdmin/AuditorView.swift` (Auditor tab). Deterministic code
only; the auditor is a second, separate check over synced logs and is
never trusted to act on its own.

## Inputs and outputs

- Inputs: T1.6 `Decision` records carried verbatim in T4.6
  `SessionLog`s, plus the synced session excerpt per session
  (`AuditorSessionExcerpt`: raw effort field values and question
  records). `AuditorSessionExcerpt(sessionLog:)` derives the excerpt
  from a synced log by reading the field values T1.6 recorded in the
  unlock decision's evidence text, so no new child-side schema exists.
- Runtime: `AuditorRuntime.adminDefault()` — an admin-app instance
  distinct from the child-app tutor runtime (T0.2). In the Demo it is
  deterministic (`DeterministicAuditorCandidates`); runtime candidates
  alone never emit a flag without a deterministic check behind them.
- Outputs: `AuditFlag` records (LLD §2.7, exact field names:
  `flagId`, `sessionId`, `category`, `severity`, `evidence`,
  `suggestedAction`, `status`), persisted by `AuditFlagManager` in
  `audit-flags.json` on the parent device. The engine runs at sync
  time (`AdminSyncController.startIfNeeded`) and on demand (Auditor
  tab → Run auditor).

Full T4.3 transcripts and T4.4 decision-log viewers are v1 inputs and
are not built here. The Demo flag detail shows the session excerpt
plus the decision justification carried with the flag.

## The seven checks (LLD §9.1)

Sessions are read in start-time order. A flag without log evidence is
never emitted; every flag's evidence cites a concrete session and
field value.

| # | Category | Rule | Severity |
|---|----------|------|----------|
| 1 | leniency-drift | ≥3 grants, effort totals falling, latest ≤ first − 4 | watch |
| 2 | false-negative | Denied while floorMet is true and effortTotal ≥ effortBar | watch |
| 3 | gaming-pattern | ≥3 granted sessions with activeSeconds ≤ 180, genuineAttempts ≤ 2, length ≤ 5 min | act |
| 4 | difficulty-miscalibration | ≥4 questions: ≥80% one form, or matched answers ≥90% at low difficulty, or ≤10% at high difficulty | watch |
| 5 | behavior-shift | Latest genuineAttempts ≤ 25% of the prior-session mean (≥3 prior, mean ≥3) | info |
| 6 | inconsistency | Two sessions within 2 effortTotal and equal floorMet with different grant/deny outcomes | watch |
| 7 | justification-mismatch | Justification blank/out of range, or its stated values differ from the raw log field values | act |

Severity `act` is reserved for justification mismatch and repeated
gaming evidence (LLD §9.2).

## Parent actions and limits

- `AuditFlagManager.dismiss(flagId:)` records `dismissed`; the flag
  clears from the open list and nothing else changes.
- `markActed(flagId:)` records `acted` and returns
  `AuditActionRoute.openPolicyEditor` — it routes the parent to the
  existing policy-editing surface and applies nothing itself.
- `detailRoute(flagId:)` routes to the flagged session excerpt.
- The engine and manager hold no policy reference and expose no
  policy-writing API. Any change after a flag is a parent's
  PolicyEditor save, delivered as a normal PolicyUpdate. Dismissed and
  acted statuses survive later audit runs.

## Automated test

`AuditorEngineTests` (EarnPlayCoreTests): staged fixtures per check
(grants with falling effort, high-effort denial, repeated minimal-work
grants, repetitive easy questions, sudden drop, similar-evidence
different outcomes, justification contradicting the raw log) assert
each check produces its expected flag with severity, evidence citing
the session, and a suggested action; a clean fixture set produces no
flags. Pass: 7/7 staged checks flag, 0 flags on the clean set.

## Manual verification (demo, not run by the agent)

1. Stage the demo leniency session (T5.4 moment 4) and sync.
2. Run the auditor — a leniency finding appears.
3. Open it — severity, the specific evidence (session/values), and a
   suggested action are shown, with the session excerpt and
   justification.
4. Dismiss the finding — it clears and the policy is unchanged.
   Expected: the auditor flagged and advised only; it changed nothing
   by itself.
