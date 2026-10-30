# SOP: EarnPlay final-phase security review on Muse Code (Wonder Full, manual run)

## 0. Purpose

An independent, read-only security review of the EarnPlay codebase in the
last phase (M3), before the Nov 3 dry run and the Nov 4 submission. This
review does NOT replace T5.2 red-teaming (already merged), Copilot PR
review, CI, or the unit-test gates. It is a second opinion from the
strongest available model, run by Vu himself, because Wonder Full cannot
be invoked by an agent run (see §1).

## 1. Why this run is manual

This review is manual because Vu wants it run on Wonder Full, the
strongest available model. Wonder Full is subscription-only and has
no published Model API id, so the assistant's SSH-driven agent runs
(which authenticate with `META_API_KEY`) cannot select it — an agent
run cannot do this review on Wonder Full at all.
- Only an interactive Muse Code session signed in with the purchasing
  account can use it. Run this SOP in such a session (`/model` picker),
  not through the assistant's build loop.
- Model rule: confirm the current model before starting (§3 step 3).
  If Vu has not explicitly overridden the model, Wonder Full is the
  model — do not substitute another one and keep the Wonder Full
  label. If Vu explicitly overrides to a different model for a run,
  use that model, record the override in the report header, and label
  the report with the actual model used (it is then not a "Wonder
  Full review").
- This review sits OUTSIDE the auto-proceed build loop: it makes no
  commits, opens no PRs, and merges nothing. Findings come back to the
  assistant for triage, and real fixes go through the normal loop
  (issue → Muse Code fix → CI → Copilot → grade → merge).

## 2. When to run it

- Run against `origin/main` AFTER the remaining M2 code tasks have merged
  (T4.7 pipeline #64 plus T5.4/T5.5 code, if any lands as code). A review
  run against a moving target goes stale fast.
- Do it early enough that real findings still have gate time: no later
  than Nov 2. No review-driven merges after the Nov 3 dry run except
  Criticals, and only on Vu's explicit call.
- If code moves after the review, re-run only the changed areas and
  append a dated addendum — do not silently carry old findings forward.

## 3. Setup (5 minutes)

1. Check out a CLEAN tree of the target: `git status` must show nothing
   but the two generated `Info.plist` files (XcodeGen outputs, never
   committed). Do not review a dirty tree.
2. Record the target commit: `git rev-parse HEAD`. Write it at the top
   of the report (§6). Every finding maps to this commit.
3. In Muse Code, open `/model` and select the Wonder Full option.
   Confirm the picker shows Wonder Full before pasting the prompt. If it
   does not appear, the session is not signed in with the purchasing
   account — stop and fix sign-in first; do not substitute another model
   and call it the Wonder Full review, unless Vu has explicitly
   overridden the model for this run (then record the override in the
   report header and label the report with the actual model used).
4. Do NOT install anything, do NOT change code, do NOT run the app.
   This is a static review. Dynamic/on-device testing is a separate
   step (T7.5) and is out of scope here.

## 4. Scope

Review these, in the checked-out tree:

- `EarnPlay/` — child app (chat UI, tutor engine, practice pipeline,
  sync client, model download).
- `EarnPlayAdmin/` — parent/admin app (policy editor, dashboard,
  auditor, sync server side).
- `EarnPlayCore/` — shared package (question generation, hint ladder,
  effort scoring, decision logger, policy store, shield manager, sync
  transport, stalling/probe logic, read-aloud).
- `project.yml` / generated project, `Docs/*.md` in the code repo —
  read ONLY to check that documented security claims match the code
  (see §5.12).

Out of scope (do not spend the run here):

- Vendored llama.cpp C++ internals line by line. Review only the
  integration surface: how it is invoked, what data crosses into it,
  and the model-download + hash-verification path.
- The GGUF model weights file itself (data, not code).
- Dynamic testing, App Store review, and any server side (none exists).
- `Docs/` in the separate private earnplay-docs repo (not submitted).

## 5. Paste-ready prompt

Copy everything between the `---` lines into Muse Code after setup.
If the session stalls or truncates, split by the numbered areas
(§5.1–§5.12) across runs and merge the findings into one report.

---

You are doing a READ-ONLY security review of the EarnPlay iOS codebase
(a private, on-device tutor + app gate for elementary-school children,
grades 1–5, demo ships 4th grade). DO NOT edit, create, or delete any
file. DO NOT commit, push, open a PR, or apply any fix. Your only output
is the findings report specified below.

CONTEXT (verify each claim against the code; do not take it on faith):

- No child data leaves the device. There is no backend, no analytics
  SDK, and no crash reporter. The only network-adjacent paths should be
  (a) the first-launch model download over HTTPS with sha256
  verification into Application Support, and (b) local Bluetooth sync
  (MultipeerConnectivity) between the child app and the parent admin
  app on nearby devices.
- Child free-text is UNTRUSTED input. The tutor never decides alone:
  math is solver-verified, a separate auditor model checks decisions,
  and decision logic (hint ladder, floor rule, effort threshold, unlock)
  lives in deterministic code, not in model output.
- Unlock is EFFORT-based, not pass/fail: active time, attempts, hints,
  revisions, explanations. Three unlock currencies: practice (30 min),
  AI-offered movement trades, parent-stocked chores.
- Shields are SIMULATED in the Demo (real FamilyControls shields are a
  v1 item, entitlement not filed). The app must never claim real
  blocking. Any user-visible text claiming real locking is a finding.
- The admin app holds parent policy; the child app must not be able to
  raise its own limits.

REVIEW THESE AREAS. For each, read the actual code and cite file +
line + quoted excerpt for every finding. Never invent a file path. If
you cannot verify a claim from the code, say so and mark the finding
"needs human verification" instead of asserting it.

5.1 Secrets and credentials. Hardcoded passwords, API keys, tokens,
private keys, or signing material in code, fixtures, test data, sample
plists, or comments. Check for keys that only look like placeholders.

5.2 Child data storage. Where session logs, practice records, answers,
and free-text are written on disk; file protection classes; whether
child free-text or answers land in logs, crash logs, or console output.
Flag any persistent store that a second app or a backup could read
without the device passcode.

5.3 Network egress. Search for URLSession, NWConnection, sockets, and
any HTTP client. List EVERY outbound destination the code can reach.
Anything beyond the model download host is a finding. Verify the model
download path end to end: HTTPS, host pinning if any, sha256 check
before first use, failure handling if the hash mismatches, and that a
failed or partial download can never be loaded as a model.

5.4 Bluetooth sync. Pairing flow, pairing-code handling, session
transport, what crosses the wire (full records vs excerpts), whether a
nearby stranger device could pair, inject a policy, or read a child's
records. Check identity handling: how a peer is recognized across
sessions and what happens on rediscovery.

5.5 Prompt injection and untrusted input. Every place child free-text
flows: into model prompts, into decisions, into unlocks, into admin
views, into logs. Check the sanitizer (length caps, control characters)
and every path that bypasses it. Attempt concrete bypasses in your head:
long input, control characters, instruction-like text ("ignore previous
instructions", fake system messages), and text that mimics tutor output.
A path where child text changes a decision, a score, or a policy is a
finding, even if it requires odd input.

5.6 Unlock and gating integrity. Can a child game effort: fake active
time (idle spoofing, backgrounding, clock changes), hint farming,
replay of old sessions, or direct manipulation of stored effort/policy
files? Check the floor rule (genuine attempt + real hint interaction),
threshold handling, and the three trade paths (practice, movement,
chore). Check whether the child app can modify policy, thresholds, or
its own unlock state without the admin app.

5.7 Shield honesty and bypass. Confirm the simulated shield never
presents as real blocking. Check for bypass paths: URL schemes, deep
links, app-group containers, or debug/preview harnesses reachable from
the practice screen that could open a locked app or expose admin
functions to the child.

5.8 Input validation. Text composer, number pad, choice taps, chore
entries, policy editor fields. Length caps, type checks, and what
happens on malformed or extreme input (crashes, hangs, or state
corruption count as findings).

5.9 Dependencies. SwiftPM packages, the llama.cpp integration, and any
vendored code: pinned versions, known-outdated pins, and whether a
dependency receives child data or network access it does not need.

5.10 Privacy. Anything that leaves the device: analytics, telemetry,
identifiers (IDFV, device name, peer display names that leak a child's
name), or data written to shared containers, pasteboard, or screenshots.
Peer display names deserve a specific check: what string is broadcast
during sync discovery.

5.11 Admin-app exposure. What the admin app shows and stores; whether
sync excerpts expose more than the dashboard needs; whether admin
actions (policy change, dismiss auditor flag) are authenticated in any
way on a shared device, and what a child holding the device could do
in the admin app.

5.12 Docs-vs-code. Read Docs/Sync.md, Docs/SessionRecording.md, and
Docs/Dashboard.md in the code repo. The following are KNOWN, documented
Demo limitations — confirm the code matches the docs, and do NOT re-file
them as fresh findings unless the code contradicts the docs:
(a) pairing-code hash is offline-guessable (no PAKE/DH-SAS in Demo);
(b) no channel binding for the sync relay (no public MultipeerConnectivity
API for channel keys); (c) shields are simulated, not real
FamilyControls. If any of these is UNDOCUMENTED in the code you read,
that gap itself is a finding.

OUTPUT — write the report as plain text in your final message, in this
exact shape:

HEADER: target commit hash, date, model used, scope as reviewed.
FINDINGS (numbered): severity (Critical / High / Medium / Low / Info),
file + line, title, evidence (quoted excerpt), exploitability (who the
attacker is, what preconditions they need, whether the path is
reachable from the child app, the admin app, or a nearby device), and
suggested fix (described, NOT applied). Order Critical first.
CLEAN AREAS: each numbered area above with one line stating what was
checked and found OK, or "not fully checked" with the reason.
NOT CHECKED: dynamic testing, on-device behavior, App Store review,
server side (none exists) — state these explicitly.
KNOWN-DEFERRED CONFIRMED: the §5.12 items, each marked docs-match-code
or docs-gap.

SEVERITY GUIDE: Critical = exploitable child-data exfiltration, or a
gate bypass with no special preconditions. High = reachable vulnerability
with realistic preconditions. Medium = defense-in-depth gap or an issue
needing unusual preconditions. Low = hygiene. Info = observation, no
action needed. When in doubt, rate one step lower and say why.

RULES: no file changes of any kind. No fix may be applied, even a
one-liner. Quote exact code; do not paraphrase a finding's evidence.
If two findings share one root cause, file them once and cross-reference.

---

## 6. Running it in chunks (if one run stalls)

Split by area, same prompt, same report shape, one area group per run:

- Run A: §5.1, §5.2, §5.3 (secrets, storage, network).
- Run B: §5.4, §5.5 (sync, injection).
- Run C: §5.6, §5.7, §5.8 (unlock, shields, input validation).
- Run D: §5.9, §5.10, §5.11, §5.12 (deps, privacy, admin, docs-vs-code).

Merge the four reports into one numbered list, de-duplicating shared
root causes, before triage. Keep each run's target commit identical;
if the commit moves between runs, note it in the header and re-check
the moved areas.

## 7. After the review (triage, with the assistant)

1. Save the report OUTSIDE the repo (for example
   `~/earnplay-security-review-2026-11-0X.md`) and paste it to the
   assistant. Do not commit the report into the code repo.
2. Triage each finding as: real → fix through the normal loop (issue →
   Muse Code fix → CI → Copilot → grade → merge); false positive →
   mark with the refuting code reference; known-deferred → confirm
   docs-match-code and leave it; needs-verification → assistant checks
   from code before any fix is scoped.
3. Do not let a review finding silently extend scope: a fix that changes
   behavior, adds a feature, or moves the freeze needs Vu's explicit
   call, same as any other scope change.
4. A clean report is a result, not a proof: record it as "Wonder Full
   static review at <commit>: N findings, M fixed, K deferred" and keep
   the report file for the submission record. It does not replace
   T5.2, Copilot review, or on-device verification.

## 8. Stop conditions

- Stop and report if the session is not on Wonder Full (wrong model
  invalidates the "Wonder Full review" label), unless Vu explicitly
  overrode the model for this run — then record the override and label
  the report with the actual model used.
- Stop and report if the tree is dirty beyond the two generated
  Info.plists, or if the target commit cannot be established.
- Stop and report if the model starts editing files: revert with git,
  note it in the header, and re-run the affected areas read-only.
