# T1.5 — Stalling probes

Owner module in EarnPlayCore: `StallingDetector`
(`StallingDetection.swift`). Deterministic code only; the tutor model is
never consulted. Correctness is judged against the solver-verified answer
(LLD §5) and only routes events (a correct answer is progress); effort
itself still comes from the T1.4 signals.

## Firing rules (LLD §4)

No single signal decides; the pattern decides. All thresholds live in
`StallDetectorConfiguration` (defaults shown):

| Pattern | Rule |
| --- | --- |
| Repeated identical wrong answers | 3 consecutive identical wrong answers (trimmed, case-insensitive), no revision since the run started |
| Rapid guessing | 3 consecutive answers with inter-attempt gaps under ~2s (the LLD guessing line), no revision |
| Hint used as an answer key | Hint interaction, then a correct answer within 10s with no revision or work in between |

Trying evidence never fires: varied answers, answer revisions,
hint-then-changed-answer-after-time, and thinking-range response gaps.
The first attempt's response time is not evaluated (question-presentation
timing arrives with TutorEngine/T1.8); the rapid rule uses inter-attempt
gaps only.

## Episodes: at most one probe each

A probe fires at most once per stalling episode. After a probe fires, the
episode stays open — further identical or rapid answers fire nothing —
until trying evidence closes it: a substantive probe reply, an answer
revision, a varied answer after a thinking-range gap (a rapid varied
answer continues the episode), or a correct answer. A later new episode
may probe again. Prompts alternate across probes in a session, starting with
"Show me one step — how did you start?", then "What have you tried so
far?".

Each `StallProbe` carries its prompt, a chat `TutorMessage` (kind
`.probe`), the trigger time, and the firing `StallSignal`s for T1.6's
Decision evidence trail.

## Probe replies are T1.4 effort

`StallProbeSession` wires one detector to one T1.4
`EffortSessionRecorder`: attempts, revisions, and hints feed both, so T1.4
counts are unchanged by the detector's presence. Reply handling:

- Substantive reply (trimmed text ≥ 3 characters including at least one
  letter or digit — punctuation-only replies such as `...` never count):
  records **one follow-up interaction** (LLD 3.3 — replying to a follow-up
  question is a real hint-or-follow-up interaction for the floor) **plus
  one explanation** (LLD 4.1 — the strongest effort signal available), and
  closes the episode. The reply is shown work, so it also resolves any
  pending hint answer-key check.
- Empty/short reply: records only a generic interaction (active-time
  accounting); the probe stays pending and the classification stays
  `.stalling` (LLD: no reply keeps the stalling classification).
- Reply with no probe pending: records nothing.

## Classification

`classification` is `.stalling` while a probe is pending, else `.trying`
once trying evidence has been observed, else `.uncertain`. Consumers:
EffortScorer and (later) the trade managers' offer decision.

## Child-app presentation (no chat UI yet)

The full chat UI is T1.8's scope. T1.5 presents the probe through
`StallProbePreviewView` in the existing session UI (`ContentView`), the
same preview pattern T1.7 used: a one-question demo session (7 × 8) with
answer submit, an always-available Hint button, the probe card with a
speaker button and reply field, and debug event counts (never the score
or threshold). T1.8 adopts the probe's `TutorMessage` into the thread;
the view holds no behavior logic.

## Scripted acceptance fixtures

`StallingDetectionTests` reproduces the task's automated test: (1) a
fixture stream of 3 identical wrong answers with no revision fires exactly
one probe; (2) a varied-attempt stream fires none; (3) a substantive
probe reply writes effort events (follow-up + explanation). Further tests
pin the at-most-once-per-episode rule, episode resolution, each firing
rule and its trying counter-evidence, and unchanged T1.4 counting.

Manual-only (not runnable here): the live-session steps — entering the
same wrong answer 3 times shows a probe in the tutor's voice, a real
explanation reply visibly resumes effort, and a varied/revising session
shows no probe.
