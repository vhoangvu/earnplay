# T3.3 — Trade offer logic

Owner module in EarnPlayCore: `TradeOfferDecider` (offer choice),
`TradeOfferContext` (inputs), `TradeOfferDecision` (choice + engine
evidence). Consumes T3.1 (`MovementTradeManager.decide`) and T3.2
(`ChoreTradeSession.selectNextOffer`) as-is; consumes T1.4
(`EffortSignals`, floor rule) and T1.5 (`StallClassification`) as the
motivation/patience signals; writes every decision — including no-offer —
to the T1.6 decision log. Deterministic code only; the tutor model
proposes the moment, this code disposes. No user-visible surface is
added, so no scores, timers, countdowns, or pass/fail language appear.

## Gate order

`TradeOfferDecider.decide(context:policy:using:)` runs these gates; the
first failure is the no-offer reason:

1. Floor (absolute): `EffortScorer.floorMet` on the session signals,
   read with the policy's `EffortFloorSettings`. Below the floor no
   alternative currency is ever offered and the engines are not
   consulted. No variation draw runs.
2. Patience: the stalling classification must be `.stalling` (patience
   exhausted while the child still wants the unlock; presence in a
   practice session is the intent proxy — no T1.4/T1.5 signal names
   intent separately). `.trying` means a motivated session that must
   never be interrupted; `.uncertain` defaults to a probe (LLD §4),
   never a trade.
3. Session cap: combined movement + chore offers this session below
   `tradeCaps.maxTradesPerSession` (across both trade types — neither
   engine sees the other, so this module enforces the shared cap and
   passes the combined count into the movement gate).
4. Engine eligibility: the movement verdict
   (`MovementTradeManager.decide` with `.aiLowMotivation` — the
   stalling gate above IS the AI low-motivation judgment, so the
   movement caps, taper rule, and activity checks all still bind) and
   the chore pick (`selectNextOffer` over the pool pre-filtered for the
   policy-level `weeklyMaxChoreTrades` cap and the per-entry
   `ChorePoolEntry.weeklyCap`, which T3.2 does not enforce itself).
5. Variation: uniform draw over the available choices, no offer
   included — both eligible: movement / chore / none (1/3 each); one
   eligible: that offer / none (1/2 each); neither eligible:
   deterministic `.noEligibleOffer`. Same mechanism as the T1.4
   threshold draw: production uses the system RNG, tests inject a
   seeded generator (`EffortSeededRNG`).

The caller supplies the resolved chore pool
(`ChoreTradePoolSource.resolve(policy).pool`, so a parent-authored
empty pool stays empty and demo mode resolves the seed), in-session
declines, chore rotation history, and weekly usage the engines do not
track (`weeklyMovementUsage` from
`MovementTradeHistory.weeklyUsageInTrailingWeek`, `weeklyChoreUsage`
and per-chore usage tracked by the host). The future TutorEngine calls
`decideAndLog` at a stalling moment and presents the returned offer —
or nothing — only when it returns.

## Decision log mapping

`decideAndLog` decides and appends atomically: if logging throws, the
caller presents nothing. Offers log as `.offerTrade`; every no-offer
logs as `.sessionJudgment` (the LLD §7 patience/offer-condition
judgment). Justification is pure (`justification(for:context:policy:)`)
and names the signals, floor state, classification, caps, both engine
verdicts, and the variation note. Confidence: rule-determined gates
0.9, the stalling classification 0.8, randomized outcomes 0.7. The
logged sequence is what "no predictable pattern" is checked against.

## Automated tests

`TradeOfferLogicTests` (package gate):

- Below-floor fixtures (idle; guessing with no hint use) return
  `.floorNotMet` on 100/100 seeded runs, with engines unconsulted.
- Above-floor stalling fixtures over 100 seeded runs return a mix:
  movement and chore both appear, no-offer appears, and neither
  currency exceeds 80/100.
- `.trying` / `.uncertain` never interrupt; the session cap blocks both
  currencies; single-eligible moments vary between that offer and a
  deliberate none; taper/cap refusals leave the other currency
  available; `decideAndLog` records a complete 100-decision sequence
  with matching types, and a logging failure presents nothing.

## Manual verification (demo)

1. Start 5 separate sessions and stall in each; record the outcomes.
   Expected: a mix of movement, chore, and at least one no-offer; not
   the same offer every time.
2. In a fresh session, stall immediately before any genuine attempt —
   no trade is offered.
3. Keep practising with good effort — no trade interrupts a motivated
   session.
