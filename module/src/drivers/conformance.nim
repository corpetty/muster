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
##   6. the action manifest is stable, DECLARED, consistent with describe(), and its
##      agreement half IS describe() (exo-002.1) — a driver that does not say what it
##      needs, touches, and discloses, or contradicts its own policy, does not ship.
##   7. the family profile (exo-a50.1.1, checkProfileConformance) is stable, DECLARED,
##      and consistent with describe() — a driver that does not say what kind of
##      multisig it is (docs/design/multisig-landscape.md) does not ship. Graded as its
##      own report so each check names exactly what an undeclared driver lacks.

import ../intents/materialization
import ./driver
import ./manifest
import ./profile

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

  # Bind the verify context to `effect` through the generic seam (undoing any state
  # the driver set while canonicalizing `tampered`), so the sample contribution is
  # checked against `effect` — for Safe this is its pending hash, for a threshold
  # driver its pending materialization, for a stateless driver a no-op.
  d.expectMaterialization(canonicalize(d, effect))
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

  # ── 6. the action manifest (docs/design/action-manifest.md) ─────────────────
  let m = d.manifest(effect)
  result.add("manifest is stable", m == d.manifest(effect))
  result.add("manifest agreement is describe()", m.agreement == desc)
  let fails = consistencyFailures(m, effect)
  result.add("manifest is declared and consistent" &
             (if fails.len > 0: " (" & $fails & ")" else: ""), fails.len == 0)

proc checkProfileConformance*(d: Driver): ConformanceReport =
  ## 7. the family profile: which multisig family this driver is, filled for its
  ## instance. Stable, declared, and consistent with describe() (profileFailures —
  ## the registry's cross-field rules plus rounds / k / finality agreement).
  let p = d.profile()
  result.add("profile is stable", p == d.profile())
  let fails = profileFailures(p, d.describe())
  result.add("profile is declared and consistent" &
             (if fails.len > 0: " (" & $fails & ")" else: ""), fails.len == 0)
