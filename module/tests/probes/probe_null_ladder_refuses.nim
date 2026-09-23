## The null ladder refuses a failed upgrade (exo-1ec.5, docs/design/null-ladder.md).
##
## The DONE-WHEN probe: a consumer that requires the real level on an axis the seam only
## fills with the null gets a REFUSAL, never a silent fall-back to the null. This is the
## TLS-downgrade lesson (FREAK/Logjam) put in the type: the null is a level you choose, not
## a level the code slips to when the real one is unavailable. Pure Nim — imports only the
## levels module, no host, no adapter closure.

import std/strutils
import ../../src/security/levels

# A seam that fills confidentiality with the null (a transparent chain), and one that fills
# it with the real thing (a shielded chain) — the SAME envelope shape, both axes present.
let nullConf = securityLevel(
  axisLevel(rungNull, "unauthenticated (no driver)"),
  axisLevel(rungNull, "unattested"),
  axisLevel(rungNull, "plaintext"))
let realConf = securityLevel(
  axisLevel(rungNull, "unauthenticated (no driver)"),
  axisLevel(rungReal, "signed hash-linked log"),
  axisLevel(rungReal, "ECIES epoch"))

# ── 1. a failed upgrade REFUSES — it never returns at the null ─────────────────────
block:
  var refused = false
  try:
    nullConf.require(axConfidentiality, rungReal)   # the consumer NEEDS confidentiality
  except DowngradeRefused as e:
    refused = true
    doAssert e.msg.contains("refuses"), "the refusal says so: " & e.msg
    doAssert e.msg.contains("plaintext"), "and names the mechanism it is stuck at"
  doAssert refused, "require(real) on a null seam RAISES — there is no orNull fallback"
  # and the real seam satisfies the same requirement without raising.
  realConf.require(axConfidentiality, rungReal)
  echo "1. a failed upgrade refuses rather than falls back to the null OK"

# ── 2. authentication refuses the same way: no driver bound is not "authenticated" ──
block:
  # require(null) always holds — the null is an explicit, displayed level.
  doAssert nullConf.atLeast(axAuthentication, rungNull)
  nullConf.require(axAuthentication, rungNull)
  # A consumer that needs a bound speaker, on a seam with no driver bound, is REFUSED —
  # never passed through as though someone had been authenticated.
  var refused = false
  try: nullConf.require(axAuthentication, rungReal)
  except DowngradeRefused: refused = true
  doAssert refused, "requiring real auth with no driver bound refuses"
  echo "2. authentication with no driver bound refuses a real requirement, never passes OK"

# ── 3. the level is READ, never inferred by branching on a concrete type ───────────
block:
  # A consumer decides by the axis rung — the SAME code path for either seam, differing only
  # in the level it reads. This is the "typed attribute on the seam, not a branch" property.
  proc canCarrySecret(seam: SecurityLevel): bool = seam.atLeast(axConfidentiality, rungReal)
  doAssert not canCarrySecret(nullConf), "the transparent seam cannot carry a secret"
  doAssert canCarrySecret(realConf), "the shielded seam can — read from the level, not the type"
  # the envelope is carried on BOTH — every axis present, same shape, no absent state.
  for ax in SecurityAxis:
    doAssert nullConf.mechanismOf(ax).len > 0 and realConf.mechanismOf(ax).len > 0,
      "the null carries the same metadata envelope as the real thing (axis " & $ax & ")"
  echo "3. the level is read as a typed attribute, the null carries the full envelope OK"

# ── 4. the rungs are ORDERED, so a richer level slots in without touching call sites ─
block:
  doAssert rungReal > rungNull, "the ladder is ordered"
  # atLeast uses >=, so a consumer asking for `null` accepts anything, and asking for `real`
  # accepts only real-or-higher — a future middle rung would satisfy `>= rungNull` unchanged.
  doAssert realConf.atLeast(axConfidentiality, rungNull), "real satisfies a null requirement"
  doAssert not nullConf.atLeast(axConfidentiality, rungReal), "null does not satisfy a real one"
  echo "4. the rungs are ordered; consumers compare with >=, never a specific rung OK"

echo "probe_null_ladder_refuses: all OK"
