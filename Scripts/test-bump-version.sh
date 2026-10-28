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
  # Normalize the scratch copy to version 0.1.0 / build 1 (quoted or
  # unquoted) so assertions below stay independent of the live file's
  # already-released values.
  sed -E 's#^([[:space:]]*MARKETING_VERSION:[[:space:]]*)("[^"]*"|[^[:space:]]+)#\1"0.1.0"#; s#^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)("[^"]*"|[^[:space:]]+)#\1"1"#' \
    "$WORK/project.yml" > "$WORK/project.yml.norm" && mv "$WORK/project.yml.norm" "$WORK/project.yml"
}

# marketing values present in a project.yml, one per line
versions_in() { grep -E '^[[:space:]]*MARKETING_VERSION:' "$1" | sed -E 's/^[^:]*:[[:space:]]*//; s/"//g'; }
builds_in()   { grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$1" | sed -E 's/^[^:]*:[[:space:]]*//; s/"//g'; }

# drop the Nth (1-based) occurrence of KEY line from $WORK/project.yml
remove_nth_key() { # key n
  awk -v key="$1" -v n="$2" 'BEGIN{c=0} $0 ~ ("^[[:space:]]*" key ":") {c++; if (c==n) next} {print}' \
    "$WORK/project.yml" > "$WORK/project.yml.tmp" && mv "$WORK/project.yml.tmp" "$WORK/project.yml"
}

# strip double quotes from the Nth (1-based) occurrence of KEY in $WORK/project.yml
unquote_nth_key() { # key n
  awk -v key="$1" -v n="$2" 'BEGIN{c=0} $0 ~ ("^[[:space:]]*" key ":") {c++; if (c==n) gsub(/"/,"")} {print}' \
    "$WORK/project.yml" > "$WORK/project.yml.tmp" && mv "$WORK/project.yml.tmp" "$WORK/project.yml"
}

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

# explicit set (plain MAJOR.MINOR.PATCH only; prerelease rejected below)
fresh
"$BUMP" --root "$WORK" --version 2.0.0 > /dev/null
expect_eq "set: explicit version" "2.0.0" "$(versions_in "$WORK/project.yml" | sort -u)"

# F1: prerelease must never land in MARKETING_VERSION (CFBundleShortVersionString
# requires three numeric components); expect_reject also proves file unchanged.
fresh
expect_reject "F1 invalid: prerelease '2.0.0-beta.1' rejected" --version 2.0.0-beta.1
expect_reject "F1 invalid: prerelease '1.2.3-rc.1' rejected" --version 1.2.3-rc.1
expect_eq "F1: MARKETING_VERSION untouched by prerelease attempt" "0.1.0" "$(versions_in "$WORK/project.yml" | sort -u)"

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

# --- R2-F1: empty --set-build must be rejected at parse time ----------------
# An empty value must not be treated as "option absent": it must fail with
# no write, and must not let --bump-build slip past the mutual-exclusion
# check in either argument order.
fresh
expect_reject "R2-F1 invalid: empty --set-build rejected" --set-build ""
expect_reject "R2-F1 invalid: --bump-build + empty --set-build rejected" --bump-build --set-build ""
expect_reject "R2-F1 invalid: empty --set-build + --bump-build rejected" --set-build "" --bump-build
expect_eq "R2-F1: version untouched after empty --set-build attempts" "0.1.0" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "R2-F1: build untouched after empty --set-build attempts" "1" "$(builds_in "$WORK/project.yml" | sort -u)"
# The real mutual-exclusion check must still fire for a non-empty conflict.
fresh
before="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
if out="$("$BUMP" --root "$WORK" --bump-build --set-build 5 2>&1)"; then
  bad "R2-F1: --bump-build + --set-build mutual exclusion fires (script exited 0)"
else
  case "$out" in
    *"cannot be combined"*) ok "R2-F1: --bump-build + --set-build mutual exclusion fires" ;;
    *) bad "R2-F1: --bump-build + --set-build mutual exclusion fires (got: $out)" ;;
  esac
fi
after="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
expect_eq "R2-F1: mutual-exclusion rejection writes nothing" "$before" "$after"

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

# --- F2: a missing entry in either target must fail --check and block a bump ----
# occurrence 1 = EarnPlay, 2 = EarnPlayAdmin
for spec in "MARKETING_VERSION 1" "MARKETING_VERSION 2" "CURRENT_PROJECT_VERSION 1" "CURRENT_PROJECT_VERSION 2"; do
  # shellcheck disable=SC2086
  set -- $spec
  fresh
  remove_nth_key "$1" "$2"
  if "$BUMP" --root "$WORK" --check > /dev/null 2>&1; then
    bad "F2 missing entry: --check fails without $1 in target #$2"
  else
    ok "F2 missing entry: --check fails without $1 in target #$2"
  fi
  expect_reject "F2 missing entry: bump blocked without $1 in target #$2" --bump-build
