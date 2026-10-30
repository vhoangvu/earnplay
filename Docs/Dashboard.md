# T4.2 — Dashboard

Owner modules: `Dashboard` (aggregates, in EarnPlayCore) and
`DashboardView` (parent screen, in EarnPlayAdmin). Consumes the merged
T1.6 `Decision` records and T4.6 synced `SessionLog`s as-is; the sync
queue, store, codec, and decision schema are unchanged.

## SessionLog detail (backward-compatible)

T4.2 adds two optional fields to `SessionLog`, both defaulting to empty:

- `questions: [SessionQuestionRecord]` — per-question skill, correctness,
  idle-paused active ms, hints used, and error type (incorrect only).
- `effort: SessionEffortRecord?` — the session's T1.4 score vs threshold
  snapshot.

Decoding uses `decodeIfPresent` for both, so pre-T4.2 decisions-only logs
still decode and sync unchanged. No producer invents detail: sessions
without recorded practice (e.g. the child sync-debug session) sync with
empty detail, and the dashboard renders those cards as "not yet" states.

## Known gap: no child-side detail producer yet (fix round 1)

No production path attaches practice detail to `SessionLog` before
upload — the only producer is the child sync-debug demo session, which
carries decisions only (`SessionLog.make` defaults). Wiring the five
detail-dependent aggregates (accuracy, active time, hint rate, top
error, effort trend) requires a child-side practice pipeline that does
not exist on this branch: there is no TutorEngine/practice chat
recording per-question results, and the only effort scorers run in
demo-scoped or interaction-only contexts that never reach sync.

The missing producer must record, per session, before `sendSessionLog`:
per-question `SessionQuestionRecord`s (questionId, skill, correct,
idle-paused activeMs, hintsUsed, errorType for incorrect answers) plus
the session's T1.4 `EffortScore` as a `SessionEffortRecord` (score,
threshold). Until that pipeline exists, child-produced logs leave the
five detail cards in their "not yet" states by design (never zero-filled
or invented); the manual two-session check below can only verify the
trade card end to end, and the other five aggregates are verified
against the hand-calculated fixture in `DashboardTests`.

## The six aggregates (`Dashboard.compute`)

Pure and deterministic over `([SessionLog], now, calendar)`:

1. Accuracy per skill, this week vs last — correct/total per skill over
   sessions in the calendar week of `now` vs the week before (by
   `startedAt`). Empty weeks are nil; skills outside both weeks omitted.
2. Active time per question — total active ms / question count, all logs.
3. Hint rate — share of questions with `hintsUsed > 0`, all logs.
4. Most common error type — mode of `errorType` over incorrect questions;
   ties break alphabetically (Unicode scalar order).
5. Effort trend — scored sessions oldest-first; direction is last vs
   first (rising / steady / dipping); fewer than two points has none.
6. Trade frequency — `.offerTrade` decisions counted, split movement vs
   chore by the exact `TradeOfferDecider.justification` outcome prefixes
   (anything else counts as other), plus trades per session.

## Screen rules (`DashboardView`, admin Progress tab)

- Synced logs only: every number comes from `SessionLogStore.allLogs`.
  No sample, fixture, or hard-coded data in the view.
- Empty state: no synced logs shows "No synced sessions yet" plus how to
  sync — never zeroes. Per-card gaps likewise show "not yet" words.
- No effort numbers, pass/fail language, timers, or countdowns anywhere
  user-visible. Trying over time is a direction word plus relative,
  date-labeled bars with no raw numbers.

## Automated tests

`DashboardTests` (package gate): a 4-session fixture spanning three weeks
asserts all six aggregates against hand-calculated values (12 tests:
6 aggregate tests plus tie-break, unscored-session, empty-state,
decisions-only, producer-wording guard, and pre-T4.2 decode tests).

## Manual verification (demo)

1. Complete 2 known sessions on the child device (record your own
   accuracy by hand). 2. Sync. 3. Open the Progress tab — accuracy,
   active time, hint rate, top error, effort trend, and trade count are
   all populated. 4. Compare accuracy and trade count to your hand record.
   Expected: exact match. (Until the producer in the known gap above
   exists, only the trade count populates from child logs.)
