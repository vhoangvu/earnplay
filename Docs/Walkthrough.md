# Feature walkthrough suite (issue #71, docs task T7.7)

`EarnPlayUITests` hosts a deterministic feature-walkthrough suite that
drives the PRODUCTION UI in a fixed order — no scripted screens, no
harness views. The suite extends the T7.6 smoke tests (`EarnPlayUITests.swift`,
untouched) with:

- `WalkthroughSupport.swift` — launchers, screenshot capture, gap
  recording, and query/scroll helpers.
- `WalkthroughFixtures.swift` — fixtures and seeds, TEST TARGET ONLY:
  `SeededChorePool` (stocks the admin chore-pool editor), the
  `ScriptedPracticeSession` Q&A script, and the `StagedLeniencySession`
  auditor-staging spec matching the T5.4 demo-staging moment
  (Docs/Auditor.md check 1). No fixture data in production code.
- `WalkthroughChildTests.swift` — child-app steps 01–10.
- `WalkthroughAdminTests.swift` — admin-app steps 01–08, driven from
  the same target via the admin bundle identifier
  (`com.vhoangvu.earnplay.admin`). No separate admin UI-test target:
  the `EarnPlay` scheme builds `EarnPlayAdmin` (see `project.yml`) so
  the test run installs it alongside the child app.

## Conventions

- Every step launches its app fresh: steps are order-independent, but
  reruns require an erased simulator (erase between reruns).
  Relaunching preserves app data: a retained child model bypasses the
  download gate, and saved admin sessions/pairing violate the
  empty/unpaired assertions. Assertions pin formats and relative
  changes, never random codes or exact versions.
- Every step captures at least one screenshot artifact named by app +
  screen + step (e.g. `child-gate-step01`, `admin-policy-saved-step03`).
  Capture never fails a test: the helper asserts nothing, and issues
  recorded by the capture itself are suppressed
  (`WalkthroughTestCase.suppressingCaptureIssues`).
- Reachable steps assert the expected screen/element and FAIL when a
  screen cannot be reached. Unreachable features are recorded as named
  gaps (reason + unblock path) via `recordGap`, attached to the test
  results and logged — never silently skipped.
- No test taps the model-download button or waits for a download. Steps
  past the model gate set `EARNPLAY_MODEL_PATH` to a nonexistent path,
  which the production readiness gate resolves through its legacy
  env-override path with no network I/O (see `Walkthrough.dummyModelPath`).
- Full two-device live pairing stays a manual T5.4/T7.5 item and is not
  attempted. Real FamilyControls shields, performance/stress/soak
  testing, narration, and video assembly are out of scope.

## Child steps (WalkthroughChildTests)

| Step | Screen | Reachable? |
|---|---|---|
| 01 | First launch + model-download gate (gate asserted, download never tapped) + pre-invite code row | yes |
| 02 | About screen + Llama license attribution (on the gate) | yes |
| 03 | Setup authorization step + honest simulator denial | yes |
| 04 | Setup enumeration → completion | GAP SETUP-COMPLETION |
| 05 | Full practice session (question, hint, wrong answer + probe, completion) | GAP PRACTICE |
| 06 | Effort-based unlock earned through practice | GAP EFFORT-UNLOCK |
| 07 | Movement trade (offer, accept, completion) | GAP MOVEMENT-TRADE |
| 08 | Chore trade (offer, accept, confirm, granted) | GAP CHORE-TRADE |
| 09 | Simulated shield (ON state, challenge, countdown) | GAP SHIELDS |
| 10 | Pairing sheet presentation + decline path (pre-invite row reached) | GAP PAIRING-SHEET |

## Admin steps (WalkthroughAdminTests)

| Step | Screen | Reachable? |
|---|---|---|
| 01 | Dashboard empty state | yes |
| 02 | Dashboard fixture-seeded filled state | GAP DASHBOARD-FILLED |
| 03 | Policy editor, every section incl. below-the-fold + example chore + save | yes |
| 04 | Sessions list + pairing screen + code + sync surface | yes (live pairing completion stays manual) |
| 05 | Auditor clean state + manual run | yes |
| 06 | Auditor staged-finding state | GAP AUDITOR-FINDING |
| 07 | Version registry + rollback controls (asserted, never tapped) | yes |
| 08 | Sessions filled list | GAP SESSIONS-FILLED |

Gap details (exact reason + unblock path) are recorded by each gap test
at runtime; see the test results' `gap-*` attachments.

## Running

The walkthrough runs on the simulator alongside the unit tests and the
T7.6 smoke tests in the existing T7.1 invocation (CI runs the same
command with `-destination 'platform=iOS Simulator,name=iPhone 16'`):

```sh
xcodebuild test \
  -project EarnPlay.xcodeproj \
  -scheme EarnPlay \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO
```

`ONLY_ACTIVE_ARCH=YES` is a BUILD SETTING here, not an environment
prefix — the env form is ignored and builds x86_64, which fails
resolving EarnPlayCore (known pre-existing arch quirk; see the PR
body). `CODE_SIGNING_ALLOWED=NO` matches CI.

To run only the walkthrough (iteration):

```sh
xcodebuild test \
  -project EarnPlay.xcodeproj \
  -scheme EarnPlay \
  -destination 'platform=iOS Simulator,name=<your-sim>' \
  -only-testing:EarnPlayUITests/WalkthroughChildTests \
  -only-testing:EarnPlayUITests/WalkthroughAdminTests \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO
```

## Full walkthrough recording (one command)

`Scripts/record-walkthrough.sh` boots the simulator, starts
`xcrun simctl io recordVideo`, runs the suite above, stops the capture,
and leaves one reviewable recording:

```sh
Scripts/record-walkthrough.sh [simulator-name] [output.mp4]
# default: Scripts/record-walkthrough.sh EarnPlay-Walkthrough EarnPlayWalkthrough.mp4
```

Equivalent manual sequence (what the script does):

```sh
UDID=$(xcrun simctl list devices available | grep -m1 " EarnPlay-Walkthrough (" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl boot "$UDID"
xcrun simctl io "$UDID" recordVideo --codec=h264 EarnPlayWalkthrough.mp4 &
RECORDER_PID=$!
xcodebuild test -project EarnPlay.xcodeproj -scheme EarnPlay \
  -destination "platform=iOS Simulator,id=$UDID" \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
kill -INT "$RECORDER_PID"
```

## Simulator notes

- Use a dedicated simulator (e.g. `EarnPlay-Walkthrough`, iPhone 16,
  iOS 27.0 runtime). `simctl create` with iPhone 17 + the iOS 27.1
  runtime fails "Incompatible device"; existing sims use the 27.0
  runtime.
- Never boot, shut down, or delete another stream's simulator.
