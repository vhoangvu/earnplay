# T0.3 — Solver service contract note

Owner module: `SolverService` in EarnPlayCore (`SolverService.swift`).
Implements the LLD Section 5 solver contract: the model proposes; the solver
decides. Wrong answers can never be taught.

## What the solver verifies

Input is a structured proposal (`ProposedProblem`): skill, form type
(story / reverse / estimation / which-is-wrong / irrelevant-numbers / direct),
and the values that define the problem, plus a passage for reading. The
model's own stated answer is never an input field.

| Skill | Values | Verified answer |
| --- | --- | --- |
| Multiplication facts | two operands, each 0...12 | exact product; operands outside 12x12 are rejected as out of range |
| Multi-digit multiplication | two non-negative operands | exact product (overflow-checked) |
| Division | dividend, divisor | quotient, or `"q r R"` when there is a remainder; divisor 0 is rejected |
| Fraction comparison | two fractions | `"<"`, `">"`, or `"="` by exact cross-multiplication |
| Fraction addition | two fractions | sum reduced to lowest terms; whole results render without a denominator |
| Word problems | relevant operands + explicit operation; irrelevant prompt numbers carried separately and ignored | exact result of the stated operation; division by zero and negative subtraction results are rejected |
| Reading | passage + proposed answer | supported / unsupported verdict (below) |

Fractions are always normalized on construction: reduced by the gcd, sign
carried by the numerator, zero stored as 0/1. A proposed fraction answer is
correct when its normalized value equals the verified value, so an unreduced
but equal answer (2/4 for 1/2) is correct and a different value is not.

On success, `verify(_:questionId:)` returns a `VerifiedQuestion` whose
`verifiedAnswer` was set by the solver — the only path by which a question
may be presented (contract step 4). On failure it returns the rejection
reason; the caller regenerates within its retry bound or falls back to a
pre-verified safe question (steps 5-6). Attempt correctness
(`checkAnswer`) is always judged against the solver-computed answer (step 7).

## What the solver explicitly does NOT do

- It never calls the model, and the model never grades its own answers.
- It never makes network requests. It is plain deterministic code with no
  dependencies beyond the standard library/Foundation value types.
- It never grades by heuristics: no fuzzy matching, no tolerance bands, no
  keyword guessing. Form types change presentation only, never the computed
  answer. A word problem without an explicit operation is rejected rather
  than guessed from its text.
- It does not generate questions, and it does not solve free-form problem
  text. It verifies structured proposals and proposed answers.

## How the reading-support check works (contract step 3)

`verifyReadingSupport(passage:proposedAnswer:)` returns
`supported(evidence:)` / `unsupported` / `invalid(reason:)`:

1. Empty passage → `invalid(.missingPassage)`; empty answer → invalid.
2. Both texts are normalized deterministically: lowercased, split on
   non-alphanumeric characters, rejoined with single spaces.
3. The normalized answer must appear as a contiguous span of the normalized
   passage. If it does, the verdict is `supported` and carries as evidence
   the first passage sentence containing the span.
4. Otherwise the verdict is `unsupported`. An answer that needs inference,
   paraphrase, or outside knowledge is unsupported by definition, because
   the solver cannot confirm it from the passage alone.

## Known deviation from the LLD text

The LLD states the contract as steps 1-7 but does not pin a Swift API,
verdict type shapes, the division-remainder string format, or fraction
answer equivalence. Those shapes were chosen here to satisfy the steps
exactly and are recorded above so later tasks build on a stated contract
rather than an invented one.
