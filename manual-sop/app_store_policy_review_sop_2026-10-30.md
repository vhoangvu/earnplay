# App Store policy review SOP (manual, pre-submission)

EarnPlay, Meta hackathon. Written 2026-10-30. Companion to
`security_review_sop_wonder_full_2026-10-30.md` (that one is about code
security; this one is about getting through App Review with as little
friction as possible).

## 0. Purpose

A reviewer with no context must be able to install the shipping build,
understand what it does, and test it without hitting a crash, a dead
end, a misleading claim, or a Kids/privacy violation. This SOP is a
code + metadata review against the App Store Review Guidelines. It is
NOT a guarantee of approval. Apple decides; this review only removes
the avoidable reasons for a rejection, a metadata rejection, or a
"please clarify" round-trip.

The review is READ-ONLY and sits OUTSIDE the auto-proceed build loop:
no commits, no PRs, no merges, no code edits from the review session.

## 1. Runner and timing

- Runner: Vu, manually, in an interactive Muse Code session. This
  review is manual for the same reason as the security review: Vu
  wants it run on Wonder Full, and Wonder Full is subscription-only
  with no published Model API id, so the assistant's API-key agent
  runs cannot select it. Only an interactive session signed in with
  the purchasing account can.
- Model rule: confirm the current model before starting (§2). If Vu
  has not explicitly overridden the model, Wonder Full is the model.
  If Vu explicitly overrides to a different model for a run, use that
  model, record the override in the report header, and label the
  report with the actual model used. The assistant can also run this
  review on request, but the submission itself is always Vu's step.
- Target: the shipping candidate, AFTER the remaining M2 code merges,
  BEFORE App Store submission. The submission window targets
  Oct 31–Nov 2, ahead of the Nov 4 hackathon submission.
- If code moves after the review, re-run the changed areas. No
  review-driven changes after the Nov 3 dry run except Criticals on
  Vu's explicit call (same freeze rule as the security review).

### Preconditions (submission blockers, not code findings)

If any of these is unmet, the review can still run, but submission
waits. Do not file them as code findings.

- Apple Developer enrollment done ($99/yr, personal Apple ID). It
  gates TestFlight and App Store alike.
- Bundle ID prefix resolved. `com.vhoangvu` is a flagged placeholder
  needing Vu's decision before any signing step. Submission must not
  be attempted with a placeholder prefix.
- An App Store Connect record exists for the app.

## 2. Setup

- Clean tree: only the 2 generated Info.plists may be dirty.
  Record `git rev-parse HEAD` and the branch. That commit is the
  review target; findings cite it.
- Confirm the current model: in Muse Code, open `/model` and confirm
  it shows Wonder Full before starting, unless Vu explicitly
  overrode the model for this run (then record the override and
  label the report with the actual model used). If Wonder Full does
  not appear and there is no explicit override, stop and fix sign-in
  first; do not substitute another model silently.
- Static review only: read code, project files, and strings. Do not
  run the app, do not modify code. If the model starts editing,
  stop, `git revert` / discard, note it, and re-run the affected
  areas read-only.
- Generated-file note: `EarnPlay.xcodeproj` is GENERATED from
  `project.yml`. Check `project.yml` as the source AND the generated
  Info.plists as shipped: entitlements, URL types, background modes,
  and usage-description keys live in both places, and a drift between
  them is itself a finding.
- The model cannot see App Store Connect fields. Anything in §5.12
  is Vu's step in Connect, not something the model verifies from
  the repo. The model must not invent Connect values.

## 3. Scope

In scope: `EarnPlay/`, `EarnPlayAdmin/`, `EarnPlayCore/`,
`project.yml`, the generated Info.plists, any
`PrivacyInfo.xcprivacy` (check whether one exists; if none exists
and no data is collected, say so explicitly), and code-repo
`Docs/*.md` wherever docs state a claim the store metadata will
repeat.

