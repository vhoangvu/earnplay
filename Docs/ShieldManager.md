# Shield manager (T2.2)

`ShieldManager` in EarnPlayCore applies and removes shields from the
policy held by `PolicyStore` (T2.1). It is framework-free: no
FamilyControls or ManagedSettings type appears in the package, so host
tests run without any entitlement.

## How shielding works

- Enumeration-first: every app enumerated via FamilyActivityPicker at
  setup (T2.3 supplies `ShieldEnumeration`) except the policy allowlist
  (`Policy.alwaysAllowed`) is shielded individually.
- Category backstop: every category seen at setup is shielded as a
  backstop, so a newly installed app that has not been enumerated yet
  is shielded through its category until it is enumerated.
- No per-app exemption: `ShieldConfiguration` has no `except` /
  exemption field. An app stays unshielded only because it is absent
  from the individual shield set and its category is withheld from the
  backstop. Categories containing an always-allowed or currently
  unlocked app are withheld entirely. This accepts a coarse trade-off
  — withholding a category also lifts its backstop for that category,
  and opening an unlock lifts the backstop for the unlocked apps'
  categories — instead of relying on a per-app exemption overriding a
  category shield, which must not be assumed to exist.
- Allowlist fallback: built-in defaults (Phone, Messages, EarnPlay
  itself) never need category coverage. When any other allowlisted app
  is enumerated with an unknown (`nil`) category or is absent from the
  enumeration, its actual category cannot be withheld, so the category
  backstop is disabled entirely to preserve allowlist access.
  Individual shields still apply.
- Unlock fallback: the same rule covers unlocks. When a real unlocked
  app has an unknown (`nil`) or missing enumeration category and no
  caller-supplied grant category covers it, the backstop is disabled
  while its window is open, so a grant never reports success while a
  category shield stays active over the app. A single-app grant with
  an explicit category withholds only that category; built-ins never
  need coverage.

## Default-deny for new apps (T2.5)

- Two enforcement layers. An install observed via `noteInstalledApp`
  (the host-side simulated install transition, driven after shields
  apply) is shielded individually in the applied configuration, so the
  backend itself — the launch gate in the simulated scope — reports
  blocked until a policy sync classifies the app. An app never observed
  stays open only when allowlisted or unlocked, so an unknown token or
  category resolves to locked rather than to allowed.
- Observations are install facts, not picker state: replacing the
  enumeration never clears them, so an installed-but-unpicked app stays
  shielded (including with an empty enumeration). An allowlisted install
  withholds its category like a picked app, and an unlocked install
  stays open; category knowledge is sticky and never regresses.
- T2.2 semantics for classified apps are unchanged, and there is still
  no per-app exemption over a category shield. Demo scope is the
  simulated backend; no real device shields.

## Unlock timers

- Unlocks run on an injected suspend-inclusive monotonic clock
  (`MonotonicClock`; production `SystemUptimeClock` uses
  `mach_continuous_time`). Wall-clock time is recorded at grant for
  display only and never read for expiry, so changing the device clock
  cannot extend an unlock, and sleeping past the real-time deadline
  expires it.
- Each window is bound to its grant-time boot session
  (`BootSessionProvider`; production uses `kern.bootsessionuuid`, or
  reports unverifiable when it is unavailable — there is no
  wall-clock-derived `kern.boottime` fallback, since a clock adjustment
  would shift it and wrongly revoke unexpired unlocks). A reloaded
  window fails closed to shielded when its identifier is missing
  (pre-change format), differs from the current boot, or cannot be
  verified — even when the new boot's uptime falls inside the old
  grant-expiry interval. An uptime regression likewise re-locks
  fail-closed.
- On expiry, shields are re-applied automatically by expiry
  monitoring (`startExpiryMonitoring`), or on the next `refresh()` /
  accessor call.
- The open window is persisted (`FileUnlockWindowStore`, JSON next to
  the policy cache) and re-evaluated when a `ShieldManager` is created
  after a restart: an unexpired window on the same boot resumes with
  its remaining monotonic time, an expired or unverifiable window
  re-locks immediately, and a corrupt record fails closed to shielded.
- Grants persist first and commit in-memory/backend state only after
  the write succeeds; a failed save returns `false` and leaves the
  previous window untouched. Revocation removes the persisted window
  first and throws when deletion fails (a missing file counts as
  success), preserving the in-memory window so revocation is never
  reported complete before durable removal.
- Active windows reconcile against the current policy and enumeration
  before shields apply: apps that stop being challenge-unlockable are
  removed with their category suppression, and category associations
  follow the latest enumeration mapping (explicit grant categories are
  preserved). When re-enumeration loses an unlocked app's category,
  its suppression is dropped and the backstop is disabled instead, so
  the app stays open until expiry rather than re-locking mid-window.
  Narrowed windows are stamped with the current policy version and
  re-persisted, with failed writes retried on later refreshes; a
  reloaded window whose version is missing or has drifted fails closed,
  so a stale record can never resurrect a removed app after the policy
  changes again.

## Backend abstraction and verification status

All application goes through the `ShieldBackend` protocol. T2.4 will
provide the simulated-shield backend behind this same protocol, and
v1 will provide the real ManagedSettings backend; `ShieldManager`
callers do not change when the backend is substituted.

Demo verification for this task runs against a simulated backend (a
test double in `ShieldManagerTests` implementing the `ShieldBackend`
interface, with a fake monotonic clock): the 60-second unlock flow,
expiry and automatic re-lock, the +2-hour wall-clock jump, allowlist /
backstop assertions, and restart re-evaluation all pass there. Real
shield enforcement is v1 — the development entitlement is a v1 input,
not a Demo gate — and is **not** verified by this task. The on-device
prototype for enumeration is confirmation-only; absence from public
docs is not proof, and only that prototype settles enumeration on
device for certain.
