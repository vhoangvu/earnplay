# T0.2 — Model runtime spike note

Goal (task card T0.2): integrate a quantized-model runtime (llama.cpp /
MLC-style), load a small open-weights model on-device, and run one
prompt-to-response round-trip fully offline. Record the model, the
cold/warm latencies, and a go/no-go on model size.

## Model used

| Item | Value |
| --- | --- |
| Model | Meta Llama 3.2 1B Instruct (Meta open-weights), GGUF Q4_K_M |
| File | `Llama-3.2-1B-Instruct-Q4_K_M.gguf` |
| Source | `bartowski/Llama-3.2-1B-Instruct-GGUF` on Hugging Face |
| Size | 807,694,464 bytes (770 MiB, ~0.81 GB) |
| SHA-256 | `6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83` |
| Runtime | llama.cpp `b11935`, built from source into `llama.xcframework` (iOS device + iOS simulator + macOS slices), CPU backend, 4 threads, 2048-token context |
| Wrapper | `ModelRuntime` in EarnPlayCore (shared package), C shim `CLlamaShim` over the llama.cpp C API. No networking code in the package. |
| Test prompts | 5 fixed prompts in `SpikePrompts` (EarnPlayCore); integration test uses prompts 1–2 |

Real-model proof in tests: the loaded model reports >500M parameters,
the exact GGUF byte count above, and a llama model description. A
canned-text stub cannot satisfy those assertions.

## Measured latencies (simulator gate run)

Environment: iPhone 17 simulator (iOS 27.0), Xcode 27.1, arm64,
CODE_SIGNING_ALLOWED=NO, ARCHS=arm64. Model staged in the app
container's Documents (see Setup). Each generation capped at 48 tokens.

| Run | Load | Generation | Round-trip total |
| --- | --- | --- | --- |
| Cold start (load + first prompt) | 1,749 ms | 10,615 ms | **12,365 ms** |
| Second run, warm (prompt 2) | 0 ms | 8,302 ms | **8,302 ms** |
| Recorded timeout asserted by the test | — | — | 300,000 ms |

Variance note: an earlier identical run on the busier host measured
42,460 ms cold / 13,039 ms warm — same order of magnitude, which is
the comparison the manual Airplane Mode check should use. Absolute
numbers move with host load; the model, prompts, and token cap did
not change between runs.

Sample output (prompt 1, fraction explanation): "A fraction is a way
to show part of a whole. You can compare it to a pizza, where you take
a slice and a slice is equal …" — genuine model text, truncated at the
48-token cap. Prompt 2 returned non-empty story-problem text.

Offline proof: the XCTest integration test installs a counting
`URLProtocol` stub, runs load + 2 prompts, and asserts the attempted
network-call count is 0. It passed. EarnPlayCore contains no
`URLSession` usage at all.

## Go / no-go on model size

**GO.** At 808 MB the Q4_K_M 1B model is inside the ~1 GB spike target
and far below the ~2 GB no-go line, loads and generates fully offline,
and leaves comfortable headroom next to the app itself. No larger
model is needed to prove the runtime path.

Latency caution (not a size blocker): numbers above are simulator +
CPU-only on a shared 8-core host. They prove correctness and the
offline property, not device speed. Physical-device latency (and any
Metal-backend comparison) is deferred to the human checkpoint.

## Setup (repeatable; nothing binary is committed)

```sh
Scripts/setup-model-spike.sh   # builds llama.xcframework + downloads/verifies the GGUF
xcodegen generate
# stage the model where the simulator test host can read it:
xcrun simctl boot "iPhone 17" || true
xcodebuild build -project EarnPlay.xcodeproj -scheme EarnPlay \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/EarnPlay.app
DATA=$(xcrun simctl get_app_container booted com.vhoangvu.earnplay data)
ln ~/Library/Caches/EarnPlay/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf "$DATA/Documents/EarnPlayModel.gguf"
xcodebuild test -project EarnPlay.xcodeproj -scheme EarnPlay \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO ARCHS=arm64
```

Why staging instead of an env var: Xcode 27 `xcodebuild test` does not
forward shell environment variables into the simulator test process
(verified: `EARNPLAY_MODEL_PATH` arrives unset). `ModelRuntime` also
accepts that variable where it does arrive (host `swift test`), and
falls back to caches. On a physical device, copy the GGUF as
`EarnPlayModel.gguf` into the app's Documents before the manual test.

CI status, stated plainly: the committed CI workflow is unchanged.
Without the setup steps above, CI builds the package without the
llama shim (`ModelRuntime` reports `runtimeUnavailable`), package
tests pass, and the simulator integration test **skips** — it does
not fake a pass. To exercise real inference in CI, add the setup +
staging steps above before the test step (plus `ARCHS=arm64`; the
universal x86_64 app build otherwise cannot resolve the arm64-only
package module build). Runtime build adds roughly a minute locally;
the 808 MB model download dominates CI time.

## Placeholders / unverified

- Manual Airplane Mode test (card's manual steps) — deferred to the
  human checkpoint; the spike screen (`SpikeView` in the child app)
  is built for it. Not performed here.
- Physical-device run — not done (no device; simulator only).
- Clean-checkout rebuild — not done here; CI on the PR is the check.
- `com.vhoangvu` bundle-ID prefix — untouched placeholder (see
  README); nothing was signed or provisioned.
- Prompt/output quality beyond non-empty, on-topic samples — out of
  spike scope; real prompt structure + validation belongs to later
  tasks (LLD section 10).
