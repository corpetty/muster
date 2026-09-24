## Live attestations — invariant 10 (and 2) on the path a real approval takes
## (spec: contracts/specs/derived-exo-ef1.spec.json, catastrophic).
##
## A driver's own signature commits to its materialization and nothing else (a Safe
## owner signs the bare safeTxHash; the chain would reject anything more). So every
## approval muster makes in-app ALSO carries a muster attestation from the SAME key
## over P:
##
##   P = signedBytes(encodePayload(context, materialization), provenance record)
##
## — the replay-bound context (invariant 2), the exact bytes the driver signs, and
## the provenance of every input that reached them (invariant 10). Everything here
## is a pure function of the log (invariant 4): the context, the inputs, and P are
## re-derived by every member from the events, never trusted from the attestation.
##
## Events (key/value on the coordination log):
##   context : "intent/<id>/context"                       value = {environment, account, expiry}
##   read    : "intent/<id>/read/<field>"                  value = {source, value}
##   attest  : "intent/<id>/attest/<contributor>/<round>"  value = attestation signature hex
##
## Grading: an approval is COMMITTED when an attestation for it verifies against the P
## this code re-derives; UNATTESTED when it was pasted (no attestation at all — the
## signer acted outside muster, so nothing muster can show was committed); and
## REJECTED when attestations exist but none verifies (forged, mismatched, from another
## intent or room) — a rejected approval does not count.

import std/[json, strutils, sets, algorithm]
import ../log/log
import ../dcbor/dcbor
import ../hashing/keccak256
import ../crypto/secp256k1
import ../crypto/curve25519
import ../drivers/driver
import ../intents/materialization
import ../intents/signing_payload
import ../intents/provenance
import ./intent_events
export provenance.SignedInput, signing_payload.SigningContext

type
  AttestGrade* = enum
    agCommitted = "committed"     ## a verifying attestation over the re-derived P
    agUnattested = "unattested"   ## pasted: signed outside muster, no attestation
    agRejected = "rejected"       ## attestation(s) present, none verifies — not counted

  ApprovalGrade* = object
    who*: string
    round*: int
    grade*: AttestGrade

const PlaceholderContext* = SigningContext(environment: "", account: "coordinated",
                                           slot: "0", expiry: high(uint64))
  ## What every intent was folded under before exo-ef1. Never a valid attestation
  ## context: an intent without a declared context cannot be attested.

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: return @[]

proc bytesOf(s: string): seq[byte] = (for c in s: result.add byte(c))

# ── events ────────────────────────────────────────────────────────────────────

proc contextEvent*(intentId: string, ctx: SigningContext,
                   parents: seq[EventId] = @[]): Event =
  ## Declared by the proposer alongside the propose. The slot is always the intent
  ## id (not carried: it is derived), so only environment/account/expiry travel.
  Event(parents: parents, key: "intent/" & intentId & "/context",
        value: $(%*{"environment": ctx.environment, "account": ctx.account,
                    "expiry": $ctx.expiry}))

proc readEvent*(intentId, field, source, value: string,
                parents: seq[EventId] = @[]): Event =
  ## Records an external read that reached the effect (e.g. the Safe's live nonce
  ## from the proposer's RPC), so it has a log position its provenance can cite.
  Event(parents: parents, key: "intent/" & intentId & "/read/" & field,
        value: $(%*{"source": source, "value": value}))

proc attestEvent*(intentId, who: string, round: int, sigHex: string,
                  parents: seq[EventId] = @[]): Event =
  Event(parents: parents,
        key: "intent/" & intentId & "/attest/" & who & "/" & $round, value: sigHex)

# ── the context (invariant 2) ─────────────────────────────────────────────────

proc intentContext*(events: seq[Event], intentId: string): SigningContext =
  ## The context this intent's attestations bind to, from its declared context event.
  ## If more than one was published (two proposers of the same effect+policy), the
  ## first in canonical order wins — deterministic on every member. No declaration →
  ## the placeholder, which nothing attests under.
  for e in canonicalOrder(events):
    if e.key != "intent/" & intentId & "/context": continue
    try:
      let j = parseJson(e.value)
      return SigningContext(environment: j{"environment"}.getStr(),
                            account: j{"account"}.getStr(), slot: intentId,
                            expiry: parseBiggestUInt(j{"expiry"}.getStr()).uint64)
    except CatchableError: return PlaceholderContext
  PlaceholderContext

