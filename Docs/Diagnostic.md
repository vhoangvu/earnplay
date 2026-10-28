# T1.1 — Diagnostic engine

Owner: `DiagnosticSession` in EarnPlayCore (`Diagnostic.swift`).
Implements the LLD TutorEngine duty "runs the diagnostic at session
start", the HLD Diagnostic screen purpose ("sets the starting
difficulty for math and reading"), and the LLD Section 5 demo content
line: "The diagnostic item set is 10 minutes across facts fluency,
fractions, word problems, reading fluency, and comprehension."

## How it works

- **Verification (T0.3).** Every bank item is a `ProposedProblem`
  re-verified through `SolverService.verify` at `start()`. Items the
  solver rejects are dropped and never presented. Answers are judged
  only by `SolverService.checkAnswer` against the verified answer,
  except items declaring `acceptableAnswers`: each extra is
  re-verified against the passage (`verifyReadingSupport`) at
  `start()` and grading accepts any verified entry (normalized).
  The passageB fluency item asks how many books were on the shelf
  *before* the move, so 48 is unambiguous. The model never grades, and no model inference runs in the
  diagnostic: T1.2 owns model-proposed generation. The diagnostic bank
  is the pre-written safe item set (LLD S5 step 6 pattern), still
  re-verified per session.
- **Flow.** Round-robin across the five areas so a time cut still
  samples broadly. Per-area adaptive staircase, difficulty 1...3:
  correct steps up, incorrect steps down. Default quotas: facts 6,
  fractions 5, word problems 4, reading fluency 3, comprehension 4
  (22 items). Default budget 600 s (10 minutes), injected clock for
  tests. `abandon()` or budget exhaustion ends the session with a
  partial profile. Callers can trigger budget completion without
  answering via `expireIfNeeded()`; submissions after the budget are
  rejected before grading and complete the session instead.
  All session operations are serialized on a recursive lock, so a
  timer calling `expireIfNeeded()` cannot interleave with `submit()`
  (that synchronization justifies `@unchecked Sendable`).
- **Scoring.** Per area: accuracy, counts, median response ms
  (even-sized samples average the two middle values).
  Levels: accuracy >= 0.8 `proficient`, >= 0.5 `developing`, else
  `emerging`; unattempted areas stay `notAssessed` (unknown ≠ weak).
  Fluency areas (facts, reading fluency) also require median
  response <= 8 s for `proficient` — slow-but-accurate is
  `developing`, because fluency is accuracy plus speed.

## Profile schema (`SkillProfile`)

The LLD names `Session.skillProfileSnapshot` (a Record) and `grade`
but defines no profile field list; this schema fills that gap and is
grade-agnostic per LLD S2 (new grade = new content pack, same schema).

| Field | Meaning |
| --- | --- |
| `grade` | Content grade; demo `"4"` |
| `estimates` | One `SkillEstimate` per `DiagnosticArea` (always all five) |
| `diagnosticSessionId` | Session that produced this profile |
| `completedAt` | When the profile was built |
| `isComplete` | True only when every area met its `itemsPerArea` quota; false on abandon/budget cut or unmet quotas |

`SkillEstimate`: `area`, `level`
(`notAssessed/emerging/developing/proficient`), `accuracy` 0...1,
`itemsAttempted`, `itemsCorrect`, `medianResponseMs`,
`recommendedDifficulty` 1...3.

Persistence: `SkillProfileStore` protocol; `FileSkillProfileStore`
writes JSON atomically on-device (LLD S13, local only).

## Integration point for T1.2

T1.2 (question generation) reads the persisted `SkillProfile`:

- `profile.recommendedDifficulty(for: area)` → starting difficulty
  for generated questions in that area.
- `profile.nextFocusArea` → weakest assessed area to practise next
  (ranked by proficiency level first, accuracy as tiebreak);
  `nil` means no diagnostic data — run the diagnostic, do not guess.
- `profile.estimate(for:).level == .notAssessed` → area unknown;
  T1.2 should probe it at difficulty 1 rather than assume weakness.
- Copy the profile into `Session.skillProfileSnapshot` at session
  start (LLD S2.2) so later profile updates never rewrite history.

## Deviations / limits

- The LLD gives no profile field schema; the schema above is new
  (see note in `Diagnostic.swift`). Flagged for doc update.
- Reading fluency is scored as passage-item accuracy + latency;
  there is no speech/WCPM scoring (Future per HLD scope). Both
  reading areas use the solver's passage-support check, so
  comprehension answers must be passage-supported verbatim spans —
  inference questions the solver cannot support are out of scope
  until the solver contract grows.
- No chat UI: T1.8 owns presentation. The engine is exercised
  through unit tests only.
