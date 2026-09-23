## The signature-audit file — one downloadable, self-verifying record of everything an
## intent's approvals cover (spec: contracts/specs/derived-exo-403.spec.json, critical).
##
## `exportAudit` reduces a member's log to one canonical-CBOR file (invariant 5): the
## effect and its materialization, the signing context, the provenance record and the
## parent-closed lineage it names, every approval with its grade (committed /
## unattested / rejected, exo-ef1) and its signature + attestation events, the
## settlement entries (external reads, with the tx hash), and the claims the log alone
## can't prove — threshold, stage, disclosure, first epoch — signed by the exporting
## member's key. Nothing is stored; the file is a function of log + keys (invariant 4).
##
## `verifyAudit` reads NOTHING but the file: it re-derives the materialization, the
## context, the inputs and P; recomputes every content id, the canonical order and the
## parent closure; checks each driver signature is by the contributor it names and
## recomputes each grade from the attestations; then checks the exporter's signature.
## The first discrepancy is named. Settlement is reported as what it is — an external
## read — never as verified against the chain. What the file cannot prove (that a
## signer is a Safe owner, that the chain agrees) is outside it, and said so.
##
## `renderAuditReport` is a pure rendering of the file for people. It carries the
## file's digest and is never authoritative: the file is what verifies.

import std/[json, strutils, sets, tables, algorithm]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../crypto/keystore
import ../crypto/secp256k1
import ../crypto/curve25519
import ../drivers/driver
import ../drivers/safe
import ../drivers/threshold
import ../drivers/frost
import ../drivers/invoke
import ../drivers/eip191
import ../drivers/manifest
import ../intents/materialization
import ../intents/signing_payload
import ../intents/provenance
import ../intents/disclosure
import ./intent_events
import ./attest
import ./intents

const AuditFormat* = "muster.signature-audit.v1"

type
  AuditResult* = object
    ok*: bool
    reason*: string          ## why the export was refused (when not ok)
    bytes*: seq[byte]        ## the canonical file (dCBOR)

  ApprovalReport* = object
    who*: string
    round*: int
    grade*: string           ## committed | unattested | rejected

  SettlementReport* = object
    kind*: string            ## submit | final
    chainRef*: string        ## the tx hash, or "" when the event predates chain refs
    grade*: string           ## always "external-read"

  AuditVerdict* = object
    ok*: bool
    reason*: string          ## the first discrepancy, when refused
    intentId*, stage*, issuer*, digest*: string
    firstEpoch*: int
    approvals*: seq[ApprovalReport]
    settlement*: seq[SettlementReport]

  AuditRefused = object of CatchableError

