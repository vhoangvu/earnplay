#!/usr/bin/env bash
# T0.2 model-runtime spike setup. Fetches everything the spike needs
# WITHOUT committing any binary to git:
#   1. llama.cpp b11935 -> builds llama.xcframework (ios-sim, ios-device,
#      macos) into EarnPlayCore/Frameworks/ (gitignored).
#   2. Llama-3.2-1B-Instruct Q4_K_M GGUF (807,694,464 bytes) into the
#      model cache OUTSIDE the repo (default ~/Library/Caches/EarnPlay).
#
# Repeatable: safe to re-run; existing verified files are kept.
# Usage: Scripts/setup-model-spike.sh [--runtime-only|--model-only]
# Env:   EARNPLAY_MODEL_DIR  override the model cache directory
#        EARNPLAY_LLAMA_DIR  override the llama.cpp checkout directory
set -euo pipefail

LLAMA_TAG="b11935"
MODEL_REPO="bartowski/Llama-3.2-1B-Instruct-GGUF"
MODEL_FILE="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
MODEL_BYTES="807694464"
MODEL_SHA256="6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83"
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
LLAMA_URL="https://github.com/ggml-org/llama.cpp.git"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_ROOT="${EARNPLAY_MODEL_DIR:-$HOME/Library/Caches/EarnPlay}"
MODEL_DIR="$CACHE_ROOT/models"
LLAMA_DIR="${EARNPLAY_LLAMA_DIR:-$CACHE_ROOT/llama.cpp-$LLAMA_TAG}"
FRAMEWORKS_DIR="$REPO_ROOT/EarnPlayCore/Frameworks"

DO_RUNTIME=1
DO_MODEL=1
case "${1:-}" in
  --runtime-only) DO_MODEL=0 ;;
  --model-only)   DO_RUNTIME=0 ;;
  "") ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

if [ "$DO_RUNTIME" -eq 1 ]; then
  if [ -d "$FRAMEWORKS_DIR/llama.xcframework" ]; then
    echo "runtime: llama.xcframework already present, skipping build"
  else
    command -v cmake >/dev/null 2>&1 || {
      echo "error: cmake 3.28+ is required (brew install cmake, or pip install cmake)" >&2
      exit 1
    }
    command -v xcrun >/dev/null 2>&1 || {
      echo "error: Xcode command-line tools are required" >&2
      exit 1
    }
    if [ ! -d "$LLAMA_DIR/.git" ]; then
      echo "runtime: cloning llama.cpp $LLAMA_TAG ..."
      git clone --depth 1 --branch "$LLAMA_TAG" "$LLAMA_URL" "$LLAMA_DIR"
    fi
    if [ "$(git -C "$LLAMA_DIR" rev-parse HEAD)" != \
        "$(git -C "$LLAMA_DIR" rev-parse --verify "${LLAMA_TAG}^{commit}")" ] || \
        ! git -C "$LLAMA_DIR" diff --quiet HEAD --; then
        echo "error: $LLAMA_DIR must be a clean checkout of llama.cpp $LLAMA_TAG" >&2
        exit 1
    fi
    echo "runtime: building llama.xcframework (ios-sim ios-device macos) ..."
    (cd "$LLAMA_DIR" && ./build-xcframework.sh ios-sim ios-device macos)
    mkdir -p "$FRAMEWORKS_DIR"
    rm -rf "$FRAMEWORKS_DIR/llama.xcframework"
    cp -R "$LLAMA_DIR/build-apple/llama.xcframework" "$FRAMEWORKS_DIR/llama.xcframework"
    echo "runtime: installed to $FRAMEWORKS_DIR/llama.xcframework"
  fi
fi

if [ "$DO_MODEL" -eq 1 ]; then
  mkdir -p "$MODEL_DIR"
  MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
  if [ -f "$MODEL_PATH" ] && [ "$(stat -f %z "$MODEL_PATH" 2>/dev/null || stat -c %s "$MODEL_PATH")" = "$MODEL_BYTES" ] \
     && [ "$(sha256_of "$MODEL_PATH")" = "$MODEL_SHA256" ]; then
    echo "model: verified GGUF already present, skipping download"
  else
    echo "model: downloading $MODEL_FILE ($MODEL_BYTES bytes) ..."
    curl -L --fail --retry 2 -o "$MODEL_PATH" "$MODEL_URL"
    ACTUAL_BYTES="$(stat -f %z "$MODEL_PATH" 2>/dev/null || stat -c %s "$MODEL_PATH")"
    ACTUAL_SHA="$(sha256_of "$MODEL_PATH")"
    [ "$ACTUAL_BYTES" = "$MODEL_BYTES" ] || {
      echo "error: model size mismatch: got $ACTUAL_BYTES, want $MODEL_BYTES" >&2; exit 1; }
    [ "$ACTUAL_SHA" = "$MODEL_SHA256" ] || {
      echo "error: model sha256 mismatch: got $ACTUAL_SHA" >&2; exit 1; }
    echo "model: verified sha256 $MODEL_SHA256"
  fi
  echo "model: $MODEL_PATH"
fi

echo "setup complete. Next steps (see Docs/ModelRuntimeSpike.md, Setup):"
echo "  xcodegen generate"
echo "  # xcodebuild test does not forward shell env vars into the simulator,"
echo "  # so stage the GGUF into the app's Documents before testing:"
echo "  xcrun simctl boot \"iPhone 17\" || true"
echo "  xcodebuild build -project EarnPlay.xcodeproj -scheme EarnPlay -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO ARCHS=arm64"
echo "  xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/EarnPlay.app"
echo "  DATA=\$(xcrun simctl get_app_container booted com.vhoangvu.earnplay data)"
echo "  ln \"$MODEL_DIR/$MODEL_FILE\" \"\$DATA/Documents/EarnPlayModel.gguf\""
echo "  xcodebuild test -project EarnPlay.xcodeproj -scheme EarnPlay -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO ARCHS=arm64"
