## Intents as a fold over the coordination log — where invariant 4
## (state = reduce(log)) becomes literal for the multi-party case.
##
## Each intent operation is a log event; `reduceIntents` replays them through the
## SAME lifecycle engine the single-instance path uses (`lifecycle.apply`), so two
## instances with the same event set compute identical intent states — no second
## state machine, no drift. The Safe driver verifies each contribution (recovers
## to an owner) before it counts toward the threshold, exactly as the hosted
## `approve` does; here that verification is part of the pure fold.
##
## Events (key/value on the coordination log):
##   propose : "intent/<id>/propose"            value = effect JSON {to,value,nonce}
##   sign    : "intent/<id>/sig/<contributor>"  value = 65-byte owner signature hex
##   submit  : "intent/<id>/submit"             value = "1"
## A contribution is keyed by contributor, so a duplicate signature from the same
## owner folds once (Safe dedups too).

import std/[json, tables, sets, strutils, algorithm]
import ../log/log
import ../intents/lifecycle
import ../intents/materialization
import ../intents/signing_payload
import ../intents/provenance     # InputClass — the spec's accountability vocabulary (inv 10)
import ../drivers/driver
import ../dcbor/dcbor
import ../hashing/keccak256
export lifecycle.Intent, lifecycle.LifecycleState
export provenance.InputClass    # so consumers can name a lineage entry's class

proc effectFromJson*(effectJson: string): Effect =
  ## Build a typed effect from JSON. The `effect` field selects the schema (default
  ## "transfer"); each schema binds its own fields, and the schemaId travels into the
  ## materialization, so a signature under one effect can never be reinterpreted as
  ## another (F-5 / invariant 5b). The ACTION is open: a new effect type is a new
  ## case here (eventually a plugin-emitted typed block, invariant 3), never a change
  ## to the fold — the core still doesn't read the bytes, the driver canonicalizes them.
  try:
    let j = parseJson(effectJson)
    if j.kind == JObject:
      let kind = if j.hasKey("effect"): j["effect"].getStr() else: "transfer"
      case kind
      of "statement":
        # A statement the room ratifies — a decision that produces a signed group
        # endorsement, not a payment. Canonicalizes under any driver whose
        # materialization is the base serialization (e.g. the threshold driver).
        var fields: seq[(string, CborValue)]
        if j.hasKey("text"): fields.add ("text", cbText(j["text"].getStr()))
        return Effect(schemaId: "muster.effect.statement.v1", fields: fields)
      of "add-driver":
        # GOVERNANCE — driver-as-proposal: a proposal that INTRODUCES a driver kind
        # into the room's capability set. What a group can do evolves by proposal, not
        # a fixed compile-time list (invariant 6). Like a statement it produces a signed
        # group decision, not an on-chain effect; it canonicalizes under the base
        # serialization, and once the room approves it the kind is admitted (see
        # roomDriverKinds). Schema-bound, so an add-driver signature can never be
        # reinterpreted as a payment (F-5).
        var fields: seq[(string, CborValue)]
        if j.hasKey("kind"): fields.add ("kind", cbText(j["kind"].getStr()))
        return Effect(schemaId: "muster.effect.governance.add-driver.v1", fields: fields)
      else:
        var fields: seq[(string, CborValue)]
        if j.hasKey("to"): fields.add ("to", cbText(j["to"].getStr()))
        if j.hasKey("value"): fields.add ("value", cbUint(uint64(j["value"].getInt())))
        if j.hasKey("nonce"): fields.add ("nonce", cbUint(uint64(j["nonce"].getInt())))
        return Effect(schemaId: "muster.effect.transfer.v1", fields: fields)
  except CatchableError: discard
  Effect(schemaId: "muster.effect.transfer.v1", fields: @[])

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc bytesHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# ── surface helpers (the hosted coordination methods are thin glue over these) ──

proc intentIdFor*(effectJson: string, policyKind = ""): string =
  ## A content-addressed intent id, so independent hosts derive the SAME id for the
  ## same (effect, policy) without a round-trip. The POLICY is part of the identity
  ## because an intent is a policy boundary: the same effect under two policies is two
  ## distinct decisions, so it must be two intents (no collision). First 8 bytes of
  ## keccak256(effect ++ "|" ++ policy). Re-proposing the same effect+policy folds once.
  var b: seq[byte]
  for c in effectJson: b.add byte(c)
  if policyKind.len > 0:
    b.add byte('|')
    for c in policyKind: b.add byte(c)
  bytesHex(keccak256(b)[0 ..< 8])

