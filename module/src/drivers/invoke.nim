## The generic "invoke" driver (P-D1 · design: docs/design/driver-derivation.md).
##
## Coordinates the intent to CALL a Logos module method — "we, the room, agree to
## invoke module.method(args)". Its coordination is a k-of-n Ed25519 endorsement
## over the room roster, identical in shape to the threshold driver (invariant 6:
## the core reads no bytes). What makes it distinct is exactly two things:
##
##   1. a per-(module, method) serialization domain, so the same args to *different*
##      methods sign to *different* bytes (invariant 5 — domain separation), and
##   2. the target + finality config the EXECUTION path (P-D2, not here) reads to
##      lp_invoke the method after the threshold is met and observe its completion.
##
## It deliberately does NOT override canonicalize: the base dCBOR materialization of
## the {module, method, args} effect under this domain IS the signable form (the
## same default path the threshold driver exercises). Nothing here signs, holds
## keys, or touches the network — the driver only describes and verifies; the CORE
## invokes (invariant 3), exactly as coordinate_submit does for the Safe driver.

import ../crypto/curve25519
import ../intents/materialization
import ./driver

type
  InvokeDriver* = ref object of Driver
    roster*: seq[Ed25519Pub]     ## the room members eligible to endorse (the authority)
    k*: int                      ## distinct endorsements that complete it
    targetModule*: string        ## the module the core will lp_invoke (read by P-D2)
    targetMethod*: string        ## the method to call
    finalityKind*: FinalityType  ## how completion is observed
    finalityEvent*: string       ## the completion event name (for finExternal)
    pending: Materialization     ## what contributions currently verify against

proc invokeDomain*(targetModule, targetMethod: string): string =
  ## The per-(module, method) serialization domain. Two methods (or two modules)
  ## never share signable bytes for the same args — invariant 5's domain separation
  ## applied to a call intent.
  "muster.invoke." & targetModule & "." & targetMethod & ".v1"

proc newInvokeDriver*(targetModule, targetMethod: string, roster: seq[Ed25519Pub],
                      k: int, finality = finImmediate, finalityEvent = ""): InvokeDriver =
  InvokeDriver(roster: roster, k: k, targetModule: targetModule,
               targetMethod: targetMethod, finalityKind: finality,
               finalityEvent: finalityEvent)

method describe*(d: InvokeDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1,
                   serializationDomain: invokeDomain(d.targetModule, d.targetMethod),
                   membership: mmNamed, finality: d.finalityKind, threshold: d.k)

# canonicalize is NOT overridden — the base dCBOR serialization of the effect under
# this driver's domain is the materialization (like the threshold driver).

proc sigOf(c: Contribution): (bool, Ed25519Sig) =
  if c.bytes.len != 64: return (false, default(Ed25519Sig))
  for i in 0 ..< 64: result[1][i] = c.bytes[i]
  result[0] = true

method verifyContribution*(d: InvokeDriver, c: Contribution, round: int): bool =
  ## Valid iff the contribution is a roster member's Ed25519 signature over the
  ## pending materialization. The core never reads these bytes; only this does.
  let (ok, sig) = sigOf(c)
  if not ok: return false
  for pk in d.roster:
    if edVerify(pk, d.pending.bytes, sig): return true
  false

method expectMaterialization*(d: InvokeDriver, m: Materialization) =
  d.pending = m

method identifyContributor*(d: InvokeDriver, m: Materialization, c: Contribution): string =
  ## The roster member (their Ed25519 key, hex) whose signature this is, or "" if no
  ## roster key verifies it — so the fold keys/dedups by endorser and rejects
  ## non-members without the core reading the bytes.
  let (ok, sig) = sigOf(c)
  if not ok: return ""
  for pk in d.roster:
    if edVerify(pk, m.bytes, sig):
      const hexd = "0123456789abcdef"
      result = "ed:"
      for b in pk: (result.add hexd[int(b shr 4)]; result.add hexd[int(b and 0x0F)])
      return
  ""
