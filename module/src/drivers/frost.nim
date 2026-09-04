## A 2-round FROST-style driver — the first driver to declare `rounds > 1`, so the
## core's round-advancement path (`Collection.submit` advancing `col.round`, driven
## ONLY by `describe().rounds`) finally gets a real driver behind it. Until now the
## stub was the only thing that exercised multi-round; Safe and threshold are both
## single-round, so the "advance to the next round" branch shipped untested by any
## real driver. This closes that.
##
## **What FROST is, and what this models.** FROST (Flexible Round-Optimized Schnorr
## Threshold signatures) is defined by its TWO rounds:
##   round 1 — commitment: each signer publishes a nonce commitment.
##   round 2 — signing:    each signer publishes a signature share over the message
##                         and the aggregated commitments.
## This driver models that *coordination structure* faithfully — two passes over a
## named roster, k-of-n in each, with the round count driver-described (invariant 6)
## — reusing Ed25519 roster signatures (curve25519, already built for the chat
## identity) as the per-round authenticated contribution. The 2-round STRUCTURE
## (collect k → advance → collect k → complete) is enforced by the core from
## `describe()`, which is exactly the path this driver exists to exercise.
##
## **Scaffold boundary — stated plainly, not buried.** This is a coordination-layer
## scaffold, not production FROST:
##   1. It does NOT implement real Schnorr nonce-commitment aggregation (that needs
##      group scalar/point arithmetic the `curve25519` seam does not expose — only
##      `edSign`/`edVerify`). A contribution is a roster member's Ed25519 signature
##      over the pending materialization, and acceptance is *round-agnostic*: the
##      SAME contribution is valid in both the commit round and the sign round. (The
##      conformance suite's convergence check reuses one contribution across both
##      rounds, so round-agnostic acceptance is also what lets this pass conformance
##      — a real per-round-tagged FROST would need that check generalized.)
##   2. To run END TO END IN A ROOM it needs a round-aware contribution dedup:
##      `reduceIntents` today dedups one contribution per member per intent
##      (`<id>/<contributor>`), which stalls any per-round protocol at round 2 (every
##      member is spent after round 1). See the follow-up pebble. The core
##      `Collection` path (and therefore `checkConformance`) is unaffected and green.
##
## Production FROST would slot in behind this same interface by (1) carrying real
## commitment/share bytes and round-tagging them, and (2) landing the round-aware
## dedup. The seam does not change.

import ../crypto/curve25519
import ../intents/materialization
import ./driver

type
  FrostDriver* = ref object of Driver
    roster*: seq[Ed25519Pub]        ## the n eligible signers
    k*: int                         ## distinct signers needed to close EACH round
    pending: Materialization        ## what contributions currently verify against

proc newFrostDriver*(roster: seq[Ed25519Pub], k: int): FrostDriver =
  FrostDriver(roster: roster, k: k)

method describe*(d: FrostDriver): DriverDescriptor =
  ## Two rounds — the defining property of FROST — with k-of-n each, a named roster,
  ## and immediate finality once both rounds close. `rounds: 2` is the whole point:
  ## it makes the core exercise its round-advancement path from the descriptor alone.
  DriverDescriptor(rounds: 2, serializationDomain: "muster.frost.v1",
                   membership: mmNamed, finality: finImmediate, threshold: d.k)

# canonicalize is NOT overridden — the base dCBOR serialization is the
# materialization (like the threshold driver), so this also exercises the default
# materialization / re-derive-or-refuse path (invariants 1 and 5).

proc sigOf(c: Contribution): (bool, Ed25519Sig) =
  if c.bytes.len != 64: return (false, default(Ed25519Sig))
  for i in 0 ..< 64: result[1][i] = c.bytes[i]
  result[0] = true

method verifyContribution*(d: FrostDriver, c: Contribution, round: int): bool =
  ## A roster member's Ed25519 signature over the pending materialization. Acceptance
  ## is round-agnostic by design (see the scaffold note): the same signer participates
  ## in the commit round and the sign round, and the CORE enforces that BOTH rounds
  ## reach k before the intent becomes executable. The core never reads these bytes —
  ## only this method does (invariant 6).
  let (ok, sig) = sigOf(c)
  if not ok: return false
  for pk in d.roster:
    if edVerify(pk, d.pending.bytes, sig): return true
  false

method expectMaterialization*(d: FrostDriver, m: Materialization) =
  d.pending = m

method identifyContributor*(d: FrostDriver, m: Materialization, c: Contribution): string =
  ## The roster member (their Ed25519 key, hex) whose signature this is, or "" if no
  ## roster key verifies it — so the fold keys/dedups by signer and rejects non-members.
  let (ok, sig) = sigOf(c)
  if not ok: return ""
  for pk in d.roster:
    if edVerify(pk, m.bytes, sig):
      const hexd = "0123456789abcdef"
      result = "frost:"
      for b in pk: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])
      return
  ""
