# TestFlight release notes — template (T7.3)

Copy this file for each build, fill in every section, and paste the
result into the TestFlight **What to Test** field when the build is
uploaded. Upload automation itself is v1 scope (T7.2); until then the
upload — and pasting these notes — is a manual step in
[the release checklist](ReleaseChecklist.md).

Keep the notes short and testable: a tester should be able to act on
each line without reading the commit log.

---

## Version

- App version: `<MAJOR.MINOR.PATCH>` (set with `Scripts/bump-version.sh`; check with `Scripts/bump-version.sh --check`)
- Build: `<build number>` (auto-incremented; must be unique for this version)
- Date: `<YYYY-MM-DD>`
- Commit: `<git short hash of the released commit>`

## What to test

- `<the one flow or screen that changed most; name the exact steps>`
- `<regression path most at risk from this change>`
- Demo moments, when affected: hard-trying child earns an unlock;
  idling child earns nothing; practice / movement / chore each earn
  one unlock; auditor catches a staged leniency error.

## What's new

- `<user-visible change, one line each; write "none — internal only" if none>`

## Known issues

- `<known bug or limit in this build, or "none known">`
- Inference is validated on the iOS simulator (CPU backend); physical-device speed is not yet measured.
- CI does not run real inference: without the fetched model and framework, the inference tests skip instead of passing.

## Feedback focus

Please report: `<the specific question this build should answer, e.g. "does the unlock land within 2 seconds of the passing answer?">`
