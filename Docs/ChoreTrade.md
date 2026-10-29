# Chore trade (T3.2)

`ChoreTradeSession` in EarnPlayCore is the deterministic single-offer
state machine. The child app renders it in `ChoreTradeView`: exactly one
chore per offer — offer card, accept/decline, Done button, then
in-person parent confirm granting the unlock. The child never sees a
chore menu or list.

## Flow (strict order)

`offer` → `accept` → `done` → `parent confirm` → `grant`.

- `makeOffer` surfaces one `currentOffer`, or nil when nothing is
  eligible, an offer is already active, or the session already
  completed a trade (one trade per session).
- `acceptOffer` / `declineOffer` apply only to an offered chore.
  Decline returns to idle and excludes that chore for the rest of the
  session; after accept there is no decline path in the demo.
- `markDone` applies only to an accepted chore and grants nothing.
  This is the explicit check: no unlock exists between Done and parent
  confirmation — no record, no minutes, no `ShieldManager` unlock.
- `parentConfirm` applies only after Done and returns the
  `ChoreTradeRecord` carrying `grantedUnlockMinutes`. A second confirm
  returns nil: one grant per trade, never a double-grant.

Out-of-order calls fail closed (`false` / `nil`) without changing state.

## Offer choice

`selectNextOffer` filters first, then picks one:

1. Eligible = unexpired (`expiry <= now` counts as expired) and not
   declined this session. An expired chore is never offered.
2. Time-of-day fit: a chore whose parent-written text names the current
   daypart (morning < 12, afternoon 12–17, evening ≥ 17) wins. The pool
   schema carries no time-of-day field, so fit reads the text.
3. Rotation: never-offered first, then least-recently-offered over
   `priorHistory + offeredHistory` (cross-session + in-session).
4. Deterministic tiebreaks (stable daypart-varying hash, then chore
   text — never `String.hashValue`, which is per-run seeded).

Weekly caps (`TradeCaps`, per-entry `weeklyCap`) are not enforced here;
T3.3 owns them with the rest of the offer-choice logic.

## Unlock grant

The record's `grantedUnlockMinutes` drive
`ShieldManager.grantChoreTradeUnlock(minutes:)`, which opens every
challenge-unlockable app for the chore's stated minutes. The view model
calls the shield manager exactly once, on parent confirm — Done never
touches it. A failed grant (persistence failure, or a policy with no
unlockable apps) leaves the session awaiting confirmation and surfaces
failure text there, so the same Confirm tap retries. After a grant the
view model starts expiry monitoring and the granted screen refreshes
its status line periodically, showing the live countdown and then an
expired state once the window ends.

## Demo inputs

- Pool: the synced parent-authored policy's pool (version > default),
  even when EMPTY — a parent-cleared pool yields no offers, never the
  demo seed. `DemoChorePool` (three parent-confirm chores, far-future
  expiry) applies only before the first sync, when the cached policy is
  still the default (version 0). The view captions which source is
  shown. Demo mode also routes the grant through an isolated fixture
  policy store; a synced policy uses the real cache and an enumeration
  derived from its own app lists.
- Parent confirmation is in person on the same device (the demo "Parent:
  Confirm completion" button). No photo-proof pipeline is built here.
- The "Take a chore break" trigger is the demo stand-in for offer
  timing; T3.3 owns when to offer and movement-vs-chore choice.
- Effort state (T1.4) is session context: the host injects its live
  `EffortSessionRecorder` so trade taps count as interactions. The
  placeholder host passes nil; the chat view (T1.8) will wire the real
  recorder. T3.3 owns effort-gated offer choice.
- Shields in the demo go through the in-app `DemoShieldBackend`
  (records configuration, enforces nothing — the demo has no
  FamilyControls entitlement). T2.4/v1 substitutes behind the same
  `ShieldBackend` protocol.

## Out of scope (not built here)

T3.3 offer-choice logic, the movement trade (T3.1), sync (T4.6), the
admin app, any chore menu or list, any unlock before parent
confirmation, entitlements, and signing (bundle IDs stay
`com.vhoangvu.earnplay*`).

## Verification status

Automated: `ChoreTradeTests` (package suite) asserts the ordered flow,
the Done-grants-nothing check at both the record and `ShieldManager`
layers, decline exclusion, the expiry filter, rotation/fit selection,
and the stated-minutes grant; `ChoreTradeAppTests` (simulator gate)
mirrors the flow, decline exclusion, and expiry drain against a
simulated backend. Real shield enforcement is v1 and is not verified.

Manual (manual-only, unverified unless actually run): 1) trigger an
offer mid-session — exactly one chore with its unlock minutes, no
list/menu; 2) decline — practice resumes, the chore does not reappear
this session; 3) new session, accept, do it, tap Done — no unlock yet;
4) parent confirms — unlock granted for the stated minutes.