proc hex0x(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc hexBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  if h.len mod 2 != 0: return @[]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: return @[]

proc refuse(why: string) {.noreturn.} = raise newException(AuditRefused, why)

proc auditDigest*(bytes: seq[byte]): string =
  ## The content address of a whole file — what the report carries and a person cites.
  toHex(@(digest(hashInput("muster.signature-audit.file.v1", @[("file", cbBytes(bytes))]))))

proc bodyDigest(body: CborValue): array[32, byte] =
  ## What the exporter signs: every field of the file except its own signature.
  let d = digest(hashInput(AuditFormat, @[("body", cbBytes(encode(body)))]))
  for i in 0 ..< 32: result[i] = d[i]

# ── event <-> CBOR ────────────────────────────────────────────────────────────

proc eventCbor(e: Event): CborValue =
  var ps = e.parents
  ps.sort()
  var arr: seq[CborValue]
  for p in ps: arr.add cbText(p)
  cbMap(@[(cbText("id"), cbText(eventId(e))), (cbText("parents"), cbArray(arr)),
          (cbText("key"), cbText(e.key)), (cbText("value"), cbText(e.value))])

proc text(v: CborValue, what: string): string =
  if v.kind != ckText: refuse(what & " is not text")
  v.t

proc arrayOf(v: CborValue, what: string): seq[CborValue] =
  if v.kind != ckArray: refuse(what & " is not a list")
  v.arr

proc eventOf(v: CborValue, what: string): Event =
  ## Rebuild an event from the file and check it is what its id claims.
  var ps: seq[EventId]
  for p in v.field("parents").arrayOf(what & " parents"): ps.add p.text(what & " parent")
  result = Event(parents: ps, key: v.field("key").text(what & " key"),
                 value: v.field("value").text(what & " value"))
  if eventId(result) != v.field("id").text(what & " id"):
    refuse(what & " '" & result.key & "' does not match its content id")

# ── drivers rebuilt from the file alone ───────────────────────────────────────

proc fileDriver(policy: string, ctx: SigningContext): Driver =
  ## The driver as far as the file can reconstruct it: enough to re-derive the
  ## materialization (its canonicalize), never the signer set — whether a signer is a
  ## Safe owner or on a roster is a fact outside the file.
  case policy
  of "safe":
    if not ctx.environment.startsWith("eip155:"): refuse("a Safe intent's environment is not an EVM chain")
    var chain: uint64
    try: chain = parseBiggestUInt(ctx.environment[7 .. ^1]).uint64
    except CatchableError: refuse("the context's chain id is malformed")
    let a = hexBytes(ctx.account)
    if a.len != 20: refuse("the context's Safe address is malformed")
    var safeAddr: Address
    for i in 0 ..< 20: safeAddr[i] = a[i]
    newSafeDriver(chainId = chain, safe = safeAddr)
  of "eip191": newPersonalSignDriver()
  of "threshold", "unanimous": newThresholdDriver(@[], 1)
  of "frost": newFrostDriver(@[], 1)
  of "invoke": newInvokeDriver(@[], 1)
  else: refuse("unknown policy '" & policy & "'")

proc signedBy(who: string, mat: seq[byte], sigHex: string): bool =
  ## Is `sigHex` a signature over the materialization by the contributor `who` names?
  ## The in-app path signs the 32-byte digest (secp) or the materialization (Ed25519).
  let sig = hexBytes(sigHex)
  if who.startsWith("ed:"):
    let pk = hexBytes(who[3 .. ^1])
    if pk.len != 32 or sig.len != 64: return false
    var edPk: Ed25519Pub
    var edSig: Ed25519Sig
    for i in 0 ..< 32: edPk[i] = pk[i]
    for i in 0 ..< 64: edSig[i] = sig[i]
    return edVerify(edPk, mat, edSig)
  if who.startsWith("0x"):
    let a = hexBytes(who)
    if a.len != 20 or sig.len != 65 or mat.len < 32: return false
    var h: array[32, byte]
    var s65: Signature65
    var owner: Address
    for i in 0 ..< 32: h[i] = mat[i]
    for i in 0 ..< 65: s65[i] = sig[i]
    for i in 0 ..< 20: owner[i] = a[i]
    try: return ecrecover(h, s65) == owner
    except CatchableError: return false
  false

# ── export ────────────────────────────────────────────────────────────────────

proc contextCbor(ctx: SigningContext): CborValue =
  cbMap(@[(cbText("environment"), cbText(ctx.environment)), (cbText("account"), cbText(ctx.account)),
          (cbText("slot"), cbText(ctx.slot)), (cbText("expiry"), cbUint(ctx.expiry))])

proc provenanceCbor(inputs: seq[SignedInput]): CborValue =
  ## The committed record's entries, exactly as encodeProvenance shapes them.
  var arr: seq[CborValue]
  for e in buildProvenance(inputs).entries:
    arr.add cbArray(@[cbText($e.class), cbText(e.logRef), cbText(e.account)])
  cbArray(arr)

proc firstEpochOf(events: seq[Event], me: EncIdentity): int =
  ## The exporter's earliest readable epoch: its own admission, or 0 for a founder.
  let mine = hex0x(me.toBytes())[2 .. ^1].toLowerAscii
  result = 0
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit" and p[3].toLowerAscii == mine:
      try: result = max(result, parseInt(p[1]))
      except ValueError: discard

proc exportAudit*(events: seq[Event], driverFor: DriverFor, intentId: string,
                  issuer: Keystore): AuditResult =
  ## One audit file for `intentId`, from THIS member's log. Refused — never truncated
  ## — when the intent's history reaches an event this member cannot read.
  try:
    let ordered = canonicalOrder(events)
    var byId = initTable[EventId, Event]()
    for e in ordered: byId[eventId(e)] = e
    let effectJson = effectJsonOf(ordered, intentId)
    if effectJson.len == 0: refuse("this intent was not proposed in this member's log")
    let policy = intentPolicyOf(ordered, intentId)
    let ctx = intentContext(ordered, intentId)
    if ctx.isPlaceholder: refuse("the intent has no signing context (proposed before exo-ef1)")
    let inputs = intentInputs(ordered, driverFor, intentId)
    if not inputs.allAccountable:
      refuse("the intent's history reaches an input this member cannot read (an earlier epoch, or never shared)")
    let drv = driverFor(policy)
    let effect = effectFromJson(effectJson)
    let mat = canonicalize(drv, effect)
    let p = attestationPayload(ordered, driverFor, intentId)

    # the lineage: every input the provenance names, and all their ancestors
    var lineage = initHashSet[EventId]()
    var queue: seq[EventId]
    for i in inputs: queue.add i.logRef
    proc needReadable(id: EventId) =
      if id notin byId:
        refuse("the intent's history reaches an event this member cannot read (an earlier epoch)")
    while queue.len > 0:
      let id = queue.pop()
      if id in lineage: continue
      needReadable(id)
      lineage.incl id
      for par in byId[id].parents: queue.add par
    var lineageEvents: seq[Event]
    for e in ordered:
      if eventId(e) in lineage: lineageEvents.add e
    var lineageArr: seq[CborValue]
    for e in canonicalOrder(lineageEvents): lineageArr.add eventCbor(e)

    # approvals, each with its grade and its signature + attestation events
    let grades = approvalGrades(ordered, driverFor, intentId)
    var approvals: seq[CborValue]
    for g in grades:
      var sigEv: Event
      var found = false
      for e in ordered:
        if e.key == "intent/" & intentId & "/sig/" & g.who & "/" & $g.round:
          sigEv = e; found = true; break
      if not found: continue
      for par in sigEv.parents: needReadable(par)
      var atts: seq[Event]
      for e in ordered:
        if e.key == "intent/" & intentId & "/attest/" & g.who & "/" & $g.round:
          for par in e.parents: needReadable(par)
          atts.add e
      atts.sort(proc (a, b: Event): int = cmp(eventId(a), eventId(b)))
      var attArr: seq[CborValue]
      for a in atts: attArr.add eventCbor(a)
      approvals.add cbMap(@[(cbText("who"), cbText(g.who)), (cbText("round"), cbUint(uint64(g.round))),
                            (cbText("grade"), cbText($g.grade)), (cbText("sig"), eventCbor(sigEv)),
                            (cbText("attests"), cbArray(attArr))])

    # settlement: the chain's answer as the room observed it — external reads
    var settlement: seq[CborValue]
    for kind in ["submit", "final"]:
      for e in ordered:
        if e.key == "intent/" & intentId & "/" & kind:
          for par in e.parents: needReadable(par)
          settlement.add eventCbor(e)
          break

    var disc: seq[CborValue]
    for r in drv.manifest(effect).fullDisclosure():
      disc.add cbArray(@[cbText(r.field), cbText($r.to)])
    let claims = cbMap(@[
      (cbText("threshold"), cbUint(uint64(max(0, drv.describe().threshold)))),
      (cbText("stage"), cbText(intentState(ordered, driverFor, intentId))),
      (cbText("disclosure"), cbArray(disc)),
      (cbText("firstEpoch"), cbUint(uint64(firstEpochOf(ordered, issuer.encIdentity()))))])

    var body = cbMap(@[
      (cbText("format"), cbText(AuditFormat)),
      (cbText("intent"), cbText(intentId)),
      (cbText("policy"), cbText(policy)),
      (cbText("effect"), cbText(effectJson)),
      (cbText("materialization"), cbBytes(mat.bytes)),
      (cbText("context"), contextCbor(ctx)),
      (cbText("provenance"), provenanceCbor(inputs)),
      (cbText("payload"), cbBytes(p)),
      (cbText("lineage"), cbArray(lineageArr)),
      (cbText("approvals"), cbArray(approvals)),
      (cbText("settlement"), cbArray(settlement)),
      (cbText("claims"), claims),
      (cbText("issuer"), cbText(hex0x(issuer.address()).toLowerAscii))])
    let sig = issuer.sign(bodyDigest(body))
    body.pairs.add (cbText("signature"), cbBytes(@sig))
    AuditResult(ok: true, bytes: encode(body))
  except AuditRefused as e:
    AuditResult(ok: false, reason: e.msg)
  except CatchableError as e:
    AuditResult(ok: false, reason: "export failed: " & e.msg)

# ── verify ────────────────────────────────────────────────────────────────────

proc verifyAudit*(bytes: seq[byte]): AuditVerdict =
  ## Refuse-on-mismatch, reading only `bytes`. The first discrepancy is named.
  result.digest = auditDigest(bytes)
  try:
    var f: CborValue
    try: f = decode(bytes)
    except CborError as e: refuse("not a canonical audit file: " & e.msg)
    if f.field("format").text("format") != AuditFormat: refuse("unknown format")
    let intentId = f.field("intent").text("intent")
    let policy = f.field("policy").text("policy")
    let effectJson = f.field("effect").text("effect")
    result.intentId = intentId

    # every event in the file is what its id claims; the lineage is in canonical
    # order; nothing names a parent the file doesn't carry
    var lineage: seq[Event]
    var ids: seq[EventId]
    for v in f.field("lineage").arrayOf("lineage"):
      let e = eventOf(v, "lineage entry")
      lineage.add e
      ids.add eventId(e)
    var canon: seq[EventId]
    for e in canonicalOrder(lineage): canon.add eventId(e)
    if canon != ids: refuse("the lineage is not in canonical order")
    var all = initHashSet[EventId]()
    for i in ids: all.incl i
    type Appr = tuple[who: string, round: int, grade: string, sig: Event, atts: seq[Event]]
    var apprs: seq[Appr]
    for v in f.field("approvals").arrayOf("approvals"):
      let sigEv = eventOf(v.field("sig"), "approval signature")
      var atts: seq[Event]
      for a in v.field("attests").arrayOf("attestations"): atts.add eventOf(a, "attestation")
      if v.field("round").kind != ckUint: refuse("an approval round is not a number")
      apprs.add (who: v.field("who").text("approval who"), round: int(v.field("round").u),
                 grade: v.field("grade").text("approval grade"), sig: sigEv, atts: atts)
      all.incl eventId(sigEv)
      for a in atts: all.incl eventId(a)
    var settle: seq[Event]
    for v in f.field("settlement").arrayOf("settlement"):
      let e = eventOf(v, "settlement entry")
      settle.add e
      all.incl eventId(e)
    for e in lineage:
      for par in e.parents:
        if par notin all: refuse("an entry names a parent the file does not carry")
    for a in apprs:
      for e in @[a.sig] & a.atts:
        for par in e.parents:
          if par notin all: refuse("approval by " & a.who & " links an entry the file does not carry")
    for e in settle:
      for par in e.parents:
        if par notin all: refuse("a settlement entry names a parent the file does not carry")

    # the intent: its proposal, policy and identity
    if effectJsonOf(lineage, intentId) != effectJson: refuse("the effect does not match the proposal in the lineage")
    if intentPolicyOf(lineage, intentId, default = "") != policy: refuse("the policy does not match the lineage")
    if intentIdFor(effectJson, policy) != intentId: refuse("the intent id does not match its effect and policy")

    # the context, the driver, the materialization
    let ctx = intentContext(lineage, intentId)
    if ctx.isPlaceholder: refuse("the lineage carries no signing context")
    let c = f.field("context")
    if c.field("environment").text("environment") != ctx.environment or
       c.field("account").text("account") != ctx.account or
       c.field("slot").text("slot") != ctx.slot or
       c.field("expiry").kind != ckUint or c.field("expiry").u != ctx.expiry:
      refuse("the context does not match the lineage")
    let fdrv = fileDriver(policy, ctx)
    let fileDriverFor: DriverFor = proc(kind: string): Driver = fdrv
    let mat = canonicalize(fdrv, effectFromJson(effectJson))
    let m = f.field("materialization")
    if m.kind != ckBytes or m.b != mat.bytes: refuse("the materialization does not re-derive from the effect")

    # the provenance record, both ways, and P
    let inputs = intentInputs(lineage, fileDriverFor, intentId)
    if not inputs.allAccountable: refuse("the provenance names an input the file does not carry")
    if encode(f.field("provenance")) != encode(provenanceCbor(inputs)):
      refuse("the provenance record does not match the lineage")
    var named = initHashSet[EventId]()
    for i in inputs: named.incl i.logRef
    var reach = named
    var changed = true
    while changed:
      changed = false
      for e in lineage:
        if eventId(e) in reach:
          for par in e.parents:
            if par notin reach: (reach.incl par; changed = true)
    for i in ids:
      if i notin reach: refuse("the lineage carries an entry no provenance names")
    let p = attestationPayload(lineage, fileDriverFor, intentId)
    let pf = f.field("payload")
    if pf.kind != ckBytes or pf.b != p: refuse("the signing payload does not re-derive")

    # every approval: signed by who it names, graded by its attestations
    var committed, unattested = 0
    var seenAppr = initHashSet[string]()
    for a in apprs:
      let k = a.who & "/" & $a.round
      if k in seenAppr: refuse("approval by " & a.who & " appears twice")
      seenAppr.incl k
      if a.sig.key != "intent/" & intentId & "/sig/" & k:
        refuse("approval by " & a.who & " carries another approval's signature")
      if not signedBy(a.who, mat.bytes, a.sig.value):
        refuse("approval by " & a.who & " is not signed by " & a.who & " over the materialization")
      var ok = false
      for att in a.atts:
        if att.key != "intent/" & intentId & "/attest/" & k:
          refuse("approval by " & a.who & " carries another approval's attestation")
        if verifyAttestation(a.who, p, att.value): ok = true
      let grade = (if ok: $agCommitted elif a.atts.len > 0: $agRejected else: $agUnattested)
      if grade != a.grade:
        refuse("approval by " & a.who & " claims '" & a.grade & "' but its attestations make it '" & grade & "'")
      if grade == $agCommitted: inc committed
      elif grade == $agUnattested: inc unattested
      result.approvals.add ApprovalReport(who: a.who, round: a.round, grade: grade)

    # settlement: external reads, never proof
    var submitted, final = false
    for e in settle:
      let kind = e.key.split('/')[^1]
      if e.key != "intent/" & intentId & "/" & kind or kind notin ["submit", "final"]:
        refuse("a settlement entry is not this intent's submit or final")
      if kind == "submit": submitted = true else: final = true
      result.settlement.add SettlementReport(kind: kind, grade: "external-read",
        chainRef: (if e.value == "1": "" else: e.value))

    # the claims the log can't prove: consistent with what it can, and signed
    let cl = f.field("claims")
    let stage = cl.field("stage").text("stage")
    if cl.field("threshold").kind != ckUint or cl.field("firstEpoch").kind != ckUint:
      refuse("the claims are malformed")
    let threshold = int(cl.field("threshold").u)
    var maxRound = 1
    for a in apprs: maxRound = max(maxRound, a.round)
    let counted = committed + unattested
    let consistent =
      if final: stage == "final"
      elif submitted: stage in ["submitted", "settling"]
      elif maxRound > 1: stage in ["proposed", "collecting", "executable"]
      elif counted == 0: stage == "proposed"
      elif counted < threshold: stage == "collecting"
      else: stage == "executable"
    if not consistent: refuse("the claimed stage '" & stage & "' does not follow from the approvals and settlement")
    discard cl.field("disclosure").arrayOf("disclosure")
    let issuer = f.field("issuer").text("issuer")
    let sigv = f.field("signature")
    if sigv.kind != ckBytes or sigv.b.len != 65: refuse("the exporter's signature is malformed")
    var body = cbMap(@[])
    for (k, v) in f.pairs:
      if not (k.kind == ckText and k.t == "signature"): body.pairs.add (k, v)
    var s65: Signature65
    for i in 0 ..< 65: s65[i] = sigv.b[i]
    var signer = ""
    try: signer = hex0x(ecrecover(bodyDigest(body), s65)).toLowerAscii
    except CatchableError: discard
    if signer != issuer.toLowerAscii: refuse("the exporter's signature does not cover this file")

    result.stage = stage
    result.issuer = issuer
    result.firstEpoch = int(cl.field("firstEpoch").u)
    result.ok = true
  except AuditRefused as e:
    result.ok = false
    result.reason = e.msg
  except CatchableError as e:
    result.ok = false
    result.reason = "unreadable audit file: " & e.msg
  if not result.ok:
    result.approvals = @[]
    result.settlement = @[]

# ── the readable report ───────────────────────────────────────────────────────

proc renderAuditReport*(bytes: seq[byte]): string =
  ## A plain-language rendering of the file, for people. A pure function of the file;
  ## it carries the file's digest and proves nothing on its own.
  let d = auditDigest(bytes)
  var f: CborValue
  try: f = decode(bytes)
  except CatchableError:
    return "# Muster audit\n\nThis file could not be read as a Muster audit file.\n\nFile digest: `" & d & "`\n"
  proc str(v: CborValue): string = (if v != nil and v.kind == ckText: v.t elif v != nil and v.kind == ckUint: $v.u else: "?")
  proc get(m: CborValue, k: string): CborValue =
    try: m.field(k) except CatchableError: nil
  proc items(v: CborValue): seq[CborValue] = (if v != nil and v.kind == ckArray: v.arr else: @[])
  var o: seq[string]
  let cl = f.get("claims")
  o.add "# Muster audit — intent `" & f.get("intent").str & "`"
  o.add ""
  o.add "File digest: `" & d & "`"
  o.add ""
  o.add "This report is generated from the audit file. The FILE is what verifies — check it with `muster-audit-verify`; editing this text changes nothing it proves."
  o.add ""
  o.add "## What was decided"
  o.add ""
  o.add "- Policy: " & f.get("policy").str & " · threshold " & cl.get("threshold").str & " · stage **" & cl.get("stage").str & "**"
  o.add "- Effect: `" & f.get("effect").str & "`"
  let c = f.get("context")
  o.add "- Bound to: " & c.get("environment").str & " · account `" & c.get("account").str & "` · slot `" & c.get("slot").str & "` · expires " & c.get("expiry").str
  o.add ""
  o.add "## Approvals"
  o.add ""
  for a in f.get("approvals").items:
    let g = a.get("grade").str
    let why = (case g
      of "committed": "signed in muster; its attestation commits to the context and to where every input came from"
      of "unattested": "signed outside muster and pasted in — it counts, but commits to nothing beyond the transaction"
      of "rejected": "its attestation does not verify — it was not counted"
      else: "")
    o.add "- `" & a.get("who").str & "` (round " & a.get("round").str & "): **" & g & "** — " & why
  if f.get("approvals").items.len == 0: o.add "- none visible to the exporter"
  o.add ""
  o.add "## Where the inputs came from"
  o.add ""
  var keyOf = initTable[string, string]()
  for e in f.get("lineage").items: keyOf[e.get("id").str] = e.get("key").str
  proc labelOf(key: string): string =
    let p = key.split('/')
    if p.len < 3: return "an entry"
    case p[2]
    of "propose": "the proposal"
    of "policy": "the policy it runs under"
    of "context": "the signing context"
    of "read": "an outside read of '" & (if p.len > 3: p[3] else: "?") & "'"
    of "material": "material shared for '" & (if p.len > 3: p[3] else: "?") & "'"
    else: "an entry"
  for e in f.get("provenance").items:
    let x = e.items
    if x.len == 3:
      o.add "- " & labelOf(keyOf.getOrDefault(x[1].str)) & " (" & x[0].str & ", entry `" &
        x[1].str[0 ..< min(16, x[1].str.len)] & "…`)" &
        (if x[2].str.len > 0: " from `" & x[2].str & "`" else: "")
  o.add ""
  o.add "## Settlement"
  o.add ""
  let st = f.get("settlement").items
  for e in st:
    let v = e.get("value").str
    o.add "- " & e.get("key").str.split('/')[^1] & ": " &
      (if v == "1": "chain reference unknown" else: "`" & v & "`") &
      " — an external read: what the room observed, not proof. Look it up on the chain yourself."
  if st.len == 0: o.add "- not settled"
  o.add ""
  o.add "## Who could see what"
  o.add ""
  for r in cl.get("disclosure").items:
    let x = r.items
    if x.len == 2: o.add "- " & x[0].str & " → " & x[1].str
  o.add ""
  o.add "## About this file"
  o.add ""
  o.add "- Exported by `" & f.get("issuer").str & "`, who signed the claims the log alone can't prove (threshold, stage, disclosure)."
  let fe = cl.get("firstEpoch").str
  o.add "- Covers membership epoch " & fe & " onward" &
    (if fe != "0" and fe != "?": ": the exporter joined then, so anything sealed before it is not shown." else: ".")
  o.add "- Not provable from the file: that each signer is a Safe owner / roster member, and that the chain agrees."
  o.join("\n") & "\n"
