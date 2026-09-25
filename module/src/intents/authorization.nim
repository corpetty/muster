## Muster-issued authorizations — the grant a host hook checks before it lets a
## gated module call through (docs/design/host-effect-policy.md; M7, exo-002.7;
## the "what am I allowing before it is allowed" want).
##
## An authorization exists ONLY for an intent the room has folded to executable:
## it names the capability (the Basecamp-side address of the action), commits to
## the exact materialization root the room agreed on, and is replay-bound the way
## every signing payload is (invariant 2): environment, account, slot (= the intent
## id), expiry. It is signed with this instance's secp256k1 authorization identity
## (the Safe/Keycard key), so the host can recover the issuer and check it against
## the issuers its policy trusts. Verification is pure and refuse-on-mismatch: a
## wrong root, an expired grant, or an untrusted issuer is a refusal with a reason.
## The plugin never dispatches anything itself (invariant 3); this only says what
## the room decided, in a form the host can check.

import std/[json, strutils]
import ../dcbor/dcbor
import ../hashing/hash_input
import ../crypto/secp256k1
import ../crypto/keystore
import ./signing_payload

type
  Authorization* = object
    intentId*: string
    capability*: string            ## e.g. "safe.execute", "lez_core.transfer_private", "room.attest"
    materializationRoot*: seq[byte]
    context*: SigningContext       ## environment · account · slot (= intentId) · expiry
    issuer*: Address
    signature*: Signature65

proc authorizationDigest*(a: Authorization): array[32, byte] =
  ## Domain-separated, deterministic (inv 5): every field is load-bearing.
  let d = digest(hashInput("muster.authorization.v1", @[
    ("intentId", cbText(a.intentId)),
    ("capability", cbText(a.capability)),
    ("materialization", cbBytes(a.materializationRoot)),
    ("environment", cbText(a.context.environment)),
    ("account", cbText(a.context.account)),
    ("slot", cbText(a.context.slot)),
    ("expiry", cbUint(a.context.expiry))]))
  for i in 0 ..< 32: result[i] = d[i]

proc issueAuthorization*(ks: Keystore, intentId, capability, environment, account: string,
                         materializationRoot: seq[byte], expiry: uint64): Authorization =
  ## Sign with THIS instance's authorization identity. The caller has already
  ## checked the intent is executable — issuing for anything else is a bug.
  result = Authorization(intentId: intentId, capability: capability,
                         materializationRoot: materializationRoot,
                         context: SigningContext(environment: environment, account: account,
                                                 slot: intentId, expiry: expiry),
                         issuer: ks.address())
  result.signature = ks.sign(authorizationDigest(result))

proc checkAuthorization*(a: Authorization, now: uint64,
                         expectedRoot: seq[byte] = @[],
                         allowedIssuers: openArray[Address] = []): tuple[ok: bool, reason: string, issuer: Address] =
  ## Pure, refuse-on-mismatch. `expectedRoot` empty = any root (the host supplies
  ## the root of the call it is about to dispatch); `allowedIssuers` empty = any
  ## issuer (the host supplies the issuers its policy trusts).
  if a.context.slot != a.intentId:
    return (false, "slot is not the intent id", default(Address))
  if now > a.context.expiry:
    return (false, "authorization expired", default(Address))
  if expectedRoot.len > 0 and a.materializationRoot != expectedRoot:
    return (false, "materialization root does not match the call being dispatched", default(Address))
  var recovered: Address
  try: recovered = ecrecover(authorizationDigest(a), a.signature)
  except Secp256k1Error:
    return (false, "signature is malformed", default(Address))
  if recovered != a.issuer:
    return (false, "signature does not recover to the claimed issuer", default(Address))
  if allowedIssuers.len > 0 and recovered notin allowedIssuers:
    return (false, "issuer is not trusted by the policy", recovered)
  (true, "", recovered)

proc capabilityOf*(policy, effectJson: string): string =
  ## The Basecamp-side name of what an intent does. Invoke intents name the
  ## module action they call (the driver-derivation namespace); a Safe intent is
  ## the Safe's execute; the room-native attestation drivers attest.
  case policy
  of "invoke":
    try:
      let j = parseJson(effectJson)
      return j{"module"}.getStr() & "." & j{"method"}.getStr()
    except CatchableError: return "invoke.unknown"
  of "safe": "safe.execute"
  of "eip191": "eip191.attest"
  of "threshold", "unanimous", "frost": "room.attest"
  else: "room." & policy

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)]

proc bytesOf(h: string): seq[byte] =
  var s = h
  if s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'): s = s[2 .. ^1]
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))

proc toJson*(a: Authorization): JsonNode =
  %*{"format": "muster.authorization.v1", "intentId": a.intentId, "capability": a.capability,
     "materializationRoot": "0x" & hexOf(a.materializationRoot),
     "environment": a.context.environment, "account": a.context.account,
     "slot": a.context.slot, "expiry": a.context.expiry,
     "issuer": "0x" & hexOf(a.issuer), "signature": "0x" & hexOf(a.signature),
     "digest": "0x" & hexOf(authorizationDigest(a))}

proc authorizationFromJson*(j: JsonNode): Authorization =
  if j.kind != JObject or j{"format"}.getStr() != "muster.authorization.v1":
    raise newException(ValueError, "not a muster.authorization.v1")
  result.intentId = j["intentId"].getStr()
  result.capability = j["capability"].getStr()
  result.materializationRoot = bytesOf(j["materializationRoot"].getStr())
  result.context = SigningContext(environment: j["environment"].getStr(),
                                  account: j["account"].getStr(), slot: j["slot"].getStr(),
                                  expiry: uint64(j["expiry"].getBiggestInt()))
  let iss = bytesOf(j["issuer"].getStr())
  if iss.len != 20: raise newException(ValueError, "issuer is not 20 bytes")
  for i in 0 ..< 20: result.issuer[i] = iss[i]
  let sig = bytesOf(j["signature"].getStr())
  if sig.len != 65: raise newException(ValueError, "signature is not 65 bytes")
  for i in 0 ..< 65: result.signature[i] = sig[i]
