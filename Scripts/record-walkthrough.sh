#!/bin/sh
# One-command full walkthrough recording (issue #71).
#
# Boots the given simulator (default: EarnPlay-Walkthrough), starts
# simulator video capture, runs the whole EarnPlay scheme test suite
# (unit tests + T7.6 smoke tests + the issue #71 walkthrough), then
# stops the capture. The result is a single reviewable recording of
# every walkthrough step in order.
#
# Usage:
#   Scripts/record-walkthrough.sh [simulator-name] [output.mp4]
#
# Examples:
#   Scripts/record-walkthrough.sh
#   Scripts/record-walkthrough.sh EarnPlay-Walkthrough /tmp/walkthrough.mp4
#
# Requirements: xcodegen-generated EarnPlay.xcodeproj in the repo root
# (run `xcodegen generate` first), and a simulator runtime matching the
# named device. Never point this at another stream's simulator.
set -u

SIM_NAME="${1:-EarnPlay-Walkthrough}"
OUTPUT="${2:-EarnPlayWalkthrough.mp4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac
RECORDER_LOG="/tmp/walkthrough-recordvideo-$$.log"

UDID="$(xcrun simctl list devices available | grep -m1 " $SIM_NAME (" | grep -o '[0-9A-F-]\{36\}')"
if [ -z "$UDID" ]; then
    echo "error: simulator '$SIM_NAME' not found" >&2
    exit 1
fi

if [ ! -d "$ROOT/EarnPlay.xcodeproj" ]; then
    echo "error: $ROOT/EarnPlay.xcodeproj missing; run 'xcodegen generate' first" >&2
    exit 1
fi

echo "Booting $SIM_NAME ($UDID)..."
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1

echo "Starting video capture to $OUTPUT..."
rm -f "$OUTPUT" "$RECORDER_LOG"
xcrun simctl io "$UDID" recordVideo --codec=h264 "$OUTPUT" 2>"$RECORDER_LOG" &
RECORDER_PID=$!

stop_recording() {
    kill -INT "$RECORDER_PID" 2>/dev/null || true
    wait "$RECORDER_PID" 2>/dev/null || true
    rm -f "$RECORDER_LOG"
}
trap stop_recording EXIT INT TERM

# Wait until the recorder has processed its first frame.
for _ in $(seq 1 30); do
    if grep -q "Recording started" "$RECORDER_LOG" 2>/dev/null; then
        break
    fi
    sleep 1
done

echo "Running walkthrough suite..."
# NOTE: ONLY_ACTIVE_ARCH=YES is passed as a BUILD SETTING (not an env
# prefix): the env form is ignored and builds x86_64, which fails
# resolving EarnPlayCore. This is the known pre-existing arch quirk.
xcodebuild test \
    -project EarnPlay.xcodeproj \
    -scheme EarnPlay \
    -destination "platform=iOS Simulator,id=$UDID" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO
TEST_EXIT=$?

stop_recording
trap - EXIT INT TERM

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "error: xcodebuild test failed (exit $TEST_EXIT); recording kept at $OUTPUT" >&2
    exit "$TEST_EXIT"
fi
echo "Done. Full walkthrough recording: $OUTPUT"