proc isPlaceholder*(ctx: SigningContext): bool =
  ctx.environment.len == 0 or ctx.account.len == 0 or ctx.account == "coordinated" or
    ctx.slot.len == 0 or ctx.slot == "0" or ctx.expiry == high(uint64)

# ── the inputs (invariant 10) ─────────────────────────────────────────────────

proc effectFieldText(j: JsonNode, field: string): string =
  if j.kind != JObject or not j.hasKey(field): return ""
  let v = j[field]
  case v.kind
  of JString: v.getStr()
  of JInt: $v.getInt()
  else: $v

proc intentInputs*(events: seq[Event], driverFor: DriverFor,
                   intentId: string): seq[SignedInput] =
  ## Every input that reached this intent's signed bytes, reduced from the log, each
  ## citing its source event's content id. The proposal, the policy declaration and
  ## the context declaration are peer messages; a bound material share is a peer
  ## message; a recorded external read is an external read. A field the proposal
  ## declares as sourced (`"sources": {field: "read"|"material"}`) whose source record
  ## is absent from the log yields an UNACCOUNTABLE input — and nothing is signed.
  let ordered = canonicalOrder(events)
  var effect = newJObject()
  for i, e in ordered:
    if e.key == "intent/" & intentId & "/propose":
      try: effect = parseJson(e.value)
      except CatchableError: discard
      result.add SignedInput(class: icPeerMessage, logPos: i, logRef: eventId(e),
                             accountable: true, valueBytes: bytesOf(e.value))
      break
  if result.len == 0: return   # not proposed here: no inputs, nothing to sign
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len < 3 or p[0] != "intent" or p[1] != intentId: continue
    case p[2]
    of "policy", "context":
      result.add SignedInput(class: icPeerMessage, logPos: i, logRef: eventId(e),
                             accountable: true, valueBytes: bytesOf(e.value))
    else: discard
  # Declared sources: each must resolve to a record in the log.
  let sources = (if effect.kind == JObject and effect.hasKey("sources") and
                    effect["sources"].kind == JObject: effect["sources"] else: newJObject())
  var fields: seq[string]
  for k in sources.keys: fields.add k
  fields.sort()
  for field in fields:
    let want = effectFieldText(effect, field)
    var found = false
    for i, e in ordered:
      let p = e.key.split('/')
      if p.len < 4 or p[0] != "intent" or p[1] != intentId: continue
      if sources[field].getStr() == "read" and p[2] == "read" and p[3] == field:
        var v = ""
        try: v = parseJson(e.value){"value"}.getStr()
        except CatchableError: discard
        if v == want:
          result.add SignedInput(class: icExternalRead, logPos: i, logRef: eventId(e),
                                 accountable: true, valueBytes: bytesOf(e.value))
          found = true
          break
      elif sources[field].getStr() == "material" and p[2] == "material" and p.len >= 5:
        var f, pub = ""
        try:
          let j = parseJson(e.value)
          f = j{"field"}.getStr(); pub = j{"public"}.getStr()
        except CatchableError: discard
        if f == field and pub == want:
          result.add SignedInput(class: icPeerMessage, logPos: i, logRef: eventId(e),
                                 account: p[4],
                                 accountable: true, valueBytes: bytesOf(e.value))
          found = true
          break
    if not found:
      result.add SignedInput(class: (if sources[field].getStr() == "read": icExternalRead
                                     else: icPeerMessage),
                             logPos: -1, logRef: "", accountable: false)

proc allAccountable*(inputs: seq[SignedInput]): bool =
  for i in inputs:
    if not i.accountable: return false
  inputs.len > 0

# ── P, and verifying an attestation over it ───────────────────────────────────

proc attestationPayloadUnder*(events: seq[Event], driverFor: DriverFor,
                              intentId: string, ctx: SigningContext): seq[byte] =
  ## P for this intent under an explicit context — what a verifier recomputes, and
  ## what a probe uses to show a single changed context field changes P. Empty when
  ## the intent can't be attested (not proposed, placeholder context, or an
  ## unaccountable input).
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0 or ctx.isPlaceholder: return @[]
  let inputs = intentInputs(events, driverFor, intentId)
  if not inputs.allAccountable: return @[]
  let drv = driverFor(intentPolicyOf(events, intentId))
  let mat = canonicalize(drv, effectFromJson(effectJson))
  let payload = encodePayload(SigningPayload(context: ctx, materializationRoot: mat.bytes))
  signedBytes(payload, buildProvenance(inputs))

