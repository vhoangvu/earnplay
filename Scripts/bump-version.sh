#!/usr/bin/env bash
# T7.3 release versioning. One command sets the app (marketing) version
# and/or the build number everywhere the build reads them.
#
# Versioning scheme (SSOT/HLD/LLD SS15):
#   - App version: MAJOR.MINOR.PATCH, three numeric components only.
#     It feeds CFBundleShortVersionString, which App Store Connect
#     requires in that form, so a prerelease label (e.g. -beta.1) must
#     never be written here; keep such labels in release notes, tags,
#     or TestFlight notes instead. Bumped MANUALLY with this script.
#     A pipeline run never changes the app version on its own.
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
SET_BUILD_GIVEN=0
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
      [ "$SET_BUILD_GIVEN" -eq 0 ] || die_usage "--set-build given twice"
      [ -n "$2" ] || die_usage "--set-build needs a non-empty value"
      SET_BUILD_GIVEN=1
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

[ -n "$MODE" ] || [ "$BUMP_BUILD" -eq 1 ] || [ "$SET_BUILD_GIVEN" -eq 1 ] \
  || die_usage "nothing to do: pass --version, --bump, --bump-build, --set-build or --check"
if [ "$MODE" = "check" ] && { [ "$BUMP_BUILD" -eq 1 ] || [ "$SET_BUILD_GIVEN" -eq 1 ]; }; then
  die_usage "--check cannot be combined with a change"
fi
if [ "$BUMP_BUILD" -eq 1 ] && [ "$SET_BUILD_GIVEN" -eq 1 ]; then
  die_usage "--bump-build and --set-build cannot be combined"
fi
[ -z "$MODE" ] && MODE="build-only"

PROJECT_FILE="$ROOT/project.yml"
[ -f "$PROJECT_FILE" ] || die_error "project file not found: $PROJECT_FILE"

# --- validation -----------------------------------------------------------

