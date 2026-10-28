# T1.2 — Question generation + verification loop

Owner modules in EarnPlayCore: `QuestionGenerator`
(`QuestionGeneration.swift`), `ModelQuestionProposer`
(`ModelQuestionProposer.swift`), `FallbackQuestionBank`
(`FallbackQuestionBank.swift`). Implements the LLD Section 5 solver
contract steps 5-6, the LLD Section 10.2 validation gates, and the
SSOT Section 5 form rule. Upstream: T0.2 `ModelRuntime` proposes, T0.3
`SolverService` verifies. Neither is reimplemented here.

## The loop

1. A caller supplies a `QuestionGenerationRequest` (skill, difficulty,
   grade). The model proposer is asked for one structured proposal:
   skill + form + values (and, for reading, passage + candidate answer).
   The loop rotates a form hint (story → reverse → estimation →
   which-is-wrong → irrelevant-numbers) across attempts and questions
   so consecutive questions vary in surface form.
2. Loop gates, in order: the proposer threw or returned nothing
   parseable; the proposal practises a different skill than requested;
   the proposal uses plain textbook form (`.direct`); the proposal has
   no question text. Any of these is one failed attempt.
3. Presentation-text gate (Copilot round-1 F1): for computed skills
   the loop discards the proposer's free-form `promptText` and renders
   the displayed text with `QuestionPromptRenderer` from the same
   structured values the solver computes from, so wording and answer
   cannot diverge. For reading it requires the text to contain the
   supporting passage verbatim (otherwise `.promptTextMismatch`).
4. Solver gate: `SolverService.verify` computes the answer
   deterministically. Only on success is a `VerifiedQuestion` created,
   and only that question may be presented. The model's own stated
   answer is never read (the proposal parser has no answer field for
   the computed skills; the reading candidate is kept only after the
   solver's passage-support check).
5. On failure the loop retries with a new proposal. Bound:
   `maxAttempts = 3` proposals per question (`QuestionGenerator.
   defaultMaxAttempts`; configurable at construction, minimum 1).
6. When the bound is exhausted, the loop serves a pre-verified
   `FallbackQuestionBank` entry for the same skill, re-verified through
   the solver with the new question id. If the bank holds nothing
   verified for the skill, the loop throws
   `QuestionGenerationError.noVerifiedFallback` rather than presenting
   anything unverified. There is no path that returns an unverified
   question.

Every call returns a `QuestionGenerationResult`: the verified question,
its source (`.modelVerified` / `.fallbackBank`), `attemptsUsed` (never
above the bound), the per-attempt verify log, the structured `proposal`
the question was verified from (for independent re-solving), and a
`finalVerification` record holding the delivered question's own solver
pass and source — recorded separately from the bounded attempt log, so
fallback items also carry a pass (F5). Callers log these — the
acceptance rule is that any presented item without a solver pass in
the log fails.

Per-question variation (F4): each `generate` call takes a monotonic
`variationIndex`; the model prompt names that variation and attempt,
and `ModelQuestionProposer.samplingSeed(for:)` derives a deterministic
per-request seed threaded to `ModelRuntime.generate(...seed:)`
(default 42 for other callers). Same request sequence replays to the
same prompts/seeds; successive questions never reuse identical inputs.

## Interface T1.1 / T1.8 will call

- T1.1 (diagnostic) produces a per-skill profile; the caller maps the
  target skill to `QuestionGenerationRequest(skill:difficulty:grade:)`.
  This task defines no profile type (T1.1 owns it and is a parallel
  stream) — the request value above is the whole contract surface.
- Production wiring: `QuestionGenerator(proposer:
  ModelQuestionProposer(runtime: ModelRuntime(...)))`. Tests and the
  debug "bad model" toggle inject any other `QuestionProposing` source.
- T1.8 (chat UI) calls `generate(_:)`, renders only the returned
  `VerifiedQuestion` (prompt text, plus passage for reading), and must
  never render a raw proposal. Attempt correctness is judged with
  `SolverService.checkAnswer(_:proposedAnswer:)` against the question's
  `verifiedAnswer` (LLD step 7) — that is T1.8/T1.3 wiring, not part of
  this loop.
- T1.3 (hints) consumes the same `VerifiedQuestion` (values are the
  proposal's, recoverable from the generation result's skill/form plus
  the question record; hint content rules stay with T1.3).

## Fallback bank

`FallbackQuestionBank.demo`: 16 hand-written entries (2+ per skill)
across multiplication facts to 12x12, multi-digit multiplication,
division, fraction comparison, fraction addition, word problems, and
reading. At construction the bank keeps only entries the solver
verifies and only presentable forms; serving rotates deterministically
per skill (no immediate repeats) and re-verifies on every serve. All
entries are real-world story or puzzle-like forms; none is `.direct`.

## Deviations and choices (the LLD pins neither)

- **Retry bound number.** LLD Section 5 step 5 says "a fixed small
  retry count" with no number. Chosen: 3 proposal attempts per
  question. It is a named constant, so changing it is a one-line change
  with the tests updated to match.
- **`.direct` form.** T0.3's `SolverForm` includes `.direct` and the
  solver computes it, but the LLD Section 2.3 form list excludes it.
  The loop therefore rejects `.direct` proposals as a failed attempt.
  Solver behaviour is unchanged.
- **Skill-profile shape.** The LLD names a per-skill profile but pins
  no Swift type, and T1.1 is a parallel task. This loop takes the
  plain `QuestionGenerationRequest` value above instead of inventing a
  profile type for T1.1 to adopt.
- **Reading prompts.** Fallback reading entries repeat the passage
  inside `promptText` (passage + question in one presentable string)
  while also carrying it in `passage`, matching how the solver retains
  the passage on the verified question for review.