proc attestationPayload*(events: seq[Event], driverFor: DriverFor,
                         intentId: string): seq[byte] =
  ## P for this intent, re-derived from the log: the replay-bound signing payload
  ## (its declared context + the driver's materialization) with the provenance record
  ## committed INSIDE the signed bytes.
  attestationPayloadUnder(events, driverFor, intentId, intentContext(events, intentId))

proc attestationDigest*(p: seq[byte]): array[32, byte] =
  ## What a secp key signs: keccak256(P) — a 32-byte digest, as the keystore's
  ## `sign` takes. Ed25519 keys sign P itself.
  let d = keccak256(p)
  for i in 0 ..< 32: result[i] = d[i]

proc verifyAttestation*(who: string, p: seq[byte], sigHex: string): bool =
  ## Does `sigHex` attest P as `who`? The contributor id names the key type (the
  ## drivers' convention): "0x…" a secp address (sig over keccak256(P)), "ed:…" an
  ## Ed25519 key (sig over P). Anything else cannot be verified, so it never is.
  if p.len == 0: return false
  let sig = hexToBytes(sigHex)
  if who.startsWith("ed:"):
    let pk = hexToBytes(who[3 .. ^1])
    if pk.len != 32 or sig.len != 64: return false
    var edPk: Ed25519Pub
    var edSig: Ed25519Sig
    for i in 0 ..< 32: edPk[i] = pk[i]
    for i in 0 ..< 64: edSig[i] = sig[i]
    return edVerify(edPk, p, edSig)
  if who.startsWith("0x"):
    let a = hexToBytes(who)
    if a.len != 20 or sig.len != 65: return false
    var s65: Signature65
    for i in 0 ..< 65: s65[i] = sig[i]
    var owner: Address
    for i in 0 ..< 20: owner[i] = a[i]
    try: return ecrecover(attestationDigest(p), s65) == owner
    except CatchableError: return false
  if who.len == 66 and who[0 .. 1] in ["02", "03"]:
    # a contributor named by its compressed secp256k1 key (a Bitcoin multisig signer,
    # exo-a50.2.4): the attestation is a recoverable signature by that same key
    let pub = hexToBytes(who)
    if pub.len != 33 or sig.len != 65: return false
    var s65: Signature65
    for i in 0 ..< 65: s65[i] = sig[i]
    try: return ecrecover(attestationDigest(p), s65) == addressOfCompressed(pub)
    except CatchableError: return false
  if who.startsWith("lez:"):
    # a vote-locus contributor (exo-12a1): the vote's key lives in the member's chain
    # wallet, so what commits to P is the member's ROOM key — an Ed25519 signature over P,
    # carried with its public key (32 + 64 bytes)
    if sig.len != 96: return false
    var edPk: Ed25519Pub
    var edSig: Ed25519Sig
    for i in 0 ..< 32: edPk[i] = sig[i]
    for i in 0 ..< 64: edSig[i] = sig[32 + i]
    return edVerify(edPk, p, edSig)
  false

# ── grading every approval ────────────────────────────────────────────────────

proc approvalGrades*(events: seq[Event], driverFor: DriverFor,
                     intentId: string): seq[ApprovalGrade] =
  ## One grade per (contributor, round) approval on this intent, in canonical order.
  let p0 = attestationPayload(events, driverFor, intentId)
  var seen = initHashSet[string]()
  let ordered = canonicalOrder(events)
  for e in ordered:
    let p = e.key.split('/')
    if p.len < 4 or p[0] != "intent" or p[1] != intentId or p[2] != "sig": continue
    let round = (if p.len >= 5: (try: parseInt(p[4]) except CatchableError: 1) else: 1)
    let k = p[3] & "/" & $round
    if k in seen: continue
    seen.incl k
    var present = false
    var ok = false
    for a in ordered:
      if a.key != "intent/" & intentId & "/attest/" & p[3] & "/" & $round: continue
      present = true
      if verifyAttestation(p[3], p0, a.value): ok = true
    result.add ApprovalGrade(who: p[3], round: round,
      grade: (if ok: agCommitted elif present: agRejected else: agUnattested))

proc gradeOf*(grades: seq[ApprovalGrade], who: string, round: int): AttestGrade =
  for g in grades:
    if g.who == who and g.round == round: return g.grade
  agUnattested

proc expired*(ctx: SigningContext, nowSec: uint64): bool =
  ## Checked at sign time and at submit time — never inside the fold, which stays a
  ## pure function of the log (invariant 4).
  nowSec > ctx.expiry