Out of scope: llama.cpp internals beyond the integration surface,
GGUF weights, the earnplay-docs repo, App Store Connect web fields
(covered by the §5.12 cross-check, not from the repo), and dynamic
testing. First-launch download behavior on a real device and a
reviewer-flow walkthrough on an unpaired device are separate device
checks; list them under "not checked" (§6), do not claim them from
static reading.

## 4. Context claims to verify (not assume)

The prompt in §5 hands the model these claims. The model's job is to
verify each against code, and file a finding wherever code
contradicts one.

- Two apps: child tutor + parent admin. iOS only. The demo ships
  4th grade.
- Shields are SIMULATED (T2.4). No FamilyControls entitlement has
  been filed (T0.4 is v1). Any claim of real screen-time locking,
  in code strings or UI copy, is itself a Critical finding.
- No accounts, no in-app purchases, no ads, no third-party
  analytics. Verify; do not assume.
- No child data leaves the device except: (a) the first-launch
  model download (HTTPS + sha256, Wi-Fi only, ~807MB), and
  (b) Bluetooth sync to a parent-paired device
  (MultipeerConnectivity, trusted pairing).
- Child free-text is untrusted input. No chat with strangers. Sync
  goes only to the paired parent device.
- Effort-based unlock with three currencies (practice, movement
  trade, parent-stocked chores). "Unlock" means the in-app app gate,
  never a purchase.
- Llama 3.2 Community License attribution belongs in the About
  screen; llama.cpp attribution where required.

## 5. Paste-ready prompt

