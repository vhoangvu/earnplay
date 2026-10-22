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

Bundle IDs (`com.vhoangvu.earnplay*`) are placeholders until T0.1 records
the real IDs from the Apple Developer account.

## CI (Route 1)

Every push to `main` and every pull request runs GitHub Actions on a
macOS runner (`.github/workflows/ci.yml`): installs XcodeGen, generates
the project, runs `swift test` for EarnPlayCore, then
`xcodebuild test` for the app scheme on an iPhone 16 simulator
(signing disabled). Check the Actions tab for results.

Deployment target: iOS 18. CI uses the macos-15 runner (Xcode 16).
