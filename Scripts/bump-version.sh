#!/usr/bin/env bash
# T7.3 release versioning. One command sets the app (marketing) version
# and/or the build number everywhere the build reads them.
#
# Versioning scheme (SSOT/HLD/LLD SS15):
#   - App version: semantic version MAJOR.MINOR.PATCH (optionally with a
#     -prerelease suffix). Bumped MANUALLY with this script. A pipeline
#     run never changes the app version on its own.
#   - Build number: positive integer (CURRENT_PROJECT_VERSION). It only
#     changes when asked: --bump-build adds 1, --set-build N sets it
#     (for a future pipeline run number, T7.2). Re-running this script
#     with the version already in place changes nothing.
#
# Where the build reads the version: project.yml holds MARKETING_VERSION
# and CURRENT_PROJECT_VERSION for both app targets (EarnPlay and
# EarnPlayAdmin). GENERATE_INFOPLIST_FILE is on, so each app's generated
# Info.plist (CFBundleShortVersionString / CFBundleVersion) takes those
# values at build time; `xcodegen generate` propagates them into the
# generated .xcodeproj. There is no checked-in Info.plist to update.
# EarnPlayCore.version is the core library's own version, not the app
# release version, and is deliberately not touched here.
#
# Usage:
#   Scripts/bump-version.sh --version X.Y.Z [--bump-build]
#   Scripts/bump-version.sh --bump major|minor|patch [--bump-build]
#   Scripts/bump-version.sh --bump-build
#   Scripts/bump-version.sh --set-build N
#   Scripts/bump-version.sh --check        # print version/build, fail on drift
#   Scripts/bump-version.sh --dry-run ...  # print the change, write nothing
# Options:
#   --root DIR   operate on DIR/project.yml (default: repo root)
#
# Exit codes: 0 ok (including "already up to date"); 2 invalid input;
# 1 missing file, drift between targets, or write failure. On any
# failure nothing is written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE=""          # set | bump | build-only | check
NEW_VERSION=""
BUMP_PART=""
BUMP_BUILD=0
SET_BUILD=""
DRY_RUN=0

