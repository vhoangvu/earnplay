# T1.3 — Hint ladder

Owner module in EarnPlayCore: `HintLadder` (`HintLadder.swift`).
Implements issue #6: three hint levels — nudge, strategy, one worked
step — offered while the child works, every use logged, with
hint → changed-answer tracking. References: LLD-hintevent,
SSOT-canonical-facts-questions-and-hints, APP-how-it-works.

## Contract

- Built per question from T1.2's output, never re-implementing it:
  `HintLadder(result:)` (a `QuestionGenerationResult`) or
  `HintLadder(question:proposal:)` with the `VerifiedQuestion` and
  the `ProposedProblem` it was verified from.
- `requestHint()` delivers one ladder level per Hint tap, strictly in
  order (`.nudge` → `.strategy` → `.workedStep`); a later level is
  never offered before the earlier ones. `nextLevel` / `hasMoreHints`
  expose what the next tap would show.
- A fourth (or later) tap returns nil, delivers no chat message, and
  logs no duplicate event.
- Delivery is a tutor message in the chat thread: `Hint.tutorMessage`
  (and the ladder's `tutorMessages`) is a `TutorMessage` with kind
  `.hint` and id `<questionId>-hint-<level>` (T1.8 shape, T1.7
  speaker-button ready).
- Content is deterministic code from the proposal's structured
  values — no model inference. Nudge and strategy never reveal the
  answer; the worked step shows one step whose arithmetic lands
  exactly on `SolverService`'s answer for the same values. If the
  solver rejects the proposal's values, no hint is shown and no
  event is logged (fail closed).

## HintEvent log

One `HintEvent` per level shown: `questionId`, `level`, `hintText`
(what was offered), `shownAt` (when; clock is injectable for tests),
and `answerBeforeHint` (the last answer submitted before the hint).

Changed-answer tracking: `recordAnswerSubmission(_:)` is called for
every answer the child submits. The first submission after a hint
resolves that hint's event — `followedByChangedAnswer` becomes true
when the submission differs in value from `answerBeforeHint`
(equivalent fractions such as `2/4` vs `1/2` count as unchanged),
false when it matches or when there was no prior answer (a first
answer is not a revision); `nextAnswer` keeps the resolving answer.
Hints still awaiting an answer keep `followedByChangedAnswer == nil`.
An optional `HintEventSink` receives each event on showing and again
on resolution (upsert by question + level), mirroring
`HintListenEventSink`.

## Tests

`HintLadderTests` (EarnPlayCoreTests): for 10 fixture problems,
hints 1–3 are requested in order; each worked step is asserted
against a hand-computed fragment ending at the independently
solver-computed answer (10/10 matches), with exactly one HintEvent
per level (30 events). Also covered: ordering, fourth-request
exhaustion with no duplicate event, tutor-message delivery,
no-answer-leak in levels 1–2, changed/unchanged/equivalent-fraction
resolution, multi-hint resolution, sink notifications, reading
worked steps quoting passage evidence, and fail-closed behaviour
on solver-rejected values.