proc effectJsonOf*(events: seq[Event], intentId: string): string =
  ## The effect a proposal carried, recovered from the log — a contributor needs it
  ## to recompute the safeTxHash their signature must cover. "" if not proposed here.
  for e in events:
    if e.key == "intent/" & intentId & "/propose": return e.value
  ""

proc contributorOf*(driver: Driver, effectJson, signatureHex: string): string =
  ## The id of whoever produced this contribution (for Safe: the owner address that
  ## signed the safeTxHash), or "" if it is not a legitimate contribution. A
  ## contribution is keyed by this, so a duplicate folds once and a non-participant
  ## never counts — driver-described (identifyContributor), so the fold is generic.
  let m = canonicalize(driver, effectFromJson(effectJson))
  identifyContributor(driver, m, Contribution(bytes: hexToBytes(signatureHex)))

# ── event constructors (what a participant publishes) ─────────────────────────

proc proposeEvent*(intentId, effectJson: string): Event =
  Event(key: "intent/" & intentId & "/propose", value: effectJson)

proc contributeEvent*(intentId, contributor, signatureHex: string,
                      parents: seq[EventId] = @[]): Event =
  Event(parents: parents, key: "intent/" & intentId & "/sig/" & contributor,
        value: signatureHex)

proc submitEvent*(intentId: string, parents: seq[EventId] = @[]): Event =
  Event(parents: parents, key: "intent/" & intentId & "/submit", value: "1")

# ── per-intent policy: the intent is the policy boundary, not the room ─────────
# The room is a membership/privacy boundary — who can read. WHICH driver governs a
# decision is the INTENT's, recorded when it is proposed, so a group (one room) can
# run many things at once, each under its own driver, and changing what you compose
# next never re-folds a decision already made. Keyed per intent ("intent/<id>/policy").

proc policyDeclEvent*(intentId, kind: string): Event =
  Event(key: "intent/" & intentId & "/policy", value: kind)

proc intentPolicyOf*(events: seq[Event], intentId: string, default = "safe"): string =
  ## The policy an intent was proposed under, recovered from the log — the driver that
  ## governs THIS decision. `default` if none recorded (a legacy propose).
  for e in events:
    if e.key == "intent/" & intentId & "/policy": return e.value
  default

# ── messages: authored chat events folded from the SAME log ───────────────────
# A message is an authored event on the coordination log — plain chat text or a
# typed card as JSON, opaque to the core. It is NOT an intent: it never touches
# the lifecycle engine, it is simply recorded and read back in timestamp order.
# Each message is its own log entry keyed by a unique content address
# ("message/<id>"), so the last-write-wins reducer preserves every one of them
# (append-only), and the same message ingested twice folds once. The id travels
# in the key inside the sealed envelope, so every participant reads the author's
# id verbatim — it needn't be re-derivable by a reader, only unique for the author.

type Message* = object
  id*: string
  author*: string       ## the author's 64-byte enc identity (ed25519 ++ x25519) hex
  ts*: int64            ## authoring wall-clock (seconds); the sort key
  body*: string         ## opaque: plain text OR a typed card as JSON

