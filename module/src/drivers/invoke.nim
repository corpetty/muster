## The generic "invoke" driver (P-D1/P-D2 · design: docs/design/driver-derivation.md).
##
## Coordinates the intent to CALL a Logos module method — "we, the room, agree to
## invoke module.method(args)" — as a k-of-n Ed25519 endorsement over the room
## roster. Any module action becomes coordinatable with no per-module code.
##
## The driver is GENERIC: it carries no module/method. The action lives entirely in
## the EFFECT — its `schemaId` is `invokeDomain(module, method)` and its fields carry
## the module/method/args — so the base dCBOR materialization (which commits to
## schemaId) already binds the signed bytes to the specific action (invariant 5:
## different method → different schemaId → different bytes). This is what lets the
## coordination fold resolve the driver by KIND alone (DriverFor = proc(kind)) and
## still re-derive the exact materialization: the effect is the sole source of the
## action, and every member folds the identical driver.
##
## Nothing here signs, holds keys, or touches the network — it describes + verifies.
## The CORE invokes the method after the threshold is met (P-D2's execution path),
## exactly as coordinate_submit does for the Safe driver (invariant 3).

import std/strutils
import ../crypto/curve25519
import ../intents/materialization
import ./driver
import ./manifest

type
  InvokeDriver* = ref object of Driver
    roster*: seq[Ed25519Pub]     ## the room members eligible to endorse (the authority)
    k*: int                      ## distinct endorsements that complete it
    pending: Materialization     ## what contributions currently verify against

proc invokeDomain*(targetModule, targetMethod: string): string =
  ## The per-(module, method) schema id an invoke effect carries. Two methods (or
  ## modules) never share signable bytes for the same args — invariant 5's domain
  ## separation, carried by the effect's schemaId rather than the driver.
  "muster.invoke." & targetModule & "." & targetMethod & ".v1"

proc newInvokeDriver*(roster: seq[Ed25519Pub], k: int): InvokeDriver =
  InvokeDriver(roster: roster, k: k)

method describe*(d: InvokeDriver): DriverDescriptor =
  ## A single round, k-of-n over a named roster. The coordination-level domain is the
  ## generic "muster.invoke.v1"; the per-action separation is in the effect's schemaId
  ## (see invokeDomain), which the base canonicalize folds into the signed bytes.
  DriverDescriptor(rounds: 1, serializationDomain: "muster.invoke.v1",
                   finality: finImmediate, threshold: d.k)

# canonicalize is NOT overridden — the base dCBOR serialization of the effect (which
# encodes the effect's schemaId = invokeDomain(module, method)) is the materialization.

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

method manifest*(d: InvokeDriver, effect: Effect): ActionManifest =
  ## The action is in the EFFECT: the target module must be loaded on the instance
  ## that executes, a roster key is needed to endorse, and the module sees the args
  ## when the core invokes it after the threshold. Whether the module in turn puts
  ## anything on a public record is the module's own disclosure, declared per action
  ## by lidl-gen's driver mode (exo-002.6) — not guessed here.
  let module = effect.fieldText("module")
  let meth = effect.fieldText("method")
  result = ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqAuthority, "roster-member", rpContributor)],
    discloses: @[row("args", obTargetModule)])
  if module.len > 0:
    result.requirements.add req(rqModule, module)
    result.touches.add touch("module:" & module & "." & meth, tmWrite)
  # LEZ Mode B (and any coordinated transfer, docs/design/lez-adapter.md §6): when the
  # effect names a `counterparty` field — the effect field that holds the recipient's
  # address (a LEZ key-node, an EVM address) — declare a COUNTERPARTY address slot bound
  # to it. The room then asks the recipient to share it (coordinate_share_material, K5/K6)
  # rather than the proposer guessing it. Generic: the invoke driver stays module-blind;
  # WHICH arg is the recipient is named by the effect, not hardcoded here. What the rail
  # then puts on the public record is the target module's own disclosure (exo-002.6).
  let cpField = effect.fieldText("counterparty")
  if cpField.len > 0:
    result.requirements.add req(rqAddress, "payee", rpCounterparty,
                               need(mcAddress, effect.fieldText("chain"), cpField))
    result.discloses.add row(cpField, obTargetModule)
  # A LEZ action needs the PROPOSER to have a set-up, funded LEZ account (exo-44b L2).
  # It is an INSTANCE infra requirement, detected by readiness against the zone and
  # remedied in the LEZ Wallet App — muster never provisions. Keyed off the effect's
  # declared chain (generic: any lez:* chain), so the invoke driver stays module-blind.
  let chain = effect.fieldText("chain")
  if chain.len > 0 and chain.startsWith("lez"):
    result.requirements.add req(rqInfra, "lez-account", rpInstance)
