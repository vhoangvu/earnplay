# EarnPlay (code)

Swift + SwiftUI code for EarnPlay — private, on-device tutor + effort-based
app gate (Meta Global AI Developer Hackathon, Indie track).
Design docs / source of truth live in the separate private repo
`vhoangvu/earnplay-docs`. This repo holds code only.

## Layout

- `EarnPlay/` — child app (tutor chat, challenge gate)
- `EarnPlayAdmin/` — parent admin app (dashboard, policy)
- `EarnPlayCore/` — shared Swift package: deterministic logic
  (effort scoring, floor rule, unlock). Safety-critical decisions live
  here in code, never in the tutor model.
- `EarnPlayTests/` — app unit tests

## Project generation

The `.xcodeproj` is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml` — it is not committed.

```sh
brew install xcodegen
xcodegen generate
open EarnPlay.xcodeproj
```

## Bundle IDs (recorded in T0.1)

These values must match Xcode's Bundle Identifier fields exactly
(source of truth: `project.yml` → each target's
`PRODUCT_BUNDLE_IDENTIFIER`):

| Target | Bundle ID |
| --- | --- |
| EarnPlay (child app) | `com.vhoangvu.earnplay` |
| EarnPlayAdmin (admin app) | `com.vhoangvu.earnplay.admin` |
| EarnPlayTests (unit tests) | `com.vhoangvu.earnplay.tests` |

> These are the maintainer's local IDs. If you build from this source
> with your own Apple Developer account, use your own bundle IDs
> (see below) — do not sign or distribute with the IDs above.

## Building with your own bundle ID

Simulator builds need no signing and work with whatever ID is in
`project.yml` — just generate and build:

```sh
xcodegen generate
xcodebuild build -scheme EarnPlay -destination 'platform=iOS Simulator,name=iPhone 16'
```

For a device build, TestFlight, or App Store upload, override the app
targets' IDs on the archive command with IDs from your own Developer
account (the test targets' IDs do not matter for distribution).
Archive each app scheme separately, so one override per command is
enough:

```sh
xcodebuild archive -scheme EarnPlay \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.earnplay
xcodebuild archive -scheme EarnPlayAdmin \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.earnplay.admin
```

You can also edit the IDs directly in `project.yml` (the source of
truth — the generated `.xcodeproj` is not committed) and regenerate.

Before uploading anything, verify the built app actually carries your
ID — an upload under the wrong ID lands under the wrong app record:

```sh
/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" \
  path/to.xcarchive/Products/Applications/EarnPlay.app/Info.plist
```

One more place to keep in sync: the UI tests launch the admin app by
its literal bundle ID (`EarnPlayUITests/UXShotUITests.swift`,
`EarnPlayUITests/WalkthroughSupport.swift`). If you change the admin
ID, update those references to match, or the admin UI tests will fail
to launch the app.

## CI (Route 1)

Every push and every pull request runs GitHub Actions on a
macOS runner (`.github/workflows/ci.yml`): installs XcodeGen, generates
the project, runs `swift test` for EarnPlayCore, then
`xcodebuild test` for the EarnPlay scheme and `xcodebuild build`
for the EarnPlayAdmin scheme on an iPhone 16 simulator
(signing disabled). Check the Actions tab for results.

Deployment target: iOS 18. CI uses the macos-15 runner (Xcode 16).

## Model spike (T0.2)

`ModelRuntime` in EarnPlayCore wraps llama.cpp (pinned `b11935`,
CPU backend) and loads Meta Llama 3.2 1B Instruct Q4_K_M
(808 MB GGUF) fully offline. Model weights and the built
`llama.xcframework` are fetched, never committed:

```sh
Scripts/setup-model-spike.sh
xcodegen generate
```

Simulator staging, measured cold/warm latencies, the go/no-go on
model size, and the exact CI gap are recorded in
`Docs/ModelRuntimeSpike.md`. Without setup, the package still builds
(runtime reports unavailable) and the offline integration test skips
rather than passing vacuously.

## Eval harness (T5.1)

Scripted end-to-end sessions for five personas (good-faith, guessing,
idling, manipulative, struggling child), scored against the LLD's fixed
pass criteria. One command, from the repo root, locally or in CI
(stub-only — no model needed):

```sh
swift run --package-path EarnPlayCore eval-harness
```

Prints a per-criterion pass/fail scorecard, writes
`EarnPlayCore/EvalHarness/eval-report-latest.json` next to the committed
baseline, and exits nonzero on any criterion failure or regression.
Details: `Docs/EvalHarness.md`.
