# T3.1 — Movement trade

Owner modules in EarnPlayCore: `MovementTradeManager` (offer gate),
`VerifiedRepCounter` (rep counting), `MovementTradeSession` (offer state
machine), `MovementTradeHistoryStore` (caps/taper history),
`MovementTradeViewModel` (observable session driver), `MotionFixtures`
(injected motion). App target: `CoreMotionSampleProvider` (real sensor),
`FixtureReplayProvider` (simulator replay), and the offer/live-counter
views in `MovementTradeViews.swift`. Deterministic code only; the tutor
model proposes the moment, this code disposes.

## Offer gate (AI-initiated only, floor first)

`MovementTradeManager.decide(_:policy:)` is the only path to an offer.
Checks run in order; the first failure is the refusal reason:

1. Initiation must be `.aiLowMotivation` (the AI judges patience
   exhausted while the child still wants the unlock). `.childRequest`
   and `.none` are refused as `.notAIInitiated` — there is no menu,
   button, or phrase that summons an offer.
2. The T1.4 floor must hold (`EffortScorer.floorMet` on the session
   signals, read with the policy's `EffortFloorSettings`).
3. Session cap: `sessionOffersUsed < tradeCaps.maxTradesPerSession`
   (default 1 — one offer per session across trade types).
4. Weekly cap: movement grants in the trailing 7×24h window
   (`MovementTradeHistory.completionsInTrailingWeek`) must be below
   `tradeCaps.weeklyMaxMovementTrades` (default 3).
5. Taper rule (see below) when the pattern holds.
6. The policy must allow at least one activity; the offer picks the
   first canonical activity allowed
   (`jumpingJacks → runningInPlace → squats → marchingInPlace`).

Refusals end the trade moment for the session (terminal) except taper
refusals, which the next session re-evaluates with fresh history.

## Rep target and grant

- Target: `defaultTargetReps` (10) clamped to `1...maxReps`. The LLD
  fixes only `maxReps` (default 20); 10 is the chosen demo default.
- Grant: `movementSettings.tradeUnlockDurationMinutes` (default 15),
  automatic on verified completion — no parent approval (LLD §7.1).
  Note `Policy` also carries `unlockDurations.tradeMinutes`; the
  movement-specific setting governs movement grants. Default policy:
  15 min trade < 30 min practice, asserted in tests.

## Rep verification (phone in pocket)

`VerifiedRepCounter` watches the deviation of acceleration magnitude
from 1g (`MotionSample.magnitudeDeviation`). One rep is one full
oscillation: the detector arms on the rising +0.35g crossing and
completes on the falling −0.35g crossing. A completed swing counts
only when all three hold:

- arm-to-complete duration in 0.25s...2.5s (exercise cadence; fast
  shaking completes in ~0.1s and is rejected);
- at least 0.4s since the previous counted rep;
- the trailing 1s window shows exercise cadence, not vibration: at
  most 8 deviation zero-crossings per second (measured over observed
  time so early vibration cannot sneak through a cold window).
  Exercise at ≤2 Hz crosses ~4/s; shaking at ≥4 Hz crosses ≥8/s.

Stillness never arms the detector. Samples rotating faster than
12 rad/s are ignored, never counted. Rejected swings are tallied as
`rejectedNoiseEvents` for the record's evidence summary.

## Motion abstraction and fixtures

`MotionSampleProvider` is the seam: the app's
`CoreMotionSampleProvider` streams `CMDeviceMotion` at 50 Hz
(userAcceleration + gravity per axis); tests and the simulator
preview use fixtures. `MotionFixtures` (seeded, exactly replayable):

- `genuineJumpingJacks` / `genuineRunningInPlace` — rhythmic pocket
  motion that counts exactly to its rep count;
- `phoneOnTable` — ~1g stillness, never verifies;
- `shakingInHand` — fast (≈5–12 Hz) erratic multi-axis motion with
  large rotation, rejected by the duration and cadence gates.

## Taper rule

`TaperRule.isPattern`: ≥4 completions in the last min(5, n) sessions
(4-of-4, 4-of-5, and 5-of-5 taper; 3-of-3 does not). When tapered:

- cooldown: an offer needs ≥2 sessions since the last movement offer
  ("offer less often"; never-offered passes);
- practice-first: ≥3 genuine attempts in the current session (the
  floor's attempt plus a short burst first).

The offer carries `taperApplied`, and the record carries
`taperPatternFlagged` for the admin app (T4.x surfaces the flag).
`sessionOffersUsed` and the weekly count come from
`MovementTradeHistory`; sessions-since-last-offer comes from the
session owner (nil when never offered).

## Session, record, history

- `MovementTradeSession`: `offered → active → granted`, with
  `declined` and `abandoned` exits. Reaching the target grants
  immediately. Out-of-phase transitions return false and change
  nothing.
- `MovementTradeRecord`: self-contained `Codable` handoff — no
  dependency on T1.6 existing yet. It becomes an `offer-trade` /
  `grant-unlock` Decision: `evidenceSummary`, `reasoning`,
  `alternativeConsidered`, and `confidence` map 1:1, plus
  `taperPatternFlagged` (admin flag) and `verificationConfidence`
  (`full` for phone-in-pocket; `reduced` records the LLD iPad caveat).
- `MovementTradeHistoryStore`: append-only JSON history in
  Application Support (`movement-trades.json`, atomic writes,
  `PolicyStore` precedent). Missing/corrupt file yields empty
  history; the session cap still bounds every session.

## App UI

`MovementTradeViewModel` (in Core, per the `ReadAloudService`
precedent) drives `MovementTradeOfferCard` (single take-it-or-leave-it
offer), `MovementTradeActiveView` (live `verified / target` counter
with progress and the phone-in-pocket instruction), and the finished
state. Production entry is `presentOffer` from the tutor only.
`MovementTradePreviewView` (placeholder-screen harness) simulates the
AI event through the real gate and replays fixtures; its simulate
trigger and motion picker are `#if DEBUG` only.

## Manual-only (NOT verified here)

The simulator cannot do real CoreMotion, so these stay manual-only:

1. Trigger a low-motivation moment (or the DEBUG simulate button) —
   the offer appears from the tutor, never from a menu.
2. Phone in pocket, do the activity — the live counter matches your
   count within 2 reps.
3. Finish — a 15-minute unlock is granted.
4. Shake the phone in hand — reps do not verify and nothing grants.

Pocket carry, the ±2-rep counter agreement, and shake-to-defeat on a
real sensor are claimed only by running these steps on device.
