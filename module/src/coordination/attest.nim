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
## intent or room) — a rejected approval does not count. Only attestations that belong to
## the intent's record count here (exo-093): one that links anything but copies of its own
## approval inside the record is no attestation of this intent.

import std/[json, strutils, sets, algorithm, sequtils, tables]
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
import ../crypto/keystore
import ../crypto/binding
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
    sig*: Event           ## the contribution that stands for (who, round): the first countable
                          ## one (never merely the first under the key, exo-c00) whose history
                          ## stays inside the intent's record (exo-093)
    copies*: seq[Event]   ## every countable copy under (who, round) inside the record, `sig` first
    attests*: seq[Event]  ## the attestations under (who, round) that belong to the intent (exo-093)

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
  ## Only the proposal's own propose and policy are inputs (proposalOf, exo-dbd): a
  ## substitute under the id never reached the signed bytes.
  let ordered = canonicalOrder(events)
  let proposal = proposalOf(events, intentId)
  var effect = newJObject()
  for i, e in ordered:
    if e.key == "intent/" & intentId & "/propose" and proposal.isProposalEvent(intentId, e):
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
      if p[2] == "policy" and not proposal.isProposalEvent(intentId, e): continue
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
  ## drivers' convention): "0x…" a secp address (sig over keccak256(P)), "ed:…" or
  ## "frost:…" an Ed25519 key (sig over P; the room FROST scaffold names its signers
  ## "frost:", exo-75c). Anything else cannot be verified, so it never is.
  if p.len == 0: return false
  let sig = hexToBytes(sigHex)
  if who.startsWith("ed:") or who.startsWith("frost:"):
    let pk = hexToBytes(who[who.find(':') + 1 .. ^1])
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

# ── the intent's record (exo-093) ─────────────────────────────────────────────
# Any epoch-key holder chooses an event's parents, so an event parented outside the intent
# (on a room message, on junk) is not part of what the intent's members did. The record is
# closed: the intent's lineage, and the copies of its approvals whose parents all lie in the
# record. The audit file, which must be parent-closed, can carry all of it; nothing outside it
# decides anything.

type
  Copy = tuple[e: Event, id: EventId, who: string, round: int]
  IntentRecord = object
    ok: bool
    drv: Driver
    m: Materialization
    desc: DriverDescriptor
    lineage: HashSet[EventId]
    copies: seq[Copy]                ## every countable contribution, in canonical order
    admitted: seq[Event]             ## the attestations that belong to the intent

proc lineageIds*(events: seq[Event], driverFor: DriverFor, intentId: string): HashSet[EventId] =
  ## Every input the intent's provenance names, and their ancestors.
  var byId = initTable[EventId, Event]()
  for e in events: byId[eventId(e)] = e
  var queue: seq[EventId]
  for i in intentInputs(events, driverFor, intentId): queue.add i.logRef
  while queue.len > 0:
    let id = queue.pop()
    if id in result or id notin byId: continue
    result.incl id
    for p in byId[id].parents: queue.add p

proc closedWithin(cands: seq[Copy], lineage: HashSet[EventId]): HashSet[EventId] =
  ## The candidates whose every parent is in the lineage or is another such candidate of
  ## the same round or an earlier one (exo-dc6). Honest copies satisfy that: a member
  ## contributes to the round being collected and links the approvals graded so far. It
  ## means the record of rounds up to r never depends on a later round, so everything the
  ## record holds for a reached round is something the audit file can carry.
  var roundOf = initTable[EventId, int]()
  for c in cands: roundOf[c.id] = c.round
  var grew = true
  while grew:
    grew = false
    for c in cands:
      if c.id in result: continue
      var inside = true
      for p in c.e.parents:
        if p in lineage: continue
        if p notin result or roundOf[p] > c.round: (inside = false; break)
      if inside: (result.incl c.id; grew = true)