> You are doing a read-only App Store policy review of the EarnPlay
> iOS apps at commit <COMMIT> (branch <BRANCH>). Do not edit any
> file. Goal: flag anything that could get the app rejected, bounced
> for metadata, or stuck in a clarification round with App Review.
> Context (verify each against code; file a finding wherever code
> contradicts it): two apps, child tutor + parent admin, iOS only,
> demo ships 4th grade. Shields are SIMULATED; no FamilyControls
> entitlement has been filed; any claim of real screen-time locking
> is a Critical finding. No accounts, no in-app purchases, no ads,
> no third-party analytics (verify). No child data leaves the
> device except the first-launch model download (HTTPS + sha256,
> Wi-Fi only, ~807MB) and Bluetooth sync to a parent-paired device.
> Child free-text is untrusted; no chat with strangers. "Unlock"
> means the in-app effort gate, never a purchase. Llama 3.2
> attribution belongs in the About screen.
>
> Check each area below. For every finding give: severity, file +
> line, quoted excerpt, why App Review would care (cite the
> guideline number where you know it), and a suggested fix you do
> NOT apply. One root cause = one finding. If an area is clean,
> say so with the evidence you checked, not just "looks fine."
>
> 5.1 Kids Category (Guideline 1.3). Child app only, plus shared
> code: no third-party ads, no third-party analytics, no links out
> of the app, no purchase opportunities, no personal-data
> collection, no social features or external content. About-screen
> attribution as plain text is fine; a tappable external link in
> the child app is a finding (it needs a real parental gate, and
> the gate must be real). Check the admin app too and say which
> findings are child-only vs shared.
>
> 5.2 Privacy / COPPA (5.1.1, 5.1.4, 5.1.2). No collection or
> transmission of a child's name, age, voice, photos, location,
> contacts, or identifiers. Verify: MCPeerID displayName is a fixed
> string (e.g. "EarnPlay-Child"), never UIDevice.name or a user
> name; no IDFV/IDFA use or transmission; no child free-text in
> logs, analytics, or crash reports; the model-download request
> carries no identifiers beyond standard HTTPS; sync payloads
> contain only session records (no device name, no child name).
> Grep for analytics/crash SDK imports (Firebase, Sentry, etc.):
> any third-party SDK in the child app is at minimum a High under
> the Kids ban and needs justification.
>
> 5.3 Permissions and purpose strings (5.1.1). Every permission
> the app can trigger must have an accurate Info.plist usage
> description, in project.yml AND the generated plist: Local
> Network (NSLocalNetworkUsageDescription), Bonjour services
> (NSBonjourServices), Bluetooth if used
> (NSBluetoothAlwaysUsagePermission), Motion for movement trades
> (NSMotionUsageDescription), and anything for voice input or
> speech (read-aloud is system speech synthesis and needs no mic;
> if any voice-input path exists, check its string). Camera/Photos
> are not expected: any request for them is a finding. A missing
> string crashes on trigger: Critical. A vague or misleading
> string: High.
>
> 5.4 FamilyControls honesty (2.5, 2.3). Grep for DeviceActivity,
> ManagedSettings, FamilyControls, and Screen Time API imports and
> calls in shipped targets. Any use without the entitlement:
> Critical. Any UI copy claiming to "block", "lock", or "limit"
> other apps as real enforcement: Critical unless the copy
> explicitly says simulated. Check store-facing strings in code
> (app name, subtitles) for "parental control" claims.
>
> 5.5 Accurate metadata / completeness (2.3, 2.1). Every
> user-visible claim in code strings must match behavior: no
> "coming soon" feature presented as working; no placeholder or
> sample data in production targets (dashboard aggregates come
> from synced logs only; verify no demo fixtures ship in
> production); no dead buttons leading nowhere; the app must be
> usable on first launch by a stranger with no developer present
> (setup/onboarding complete). Critical sub-check: the child app
> must be practicable WITHOUT a paired admin device. A reviewer
> has one device; if practice requires pairing before any
> practice, that is a reviewer dead-end: Critical. Verify, do not
> assume, that practice works unpaired and sync is optional.
>
> 5.6 Model download and first launch (2.5.2, 2.1). ~807MB
> download: verify Wi-Fi-only gating in code (no cellular
> download attempt); verify progress UI plus retry plus a failure
> state (not a blank screen, not a spinner forever); verify the
> app does not re-download on every launch (already-downloaded
> check + sha256 verify); verify behavior if download fails or is
> cancelled (practice unavailable vs degraded must be explained
> in UI, not a crash). Verify no downloading of executable code
> anywhere: GGUF weights are model data, not code (say so in the
> finding text if a reviewer could misread it); any remote code
> loading is a Critical.
>
> 5.7 No hidden behavior (2.5.2, 2.3.1). No remote code, no
> JavaScript bridges loading remote content, no remotely fetched
> feature flags that change behavior, no debug/preview harnesses
> reachable in the Release build (check SyncDebugView and the
> previewHarnesses surface: verify #if DEBUG gating, target
> membership, or reachability, and say exactly how a reviewer
> could or could not reach them). No undocumented URL schemes or
> deep links that change state (check URL types in project.yml
> and the Info.plists).
>
> 5.8 Purchases and external payments (3.1). Verify no StoreKit,
> no IAP products, no external purchase links, and no "unlock"
> copy a reviewer could read as a paid unlock. The three unlock
> currencies must be clearly earnable in-app without payment:
> check UI copy for price language ("buy", "$", "purchase") near
> unlock flows; any hit is a finding.
>
> 5.9 Background modes and battery (2.5.4). Verify
> UIBackgroundModes claims only what is used (Multipeer
> advertising while backgrounded, if claimed, needs justification;
> unneeded background modes are a finding). No excessive
> background work. On-device inference itself is fine.
>
> 5.10 Third-party content and licenses (5.2). Llama 3.2
> attribution present in the shipped About screen, not just in
> docs; llama.cpp attribution where required; no third-party
> images, fonts, or code without a license; no claim of Apple
> endorsement in naming or strings.
>
> 5.11 Age rating and content. Content is educational; no
> user-generated content shared with anyone; no web content; no
> chat with strangers. Confirm the rating-questionnaire answers
> these imply (no UGC, no web access, no gambling, no ads) match
> code. If the admin app shows child free-text excerpts to the
> parent (auditor justifications), that is the parent's own
> child's data on their own device: fine, but flag it if any
> excerpt could leave the device (it must not).
>
> 5.12 App Store Connect metadata cross-check (Vu's step, not
> verifiable from the repo; list each item as "for Vu to confirm
> in Connect", do not invent values): description states
> explicitly that locking is simulated; screenshots show only
> shipped features and do not imply real blocking; privacy
> nutrition label matches code (if code collects nothing, the
> label must say Data Not Collected; a label/code mismatch is a
> Critical); support URL live; age rating appropriate; no
> "demo", "beta", or "test" language in the app name or
> description (Guideline 2.2 beta-language risk: "demo" in the
> hackathon sense must not appear in store copy).

## 6. Output format

- Header: target commit, date, model used.
- Findings: severity, file + line, quoted excerpt, why App Review
  would care (guideline number where known), suggested fix (NOT
  applied).
- Clean areas: one line each, with the evidence checked.
- Not checked: device behaviors (first-launch download on a real
  device, unpaired reviewer walkthrough) and Connect fields (§5.12).
- Known-open-confirmed: items from §6.1 that the code confirms are
  still in their known state. Do not re-file them as new findings.

### 6.1 Known-open items: confirm, do not re-file

File these as NEW findings only if code contradicts the known
state.

- (a) Simulated shields: known and intended. A finding only if
  code or UI copy claims real locking.
- (b) First-time pairing confirmation has no production UI
  (known gap, #64 merge decision pending). Confirm its current
  status; do not re-file as new unless code changed.
- (c) Bundle-ID placeholder: a submission precondition (§1), not
  a code finding, unless submission is attempted with it.
- (d) Pairing-code hash / sync-relay channel binding: security
  review items, not policy findings.

### 6.2 Severity guide

- Critical: certain rejection, crash during review, or a
  Kids/privacy violation (missing purpose string, FamilyControls
  API without entitlement, debug UI reachable in Release, metadata
  claiming real locking, label/code privacy mismatch).
- High: likely rejection, or a reviewer dead-end / confusion
  (practice requires pairing, third-party SDK in the child app,
  misleading purpose string, "unlock" copy reading as paid).
- Medium: fix before submission; unlikely alone to reject.
- Low / Info: polish or reviewer-clarity notes.
- When in doubt, rate one step lower and say why.

## 7. Chunking fallback

If one session cannot cover all of §5, split it: Run A §5.1–5.3,
Run B §5.4–5.6, Run C §5.7–5.9, Run D §5.10–5.12. Same target
commit for all runs. Merge the outputs and dedupe by root cause
before triage.

## 8. Triage

- Save the report OUTSIDE the repo (e.g.
  `~/earnplay-app-policy-review-2026-11-0X.md`) and paste it to
  the assistant.
- Real finding: fix before submission. Code fixes go through the
  normal loop (issue, implementation, CI, Copilot, grade, merge)
  unless the Nov 3 dry-run freeze applies, in which case only
  Criticals on Vu's explicit call. Metadata fixes (§5.12) are
  Vu's Connect step.
- False positive: mark it with the refuting code reference so it
  is not re-filed.
- Known-open: confirm and leave.
- Needs-device-verification: schedule the device check
  (first-launch download on a real device; unpaired reviewer-flow
  walkthrough) before submission.
- No silent scope extension: a finding that implies a feature
  change (e.g. building a new pairing UI) is a decision for Vu,
  not something the review session implements.
- A clean report is recorded as "App-policy review at <commit>:
  N findings, M fixed, K known-open", not as a guarantee of
  approval.

## 9. Stop conditions

- Wrong target (dirty tree beyond the 2 Info.plists, or the commit
  is not the shipping candidate): stop and re-establish the target.
- Wrong model: if the session is not on Wonder Full and Vu has not
  explicitly overridden the model for this run, stop and fix sign-in
  first; do not substitute another model silently. An explicit
  override is recorded in the report header and the report is labeled
  with the actual model used.
- Model starts editing code: stop, discard the edits, note it, and
  re-run the affected areas read-only.
- Model asserts App Store Connect values it cannot see: stop that
  line of reasoning, move those items to §5.12 "for Vu to confirm",
  and say so in the report.
