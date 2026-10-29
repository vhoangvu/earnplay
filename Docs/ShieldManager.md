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

## Unlock timers

- Unlocks run on an injected monotonic clock (`MonotonicClock`;
  production `SystemUptimeClock` uses system uptime). Wall-clock time
  is recorded at grant for display only and never read for expiry, so
  changing the device clock cannot extend an unlock.
- On expiry, shields are re-applied automatically by expiry
  monitoring (`startExpiryMonitoring`), or on the next `refresh()` /
  accessor call.
- The open window is persisted (`FileUnlockWindowStore`, JSON next to
  the policy cache) and re-evaluated when a `ShieldManager` is created
  after a restart: an unexpired window resumes with its remaining
  monotonic time, an expired window re-locks immediately, a corrupt
  record fails closed to shielded, and an uptime regression (device
  reboot reset the uptime clock) re-locks fail-closed rather than
  extending the window.

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
