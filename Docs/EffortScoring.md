# T1.4 — Effort scoring

Owner module in EarnPlayCore: `EffortScorer`
(`EffortScoring.swift`). Deterministic code only; the tutor model is
never consulted, and answer correctness is never an input — a session
of wrong answers with genuine trying passes, an idle session fails.

## Scoring (Band B, grades 3–5)

`EffortWeights.bandB` (Band A weights are v1 scope, T6.7/T6.8):

| Signal | Points |
| --- | --- |
| Whole active minute | 1 |
| Genuine attempt | 2 |
| Hint interaction | 2 |
| Follow-up interaction | 1 |
| Answer revision | 1 |
| Verbal explanation given | 2 |

Partial active minutes never score; negative counts clamp to zero.
Verbal explanations are weighed alongside retries (attempts +
revisions), hint use, and active time, per the Band B rule.

## Active time (~20-second idle pause)

`ActiveTimeTracker.activeSeconds(...)`: anchors are the session start
plus every recorded interaction. Each gap between anchors (and to the
evaluation time) contributes at most `idlePauseSeconds` (default 20).
Time beyond about 20 seconds with no interaction is paused and never
scores; active time resumes on the next interaction without counting
the idle gap, so a score does not rise while the child is idle.

## Threshold and floor rule

- One `EffortScorer` per session. Its threshold is drawn once at
  construction from `8...14` (`EffortScorer.thresholdRange`), from the
  system RNG (`init()`), a seeded RNG (`init(seed:)`, reproducible for
  scripted fixtures), or an explicit value clamped into the range
  (`init(threshold:)`). Because the draw varies per session, the
  target cannot be learned.
- Floor rule (`EffortFloorSettings` from T2.1's `Policy`, default
  1 + 1): at least one genuine attempt **and** at least one real hint
  or follow-up interaction. Below the floor, no amount of elapsed or
  active time unlocks, even when the score exceeds the threshold.
  Both minima clamp to at least 1 (construction, policy decode, and
  scoring all enforce it), so policy can strengthen the mandatory
  floor but never remove it.

## Interface for T1.5 / T1.6 / T3.1 / T5.1

- Record a session with `EffortSessionRecorder`: `recordAttempt()`,
  `recordHintInteraction()`, `recordFollowUpInteraction()`,
  `recordAnswerRevision()`, `recordExplanation()`, and
  `recordInteraction()` for any other interaction. Every recorded
  event also resets the idle pause. `signals(at:)` scopes both the
  active time and the event counts to the session evaluation
  interval (`startedAt...evaluatedAt`): events before the session
  started or after the evaluation time score nothing. Or build an
  `EffortSignals` value directly (its `activeSeconds` must already
  be idle-paused).
- Score with `EffortScorer.evaluate(_:)` (alias `score(_:)`). The
  returned `EffortScore` carries the required `(score, threshold,
  floorMet)`, the per-signal `breakdown`, `unlockGranted`, and the
  `decision` (`.granted` / `.denied`) that T1.6 consumes: grant the
  unlock as a reward only when `decision == .granted` (threshold and
  floor both hold).
- On a grant, `EffortScore.narration` is the reward narration naming
  the specific effort observed (active minutes, tries, hint or
  follow-up use, revisions, explanations). On a denial it names the
  effort so far and never claims the unlock.
- Legacy callers: `points(activeSeconds:attempts:)` still exists and
  now uses the Band B weights above.

## Recorded hint interactions (T1.3 note)

T1.3's hint ladder is not present on this branch's base, so no ladder
was re-implemented here. The recorder scores *recorded* hint
interactions from two present sources: direct
`recordHintInteraction()` calls, and hint listens — the recorder
conforms to the existing `HintListenEventSink` (T1.7), so assigning it
as `ReadAloudService.hintListenSink` counts each read-aloud hint as
one hint interaction. When T1.3 lands, its ladder should record hint
use through this same recorder/signals interface; until then no
hint-ladder-specific signal (e.g. ladder rung reached) exists, and
none is scored.

## Scripted acceptance fixtures

`EffortScoringTests` reproduces both scripted outcomes from fixtures:
(a) active trying with wrong answers for the full window unlocks even
at the maximum threshold; (b) an idle session (no interaction beyond
the 20-second pauses, 0 attempts) is denied and its score does not
rise while idle; (c) attempts/time below the floor with long elapsed
time is denied. A scorer change that breaks either fixture fails
acceptance.