proc intentRecord(events: seq[Event], driverFor: DriverFor, intentId: string): IntentRecord =
  let ej = effectJsonOf(events, intentId)
  if ej.len == 0: return                  # not proposed here: the fold has no intent to count toward
  result.drv = driverFor(intentPolicyOf(events, intentId))
  try:
    let effect = effectFromJson(ej)
    result.m = canonicalize(result.drv, effect)
    result.desc = describeFor(result.drv, effect)   # this proposal's policy, the one the fold's collection runs (exo-18d)
  except CatchableError: return           # nothing to verify against, so nothing verifies
  result.ok = true
  let ordered = canonicalOrder(events)
  result.lineage = lineageIds(ordered, driverFor, intentId)
  for e in ordered:
    let p = e.key.split('/')
    if p.len < 4 or p[0] != "intent" or p[1] != intentId or p[2] != "sig": continue
    let round = (if p.len >= 5: (try: parseInt(p[4]) except CatchableError: 1) else: 1)
    # The fold's rule for filling a slot (countable): attribution (exo-a5a) and the driver's
    # verify (exo-b96). signedByNamed passes whenever the driver cannot name a signer, which
    # is also what it says of a contribution that is not valid at all (a non-member's
    # signature, a malformed one, a vote for another pointer); the fold never counts those,
    # so neither may any view. Verified at the key's round, since a multi-round driver's
    # contribution carries its own (a FROST round-1 payload is not a round-2 partial).
    # Before dedup, as in the fold: junk that arrives first must not take the named
    # member's slot (exo-c00).
    if countable(result.drv, result.m, p[3], round, e.value):
      result.copies.add (e: e, id: eventId(e), who: p[3], round: round)
  # An attestation belongs to the intent only if it links nothing but copies of its own
  # approval inside the record (an honest one links exactly its own signature; one with no
  # parents links nothing). A forged one parented on a room message or on junk is no
  # attestation of this intent: it neither rejects the approval nor rides in its audit.
  var inRecord = initTable[EventId, string]()
  let closed = closedWithin(result.copies.filterIt(it.round in 1 .. result.desc.rounds), result.lineage)
  for c in result.copies:
    if c.id in closed: inRecord[c.id] = c.e.key
  for e in ordered:
    let p = e.key.split('/')
    if p.len < 5 or p[0] != "intent" or p[1] != intentId or p[2] != "attest": continue
    let own = "intent/" & intentId & "/sig/" & p[3] & "/" & p[4]
    if e.parents.allIt(inRecord.getOrDefault(it, "") == own): result.admitted.add e

proc admittedAttestations*(events: seq[Event], driverFor: DriverFor, intentId: string): seq[Event] =
  ## The attestations that belong to the intent, in canonical order (see intentRecord): what
  ## the fold's attestation gate, the FROST signer set and every grade read.
  intentRecord(events, driverFor, intentId).admitted

# ── grading every approval ────────────────────────────────────────────────────

proc approvalGrades*(events: seq[Event], driverFor: DriverFor,
                     intentId: string): seq[ApprovalGrade] =
  ## One grade per (contributor, round) approval on this intent, in canonical order.
  ## Only a contribution the fold would count gets one: every surface (the card, the
  ## activity feed, both provenance views, the audit file) reads these grades, so a
  ## contribution with no grade is on none of them.
  let rec = intentRecord(events, driverFor, intentId)
  if not rec.ok: return
  let p0 = attestationPayload(events, driverFor, intentId)
  let desc = rec.desc
  var seen = initHashSet[string]()
  for c in rec.copies:
    let k = c.who & "/" & $c.round
    if k in seen: continue
    seen.incl k
    var atts: seq[Event]
    var ok = false
    for a in rec.admitted:
      if a.key != "intent/" & intentId & "/attest/" & k: continue
      atts.add a
      if verifyAttestation(c.who, p0, a.value): ok = true
    result.add ApprovalGrade(who: c.who, round: c.round, sig: c.e, attests: atts,
      grade: (if ok: agCommitted elif atts.len > 0: agRejected else: agUnattested))
  # exo-e42: and the fold's round rule. The fold counts a contribution only toward its own
  # round, which it reaches once every earlier round has `threshold` approvals (a rejected
  # one closes nothing there either). So a key under a round the collection has not
  # reached, like one member's copy under round 2 while round 1 waits, or under a round the
  # driver does not run, is no one's approval, however valid its bytes. The rounds and the
  # threshold are the proposal's own (describeFor), as in the fold.
  var reached = 1
  while reached < desc.rounds:
    var closers = initHashSet[string]()
    for g in result:
      if g.round == reached and g.grade != agRejected: closers.incl g.who
    if closers.len < desc.threshold: break
    inc reached
  var inReach: seq[ApprovalGrade]
  for g in result:
    if g.round in 1 .. reached: inReach.add g
  result = inReach
  # exo-093: the copy that stands for each approval is the first whose history stays inside
  # the record: its parents are the lineage, or copies of the approvals graded here (a
  # fixpoint). So a copy parented outside the intent stands for nothing, however early it
  # sorts, and approvals made after it do not link it. With no such copy (an approval from
  # before exo-96d that linked junk), the first valid one, which the export then refuses.
  var graded = initHashSet[string]()
  for g in result: graded.incl g.who & "/" & $g.round
  let standing = closedWithin(rec.copies.filterIt((it.who & "/" & $it.round) in graded), rec.lineage)
  for g in result.mitems:
    var first = true
    for c in rec.copies:
      if c.who != g.who or c.round != g.round or c.id notin standing: continue
      if first: (g.sig = c.e; first = false)
      g.copies.add c.e