# App marketing version: MAJOR.MINOR.PATCH only, no leading zeros and
# no prerelease/build suffix (see header: CFBundleShortVersionString).
valid_version() {
  local v="$1"
  [[ "$v" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

valid_build() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if [ "$MODE" = "set" ]; then
  valid_version "$NEW_VERSION" \
    || die_usage "invalid semantic version: '$NEW_VERSION' (want MAJOR.MINOR.PATCH, e.g. 1.2.3)"
fi
if [ "$SET_BUILD_GIVEN" -eq 1 ]; then
  valid_build "$SET_BUILD" \
    || die_usage "invalid build number: '$SET_BUILD' (want a positive integer)"
fi

# --- read current values --------------------------------------------------

# Prints each distinct value of KEY in project.yml, one per line.
read_values() {
  grep -E "^[[:space:]]*$1:" "$PROJECT_FILE" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//' | sort -u || true
}

# Prints each value of KEY inside TARGET's block under `targets:`, one per
# line. Target blocks start at two-space indent; the block ends at the next
# target or at the next top-level key (e.g. `schemes:`).
target_values() {
  local target="$1" key="$2"
  awk -v target="$target" -v key="$key" '
    /^targets:/ { in_targets=1; next }
    /^[^[:space:]]/ { in_targets=0 }
    in_targets && /^  [^[:space:]]/ {
      name=$0; sub(/^  /, "", name); sub(/:.*/, "", name); current=name; next
    }
    in_targets && current==target && $0 ~ ("^[[:space:]]*" key ":") { print }
  ' "$PROJECT_FILE" | sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//' || true
}

# Both app targets must resolve both settings before any comparison:
# a missing entry must not hide behind the other target's value.
for target in EarnPlay EarnPlayAdmin; do
  for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
    [ -n "$(target_values "$target" "$key")" ] \
      || die_error "missing $key for target $target in $PROJECT_FILE (both EarnPlay and EarnPlayAdmin must set MARKETING_VERSION and CURRENT_PROJECT_VERSION)"
  done
done

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
  base="$CURRENT_VERSION"
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
if [ "$SET_BUILD_GIVEN" -eq 1 ]; then
  TARGET_BUILD="$SET_BUILD"
fi

if [ "$TARGET_VERSION" = "$CURRENT_VERSION" ] && [ "$TARGET_BUILD" = "$CURRENT_BUILD" ]; then
  echo "already at version $CURRENT_VERSION (build $CURRENT_BUILD); nothing to do"
  exit 0
fi

# --- write ----------------------------------------------------------------

# Stages every requested change in one temporary file, validates it,
# then atomically renames it over project.yml. Every `KEY: old` /
# `KEY: "old"` becomes `KEY: "new"`; read_values accepts both quoted and
# unquoted YAML, so the write must handle both. All targets move
# together: every changed KEY line must end at the new value. A failure
# anywhere before the rename leaves project.yml untouched, so a combined
# bump can never leave a partial state. The rename preserves the
# original file's permissions (mktemp creates 0600).
write_all() {
  local tmp perms
  tmp="$(mktemp "$PROJECT_FILE.tmp.XXXXXX")" \
    || die_error "failed to create temporary file next to $PROJECT_FILE"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ] && [ "$TARGET_BUILD" != "$CURRENT_BUILD" ]; then
    if ! sed -E \
      -e "s#^([[:space:]]*MARKETING_VERSION:[[:space:]]*)(\"[^\"]*\"|[^[:space:]#]+)#\1\"$TARGET_VERSION\"#" \
      -e "s#^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)(\"[^\"]*\"|[^[:space:]#]+)#\1\"$TARGET_BUILD\"#" \
      "$PROJECT_FILE" > "$tmp"; then
      rm -f "$tmp"; trap - EXIT; die_error "failed to stage $PROJECT_FILE"
    fi
  elif [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
    if ! sed -E \
      "s#^([[:space:]]*MARKETING_VERSION:[[:space:]]*)(\"[^\"]*\"|[^[:space:]#]+)#\1\"$TARGET_VERSION\"#" \
      "$PROJECT_FILE" > "$tmp"; then
      rm -f "$tmp"; trap - EXIT; die_error "failed to stage $PROJECT_FILE"
    fi
  elif [ "$TARGET_BUILD" != "$CURRENT_BUILD" ]; then
    if ! sed -E \
      "s#^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)(\"[^\"]*\"|[^[:space:]#]+)#\1\"$TARGET_BUILD\"#" \
      "$PROJECT_FILE" > "$tmp"; then
      rm -f "$tmp"; trap - EXIT; die_error "failed to stage $PROJECT_FILE"
    fi
  else
    cp "$PROJECT_FILE" "$tmp" || { rm -f "$tmp"; trap - EXIT; die_error "failed to stage $PROJECT_FILE"; }
  fi
  # Validate every changed key in the staged file before committing.
  if [ "$TARGET_VERSION" != "$CURRENT_VERSION" ]; then
    validate_key MARKETING_VERSION "$TARGET_VERSION" "$tmp" \
      || { rm -f "$tmp"; trap - EXIT; die_error "failed to update MARKETING_VERSION in $PROJECT_FILE"; }
  fi
  if [ "$TARGET_BUILD" != "$CURRENT_BUILD" ]; then
    validate_key CURRENT_PROJECT_VERSION "$TARGET_BUILD" "$tmp" \
      || { rm -f "$tmp"; trap - EXIT; die_error "failed to update CURRENT_PROJECT_VERSION in $PROJECT_FILE"; }
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    perms="$(stat -f '%Lp' "$PROJECT_FILE")" || { rm -f "$tmp"; trap - EXIT; die_error "failed to read permissions of $PROJECT_FILE"; }
  else
    perms="$(stat -c '%a' "$PROJECT_FILE")" || { rm -f "$tmp"; trap - EXIT; die_error "failed to read permissions of $PROJECT_FILE"; }
  fi
  chmod "$perms" "$tmp" || { rm -f "$tmp"; trap - EXIT; die_error "failed to preserve permissions on staged $PROJECT_FILE"; }
  mv "$tmp" "$PROJECT_FILE" || { rm -f "$tmp"; trap - EXIT; die_error "failed to replace $PROJECT_FILE"; }
  trap - EXIT
}

# Fails unless every KEY line in $3 now reads exactly "new value" $2.
validate_key() {
  local key="$1" new_value="$2" staged="$3" total updated
  total="$(grep -cE "^[[:space:]]*$key:" "$staged" || true)"
  updated="$(grep -cE "^[[:space:]]*$key:[[:space:]]*\"$new_value\"[[:space:]]*$" "$staged" || true)"
  [ "$total" -gt 0 ] && [ "$updated" -eq "$total" ]
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

# Stage both keys in one temporary file, validate, then atomically
# rename over project.yml: a combined bump lands both keys or neither.
write_all

describe
echo "next: run 'xcodegen generate' so the generated project and Info.plist pick this up"
