## An in-room approval signed by keystore_module (exo-149.2 K2). Pure over the room: it
## builds the request a human approves in an approver, and later publishes what came
## back. The lp_* calls and the pump live in the hosted module.
##
## The same gates as liveContribute (planApproval) run twice: once before the request,
## so a human is never asked to approve what muster would refuse; and again when the
## signatures come back, because the room may have moved while the human decided. If P
## (the attestation payload) is not exactly what the human approved, nothing is
## published (`inputs-changed`) and the member approves again.
##
## What the human sees (docs/design/keystore-module-backend.md §3–4): leg 1 is the SafeTx
## as an EIP-712 document the signer renders field by field; leg 2 is muster's
## attestation over P as a digest leg. That second leg is opaque to the human and is an
## interim the card flags until typed forms land (exo-149.6). The key's F-14 binding is
## not requested here: it is signed once, when the member selects the account (K5,
## exo-149.5). Until then, a keystore-backed approval carries no binding, like a pasted one.

import std/[json, strutils]
import ../drivers/driver
import ../drivers/safe
import ../intents/materialization
import ../wallet/keystore_legs
import ../wallet/keystore_requests
import ./session
import ./intents
import ./live
import ./attest

type KeystoreApproval* = object
  refusal*: string            ## "" when the request may be sent
  intent*: JsonNode           ## request_approval's {address, purpose, legs}
  legs*: seq[SignLeg]         ## muster's own hash per leg, checked against what comes back
  p*: seq[byte]               ## P as the human will approve it

const AttestationPurpose* =
  "Muster attestation (interim): binds this approval to its room, account, slot and " &
  "expiry, and to where each of its inputs came from. Muster's own commitment, shown " &
  "as a hash; the signer cannot read it."

proc safeApprover*(backend: string, attested: bool, selected, own: string, testChain: bool): string =
  ## Who approves THIS member's Safe intents: their selected keystore_module account, or the
  ## module's own key. "interim" always uses the account; "auto" (the default) where
  ## keystore_module attests muster and only on a test chain, since the attestation still
  ## reaches the signer as an opaque digest until its typed form lands (exo-149.6); "off"
  ## never. The composer says who you act as, and contribute routes the approval, by this
  ## one rule, so the warning and the signature never disagree.
  let on = backend == "interim" or (backend == "auto" and attested)
  if on and selected.len > 0 and (backend == "interim" or testChain): selected.toLowerAscii()
  else: own

proc planKeystoreApproval*(s: CoordinationSession, driverFor: DriverFor, intentId, account: string,
                           nowSec: uint64): KeystoreApproval =
  ## The request for `account` (a keystore_module account) to approve `intentId`, after
  ## every check liveContribute makes before signing. Safe intents only for now.
  let plan = planApproval(s, driverFor, intentId, inApp = true, nowSec)
  if plan.refusal.len > 0: return KeystoreApproval(refusal: plan.refusal)
  if not (plan.drv of SafeDriver): return KeystoreApproval(refusal: "keystore-unsupported-kind")
  let effect = effectFromJson(plan.effectJson)
  # never ask a human to approve what cannot count: an account the driver knows is not a signer
  if plan.drv.mayContribute(effect, @[account.toLowerAscii()]) == elNo:
    return KeystoreApproval(refusal: "not-a-signer")
  let d = SafeDriver(plan.drv)
  var matHash: array[32, byte]
  if plan.mat.bytes.len != 32: return KeystoreApproval(refusal: "no-materialization")
  for i in 0 ..< 32: matHash[i] = plan.mat.bytes[i]
  let attestDigest = attestationDigest(plan.p)
  var legs: seq[JsonNode]
  try:
    legs = @[safeTxLeg(toSafeTx(effect), d.chainId, d.safe),          # hashes to matHash, checked
             digestLeg(attestDigest, AttestationPurpose)]
  except KeystoreLegError as e:
    return KeystoreApproval(refusal: "leg: " & e.msg)
  let purpose = "Approve Muster proposal " & intentId[0 ..< min(12, intentId.len)] &
                " (a Safe transaction on chain " & $d.chainId & ")"
  try:
    result.intent = approvalIntent(account.toLowerAscii(), purpose, legs)
  except KeystoreLegError as e:
    return KeystoreApproval(refusal: "intent: " & e.msg)
  result.legs = @[SignLeg(kind: "contribution", hash: matHash),
                  SignLeg(kind: "attestation", hash: attestDigest)]
  result.p = plan.p

proc publishKeystoreApproval*(s: CoordinationSession, driverFor: DriverFor, intentId: string,
                              approved: KeystoreApproval, sigs: seq[string], nowSec: uint64,
                              bindingHex = ""): string =
  ## Publish the signatures a human approved (already checked to recover to the account
  ## over muster's own hashes, keystore_requests.onFetched). The gates run again; P must
  ## be exactly what was approved. `bindingHex` is the account's F-14 binding, signed once
  ## at selection (K5, keystore_identity): published beside the approval, it lets every
  ## member's view tell the approval is this member's. Returns the intent's state, or a
  ## refusal word.
  if sigs.len != 2: return "rejected"
  let plan = planApproval(s, driverFor, intentId, inApp = true, nowSec)
  if plan.refusal.len > 0: return plan.refusal
  if plan.p != approved.p: return "inputs-changed"
  let binding: proc(): string =
    if bindingHex.len > 0: (proc(): string = bindingHex) else: nil
  publishApproval(s, driverFor, plan, intentId, sigs[0], sigs[1], inApp = true, binding)
