#!/usr/bin/env bash
# T7.3 tests for Scripts/bump-version.sh. Exercises the REAL script on
# scratch copies of the repo's real project.yml; the worktree is never
# modified. Run: Scripts/test-bump-version.sh
# Exit 0 = all cases pass, 1 = at least one failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUMP="$SCRIPT_DIR/bump-version.sh"
FIXTURE="$REPO_ROOT/project.yml"

PASS=0
FAIL=0
WORK=""

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

fresh() {
  WORK="$(mktemp -d)"
  cp "$FIXTURE" "$WORK/project.yml"
}

# marketing values present in a project.yml, one per line
versions_in() { grep -E '^[[:space:]]*MARKETING_VERSION:' "$1" | sed -E 's/^[^:]*:[[:space:]]*//; s/"//g'; }
builds_in()   { grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$1" | sed -E 's/^[^:]*:[[:space:]]*//; s/"//g'; }

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

expect_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2], got [$3])"; fi
}

expect_reject() { # name args... ; script must exit non-zero and not write
  local name="$1"; shift
  local before after
  before="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
  if "$BUMP" --root "$WORK" "$@" > /dev/null 2>&1; then
    bad "$name (script exited 0)"
    return
  fi
  after="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
  if [ "$before" = "$after" ]; then ok "$name"; else bad "$name (file changed on rejected input)"; fi
}

# --- version parse: --check reads the real file's values ------------------
fresh
out="$("$BUMP" --root "$WORK" --check)"
expect_eq "parse: --check reads marketing version" "version: 0.1.0" "$(printf '%s\n' "$out" | head -n 1)"
expect_eq "parse: --check reads build number" "build:   1" "$(printf '%s\n' "$out" | sed -n 2p)"

# --- bump major / minor / patch -------------------------------------------
fresh
"$BUMP" --root "$WORK" --bump major > /dev/null
expect_eq "bump major: 0.1.0 -> 1.0.0" "1.0.0" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "bump major: both targets updated" "2" "$(versions_in "$WORK/project.yml" | wc -l | tr -d ' ')"
expect_eq "bump major: build untouched" "1" "$(builds_in "$WORK/project.yml" | sort -u)"

fresh
"$BUMP" --root "$WORK" --bump minor > /dev/null
expect_eq "bump minor: 0.1.0 -> 0.2.0" "0.2.0" "$(versions_in "$WORK/project.yml" | sort -u)"

fresh
"$BUMP" --root "$WORK" --bump patch > /dev/null
expect_eq "bump patch: 0.1.0 -> 0.1.1" "0.1.1" "$(versions_in "$WORK/project.yml" | sort -u)"

# explicit set, including a prerelease suffix
fresh
"$BUMP" --root "$WORK" --version 2.0.0-beta.1 > /dev/null
expect_eq "set: explicit prerelease version" "2.0.0-beta.1" "$(versions_in "$WORK/project.yml" | sort -u)"

# --- build-number auto-increment, only when asked --------------------------
fresh
"$BUMP" --root "$WORK" --bump-build > /dev/null
expect_eq "build: --bump-build 1 -> 2" "2" "$(builds_in "$WORK/project.yml" | sort -u)"
expect_eq "build: both targets updated" "2" "$(builds_in "$WORK/project.yml" | wc -l | tr -d ' ')"
expect_eq "build: version untouched" "0.1.0" "$(versions_in "$WORK/project.yml" | sort -u)"
"$BUMP" --root "$WORK" --bump-build > /dev/null
expect_eq "build: second --bump-build 2 -> 3" "3" "$(builds_in "$WORK/project.yml" | sort -u)"
"$BUMP" --root "$WORK" --set-build 42 > /dev/null
expect_eq "build: --set-build 42" "42" "$(builds_in "$WORK/project.yml" | sort -u)"

# combined version bump + build bump in one run
fresh
"$BUMP" --root "$WORK" --bump patch --bump-build > /dev/null
expect_eq "combined: patch bump" "0.1.1" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "combined: build bump" "2" "$(builds_in "$WORK/project.yml" | sort -u)"

# --- idempotent re-run ------------------------------------------------------
fresh
"$BUMP" --root "$WORK" --version 0.2.0 > /dev/null
before="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
out="$("$BUMP" --root "$WORK" --version 0.2.0)"
after="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
expect_eq "idempotent: re-run with same version exits 0 and changes nothing" "$before" "$after"
case "$out" in
  *"nothing to do"*) ok "idempotent: re-run reports nothing to do" ;;
  *) bad "idempotent: re-run reports nothing to do (got: $out)" ;;
esac
expect_eq "idempotent: build not incremented by re-run" "1" "$(builds_in "$WORK/project.yml" | sort -u)"
out="$("$BUMP" --root "$WORK" --check)"
expect_eq "idempotent: --check still agrees" "version: 0.2.0" "$(printf '%s\n' "$out" | head -n 1)"

# --- dry run writes nothing --------------------------------------------------
fresh
before="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
"$BUMP" --root "$WORK" --bump major --bump-build --dry-run > /dev/null
after="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
expect_eq "dry-run: file unchanged" "$before" "$after"

# --- invalid-input rejection --------------------------------------------------
fresh
expect_reject "invalid: '1.2' rejected" --version 1.2
expect_reject "invalid: 'v1.2.3' rejected" --version v1.2.3
expect_reject "invalid: '1.02.3' rejected" --version 1.02.3
expect_reject "invalid: 'abc' rejected" --version abc
expect_reject "invalid: empty version rejected" --version ""
expect_reject "invalid: '1.2.3.4' rejected" --version 1.2.3.4
expect_reject "invalid: --bump huge rejected" --bump huge
expect_reject "invalid: --set-build 0 rejected" --set-build 0
expect_reject "invalid: --set-build -1 rejected" --set-build -1
expect_reject "invalid: --set-build abc rejected" --set-build abc
expect_reject "invalid: unknown flag rejected" --frobnicate
expect_reject "invalid: conflicting --bump-build + --set-build rejected" --bump-build --set-build 5

# --- drift detection -----------------------------------------------------------
fresh
# make the two targets disagree on purpose
awk 'BEGIN{n=0} /MARKETING_VERSION:/{n++; if(n==2) sub(/"[^"]*"/,"\"9.9.9\"")} {print}' \
  "$WORK/project.yml" > "$WORK/project.yml.drift" && mv "$WORK/project.yml.drift" "$WORK/project.yml"
if "$BUMP" --root "$WORK" --check > /dev/null 2>&1; then
  bad "drift: --check fails when targets disagree"
else
  ok "drift: --check fails when targets disagree"
fi

# --- missing file ---------------------------------------------------------------
empty="$(mktemp -d)"
if "$BUMP" --root "$empty" --check > /dev/null 2>&1; then
  bad "missing file: --check fails without project.yml"
else
  ok "missing file: --check fails without project.yml"
fi
rm -rf "$empty"

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