proc approvalParents*(events: seq[Event], driverFor: DriverFor, intentId: string): seq[EventId] =
  ## What a new approval links (exo-403): the proposal and every approval on the intent,
  ## as the grades' own events. A member who later reads the approval but not those can
  ## tell its history reaches events it cannot read, and the audit file, which carries
  ## exactly those, stays parent-closed. Never any other sig event (exo-96d): junk under a
  ## name, a non-member's signature, a key the collection never reached is no approval, and
  ## a link to it would leave the file a parent it does not carry. Nor a substitute
  ## propose under the id (exo-dbd): only the proposal's own.
  let proposal = proposalOf(events, intentId)
  for e in events:
    if e.key == "intent/" & intentId & "/propose" and proposal.isProposalEvent(intentId, e):
      result.add eventId(e)
  for g in approvalGrades(events, driverFor, intentId): result.add eventId(g.sig)

proc gradeOf*(grades: seq[ApprovalGrade], who: string, round: int): AttestGrade =
  for g in grades:
    if g.who == who and g.round == round: return g.grade
  agUnattested

proc expired*(ctx: SigningContext, nowSec: uint64): bool =
  ## Checked at sign time and at submit time — never inside the fold, which stays a
  ## pure function of the log (invariant 4).
  nowSec > ctx.expiry

# ── "did I approve this?" — read from the log and my keys (exo-59c) ──────────────
# The card used to claim nothing per-viewer, so Approve stayed after you used it. What is
# claimed now is only what the log and this member's keys prove: an approval named by one
# of MY names, or one whose key the log binds to my encryption identity with a statement
# that key itself signed. A FROST-group or LEZ-vote approval is named by a key neither
# rule reaches; the host remembers those it made itself.

proc lowHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc myContributorNames*(ks: Keystore): seq[string] =
  ## The names the drivers give THIS member's approvals, derived from its keys: a Safe /
  ## EIP-191 approval is named by a secp address (every key the keystore holds), a
  ## Bitcoin multisig approval by the primary key's compressed public key, a threshold /
  ## invoke / room-FROST approval by the Ed25519 key.
  let e = ks.encIdentity()
  for r in ks.keyRefs(): result.add r.toLowerAscii()
  let a = "0x" & lowHex(ks.address())
  if a notin result: result.add a
  try: result.add lowHex(ks.btcPubKey())
  except CatchableError: discard
  result.add "ed:" & lowHex(e.ed)
  result.add "frost:" & lowHex(e.ed)

proc approvedByMe*(events: seq[Event], intentId: string, approvers: seq[string],
                   me: EncIdentity, myNames: seq[string]): bool =
  ## Whether THIS member is among an intent's approvers. `approvers` are the names the
  ## fold counted (non-rejected grades). A binding (intent/<id>/binding/<who>) counts
  ## only when its statement names my identity AND its signer is that approver — so no
  ## one can make my card claim an approval by binding their own key to me.
  var mine: seq[string]
  for n in myNames: mine.add n.toLowerAscii()
  var named: seq[string]
  for w in approvers:
    let lw = w.toLowerAscii()
    if lw in mine: return true
    named.add lw
  for e in events:
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "intent" or p[1] != intentId or p[2] != "binding": continue
    let who = p[3].toLowerAscii()
    if who notin named: continue
    try:
      let st = decodeLink(hexToBytes(e.value))
      if st.enc != me: continue
      let signer = bindingSigner(st, 0)          # the key that vouched; expiry is not the question here
      if who == "0x" & lowHex(signer): return true
      if who.len == 66 and addressOfCompressed(hexToBytes(who)) == signer: return true
    except CatchableError: discard
  false
