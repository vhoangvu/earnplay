# Versioning + rollback (T5.3)

Records which model and prompt version ran every session, how to roll
back a regressing one, and what the admin app shows. Design basis:
LLD sections 2.2 (Session) and 10.3 (Versioning and rollback).

## What "version" means

| Kind | Current value | Source of truth in code |
| --- | --- | --- |
| Model | `meta-llama Llama-3.2-1B-Instruct, GGUF Q4_K_M (bartowski/Llama-3.2-1B-Instruct-GGUF) / llama.cpp b11935, CPU backend` | `ModelRuntime.versionStamp`, derived from `ModelRuntime.modelIdentifier` + `ModelRuntime.runtimeIdentifier` (EarnPlayCore) |
| Prompt | `spike-v1` | `SpikePrompts.version` (EarnPlayCore) |

- Model version: the T0.2 runtime's identity. The session stamp is
  derived from the runtime constants, never a copied string, so the
  stamp cannot drift from the configured build.
- Prompt version scheme: `"<set-id>-v<major>"` (see `SpikePrompts`).
  Bump the major number on any wording or rule change to the set.
  The real tutor prompt set (LLD section 10) gets its own set ID when
  it lands; the spike set stays `spike-v1`.
- A *bundle* (`VersionBundle`) is one selectable model + prompt
  pairing. `VersionRegistry` holds the registered bundles and the
  active one; sessions stamp the active bundle at session start.

## Session recording

`SessionRecord.start(sessionId:startedAt:registry:)` stamps the
registry's active `modelVersion` and `promptVersion` onto the record.
Construction validates both fields: an empty or whitespace version
throws `SessionRecordError.missingVersion` instead of producing an
unstamped record — a session without both versions is a bug, and the
tests in `EarnPlayCoreTests/VersioningTests.swift` cover that case,
the fixture-session stamp, and the rollback stamp change.

Note on scope: the full LLD 2.2 Session schema (child profile ref,
skill snapshot, end time) belongs to the session-schema task (T1.6),
which has not landed yet. `SessionRecord` carries the version-bearing
subset (ID, start time, both versions); later session code is
expected to keep stamping through this factory.

## When to roll back

Per LLD 10.3 and 12.3, roll back when:

- the regression/eval suite fails for the running version, or
- auditor flags implicate the running version (for example repeated
  justification mismatch), or
- parents report a visible behaviour regression traced to a version.

A model or prompt update ships only after the regression suite
passes; a failure blocks the update and triggers this procedure for
anything already deployed.

## Rollback procedure (model or prompt)

Prerequisite — keep the previous bundle available: *before*
selecting a new bundle, register the outgoing one under the bundle ID
`previous-known-good` (`VersionRegistry.previousKnownGoodBundleID`).
Today the production registry holds exactly one bundle, so rollback
is armed by that registration step, not by install time.

1. Confirm the regression is version-linked: compare session stamps
   (`modelVersion` / `promptVersion` on `SessionRecord`) between
   healthy and regressing sessions. If the stamps are identical, the
   cause is elsewhere — do not roll back blind.
2. Select the previous bundle:
   - Code path: `try registry.rollbackToPreviousKnownGood()`. It
     throws `VersioningError.noPreviousBundle` when no previous
     bundle was registered — an honest failure, not a silent no-op.
     Selecting an unknown bundle ID throws
     `VersioningError.unknownBundle` and leaves the active bundle
     unchanged.
   - Demo/manual path: the same selection is what the admin app's
     "Running version" panel reflects on next launch, because the
     panel and session stamping read the same registry.
3. Verify: start a new session and check its record stamps the older
   model/prompt version (automated equivalent:
   `testRollbackChangesStampedVersionAndRollForwardRestores`).
4. Record the rollback like any other version change: sessions after
   the rollback carry the older stamp, which is the audit trail (LLD
   10.3 — "rollback is a version change, recorded like any other").
5. Roll forward: fix or re-validate the regressing bundle, then
   `select(bundleID:)` it again and confirm a new session stamps the
   current version.

### Explicitly out of scope

Re-downloading old model binaries is **out of scope**. Rollback
selects among bundles already installed/registered on the device;
if the previous model file is not on the device, rollback of the
*model* half cannot complete until that file is restored by other
means (for the spike build: re-run `Scripts/setup-model-spike.sh`,
which fetches and checksum-verifies the GGUF). This procedure never
pretends a download happened.

## Known limits (admin app note)

The admin app ("Running version" panel) shows the active bundle plus
these limits (`VersionKnownLimits` in EarnPlayCore), each verified
against the current project state:

- Inference is validated on the iOS simulator only (CPU backend);
  physical-device speed is not yet measured.
  *(Docs/ModelRuntimeSpike.md, "Placeholders / unverified")*
- The runtime runs on the CPU backend with a 2048-token context; no
  Metal backend is in use. *(ModelRuntime.swift; spike note)*
- CI does not run real inference: without the fetched model and
  framework, the inference tests skip instead of passing.
  *(.github/workflows/ci.yml runs no setup script; XCTSkip guards in
  ModelRuntimeTests.swift / ModelRuntimeIntegrationTests.swift)*
- The prompt set is the 5-prompt T0.2 spike set; the full tutor
  prompt structure and output validation (LLD section 10) are not
  built yet. *(SpikePrompts.swift)*
- Rollback selects an already-installed previous bundle; it cannot
  re-download older model files. *(this procedure, out-of-scope note)*

One candidate limit was checked and **excluded**: an "exact-span
reading rule" does not appear in the source of truth, high-level
design, or low-level design in the docs repo, so it is not listed.
Update `VersionKnownLimits.notes` in the same change that removes a
limit — the admin note and this section must not drift apart.
