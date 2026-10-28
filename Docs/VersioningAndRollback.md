# Versioning + rollback (T5.3)

Records which model and prompt version ran every session, how to roll
back a regressing one, and what the admin app shows. Design basis:
LLD sections 2.2 (Session) and 10.3 (Versioning and rollback).

## What "version" means

| Kind | Current value | Source of truth in code |
| --- | --- | --- |
| Model (configured spike build) | `meta-llama Llama-3.2-1B-Instruct, GGUF Q4_K_M (bartowski/Llama-3.2-1B-Instruct-GGUF) / llama.cpp b11935, CPU backend` | `ModelRuntime.versionStamp` (configured identity only — see verified identity below) |
| Model (installed file, verified) | `"<file name> (<byte count> bytes, GGUF) / llama.cpp b11935, CPU backend"` | `ModelRuntime.verifiedModelVersion(forModelAt:)` — read from the actual GGUF file (name, size, GGUF magic) |
| Prompt | `spike-v1` | `SpikePrompts.version` (EarnPlayCore) |

- Verified model identity (fix round 2, Copilot F5): a session or
  registry stamp for an *installed* file comes from
  `verifiedModelVersion(forModelAt:)`, which checks the file exists,
  starts with the GGUF magic, and names the file itself. A non-GGUF
  file is rejected with `ModelRuntimeError.invalidModelFile`, and
  `ModelRuntime.load()` applies the same check — an arbitrary GGUF
  placed via `modelPath` / `EARNPLAY_MODEL_PATH` /
  `Documents/EarnPlayModel.gguf` is never reported as Llama.
- Prompt version scheme: `"<set-id>-v<major>"` (see `SpikePrompts`).
  Bump the major number on any wording or rule change to the set.
- A *bundle* (`VersionBundle`) is one selectable model + prompt
  pairing, bound to its artifacts: `modelFilePath` (the GGUF file
  inference loads) and `promptTexts` (the prompts inference runs).
  A nil artifact means "this build's default for the version named
  here" and is selectable only when that version is the build
  default. `VersionRegistry` holds the registered bundles and the
  active one; sessions stamp the active bundle at session start.

## What selection does (exactly)

`select(bundleID:)` / `rollbackToPreviousKnownGood()`:

1. Rejects an unknown ID (`VersioningError.unknownBundle`) and
   leaves the active bundle unchanged.
2. Rejects a bundle whose artifacts cannot be applied
   (`VersioningError.artifactUnavailable`): its model file is
   missing, or it names a non-default model/prompt version without
   bound artifacts. The active bundle is left unchanged — a
   label-only rollback that would keep running the regressing
   artifacts under an old label is not possible.
3. On success, persists the new selection (see below) and changes
   what inference uses: `VersionRegistry.inferenceArtifacts()`
   returns the active bundle's model file and prompt texts, the
   child app's `SpikeView` builds its `ModelRuntime` from that
   model file and runs those prompts, and new `SessionRecord`s
   stamp that bundle's versions. The session stamp and the loaded
   artifacts therefore always agree.

## Persistence

`VersionRegistry.production()` persists registered bundles and
the active selection as Codable JSON at
`Application Support/EarnPlay/version-registry.json`
(`VersionRegistry.defaultStoreURL()`), written atomically on every
register/select, and restores them on construction — so a bundle
registered before an app update, and a rollback selection, both
survive restart. On restore, the `current` bundle is refreshed to
the running build's (verified, when a model file is installed)
identity without changing the persisted selection. All registry
state access is lock-synchronized, so the registry can be shared
across tasks.

## Session recording

`SessionRecord.start(sessionId:startedAt:registry:)` stamps the
registry's active `modelVersion` and `promptVersion`. Construction
validates both fields (empty/whitespace throws
`SessionRecordError.missingVersion`), and decoding goes through
the same validating initializer (custom `init(from:)`), so a
restored or synced record cannot bypass the invariant.

Note on scope: the full LLD 2.2 Session schema belongs to T1.6,
which has not landed yet. `SessionRecord` carries the
version-bearing subset (ID, start time, both versions).

## When to roll back

Per LLD 10.3 and 12.3, roll back when the regression/eval suite
fails for the running version, auditor flags implicate the running
version, or parents report a visible behaviour regression traced
to a version.

## Rollback procedure (model or prompt)

Operator entry point (shipped): open the **EarnPlayAdmin** app.
Its "Rollback operator controls" operate on the persisted
production registry (the same store the "Running version" panel
reads — the panel never constructs a fresh in-memory registry):

1. *Before an update ships:* tap **Register active bundle as
   previous known-good**. This copies the active bundle, with its
   model file path and prompt texts, under the bundle ID
   `previous-known-good` (`VersionRegistry.previousKnownGoodBundleID`)
   and persists it, so it survives the update and restart.
2. Confirm the regression is version-linked: compare session stamps
   between healthy and regressing sessions. If identical, do not
   roll back blind.
3. Tap **Roll back to previous known-good**. This calls
   `registry.rollbackToPreviousKnownGood()` on the persisted
   registry: it throws `VersioningError.noPreviousBundle` when no
   previous bundle was registered, and
   `VersioningError.artifactUnavailable` when the previous bundle's
   model file is not on the device — both shown in the panel, with
   the active bundle unchanged. On success the selection is
   persisted and the panel shows the rolled-back versions.
4. Verify: in the child app, `SpikeView` now loads the rolled-back
   bundle's model file and prompts (it resolves
   `inferenceArtifacts()` from the persisted registry at launch),
   and a new session stamps the older versions. Automated
   equivalents: `testRollbackArtifactsAreUsedByInference` and
   `testPersistedRegistrySurvivesReconstructionAndPanelReadsIt`.
5. Record the rollback like any other version change: sessions
   after the rollback carry the older stamp (LLD 10.3).
6. Roll forward: tap **Roll forward to current** in EarnPlayAdmin
   (or `select(bundleID: "current")` in code), then confirm a new
   session stamps the current version.

Programmatic equivalent (same persisted registry):
`let registry = try VersionRegistry.production()`, then
`try registry.rollbackToPreviousKnownGood()`.

Note on processes: the child and admin apps are separate
processes with separate Application Support sandboxes, so each
persists its own registry file; the admin panel reflects
selections made through the admin app (and any code writing the
same store file), and each app reads its persisted selection at
launch. Live cross-process sync would need a shared app-group
container, which this project does not configure yet.

### Explicitly out of scope

Re-downloading old model binaries is **out of scope**. Rollback
selects among bundles already installed/registered on the device;
if the previous model file is not on the device, selection is
rejected with `artifactUnavailable` until the file is restored by
other means (for the spike build: re-run
`Scripts/setup-model-spike.sh`). This procedure never pretends a
download happened.

## Known limits (admin app note)

The admin app ("Running version" panel) shows the active bundle
plus the limits in `VersionKnownLimits` (EarnPlayCore), each
verified against the current project state:

- Inference is validated on the iOS simulator only (CPU backend);
  physical-device speed is not yet measured.
- The runtime runs on the CPU backend with a 2048-token context;
  no Metal backend is in use.
- CI does not run real inference: without the fetched model and
  framework, the inference tests skip instead of passing.
- The prompt set is the 5-prompt T0.2 spike set; the full tutor
  prompt structure and output validation (LLD section 10) are not
  built yet.
- Rollback selects an already-installed previous bundle; it cannot
  re-download older model files.

Update `VersionKnownLimits.notes` in the same change that removes
a limit — the admin note and this section must not drift apart.