proc newMessageEvent*(author: string, ts: int64, body: string,
                      nonce: uint64): (string, Event) =
  ## Build an authored message event and its message id. The id is
  ## keccak256(author ++ body ++ ts ++ nonce)[:12]; the nonce (a per-author
  ## monotonic counter) keeps two identical bodies in the same second distinct.
  let value = $(%*{"author": author, "ts": ts, "body": body})
  var b: seq[byte]
  for c in author: b.add byte(c)
  for c in body: b.add byte(c)
  var t = cast[uint64](ts)
  for _ in 0 ..< 8: (b.add byte(t and 0xff'u64); t = t shr 8)
  var n = nonce
  for _ in 0 ..< 8: (b.add byte(n and 0xff'u64); n = n shr 8)
  let id = bytesHex(keccak256(b)[0 ..< 12])
  (id, Event(key: "message/" & id, value: value))

proc reduceMessages*(events: seq[Event]): seq[Message] =
  ## Fold the authored messages out of the shared log, oldest-first. Ordered by
  ## timestamp with the message id as a deterministic tiebreak, so two instances
  ## with the same event set produce the identical ordering (invariant 4).
  const prefix = "message/"
  for e in canonicalOrder(events):
    if not e.key.startsWith(prefix): continue
    try:
      let j = parseJson(e.value)
      result.add Message(id: e.key[prefix.len .. ^1],
                         author: j["author"].getStr(),
                         ts: j["ts"].getBiggestInt(),
                         body: j["body"].getStr())
    except CatchableError: continue
  result.sort(proc (a, b: Message): int =
    if a.ts != b.ts: (if a.ts < b.ts: -1 else: 1) else: cmp(a.id, b.id))

# ── the fold: intent lifecycle = reduce(log) ──────────────────────────────────

type DriverFor* = proc(kind: string): Driver
  ## Resolve a policy kind to its driver. Each intent folds under the driver of the
  ## policy it was proposed with — the intent is the policy boundary.

proc reduceIntents*(events: seq[Event], driverFor: DriverFor): Table[string, Intent] =
  ## Deterministic: proposes, then contributions, then submits, each in canonical
  ## order — a pure function of the event SET (invariant 4, R-2/R-3). Each intent uses
  ## ITS OWN driver, resolved from the policy it was proposed under (intentPolicyOf),
  ## so one room can carry many intents under different drivers at once and changing
  ## the compose default never re-folds an existing decision.
  result = initTable[string, Intent]()
  var seenSig = initHashSet[string]()   # "<id>/<contributor>" — one signature per owner
  var now: uint64 = 0
  let ordered = canonicalOrder(events)

  proc opOf(e: Event): (string, string, string) =
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent":
      (p[1], p[2], (if p.len >= 4: p[3] else: ""))
    else: ("", "", "")

  proc driverOf(id: string): Driver = driverFor(intentPolicyOf(events, id))

  for e in ordered:                                    # pass 1 — proposes
    let (id, op, _) = opOf(e)
    if op != "propose" or id.len == 0 or id in result: continue
    inc now
    let effect = effectFromJson(e.value)
    let driver = driverOf(id)
    let ctx = SigningContext(environment: "", account: "coordinated", slot: "0",
                             expiry: high(uint64))
    var it = newIntent(driver, effect, ctx)   # canonicalize dispatches to THIS intent's driver
    it.apply(driver, IntentEvent(kind: iePropose, now: now))
    result[id] = it

  for e in ordered:                                    # pass 2 — contributions
    let (id, op, who) = opOf(e)
    if op != "sig" or id notin result: continue
    let dedup = id & "/" & who
    if dedup in seenSig: continue
    seenSig.incl dedup
    inc now
    let driver = driverOf(id)
    driver.expectMaterialization(result[id].materialization)   # verify against THIS intent (full bytes)
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieContribute, now: now,
                                 contribution: Contribution(bytes: hexToBytes(e.value))))
    result[id] = it

  for e in ordered:                                    # pass 3 — submits
    let (id, op, _) = opOf(e)
    if op != "submit" or id notin result: continue
    inc now
    let driver = driverOf(id)
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieSubmit, now: now))
    result[id] = it

proc intentState*(events: seq[Event], driverFor: DriverFor, intentId: string): string =
  ## The lifecycle state of one intent as a string (draft/proposed/collecting/
  ## executable/…), or "unknown".
  let intents = reduceIntents(events, driverFor)
  if intentId in intents: $intents[intentId].state else: "unknown"

proc roomDriverKinds*(events: seq[Event], driverFor: DriverFor): seq[string] =
  ## The driver kinds the room may use, folded from the log — driver-as-proposal
  ## (invariant 6). The base is the founding capability set; each `add-driver`
  ## governance intent the room APPROVED (reached executable or beyond) admits its
  ## kind. Deterministic: every member derives the same capability set from the same
  ## events, and a capability appears only once the group has actually agreed to it.
  result = @["safe", "threshold"]          # the founding capabilities
  let intents = reduceIntents(events, driverFor)
  for id, it in intents:
    if $it.state notin ["executable", "submitted", "final"]: continue
    let ej = effectJsonOf(events, id)
    if ej.len == 0: continue
    try:
      let j = parseJson(ej)
      if j.kind == JObject and j.hasKey("effect") and j["effect"].getStr() == "add-driver":
        let k = (if j.hasKey("kind"): j["kind"].getStr() else: "")
        if k.len > 0 and k notin result: result.add k
    except CatchableError: discard

