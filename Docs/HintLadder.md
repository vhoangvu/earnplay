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
  values — no model inference. No level ever reveals the answer:
  nudge and strategy never mention it, and the worked step shows
  one intermediate step (a near-complete product, all but the last
  group, converted-but-uncompared/unadded fractions, a first
  subtraction, a blanked evidence sentence) that is cross-checked
  against `SolverService`'s answer for the same values and stops
  short of the solution. If the solver rejects the proposal's
  values — or the proposal does not re-verify to exactly the
  supplied question (a mismatched pair) — no hint is shown and no
  event is logged (fail closed).
- Fraction hints use checked arithmetic: when the common
  denominator overflows `Int` on a pair the solver still verifies,
  comparison hints switch to a cross-multiplication strategy
  instead of trapping.

## HintEvent log

One `HintEvent` per level shown: `questionId`, `level`, `hintText`
(what was offered), `shownAt` (when; clock is injectable for tests),
and `answerBeforeHint` (the last answer submitted before the hint).

Changed-answer tracking: `recordAnswerSubmission(_:)` is called for
every answer the child submits. The first submission after a hint
resolves that hint's event — `followedByChangedAnswer` becomes true
when the submission differs in value from `answerBeforeHint`
(equivalence follows the current skill's grading: reading ignores
case and punctuation, comparison treats `==` as `=`, addition
compares fraction values such as `2/4` vs `1/2`), false when it
matches or when there was no prior answer (a first answer is not a
revision); `nextAnswer` keeps the resolving answer. Hints still
awaiting an answer keep `followedByChangedAnswer == nil`. An
optional `HintEventSink` receives each event on showing and again
on resolution (upsert by question + level), mirroring
`HintListenEventSink`; notifications are queued under each
ladder's lock in state-change order and drained asynchronously
and serially on one shared queue, so callbacks never overlap
even when successive questions share a session log sink, an
older unresolved event can never overwrite its own resolution,
and a synchronous sink that reads ladder state back cannot
deadlock the Hint tap.

The mismatch check binds values, not just text: `VerifiedQuestion`
carries the source operands, fractions, and operation it was
verified from, so a same-prompt same-answer collision from
different values (6×6 vs 9×4) is still rejected. Degenerate
addition (all single-digit or all multiples of ten) splits one
addend instead of showing a partial sum that equals the answer;
zero take-aways are ignored before choosing the subtraction step.
Multiplication nudges name no operand orientation (rendered
stories use opposite orientations per skill); zero products use a
conceptual step instead of the near-complete-product template.
Quotient-one division leaves the remaining groups for the child.
Same-denominator fractions name that no rewriting is needed and
work from the numerators. Reading evidence is the unique
answer-containing sentence, or — when several contain the answer
— the single candidate that alone satisfies the generation
verifier, falling back to question-word overlap only for shapes
the verifier does not support; on ambiguity no sentence is
quoted. Blanking follows the reading grader's normalization, so
every accepted spelling of the answer is blanked.

## Tests

`HintLadderTests` (EarnPlayCoreTests): for 12 fixture problems,
hints 1–3 are requested in order; each worked step is asserted
against a hand-computed intermediate fragment (12/12 matches),
and every level of every fixture is asserted not to reveal the
independently solver-computed answer (comparison hints must show
no comparison symbol at all), with exactly one HintEvent per
level (36 events). Also covered: ordering, fourth-request
exhaustion with no duplicate event, tutor-message delivery,
changed/unchanged/skill-equivalent resolution (reading,
comparison, fraction respelling), multi-hint resolution, sink
notifications including a synchronous sink that reads ladder
state back, reading worked steps quoting blanked passage
evidence, fail-closed behaviour on solver-rejected values and
on mismatched proposal/question pairs, and the
huge-denominator comparison that takes the cross-multiplication
path without trapping. Fix round 2 adds: operand/operation
binding collisions, concurrent-tap sink serialization and
ordering, degenerate-addition and zero-subtraction stop-short
steps, normalized blanking of every accepted spelling,
division-strategy nonnegative-leftover wording, and
question-relevant (or abstaining) reading evidence. Fix round 3
adds: shared-sink serialization across ladders, orientation-free
multiplication nudges, zero-product and quotient-one stop-short
steps, same-denominator fraction worked steps, and
verifier-based reading evidence (fox/hen).