die_usage() { echo "error: $1" >&2; echo "run with --help for usage" >&2; exit 2; }
die_error() { echo "error: $1" >&2; exit 1; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die_usage "--version needs a value"
      [ -z "$MODE" ] || die_usage "--version and --bump cannot be combined"
      MODE="set"; NEW_VERSION="$2"; shift 2 ;;
    --bump)
      [ $# -ge 2 ] || die_usage "--bump needs major, minor or patch"
      [ -z "$MODE" ] || die_usage "--version and --bump cannot be combined"
      case "$2" in major|minor|patch) ;; *) die_usage "--bump must be major, minor or patch (got: $2)" ;; esac
      MODE="bump"; BUMP_PART="$2"; shift 2 ;;
    --bump-build)
      BUMP_BUILD=1; shift ;;
    --set-build)
      [ $# -ge 2 ] || die_usage "--set-build needs a value"
      [ -z "$SET_BUILD" ] || die_usage "--set-build given twice"
      SET_BUILD="$2"; shift 2 ;;
    --check)
      [ -z "$MODE" ] || die_usage "--check cannot be combined with a change"
      MODE="check"; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --root)
      [ $# -ge 2 ] || die_usage "--root needs a directory"
      ROOT="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ] || [ "$BUMP_BUILD" -eq 1 ] || [ -n "$SET_BUILD" ] \
  || die_usage "nothing to do: pass --version, --bump, --bump-build, --set-build or --check"
if [ "$MODE" = "check" ] && { [ "$BUMP_BUILD" -eq 1 ] || [ -n "$SET_BUILD" ]; }; then
  die_usage "--check cannot be combined with a change"
fi
if [ "$BUMP_BUILD" -eq 1 ] && [ -n "$SET_BUILD" ]; then
  die_usage "--bump-build and --set-build cannot be combined"
fi
[ -z "$MODE" ] && MODE="build-only"

PROJECT_FILE="$ROOT/project.yml"
[ -f "$PROJECT_FILE" ] || die_error "project file not found: $PROJECT_FILE"

# --- validation -----------------------------------------------------------

# Semantic version: MAJOR.MINOR.PATCH, no leading zeros, optional
# -prerelease of dot-separated [0-9A-Za-z-] identifiers.
valid_version() {
  local v="$1"
  [[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

valid_build() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if [ "$MODE" = "set" ]; then
  valid_version "$NEW_VERSION" \
    || die_usage "invalid semantic version: '$NEW_VERSION' (want MAJOR.MINOR.PATCH, e.g. 1.2.3)"
fi
if [ -n "$SET_BUILD" ]; then
  valid_build "$SET_BUILD" \
    || die_usage "invalid build number: '$SET_BUILD' (want a positive integer)"
fi

# --- read current values --------------------------------------------------

# Prints each distinct value of KEY in project.yml, one per line.
read_values() {
  grep -E "^[[:space:]]*$1:" "$PROJECT_FILE" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//' | sort -u || true
}

CURRENT_VERSION="$(read_values MARKETING_VERSION)"
CURRENT_BUILD="$(read_values CURRENT_PROJECT_VERSION)"
[ -n "$CURRENT_VERSION" ] || die_error "no MARKETING_VERSION found in $PROJECT_FILE"
[ -n "$CURRENT_BUILD" ] || die_error "no CURRENT_PROJECT_VERSION found in $PROJECT_FILE"
[ "$(printf '%s\n' "$CURRENT_VERSION" | wc -l | tr -d ' ')" -eq 1 ] \
  || die_error "MARKETING_VERSION drift in $PROJECT_FILE: $(printf '%s' "$CURRENT_VERSION" | tr '\n' ' ')(targets must agree; fix project.yml first)"
[ "$(printf '%s\n' "$CURRENT_BUILD" | wc -l | tr -d ' ')" -eq 1 ] \
  || die_error "CURRENT_PROJECT_VERSION drift in $PROJECT_FILE: $(printf '%s' "$CURRENT_BUILD" | tr '\n' ' ')(targets must agree; fix project.yml first)"
valid_version "$CURRENT_VERSION" \
  || die_error "current MARKETING_VERSION is not a semantic version: '$CURRENT_VERSION'"
valid_build "$CURRENT_BUILD" \
  || die_error "current CURRENT_PROJECT_VERSION is not a positive integer: '$CURRENT_BUILD'"

if [ "$MODE" = "check" ]; then
  echo "version: $CURRENT_VERSION"
  echo "build:   $CURRENT_BUILD"
  echo "file:    $PROJECT_FILE"
  exit 0
fi

# --- compute target values ------------------------------------------------

TARGET_VERSION="$CURRENT_VERSION"
if [ "$MODE" = "set" ]; then
  TARGET_VERSION="$NEW_VERSION"
elif [ "$MODE" = "bump" ]; then
  base="${CURRENT_VERSION%%-*}"
  major="${base%%.*}"; rest="${base#*.}"
  minor="${rest%%.*}"; patch="${rest#*.}"
  case "$BUMP_PART" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  TARGET_VERSION="$major.$minor.$patch"
fi

TARGET_BUILD="$CURRENT_BUILD"
if [ "$BUMP_BUILD" -eq 1 ]; then
  TARGET_BUILD=$((CURRENT_BUILD + 1))
fi
if [ -n "$SET_BUILD" ]; then
  TARGET_BUILD="$SET_BUILD"
fi

if [ "$TARGET_VERSION" = "$CURRENT_VERSION" ] && [ "$TARGET_BUILD" = "$CURRENT_BUILD" ]; then
  echo "already at version $CURRENT_VERSION (build $CURRENT_BUILD); nothing to do"
  exit 0
fi

# --- write ----------------------------------------------------------------

# Replaces every `KEY: "old"` with `KEY: "new"`; all targets move together.
write_key() {
  local key="$1" new_value="$2" tmp
  tmp="$(mktemp "$PROJECT_FILE.tmp.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN
  sed -E "s|^([[:space:]]*$key:[[:space:]]*)\"[^\"]*\"|\1\"$new_value\"|" "$PROJECT_FILE" > "$tmp"
  grep -qE "^[[:space:]]*$key:[[:space:]]*\"$new_value\"" "$tmp" \
    || die_error "failed to update $key in $PROJECT_FILE"
  cat "$tmp" > "$PROJECT_FILE"
  rm -f "$tmp"
  trap - RETURN
}

describe() {
  echo "version: $CURRENT_VERSION -> $TARGET_VERSION"
  echo "build:   $CURRENT_BUILD -> $TARGET_BUILD"
  echo "file:    $PROJECT_FILE"
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run; nothing written"
  describe
  exit 0
fi

# Update version first, then build, so a crash cannot leave a new build
# number on the old version. Both keys live in the same file and each
# write is a whole-file rewrite of already-validated content.
[ "$TARGET_VERSION" != "$CURRENT_VERSION" ] && write_key MARKETING_VERSION "$TARGET_VERSION"
[ "$TARGET_BUILD" != "$CURRENT_BUILD" ] && write_key CURRENT_PROJECT_VERSION "$TARGET_BUILD"

describe
echo "next: run 'xcodegen generate' so the generated project and Info.plist pick this up"
