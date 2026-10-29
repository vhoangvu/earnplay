# Setup flow (T2.3)

`SetupFlow` in EarnPlayCore is the guided first-run state machine for the
child device. The child app (`SetupFlowView` + `SetupFlowViewModel`)
drives it from FamilyControls UI. It depends on T2.1 (`PolicyStore`) and
T2.2 (`ShieldManager`); both are used, neither is modified by this task.

## Steps (strictly ordered, no skipping)

1. **Authorization** — FamilyControls authorization in Screen Time
   (`AuthorizationCenter.requestAuthorization(for: .individual)`), on the
   child's device. A denial leaves the flow on this step.
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
write the initial policy (version `storedVersion + 1`; allowlist =
Phone/Messages/EarnPlay defaults plus the staged allowlist; unblockable =
the staged set; no never-unlockable overrides — the admin app may add
those later), then hand the enumeration to `ShieldManager`, which shields
every enumerated app except the allowlist (enumeration-first) with the
picked categories as the backstop for newly installed apps.

## No half-open state

- Abandoning the flow before the commit leaves no policy, no persisted
  enumeration, and no shield change: the flow returns to `authorization`
  and claims no protection. Abandoning a completed setup is a no-op.
- If the enumeration or the policy cannot be persisted, the commit
  reports `persistenceFailed`, the flow stays on the guidance step, and
  shields stay inactive; the parent may retry.
- A completed setup survives relaunch: a new `SetupFlow` over the same
  stores starts at `complete` (policy version > 0 AND a non-empty
  persisted enumeration) and re-applies the enumeration to its
  `ShieldManager`. A policy without an enumeration, an enumeration
  without a policy, or a corrupt enumeration file all restore as
  incomplete and claim no protection.
- Handoff: once a policy exists, unknown apps are governed by T2.5's
  default-deny rule (a later task; only the handoff is stated here).

## Token mapping and the category caveat

Picker tokens are opaque, so the view model assigns each picked token a
stable `AppRef` / `AppCategoryRef` identifier and persists the pairing in
`SetupTokenStore` (`setup-token-mapping.json`). The mapping renders the
picked apps' names/icons after a relaunch and will let the v1
ManagedSettings backend resolve each `AppRef` back to its token. Shields
and counts never depend on it — only the token-backed labels do.

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