# ── render-ready projection (what a card needs, still a pure fold) ─────────────

type IntentView* = object
  ## Everything a proposal card renders, derived from the log alone. It is the
  ## intent fold plus the two facts `reduceIntents` doesn't surface on its own: the
  ## effect the proposal carried, and how many DISTINCT owners have contributed so
  ## far (the "M" against the driver's threshold "N"). Nothing here is per-viewer —
  ## the log doesn't say which owner "you" are — so a card renders the room's shared
  ## truth, never a personalized claim it can't stand behind.
  id*: string
  state*: string          ## draft/proposed/collecting/executable/submitted/final
  effectJson*: string     ## the proposed effect JSON, or "" if not proposed here
  approvals*: int         ## distinct owners folded in (dedup by contributor)
  txhash*: string         ## the driver-re-derived materialization (safeTxHash) as hex —
                          ## the exact bytes an owner signs (F-4/F-5), for the verify view
  policy*: string         ## the policy (driver kind) THIS intent was proposed under

proc reduceIntentViews*(events: seq[Event], driverFor: DriverFor): seq[IntentView] =
  ## Deterministic (sorted by id), so two instances render the identical list from
  ## the same event set (invariant 4). Approvals count DISTINCT contributors — the
  ## same dedup the fold applies — so a re-submitted owner signature never inflates
  ## the "M of N" a card shows. Each view carries the intent's own policy.
  let intents = reduceIntents(events, driverFor)
  var approvals = initTable[string, HashSet[string]]()
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[2] == "sig":
      approvals.mgetOrPut(p[1], initHashSet[string]()).incl(p[3])
  for id, it in intents:
    result.add IntentView(id: id, state: $it.state,
                          effectJson: effectJsonOf(events, id),
                          approvals: approvals.getOrDefault(id).len,
                          txhash: bytesHex(it.materialization.bytes),
                          policy: intentPolicyOf(events, id))
  result.sort(proc (a, b: IntentView): int = cmp(a.id, b.id))

# ── provenance: how this decision's data got in front of you (invariant 10) ────

type ProvItem* = object
  ## One link in a decision's lineage — a log entry that put this intent in front
  ## of the reader, named by the spec's accountability vocabulary (InputClass).
  cls*: InputClass      ## peer-message (the proposal) · driver-contribution (a signature)
  logPos*: int          ## position in the canonical log order the input came from
  account*: string      ## the contributing account — named under mmNamed, "" under mmAnonymous
  accountable*: bool    ## can this input's origin be accounted for? (always true in a live fold)
  what*: string         ## a plain-language label for the reader

proc intentProvenance*(events: seq[Event], driverFor: DriverFor, intentId: string): seq[ProvItem] =
  ## The lineage of a decision, folded from the log: every entry that reached this
  ## intent, in canonical order. The propose carried the effect — a peer message,
  ## sealed to the room's epoch, so only a member could have placed it; each
  ## signature is a driver-contribution the driver verified recovers to a configured
  ## member (a non-owner never reaches the fold). Whether an entry names its account
  ## follows the driver's membership model (6): named for Safe (mmNamed), silent for
  ## an anonymous driver, so the trail never leaks an identity the room wouldn't.
  ## Everything here is accountable by construction — an input whose origin could not
  ## be accounted for would have been refused before signing (invariant 10), so it
  ## would never appear. A duplicate owner signature folds once, exactly as it counts.
  let named = driverFor(intentPolicyOf(events, intentId)).describe().membership == mmNamed
  let ordered = canonicalOrder(events)
  var seenSig = initHashSet[string]()
  for i in 0 ..< ordered.len:
    let p = ordered[i].key.split('/')
    if p.len < 3 or p[0] != "intent" or p[1] != intentId: continue
    if p[2] == "propose":
      result.add ProvItem(cls: icPeerMessage, logPos: i, account: "",
                          accountable: true, what: "the proposed effect")
    elif p[2] == "sig" and p.len >= 4:
      if p[3] in seenSig: continue
      seenSig.incl p[3]
      result.add ProvItem(cls: icContribution, logPos: i,
                          account: (if named: p[3] else: ""),
                          accountable: true, what: "an owner signature")
