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

RECORDER_EXIT=0
stop_recording() {
    kill -INT "$RECORDER_PID" 2>/dev/null || true
    wait "$RECORDER_PID" 2>/dev/null
    RECORDER_EXIT=$?
}
trap 'stop_recording; rm -f "$RECORDER_LOG"' EXIT INT TERM

# Wait until the recorder has processed its first frame. Both the
# startup acknowledgement AND a live recorder process are required:
# without them the suite would run and report success for a
# recording that may not exist.
RECORDING_STARTED=0
for _ in $(seq 1 30); do
    if grep -q "Recording started" "$RECORDER_LOG" 2>/dev/null; then
        RECORDING_STARTED=1
        break
    fi
    if ! kill -0 "$RECORDER_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done

if [ "$RECORDING_STARTED" -ne 1 ] || ! kill -0 "$RECORDER_PID" 2>/dev/null; then
    # Grace period so a dying recorder flushes its diagnostics.
    sleep 1
    echo "error: simulator video capture did not start; not running the suite" >&2
    echo "--- recorder log ($RECORDER_LOG) ---" >&2
    if [ -s "$RECORDER_LOG" ]; then
        cat "$RECORDER_LOG" >&2
    else
        echo "(recorder produced no diagnostics)" >&2
    fi
    exit 1
fi

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

# A recorder that dies after acknowledging startup leaves a missing or
# incomplete video; passing tests must not report a full recording.
# Capture failure is a nonzero recorder exit OR a missing/empty output
# after finalization. Either failure propagates; a recorder failure
# never masks a test failure (both are reported, test exit wins).
RECORDER_FAILED=0
RECORDER_REASON=""
if [ "$RECORDER_EXIT" -ne 0 ]; then
    RECORDER_FAILED=1
    RECORDER_REASON="recorder exited with status $RECORDER_EXIT"
elif [ ! -s "$OUTPUT" ]; then
    RECORDER_FAILED=1
    if [ ! -e "$OUTPUT" ]; then
        RECORDER_REASON="recording missing at $OUTPUT"
    else
        RECORDER_REASON="recording empty at $OUTPUT"
    fi
fi

if [ "$RECORDER_FAILED" -ne 0 ]; then
    echo "error: simulator video capture failed ($RECORDER_REASON); recording incomplete" >&2
    echo "--- recorder log ($RECORDER_LOG) ---" >&2
    if [ -s "$RECORDER_LOG" ]; then
        cat "$RECORDER_LOG" >&2
    else
        echo "(recorder produced no diagnostics)" >&2
    fi
    rm -f "$RECORDER_LOG"
    if [ "$TEST_EXIT" -ne 0 ]; then
        echo "error: xcodebuild test failed (exit $TEST_EXIT); recording incomplete" >&2
        exit "$TEST_EXIT"
    fi
    if [ "$RECORDER_EXIT" -ne 0 ]; then
        exit "$RECORDER_EXIT"
    fi
    exit 1
fi

rm -f "$RECORDER_LOG"

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "error: xcodebuild test failed (exit $TEST_EXIT); recording kept at $OUTPUT" >&2
    exit "$TEST_EXIT"
fi
echo "Done. Full walkthrough recording: $OUTPUT"
