## The driver conformance suite — the standard every Driver must pass before it
## ships (the working agreement: "conformance before driver features; never merge
## with it red"). It is grounded in the invariants, not in any one chain, so it
## grades the stub, the Safe driver, and any new driver identically.
##
## A driver is now a complete unit behind one interface — describe (coordination
## policy, inv 6), canonicalize (effect → signable bytes, inv 1/5), and
## verifyContribution (inv 6) — and this checks that the four properties the core
## relies on actually hold for it:
##   1. describe() is stable — the declared policy does not flicker.
##   2. canonicalize is deterministic — same effect, same bytes (inv 5; the basis
##      of the re-derive-or-refuse check).
##   3. re-derive-or-refuse accepts a faithful materialization and REFUSES one
##      that does not match the reviewed effect (inv 1, catastrophic).
##   4. verifyContribution is a pure function of (contribution, round) (inv 6).
##   5. the collection converges at the declared threshold/rounds, driven only by
##      describe() — no hardcoded constant in the core.

import ../intents/materialization
import ./driver

type
  ConformanceReport* = object
    checks*: seq[(string, bool)]

proc allPass*(r: ConformanceReport): bool =
  for c in r.checks:
    if not c[1]: return false
  true

proc failed*(r: ConformanceReport): seq[string] =
  for c in r.checks:
    if not c[1]: result.add c[0]

proc add(r: var ConformanceReport, name: string, ok: bool) =
  r.checks.add (name, ok)

proc checkConformance*(d: Driver, effect, tampered: Effect,
                       validContribution: Contribution): ConformanceReport =
  ## `effect` and `tampered` must canonicalize to different bytes (a real change,
  ## e.g. a different amount). `validContribution` is one the driver accepts for
  ## `effect` — supplied by the caller because what is valid is driver-specific.
  result.add("describe is stable", d.describe() == d.describe())

  result.add("canonicalize is deterministic",
             canonicalize(d, effect).bytes == canonicalize(d, effect).bytes)

  let claimed = canonicalize(d, effect)
  result.add("faithful materialization verifies (inv 1)",
             reviewAndCheck(d, effect, claimed))
  result.add("tampered effect is refused (inv 1)",
             not reviewAndCheck(d, tampered, claimed))

  # Re-establish any per-effect state the driver set while canonicalizing `tampered`
  # (e.g. Safe's pendingHash), so the sample contribution is checked against `effect`.
  discard canonicalize(d, effect)
  result.add("verifyContribution is pure (inv 6)",
             d.verifyContribution(validContribution, 1) ==
               d.verifyContribution(validContribution, 1))

  let desc = d.describe()
  if d.verifyContribution(validContribution, 1):
    var col = startCollection(d)
    for _ in 0 ..< desc.threshold * max(1, desc.rounds):
      submit(col, d, validContribution)
    result.add("collection converges at the declared threshold (inv 6)", col.complete)
  else:
    result.add("collection convergence (sample not accepted — supply a valid one)", false)
