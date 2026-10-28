# Release checklist (T7.3)

Steps from version bump through a release build, for every TestFlight
release. The flow is the HLD release flow — version bump → pipeline
build/test/archive → TestFlight upload → on-device verification →
(v1) App Store submission — with each step owned below.

Versioning is one script run: `Scripts/bump-version.sh`. The script,
its rules, and its tests are described at the bottom of this doc.

TestFlight upload automation is v1 scope (T7.2), and App Store
submission is v1 scope. Steps that only apply once a build is uploaded
are marked *(on upload, T7.2+)*; they are written now so the first
uploaded build follows the same checklist.

## 1. Bump the version

- [ ] Decide the bump: breaking change → major, new feature → minor,
      fix → patch.
- [ ] Run it (one command, from the repo root):

      Scripts/bump-version.sh --bump patch --bump-build

      Use `--version X.Y.Z` instead of `--bump ...` to set an exact
      version, or `--bump-build` alone when only the build number
      moves. Add `--dry-run` to preview without writing.
- [ ] Confirm the result: `Scripts/bump-version.sh --check` prints the
      intended version and build, and both app targets agree (the
      script refuses to run while they drift).
- [ ] Regenerate the project so the generated project and Info.plist
      carry the new values: `xcodegen generate` (CI does this itself).

## 2. Pipeline build and test

- [ ] Commit the `project.yml` change and push. CI (`.github/workflows/ci.yml`)
      checks version consistency, builds both targets, and runs the
      test suite on every push.
- [ ] CI is green. A failed build or test blocks everything below —
      fix and re-push rather than releasing around it.
- [ ] Note: a pipeline run never changes the app version on its own.
      If the version is wrong, go back to step 1; do not edit it in CI.

## 3. Release notes

- [ ] Copy [the release-notes template](TestFlightReleaseNotesTemplate.md),
      fill in every section (version, build, and commit must match
      step 1), and keep it with the release record.

## 4. Archive and upload *(on upload, T7.2+)*

- [ ] Archive from the exact commit CI verified.
- [ ] Upload to TestFlight (xcrun altool or the App Store Connect API,
      per LLD §15) and paste the release notes from step 3 into
      **What to Test**.
- [ ] Entitlement check: the approved FamilyControls distribution
      entitlement (T0.4) is in place for this bundle ID. TestFlight
      builds that enforce shields require it; without it, ship the
      simulated-shield fallback and say so in the release notes.

## 5. On-device verification *(on upload, T7.2+)*

- [ ] Install the build from TestFlight on a real device (not only the
      simulator).
- [ ] Verify the demo moments end to end: hard-trying child earns an
      unlock; idling child earns nothing; practice / movement / chore
      each earn one unlock; auditor catches a staged leniency error.
- [ ] Confirm the version and build shown for the installed build
      match step 1.

## 6. After the release

- [ ] Tag or otherwise record the released commit with its version
      and build number.
- [ ] Rollback, if a regression is traced to this release. Never
      re-upload the previous version/build pair: App Store Connect
      rejects a build number already uploaded for that version. Choose
      one of:
      - Make an existing build available again: if the previous
        known-good build is still in TestFlight, select / re-enable
        that existing build for the tester group in App Store Connect.
        Nothing is uploaded again.
      - Publish a rebuilt rollback: restore the known-good source.
        Do NOT use `--bump-build` for this: it only adds 1 to the
        build number in the restored source, which may already have
        been uploaded. For example, rolling back from 0.1.0/2 to the
        source for 0.1.0/1 and running `--bump-build` produces
        0.1.0/2 again, which App Store Connect rejects as a duplicate.
        Instead, check App Store Connect / TestFlight for the uploaded
        builds of the intended marketing version for BOTH apps
        (EarnPlay and EarnPlayAdmin), note the highest build number
        uploaded for each, and run `Scripts/bump-version.sh
        --set-build N` with N greater than both of those highest
        build numbers (the script writes the same N to both targets;
        `--set-build` is described under "How versioning works"
        below). When required for an App Store release, also use a
        newer marketing version than the release being rolled back.
        Then repeat steps 1–5 for the rebuilt rollback.
      Model and prompt rollback inside the apps follows
      [VersioningAndRollback.md](VersioningAndRollback.md).
- [ ] (v1) App Store submission is a separate, later step and is not
      part of this checklist's Demo scope.

## How versioning works

| Piece | Rule |
| --- | --- |
| App version | `MAJOR.MINOR.PATCH` only (three numeric components), bumped manually with `Scripts/bump-version.sh`. It feeds `CFBundleShortVersionString`, so a prerelease label such as `-beta.1` is rejected by the script and must never be written there; keep prerelease labels in release notes, tags, or TestFlight notes instead. |
| Build number | Positive integer. `--bump-build` adds 1; `--set-build N` sets it (for a future pipeline run number, T7.2). It never changes unless asked. |
| Re-running | Safe: setting the version already in place changes nothing and does not touch the build number. |
| Source of truth | `project.yml` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for both app targets. The generated Info.plist derives from them (`GENERATE_INFOPLIST_FILE`), so project and Info.plist agree after `xcodegen generate`. |
| Guard | CI runs `Scripts/bump-version.sh --check` on every push; it fails if the two targets' versions or build numbers drift apart, or if either target is missing a version/build entry. |
| Drift | If the targets ever disagree, the script refuses to run. Fix `project.yml` by hand, then re-run. |
| Not the app version | `EarnPlayCore.version` is the core library's own version and is not changed by the bump script. |

Script tests: `Scripts/test-bump-version.sh` exercises the real script
on scratch copies of `project.yml` (version parse; major/minor/patch
bumps; build-number increment; idempotent re-run; invalid-input
rejection including prerelease versions; drift, missing-entry, and
missing-file failures; mixed quoted/unquoted values). The scratch copy
is normalized to version 0.1.0 / build 1, so the suite does not depend
on the live file's already-released values.
