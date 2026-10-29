# Setup flow (T2.3)

`SetupFlow` in EarnPlayCore is the guided first-run state machine for the
child device. The child app (`SetupFlowView` + `SetupFlowViewModel`)
drives it from FamilyControls UI. It depends on T2.1 (`PolicyStore`) and
T2.2 (`ShieldManager`); both are used, neither is modified by this task.

## Steps (strictly ordered, no skipping)

1. **Authorization** — FamilyControls authorization in Screen Time
   (`AuthorizationCenter.requestAuthorization(for: .child)` — the
   guardian-approved child member, so the parent approves and the child
   cannot self-approve or revoke alone), on the child's device. A denial
   leaves the flow on this step.
2. **Enumeration** — `FamilyActivityPicker` enumerates the apps and
   categories on the device. The pick must be non-empty (at least one app
   or one category); an empty pick is refused because it would shield
   nothing. The selection step offers a re-pick (`restartEnumeration`),
   which returns to this step without skipping anything later.
3. **Selection** — the parent splits the enumerated apps into the
   allowlist (never blocked) and the unblockable list (a completed
   challenge may open them). Enumerated apps in neither list stay blocked
   with no challenge offered. Apps named in both lists are sanitized to
   the allowlist, matching `Policy.isChallengeUnlockable` precedence.
4. **Prevent-deleting-apps guidance** — static instructions
   (Settings → Screen Time → Content & Privacy Restrictions →
   iTunes & App Store Purchases → Deleting Apps → Don't Allow) so the
   child app cannot simply be removed. Acknowledging commits setup.
5. **Complete** — the initial policy is written and shields are applied.

Completion is a single atomic commit, in order: persist the enumeration,
write the policy (version snapshot + 1 — the bump applies to the
snapshot being edited, so a concurrently synced newer policy wins over a
stale commit instead of being overwritten by it — starting from the current
policy so existing overrides, chore pool, durations, caps, and settings
are preserved — only the setup selections change: allowlist =
Phone/Messages/EarnPlay defaults plus the staged allowlist; unblockable =
the staged set), clear the incomplete restrictive record below (the staged
enumeration replaces all prior incomplete restrictions), then hand the
enumeration to `ShieldManager`, which shields
every enumerated app except the allowlist (enumeration-first) with the
picked categories as the backstop for newly installed apps. Finishing
rechecks live Screen Time authorization first: if access was revoked while
the user was in Settings, nothing is saved and the flow returns to
`authorization` with an authorization error. The completion summary
(including the category-backstop-disabled warning) stays visible until the
parent taps Continue, and each picked app's choice is restored from the
effective policy (always-allowed → Allowed, else challenge-unlockable →
Earn, else Blocked), so a relaunch shows the saved choices instead of
Blocked-for-all.

## No half-open state

- Every accepted enumeration is persisted (merged with prior incomplete
  picks) as a distinctly-incomplete restrictive record, so terminating
  the app from the selection or guidance step loses nothing; a relaunch
  restores those shields while staying incomplete. If that persist fails,
  the submit itself fails and the flow stays at enumeration — it never
  advances on a promise of restoration it cannot deliver. Abandoning the
  flow before the commit writes no policy, but picked apps are not left
  unshielded: abandoning with a staged enumeration merges it forward with
  the previously persisted restrictions, persists the merged record to
  the incomplete file regardless of policy version, and applies the
  merged configuration (default-deny) — an aborted retry never loosens
  prior restrictions. Abandoning from the picker submits the current
  selection first, so Start over before Continue still shields the picked
  apps. Abandoning a completed setup — or one waiting for
  reauthorization — is a no-op that preserves the pair. The incomplete
  record can never confer completion: only the completion file plus a
  stored policy restores as complete.
- If the enumeration or the policy cannot be persisted, the commit
  reports `persistenceFailed`, the flow stays on the guidance step, and
  the caller may retry. On a policy failure the just-written completion
  enumeration is rolled back (the previous content, if any, is restored),
  so no uncommitted completion data survives and a relaunch cannot
  mistake the failed setup for a completed one; the incomplete
  restrictive record (if any) survives and restores as incomplete with
  shields, by design.
- A completed setup survives relaunch only while Screen Time access is
  still approved: a new `SetupFlow` over the same stores starts at
  `complete` (policy version > 0 AND a non-empty persisted enumeration)
  and re-applies the enumeration to its `ShieldManager` only with current
  approval. With a committed pair but revoked access, the flow starts at
  `authorization` with reauthorization offered (a re-grant restores
  completion without re-picking) and no shields applied. A policy without
  any persisted record, or a corrupt enumeration file, restores as
  incomplete with nothing applied; a persisted enumeration without a
  policy (an abandoned run's record from before the incomplete file
  existed) plus the incomplete file restore as incomplete with the merged
  apps shielded.
- Handoff: once a policy exists, unknown apps are governed by T2.5's
  default-deny rule (a later task; only the handoff is stated here).

## Token mapping and the category caveat

Picker tokens are opaque, so the view model assigns each picked token a
stable `AppRef` / `AppCategoryRef` identifier and persists the pairing in
`SetupTokenStore` (`setup-token-mapping.json`). Identifiers are stable
across reselection: deselecting an app never releases its identifier, so
re-picking reuses the original `AppRef` and can never orphan a retained
admin override. The mapping renders the picked apps' names/icons after a
relaunch and will let the v1 ManagedSettings backend resolve each
`AppRef` back to its token. Shields and counts never depend on it — only
the token-backed labels do — and the Earn-to-unblock count covers only
effectively earnable apps (`isChallengeUnlockable`), matching each app's
displayed choice.

FamilyControls does not reveal which category an app belongs to, so
per-app categories are recorded as unknown on the real-device path. T2.2's
allowlist fallback therefore governs there: when the allowlist holds a
real app, the category backstop is disabled to preserve allowlist access,
and the completion screen reports that honestly. The picked categories
are always recorded as the backstop set, and the simulated path (where
categories are known) shields through them — see the backstop assertions
in `SetupFlowTests`.

## Backend and verification status

The child app installs `NonEnforcingShieldBackend`, which records the
applied configuration so the completion screen can report what WOULD be
shielded, and enforces nothing. T2.4 replaces it with the
simulated-shield backend behind the same protocol; v1 replaces that with
the real ManagedSettings backend.

Demo verification for this task runs against a simulated backend (unit
tests in `SetupFlowTests`, package and app suites): the no-skip state
machine, the non-empty initial policy, enumeration-first shielding, and
the category backstop all pass there. The FamilyControls distribution
entitlement is NOT filed, so real authorization cannot be granted on
device. Real shield enforcement is NOT verified by this task and must
never be claimed as working without the entitlement.

## Manual-only steps (unverified here — never reported as passed)

- The Screen Time authorization prompt on a real device.
- The FamilyActivityPicker sheet (enumeration + re-pick).
- Opening a shielded, unblockable, or allowlist app on device.
- The prevent-deleting-apps setting actually blocking deletion.
- Token-label rendering (`Label(token)`) after a relaunch on device.

These need a device build with the entitlement (v1) and are listed in
the PR body as manual-only/unverified.
