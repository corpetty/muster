## A threshold driver — k-of-n endorsement over an Ed25519 roster. The second real
## coordination driver, and the proof that the Driver contract is generic: it is
## nothing like Safe (no secp, no EIP-712, no chain), yet it runs the same
## multi-party fold end to end through the same seam.
##
## A contribution is an Ed25519 signature by a roster member over the intent's
## materialization; the collection completes when k distinct members have signed
## (invariant 6 — k and the round count come from describe(), never hardcoded in
## the core). The materialization is the base dCBOR serialization (this driver does
## not override canonicalize), so it also exercises the default materialization
## path. Reuses curve25519 (Ed25519), already built for the chat identity.

import ../crypto/curve25519
import ../intents/materialization
import ./driver

type
  ThresholdDriver* = ref object of Driver
    roster*: seq[Ed25519Pub]        ## the n eligible endorsers
    k*: int                         ## how many distinct endorsements complete it
    pending: Materialization        ## what contributions currently verify against

proc newThresholdDriver*(roster: seq[Ed25519Pub], k: int): ThresholdDriver =
  ThresholdDriver(roster: roster, k: k)

method describe*(d: ThresholdDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "muster.threshold.v1",
                   membership: mmNamed, finality: finImmediate, threshold: d.k)

# canonicalize is NOT overridden — the base dCBOR serialization is the
# materialization, so this driver exercises the default materialization path.

proc sigOf(c: Contribution): (bool, Ed25519Sig) =
  if c.bytes.len != 64: return (false, default(Ed25519Sig))
  for i in 0 ..< 64: result[1][i] = c.bytes[i]
  result[0] = true

method verifyContribution*(d: ThresholdDriver, c: Contribution, round: int): bool =
  ## Valid iff the contribution is a roster member's Ed25519 signature over the
  ## pending materialization. The core never reads these bytes; only this does.
  let (ok, sig) = sigOf(c)
  if not ok: return false
  for pk in d.roster:
    if edVerify(pk, d.pending.bytes, sig): return true
  false

method expectMaterialization*(d: ThresholdDriver, m: Materialization) =
  d.pending = m

method identifyContributor*(d: ThresholdDriver, m: Materialization, c: Contribution): string =
  ## The roster member (their Ed25519 key, hex) whose signature this is, or "" if
  ## no roster key verifies it — so the fold keys/dedups by endorser and rejects
  ## non-members.
  let (ok, sig) = sigOf(c)
  if not ok: return ""
  for pk in d.roster:
    if edVerify(pk, m.bytes, sig):
      const hexd = "0123456789abcdef"
      result = "ed:"
      for b in pk: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])
      return
  ""
