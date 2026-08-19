## Input provenance / accountability lineage (spec:
## contracts/specs/derived-exo-3a1.spec.json, invariant 10, catastrophic).
##
## Every signature carries, and structurally commits to, an account of where each
## input that reached the signed bytes came from — by class (plugin block,
## driver-interpreted contribution, external read, peer message) and log position.
## Signing is refused when any input's origin cannot be accounted for. Whether the
## record also names the contributing account follows the driver's declared
## membership model: silent under anonymous, named otherwise. The record is a
## reduction over the log (rebuildable from log + keys, no side-car) and is scoped
## to the membership epoch of the entries it describes, so a keyless or later-
## joining actor cannot reconstruct earlier lineage.

import ../dcbor/dcbor
import ../hashing/hash_input
import ../drivers/driver     # MembershipModel
import ../crypto/epochs      # epoch scoping (Group, canDerive)
export driver

type
  InputClass* = enum
    icPluginBlock = "plugin-block"
    icContribution = "driver-contribution"
    icExternalRead = "external-read"
    icPeerMessage = "peer-message"

  SignedInput* = object
    class*: InputClass
    logPos*: int          ## log position the input reached the signed bytes from
    account*: string      ## contributing account (used only under a named model)
    accountable*: bool    ## can this input's origin be accounted for?
    epoch*: int           ## membership epoch the input belongs to
    valueBytes*: seq[byte] ## the input's actual value bytes

  ProvenanceEntry* = object
    class*: InputClass
    logPos*: int
    account*: string      ## "" under anonymous membership

  ProvenanceRecord* = object
    entries*: seq[ProvenanceEntry]

proc buildProvenance*(inputs: seq[SignedInput], membership: MembershipModel): ProvenanceRecord =
  ## One entry per contributing input; the account is recorded only under a named
  ## membership model, absent (not merely unshown) under an anonymous one.
  for inp in inputs:
    result.entries.add ProvenanceEntry(
      class: inp.class, logPos: inp.logPos,
      account: (if membership == mmNamed: inp.account else: ""))

proc encodeProvenance*(rec: ProvenanceRecord): seq[byte] =
  var arr: seq[CborValue]
  for e in rec.entries:
    arr.add cbArray(@[cbText($e.class), cbUint(uint64(e.logPos)), cbText(e.account)])
  encodeHashInput(hashInput("muster.provenance.v1", @[("entries", cbArray(arr))]))

proc signedBytes*(materialization: seq[byte], rec: ProvenanceRecord): seq[byte] =
  ## The provenance record is committed to INSIDE the signed bytes — not attached
  ## alongside — so changing any input's provenance changes what gets signed.
  encodeHashInput(hashInput("muster.signed-with-provenance.v1", @[
    ("materialization", cbBytes(materialization)),
    ("provenance", cbBytes(encodeProvenance(rec)))]))

type SignDecision* = enum sdRefused, sdSigned

proc trySign*(materialization: seq[byte], inputs: seq[SignedInput],
              membership: MembershipModel): SignDecision =
  ## Refuse to sign when ANY input's origin cannot be accounted for; complete when
  ## every input can be.
  for inp in inputs:
    if not inp.accountable: return sdRefused
  discard signedBytes(materialization, buildProvenance(inputs, membership))
  sdSigned

proc coverageTwoWay*(inputs: seq[SignedInput], rec: ProvenanceRecord): bool =
  ## Every input has an entry naming its actual class + log position, and every
  ## entry corresponds to an input that actually contributed. Both directions.
  if rec.entries.len != inputs.len: return false
  for inp in inputs:
    var found = false
    for e in rec.entries:
      if e.class == inp.class and e.logPos == inp.logPos: found = true
    if not found: return false
  for e in rec.entries:
    var found = false
    for inp in inputs:
      if e.class == inp.class and e.logPos == inp.logPos: found = true
    if not found: return false
  true

proc canReconstruct*(g: Group, actor: MemberId, epoch: int): bool =
  ## Reconstructing the provenance of an epoch-E input requires epoch E's key —
  ## the same derivation boundary the epoch scheme enforces (invariant 7).
  g.canDerive(actor, epoch)
