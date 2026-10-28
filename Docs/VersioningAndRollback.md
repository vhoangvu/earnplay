# Versioning + rollback (T5.3)

Records which model and prompt version ran every session, how to roll
back a regressing one, and what the admin app shows. Design basis:
LLD sections 2.2 (Session) and 10.3 (Versioning and rollback).

## What "version" means

| Kind | Current value | Source of truth in code |
| --- | --- | --- |
| Model (configured spike build) | `meta-llama Llama-3.2-1B-Instruct, GGUF Q4_K_M (bartowski/Llama-3.2-1B-Instruct-GGUF) / llama.cpp b11935, CPU backend` | `ModelRuntime.versionStamp` (configured identity only — see verified identity below) |
| Model (installed file, verified) | `"<file name> (<byte count> bytes, GGUF, sha256:<hex>) / llama.cpp b11935, CPU backend"` | `ModelRuntime.verifiedModelVersion(forModelAt:)` — streamed SHA-256 of the actual GGUF file (plus name, size, GGUF magic); same-size different content yields a different stamp |
| Prompt | `spike-v1` | `SpikePrompts.version` (EarnPlayCore) |

- Verified model identity: a session or registry stamp for an
  *installed* file comes from `verifiedModelVersion(forModelAt:)`,
  which checks the file is a regular file, starts with the GGUF
  magic, and includes its streamed SHA-256 (`contentSHA256`).
  A non-GGUF file or directory is rejected with
  `ModelRuntimeError.invalidModelFile`, and `ModelRuntime.load()`
  applies the same check. Each bundle also stores
  `modelContentDigest`; selection and `inferenceArtifacts()` reject
  a file whose digest no longer matches, and a bundle claiming only
  the configured `versionStamp` does not bind an unrelated file that
  later appears at the default path.
- Prompt version scheme: `"<set-id>-v<major>"` (see `SpikePrompts`).
  Bump the major number on any wording or rule change to the set.
- Runtime composition (round 4 F13, chosen option): snapshots
  retain the model file and prompts, not a past llama.cpp
  runtime (the runtime is linked into the app binary and cannot
  be swapped per-bundle). The reported version is therefore
  composed at stamp/inference time by
  `ModelRuntime.reportedModelVersion(storedModelVersion:)`: the
  retained model identity (everything before `" / "`) with the
  runtime identifier actually running. A rolled-back bundle
  never reports the old runtime it was registered under; it
  reports the retained model run by the current runtime.
- Load-time verification (F1/F2): `contentSHA256` always
  re-reads the file (no path/size/mtime cache), and a
  `ModelRuntime` created from resolved artifacts is bound to
  their content digest. `load()` re-hashes and rejects a file
  replaced after resolution (`modelContentMismatch`) instead of
  loading it under the old stamp. Registry reads
  (`activeBundle`, `activeBundleID`, `registeredBundles`) are
  throwing: a persisted-store reload failure propagates to
  session stamping and both apps' panels instead of silently
  showing stale state (F4). `production()` holds the shared
  per-store lock across restore/create/refresh (F3).
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
survive restart. If that file exists but cannot be read or decoded,
production throws instead of silently resetting it; a fresh store
is created only when the file is absent. A corrupt/non-GGUF current
model does not block restore: the persisted registry is loaded
first and current-artifact validation is deferred to
select/inference. On restore, the `current` bundle is refreshed to
the running build's (verified, when a model file is installed)
identity without changing the persisted selection.
Registries sharing a store also share a per-store lock and reload
the latest persisted state under it before every write, so two
instances cannot overwrite each other's updates; failed
register/select writes restore the prior in-memory state.

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

Operator entry points (shipped): **EarnPlayAdmin** ("Rollback
operator controls") and the child **EarnPlay** app's SpikeView
("Version rollback (this app)"). Both obtain the persisted
production registry via `VersionRegistry.production()` — never a
fresh in-memory registry — and perform the calls below on it.
Because the two apps have separate sandboxes (see "Note on
processes"), use the child app's controls to change what child
inference runs; the admin controls change the admin app's own
persisted registry and demonstrate/verify the same procedure.

1. *Before an update ships:* tap **Register active bundle as
   previous known-good**. This first checks the installed model
   file still matches the active bundle's bound SHA-256 (a
   replaced file is rejected, not snapshotted under the old
   version), then snapshots the active bundle's resolved prompt
   texts and retains the actual model file at a distinct
   immutable path `previous-known-good-model-<digest-prefix>.gguf`
   next to the registry store (with its SHA-256), under bundle ID
   `previous-known-good`, and persists the new registry entry;
   only after that persist succeeds is a previous snapshot file
   that no bundle references retired — and only when this
   registry owns it (tracked snapshot ownership; externally
   registered model files are never deleted). The copied
   snapshot bytes are re-hashed and checked against the source
   digest before publishing, retained model paths persist
   relative to the registry directory (legacy absolute paths
   migrate on load), candidate selections are load-validated
   before committing when the app installs its validator, the
   runtime loads a retained immutable copy of the verified
   bytes, and sessions stamp from the same artifacts snapshot
   used to start inference. It therefore survives the
   update, a prompt bump, replacement of the default model, and
   restart, and a failed persist cannot destroy the prior
   rollback. With no model file installed, the snapshot is
   rejected (`artifactUnavailable`) instead of reporting success.
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
6. Roll forward: tap **Roll forward to current** in the child
   app's **SpikeView** ("Version rollback (this app)"), or call
   `select(bundleID: "current")` on the child's persisted
   registry in code, then confirm in the child app that a new
   session stamps the current version. Do **not** use the
   EarnPlayAdmin roll-forward button for this step: the admin
   app has its own sandbox and registry, so its button changes
   only the admin app's selection and leaves child inference
   rolled back (see "Note on processes" below).

Programmatic equivalent (same persisted registry):
`let registry = try VersionRegistry.production()`, then
`try registry.rollbackToPreviousKnownGood()`.

Note on processes: the child and admin apps are separate
processes with separate Application Support sandboxes, so each
persists its own registry file. That is exactly why the child app
also ships rollback controls: a rollback performed in EarnPlay's
SpikeView reloads that app's inference artifacts immediately, so
it is the entry point that affects child inference. The admin
panel reflects selections made through the admin app, and each
app reads its persisted selection at launch. Live cross-process
sync would need a shared app-group container, which this project
does not configure yet — the admin rollback is not claimed to
change the child app.

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