done

# --- F3: mixed quoted/unquoted values must all be updated -----------------------
fresh
unquote_nth_key CURRENT_PROJECT_VERSION 2
if "$BUMP" --root "$WORK" --check > /dev/null 2>&1; then
  ok "F3 mixed quoting: --check passes with quoted+unquoted build"
else
  bad "F3 mixed quoting: --check passes with quoted+unquoted build"
fi
"$BUMP" --root "$WORK" --bump-build > /dev/null
expect_eq "F3 mixed quoting: both builds bumped 1 -> 2" "2" "$(builds_in "$WORK/project.yml" | sort -u)"
expect_eq "F3 mixed quoting: both targets present after bump" "2" "$(builds_in "$WORK/project.yml" | wc -l | tr -d ' ')"
if "$BUMP" --root "$WORK" --check > /dev/null 2>&1; then
  ok "F3 mixed quoting: --check still passes after bump"
else
  bad "F3 mixed quoting: --check still passes after bump"
fi

fresh
unquote_nth_key MARKETING_VERSION 2
"$BUMP" --root "$WORK" --version 1.0.0 > /dev/null
expect_eq "F3 mixed quoting: both versions set to 1.0.0" "1.0.0" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "F3 mixed quoting: both version targets present after set" "2" "$(versions_in "$WORK/project.yml" | wc -l | tr -d ' ')"

# --- F4: suite baseline is independent of the live file's released values -------
# Simulate a live project.yml that already carries a bumped version/build by
# pointing the fixture at a bumped copy; fresh() must normalize it to 0.1.0/1.
saved_fixture="$FIXTURE"
bumped_dir="$(mktemp -d)"
sed -E 's#^([[:space:]]*MARKETING_VERSION:[[:space:]]*)("[^"]*"|[^[:space:]]+)#\1"9.8.7"#; s#^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)("[^"]*"|[^[:space:]]+)#\1"42"#' \
  "$FIXTURE" > "$bumped_dir/project.yml"
FIXTURE="$bumped_dir/project.yml"
fresh
out="$("$BUMP" --root "$WORK" --check)"
expect_eq "F4 bumped live file: normalized version baseline" "version: 0.1.0" "$(printf '%s\n' "$out" | head -n 1)"
expect_eq "F4 bumped live file: normalized build baseline" "build:   1" "$(printf '%s\n' "$out" | sed -n 2p)"
"$BUMP" --root "$WORK" --bump patch --bump-build > /dev/null
expect_eq "F4 bumped live file: patch bump from normalized baseline" "0.1.1" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "F4 bumped live file: build bump from normalized baseline" "2" "$(builds_in "$WORK/project.yml" | sort -u)"
FIXTURE="$saved_fixture"
rm -rf "$bumped_dir"

# --- R2-F2: project.yml writes are atomic -------------------------------------
# A combined bump updates both keys or neither, the original permissions
# survive the rename, and a failure while staging the build-number change
# leaves project.yml byte-identical (no partial bump).
mode_of() { # file
  if [ "$(uname -s)" = "Darwin" ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

fresh
chmod 640 "$WORK/project.yml"
"$BUMP" --root "$WORK" --bump patch --bump-build > /dev/null
expect_eq "R2-F2 combined: version bumped" "0.1.1" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "R2-F2 combined: build bumped" "2" "$(builds_in "$WORK/project.yml" | sort -u)"
expect_eq "R2-F2 combined: permissions preserved" "640" "$(mode_of "$WORK/project.yml")"

fresh
chmod 640 "$WORK/project.yml"
before="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
fakebin="$WORK/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/sed" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in *CURRENT_PROJECT_VERSION*) echo "simulated failure staging build change" >&2; exit 1 ;; esac
done
exec /usr/bin/sed "$@"
SHIM
chmod +x "$fakebin/sed"
if PATH="$fakebin:$PATH" "$BUMP" --root "$WORK" --bump patch --bump-build > /dev/null 2>&1; then
  bad "R2-F2 atomic: simulated mid-bump failure is reported (script exited 0)"
else
  ok "R2-F2 atomic: simulated mid-bump failure is reported"
fi
after="$(shasum -a 256 "$WORK/project.yml" | awk '{print $1}')"
expect_eq "R2-F2 atomic: failed combined bump leaves file byte-identical" "$before" "$after"
expect_eq "R2-F2 atomic: version not partially bumped" "0.1.0" "$(versions_in "$WORK/project.yml" | sort -u)"
expect_eq "R2-F2 atomic: build not partially bumped" "1" "$(builds_in "$WORK/project.yml" | sort -u)"
expect_eq "R2-F2 atomic: permissions untouched by failed bump" "640" "$(mode_of "$WORK/project.yml")"

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
