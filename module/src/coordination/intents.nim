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
##   propose : "intent/<id>/propose"                   value = effect JSON {to,value,nonce}
##   sign    : "intent/<id>/sig/<contributor>/<round>" value = signature hex
##   submit  : "intent/<id>/submit"                    value = "1"
## A contribution is keyed by contributor AND round, so a duplicate signature from the
## same contributor in the same round folds once, while a multi-round driver (FROST)
## can have the same member contribute in each round. Single-round drivers pass round
## 1, so this is behaviour-preserving for Safe/threshold.

import std/[json, tables, sets, strutils, algorithm]
import ../log/log
import ../intents/lifecycle
import ../intents/materialization
import ../intents/signing_payload
import ../intents/provenance     # InputClass — the spec's accountability vocabulary (inv 10)
import ../drivers/driver
import ../drivers/invoke          # invokeDomain — the invoke effect's schema id
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
      of "invoke":
        # A generic module-action intent: call module.method(args). The schemaId is
        # invokeDomain(module, method), so the signed bytes commit to the specific
        # action (invariant 5 — different method → different schemaId → different
        # bytes). The core executes it after the room endorses it (P-D2). args are
        # stored as their verbatim JSON text: every member folds the SAME propose
        # event, so the materialization is identical across the room, and the
        # execution path reparses the text into the positional lp_invoke args.
        let module = j{"module"}.getStr()
        let meth = j{"method"}.getStr()
        var fields: seq[(string, CborValue)]
        fields.add ("module", cbText(module))
        fields.add ("method", cbText(meth))
        if j.hasKey("args"): fields.add ("args", cbText($j["args"]))
        # LEZ Mode B / any coordinated transfer (exo-45e, drivers/invoke.nim §manifest):
        # carry the `counterparty` field name (which arg holds the recipient) and the
        # `chain`, so the folded effect declares the counterparty address slot the room
        # asks the recipient to fill, plus the proposer's lez-account requirement for a
        # lez:* chain. Committed to the signed bytes (invariant 5) — the recipient the
        # room agreed on is part of what is endorsed, not a post-hoc substitution.
        let cp = j{"counterparty"}.getStr()
        if cp.len > 0:
          fields.add ("counterparty", cbText(cp))
          # The bound recipient arg becomes a FIRST-CLASS effect field, not just an entry in
          # the args blob: the manifest's counterparty slot binds this field (consistency
          # requires the effect to carry it), and — the point — the recipient the room agreed
          # on is committed to the signed bytes (invariant 5), never a post-hoc substitution.
          # Its value comes from args if the proposer already knows it, else empty — the room
          # fills it via coordinate_share_material (K5) before the intent is endorsed.
          var cpVal = ""
          if j.hasKey("args") and j["args"].kind == JObject and j["args"].hasKey(cp):
            cpVal = j["args"][cp].getStr()
          fields.add (cp, cbText(cpVal))
        let chain = j{"chain"}.getStr()
        if chain.len > 0: fields.add ("chain", cbText(chain))
        return Effect(schemaId: invokeDomain(module, meth), fields: fields)
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
                      round = 1, parents: seq[EventId] = @[]): Event =
  ## `round` is the collection round this contribution belongs to. It is part of the
  ## dedup key (one contribution per contributor PER ROUND), so a multi-round driver
  ## (FROST, rounds > 1) can have the same member contribute in each round without the
  ## fold collapsing them into one. Single-round drivers always pass round 1, so the
  ## key is `…/sig/<contributor>/1` and behaviour is unchanged. The signed bytes are
  ## the materialization, never this key, so this does not touch the signing path.
  Event(parents: parents, key: "intent/" & intentId & "/sig/" & contributor & "/" & $round,
        value: signatureHex)

proc submitEvent*(intentId: string, parents: seq[EventId] = @[]): Event =
  Event(parents: parents, key: "intent/" & intentId & "/submit", value: "1")

proc declineEvent*(intentId, who: string, parents: seq[EventId] = @[]): Event =
  ## A member declines to take part in an intent (the card's Deny, exo-002.3). It is
  ## informational: it never blocks the driver's threshold — whether a decline by a
  ## required signer should DROP the intent is driver policy, not core policy. `who`
  ## dedups one decline per member; under a named driver the view names it, under an
  ## anonymous one the caller passes an unlinkable nonce and the view only counts.
  Event(parents: parents, key: "intent/" & intentId & "/decline/" & who, value: "1")

proc finalEvent*(intentId: string, parents: seq[EventId] = @[]): Event =
  ## Published once the on-chain execution is observed final (R-8) — folds the intent
  ## to `final` so every member's card converges on "paid", not just "submitted".
  Event(parents: parents, key: "intent/" & intentId & "/final", value: "1")

proc materialShareEvent*(intentId, reqName, who, public, form, class, field: string,
                         parents: seq[EventId] = @[]): Event =
  ## A participant SHARES a chosen material into the room, bound to an intent
  ## (exo-45e K5, docs/design/material-and-disclosure.md §3.4). This is how counterparty
  ## material — a payee's receiving address, say — enters the log: only its PUBLIC face
  ## and class travel (never a handle, s1), and only on this explicit act (rule s2). It
  ## generalizes the address-share card into a fold-bound event: the value names which
  ## effect `field` it fills, so the composer proposes the complete effect with it bound
  ## in. `who` dedups one share per (requirement, member) — named under a named driver so
  ## the room sees who shared, an unlinkable nonce under an anonymous one (invariant 9).
  Event(parents: parents, key: "intent/" & intentId & "/material/" & reqName & "/" & who,
        value: $(%*{"public": public, "form": form, "class": class, "field": field}))

proc keyBindingEvent*(intentId, contributor, linkHex: string,
                      parents: seq[EventId] = @[]): Event =
  ## Published alongside a keyed contribution (exo-45e K5): the F-14 binding statement
  ## for the authorization key that signed, proving *that* key belongs to the same party
  ## as the contributor's admitted encryption identity (F-14/F-9). Without it the room
  ## sees only that a valid owner signed; with it the room can check the owner is bound to
  ## an admitted member. `contributor` (the recovered signer) dedups one binding per
  ## (intent, key); `linkHex` is `encodeLink(statement)` hex — the binding is epoch-scoped
  ## via its own LinkContext, so a later joiner cannot lift it (invariant 7 holds here too).
  Event(parents: parents, key: "intent/" & intentId & "/binding/" & contributor,
        value: linkHex)

type
  MaterialShare* = object
    reqName*: string     ## the requirement this fills
    who*: string         ## the sharer (named driver) or a nonce (anonymous)
    public*: string      ## the disclosed public face — never a handle
    form*: string
    class*: string
    field*: string       ## the effect field it lands in

proc reduceShares*(events: seq[Event], intentId: string): seq[MaterialShare] =
  ## The materials shared into one intent, folded from the log (idempotent under reorder
  ## / duplication, invariant 4): one per (requirement, sharer), first write wins.
  var seen = initHashSet[string]()
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len >= 5 and p[0] == "intent" and p[1] == intentId and p[2] == "material":
      let dedup = p[3] & "/" & p[4]
      if dedup in seen: continue
      seen.incl dedup
      var pub, form, class, field = ""
      try:
        let j = parseJson(e.value)
        pub = j{"public"}.getStr(); form = j{"form"}.getStr()
        class = j{"class"}.getStr(); field = j{"field"}.getStr()
      except CatchableError: discard
      result.add MaterialShare(reqName: p[3], who: p[4], public: pub, form: form,
                               class: class, field: field)

type
  KeyBinding* = object
    contributor*: string   ## the recovered signer (an owner address) this binding vouches for
    linkHex*: string       ## encodeLink(statement) hex — the F-14 link statement, verifiable

proc reduceBindings*(events: seq[Event], intentId: string): seq[KeyBinding] =
  ## The per-key F-14 bindings published for one intent's contributions, folded from the
  ## log (idempotent under reorder / duplication, invariant 4): one per (intent, key),
  ## first write wins. A card can pair each approval with its binding to show the signer
  ## is an admitted member (F-9), not merely a valid owner.
  var seen = initHashSet[string]()
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == intentId and p[2] == "binding":
      if p[3] in seen: continue
      seen.incl p[3]
      result.add KeyBinding(contributor: p[3], linkHex: e.value)

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

  proc opOf(e: Event): (string, string, string, string) =
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent":
      # id, op, who (p[3]), round (p[4] — "1" when absent, so single-round drivers
      # and any pre-round-tag events dedup by contributor exactly as before).
      (p[1], p[2], (if p.len >= 4: p[3] else: ""), (if p.len >= 5: p[4] else: "1"))
    else: ("", "", "", "")

  proc driverOf(id: string): Driver = driverFor(intentPolicyOf(events, id))

  for e in ordered:                                    # pass 1 — proposes
    let (id, op, _, _) = opOf(e)
    if op != "propose" or id.len == 0 or id in result: continue
    inc now
    let effect = effectFromJson(e.value)
    let driver = driverOf(id)
    let ctx = SigningContext(environment: "", account: "coordinated", slot: "0",
                             expiry: high(uint64))
    var it = newIntent(driver, effect, ctx)   # canonicalize dispatches to THIS intent's driver
    it.apply(driver, IntentEvent(kind: iePropose, now: now))
    result[id] = it

  # pass 2 — contributions, processed in ROUND ORDER (then canonical order within a
  # round). A driver's collection counts contributions positionally against the round
  # it is currently in, so for a MULTI-round driver every round-1 contribution must be
  # folded before any round-2 one — otherwise a member racing ahead could be counted
  # into the wrong round. Sorting by round makes this hold regardless of how canonical
  # order interleaves the events, and stays a pure function of the event SET (inv 4).
  # Single-round drivers put everything in round 1, so this is a no-op for them.
  var sigs: seq[tuple[id, who, value: string, round, ord: int]]
  for i, e in ordered:
    let (id, op, who, roundStr) = opOf(e)
    if op != "sig" or id notin result: continue
    var r = 1
    try: r = parseInt(roundStr) except CatchableError: discard
    sigs.add (id: id, who: who, value: e.value, round: r, ord: i)
  sigs.sort(proc (a, b: auto): int =
    (if a.round != b.round: cmp(a.round, b.round) else: cmp(a.ord, b.ord)))
  for s in sigs:
    let dedup = s.id & "/" & $s.round & "/" & s.who      # one contribution per (contributor, round)
    if dedup in seenSig: continue
    seenSig.incl dedup
    inc now
    let driver = driverOf(s.id)
    driver.expectMaterialization(result[s.id].materialization)   # verify against THIS intent (full bytes)
    var it = result[s.id]
    it.apply(driver, IntentEvent(kind: ieContribute, now: now,
                                 contribution: Contribution(bytes: hexToBytes(s.value))))
    result[s.id] = it

  for e in ordered:                                    # pass 3 — submits
    let (id, op, _, _) = opOf(e)
    if op != "submit" or id notin result: continue
    inc now
    let driver = driverOf(id)
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieSubmit, now: now))
    result[id] = it

  for e in ordered:                                    # pass 4 — finals (on-chain settled)
    let (id, op, _, _) = opOf(e)
    if op != "final" or id notin result: continue
    inc now
    let driver = driverOf(id)
    var it = result[id]
    it.apply(driver, IntentEvent(kind: ieFinal, now: now))   # submitted/settling → final ("paid")
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
  result = @["safe", "threshold", "frost", "invoke", "eip191"]   # the founding capabilities
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
  round*: int             ## the collection's current round, 1-based
  rounds*: int            ## how many rounds this driver runs (describe().rounds; 1 = single-round)
  roundApprovals*: int    ## distinct contributors folded in THE CURRENT round — the honest
                          ## "M of N this round" for a multi-round driver; equals `approvals`
                          ## when rounds == 1
  declines*: int          ## distinct members who declined to take part (informational)
  decliners*: seq[string] ## who declined — ONLY under a named driver; empty under anonymous (inv 9)

proc reduceIntentViews*(events: seq[Event], driverFor: DriverFor): seq[IntentView] =
  ## Deterministic (sorted by id), so two instances render the identical list from
  ## the same event set (invariant 4). Approvals count DISTINCT contributors — the
  ## same dedup the fold applies — so a re-submitted owner signature never inflates
  ## the "M of N" a card shows. Each view carries the intent's own policy.
  let intents = reduceIntents(events, driverFor)
  var approvals = initTable[string, HashSet[string]]()            # <id> -> distinct contributors (any round)
  var roundApp = initTable[string, HashSet[string]]()            # "<id>/<round>" -> contributors that round
  var declined = initTable[string, HashSet[string]]()            # <id> -> distinct decliners
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[2] == "sig":
      approvals.mgetOrPut(p[1], initHashSet[string]()).incl(p[3])
      let rnd = (if p.len >= 5: p[4] else: "1")
      roundApp.mgetOrPut(p[1] & "/" & rnd, initHashSet[string]()).incl(p[3])
    elif p.len >= 4 and p[0] == "intent" and p[2] == "decline":
      declined.mgetOrPut(p[1], initHashSet[string]()).incl(p[3])
  for id, it in intents:
    let pol = intentPolicyOf(events, id)
    let desc = driverFor(pol).describe()
    let curRound = it.collection.round
    var decliners: seq[string]
    if desc.membership == mmNamed:
      for w in declined.getOrDefault(id, initHashSet[string]()): decliners.add w
      decliners.sort()
    result.add IntentView(id: id, state: $it.state,
                          effectJson: effectJsonOf(events, id),
                          approvals: approvals.getOrDefault(id).len,
                          txhash: bytesHex(it.materialization.bytes),
                          policy: pol,
                          round: curRound,
                          rounds: desc.rounds,
                          roundApprovals: roundApp.getOrDefault(id & "/" & $curRound, initHashSet[string]()).len,
                          declines: declined.getOrDefault(id, initHashSet[string]()).len,
                          decliners: decliners)
  result.sort(proc (a, b: IntentView): int = cmp(a.id, b.id))

# ── activity: how the room reached its state (the education seam) ──────────────
# A human-readable narrative of every state transition on the coordination log, in
# canonical (causal) order — proposed, each approval (running count, and who under a
# named driver), threshold reached, submitted on-chain, settled. This is not a new
# source of truth: it is the SAME reduce(log) the cards are drawn from, retold as a
# timeline, so a member can see how the room got where it is and watch it change as
# it happens. Deterministic and idempotent (invariant 4): two members fold the
# identical timeline. Membership changes (join/admit/re-key) are transport control
# frames, not log events, so they do not appear here yet — see the follow-up.

type
  ActivityEntry* = object
    seq*: int            ## canonical log index — the stable ordering key (inv 4)
    order*: int          ## tiebreak within one index (a derived line after its trigger)
    kind*: string        ## "propose" | "approve" | "decline" | "ready" | "submit" | "settled" | "admit"
    intentId*: string    ## the intent this concerns
    account*: string     ## the contributor, named only where the driver is mmNamed, else ""
    title*: string       ## the plain-language headline
    detail*: string      ## a supporting line (may be "")

proc shortId(s: string): string =
  ## A short, stable handle for a long hex id (an owner address / identity).
  if s.len > 12: s[0 ..< 6] & "…" & s[^4 .. ^1] else: s

proc activityEffectLabel(events: seq[Event], id: string): string =
  ## A short summary of an intent's effect for the activity feed — honest about the
  ## three effect shapes (payment / statement / add-driver), never fabricated.
  let ej = effectJsonOf(events, id)
  if ej.len == 0: return "a proposal"
  try:
    let j = parseJson(ej)
    let kind = if j.hasKey("effect"): j["effect"].getStr() else: ""
    if kind == "statement":
      let t = if j.hasKey("text"): j["text"].getStr() else: ""
      return "a statement: “" & t & "”"
    if kind == "add-driver":
      let k = if j.hasKey("kind"): j["kind"].getStr() else: "?"
      return "a new policy: " & k
    let val = if j.hasKey("value"): $j["value"] else: "0"
    let to = if j.hasKey("to"): j["to"].getStr() else: ""
    return "a payment: " & val & " → " & shortId(to)
  except CatchableError:
    return "a proposal"

proc reduceActivity*(events: seq[Event], driverFor: DriverFor): seq[ActivityEntry] =
  ## The room's coordination history as reduce(log). See the section note above.
  let ordered = canonicalOrder(events)
  let folded = reduceIntents(events, driverFor)
  var approvers = initTable[string, HashSet[string]]()   # id -> {who/round} seen
  var lastSig = initTable[string, int]()                 # id -> index of its last sig
  var proposeSeq = initTable[string, int]()              # id -> index of its propose (groups the intent's lines together, in the order intents were proposed)
  for i in 0 ..< ordered.len:
    let p = ordered[i].key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      # a membership transition, from the log itself (exo-275 / M4)
      result.add ActivityEntry(seq: i, order: 0, kind: "admit", intentId: "",
        account: p[3], title: "A member was admitted — room re-keyed to epoch " & p[1],
        detail: "they read from here on, nothing before (F-16)")
      continue
    if p.len < 3 or p[0] != "intent": continue
    let id = p[1]
    let op = p[2]
    if op == "policy": continue        # the policy decl rides with the propose line
    let desc = driverFor(intentPolicyOf(events, id)).describe()
    let named = desc.membership == mmNamed
    case op
    of "propose":
      proposeSeq[id] = i
      result.add ActivityEntry(seq: i, order: 0, kind: "propose", intentId: id,
        account: "", title: "Proposed " & activityEffectLabel(events, id),
        detail: "under the " & intentPolicyOf(events, id) & " policy")
    of "sig":
      if p.len < 4: continue
      let who = p[3]
      let rnd = if p.len >= 5: p[4] else: "1"
      if id notin approvers: approvers[id] = initHashSet[string]()
      let dkey = who & "/" & rnd
      if dkey in approvers[id]: continue     # one contribution per (contributor, round)
      approvers[id].incl dkey
      lastSig[id] = i
      var distinctWho = initHashSet[string]()
      for k in approvers[id]: distinctWho.incl k.split('/')[0]
      result.add ActivityEntry(seq: i, order: 0, kind: "approve", intentId: id,
        account: (if named: who else: ""),
        title: (if named: "Approved by " & shortId(who) else: "An owner approved"),
        detail: $distinctWho.len & " of " & $desc.threshold & " needed" &
                (if desc.rounds > 1: "  ·  round " & rnd & " of " & $desc.rounds else: ""))
    of "decline":
      if p.len < 4: continue
      result.add ActivityEntry(seq: i, order: 0, kind: "decline", intentId: id,
        account: (if named: p[3] else: ""),
        title: (if named: "Declined by " & shortId(p[3]) else: "A member declined"),
        detail: "chose not to take part — the threshold is unchanged")
    of "submit":
      result.add ActivityEntry(seq: i, order: 0, kind: "submit", intentId: id,
        account: "", title: "Submitted on-chain",
        detail: "the Safe execTransaction was sent through the RPC")
    of "final":
      result.add ActivityEntry(seq: i, order: 0, kind: "settled", intentId: id,
        account: "", title: "Settled on-chain", detail: "final — the payment landed")
    else: discard
  # Derived "ready" line: narrate the threshold being met, positioned right after the
  # intent's last approval. Authoritative from the fold's own state — never a
  # re-implemented count that could diverge from the driver's finality (invariant 6).
  for id, it in folded:
    if id notin lastSig: continue
    if $it.state in ["executable", "submitted", "settling", "final"]:
      result.add ActivityEntry(seq: lastSig[id], order: 1, kind: "ready", intentId: id,
        account: "", title: "Ready — the approvals are collected", detail: "")
  # Order for reading, not by content hash. canonicalOrder among these events is
  # smallest-id-first (they carry no parent links), which scrambles a proposal's
  # lifecycle — an approval could sort before its propose. Instead: group every line
  # of one intent together (by where the intent was proposed), and within the group
  # walk the lifecycle — proposed → approvals → ready → submitted → settled. A
  # membership admit has no intent, so it sits at its own position. Deterministic (a
  # pure function of the event set, invariant 4) and chronological for the common
  # single-intent flow; interleaved multi-intent timing without an authored clock is
  # a known limit (the log carries no wall-clock on coordination events).
  proc lifecycleRank(kind: string): int =
    case kind
    of "propose": 0
    of "approve", "decline": 1
    of "ready": 2
    of "submit": 3
    of "settled": 4
    else: 0                       # admit / anything else: no intra-intent phase
  proc groupOrder(e: ActivityEntry): int =
    if e.intentId.len > 0 and e.intentId in proposeSeq: proposeSeq[e.intentId] else: e.seq
  result.sort(proc (a, b: ActivityEntry): int =
    let ga = groupOrder(a)
    let gb = groupOrder(b)
    if ga != gb: return cmp(ga, gb)
    let ra = lifecycleRank(a.kind)
    let rb = lifecycleRank(b.kind)
    if ra != rb: return cmp(ra, rb)
    if a.seq != b.seq: return cmp(a.seq, b.seq)
    cmp(a.order, b.order))

# ── provenance: how this decision's data got in front of you (invariant 10) ────

type ProvItem* = object
  ## One link in a decision's lineage — a log entry that put this intent in front
  ## of the reader, named by the spec's accountability vocabulary (InputClass).
  cls*: InputClass      ## peer-message (the proposal) · driver-contribution (a signature)
  logPos*: int          ## position in the canonical log order the input came from
  account*: string      ## the contributing account — named under mmNamed, "" under mmAnonymous
  accountable*: bool    ## can this input's origin be accounted for? (always true in a live fold)
  what*: string         ## a plain-language label for the reader
  detail*: string       ## the concrete content — the effect summary for a proposal, the round for a signature
  guarantee*: string    ## WHY this input can be trusted, by class — the guarantee the code enforces

proc summarizeEffect*(effectJson: string): string =
  ## A one-line, human summary of what a proposal would do — so its provenance entry
  ## reads "pay 1000 to 0x…", not "the proposed effect". Pure, from the effect JSON.
  try:
    let j = parseJson(effectJson)
    if j.kind != JObject: return ""
    case j{"effect"}.getStr("transfer")
    of "statement":  return "a statement: \"" & j{"text"}.getStr() & "\""
    of "invoke":     return "call " & j{"module"}.getStr() & "." & j{"method"}.getStr() & "(…)"
    of "add-driver": return "admit the driver kind: " & j{"kind"}.getStr()
    else:
      if j.hasKey("to") or j.hasKey("value"):
        return "pay " & $j{"value"}.getInt() & " to " & j{"to"}.getStr()
  except CatchableError: discard
  ""

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
                          accountable: true, what: "the proposal",
                          detail: summarizeEffect(ordered[i].value),
                          guarantee: "sealed to the room's epoch — only a member could have placed it")
    elif p[2] == "sig" and p.len >= 4:
      if p[3] in seenSig: continue
      seenSig.incl p[3]
      let round = (if p.len >= 5: p[4] else: "1")
      result.add ProvItem(cls: icContribution, logPos: i,
                          account: (if named: p[3] else: ""),
                          accountable: true, what: "an approval",
                          detail: (if round != "1": "round " & round else: ""),
                          guarantee: "the driver verified this recovers to a configured member — a non-member never reaches the fold")

# ── provenance for EVERY action (M4, exo-002.4): the room-wide lineage ──────────
# intentProvenance answers "how did THIS decision get in front of me"; this answers
# it for every entry in the log — messages, proposals, signatures, declines,
# policy declarations, submits/finals (external reads: the chain's answer as the
# room observed it), and membership transitions — each classed by the F-20
# vocabulary and graded by the guarantee the code actually enforces. Honest about
# attribution: a message's author is what its sender wrote inside a room-sealed
# envelope (any epoch holder could have written it); only a driver-verified
# signature proves WHO. Named accounts follow the driver's membership model.

type LogProvItem* = object
  seq*: int               ## canonical log position
  cls*: InputClass
  kind*: string           ## message · propose · sig · decline · policy · submit · final · admit
  intentId*: string       ## "" for a message / membership entry
  account*: string        ## named only where the guarantee lets us name it
  accountable*: bool
  what*: string
  detail*: string
  guarantee*: string
  epoch*: int             ## the membership epoch the entry belongs to (0 = the founding epoch)

proc membershipEvent*(epoch: int, joinerHex: string, parents: seq[EventId] = @[]): Event =
  ## Recorded by the admitting member right after re-keying (exo-275): sealed under
  ## the NEW epoch, so the joiner reads its own admission and nothing before it (F-16).
  Event(parents: parents, key: "membership/" & $epoch & "/admit/" & joinerHex, value: "1")

proc logProvenance*(events: seq[Event], driverFor: DriverFor): seq[LogProvItem] =
  let ordered = canonicalOrder(events)
  var epoch = 0
  var seenSig = initHashSet[string]()
  var seenDecline = initHashSet[string]()
  for i in 0 ..< ordered.len:
    let e = ordered[i]
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      try: epoch = max(epoch, parseInt(p[1]))
      except ValueError: discard
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "admit", account: p[3],
        accountable: true, what: "a member was admitted",
        detail: "room re-keyed to epoch " & p[1],
        guarantee: "sealed under the new epoch by the admitting member — the joiner reads from here on, nothing before (F-16)",
        epoch: epoch)
      continue
    if p.len >= 2 and p[0] == "message":
      var author = ""
      try:
        let j = parseJson(e.value)
        if j.kind == JObject: author = j{"author"}.getStr()
      except CatchableError: discard
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "message", account: author,
        accountable: true, what: "a message",
        detail: "",
        guarantee: "sealed to the room's epoch — a member placed it; the author is what the sender wrote, not a verified signature",
        epoch: epoch)
      continue
    if p.len < 3 or p[0] != "intent": continue
    let id = p[1]
    let desc = driverFor(intentPolicyOf(events, id)).describe()
    let named = desc.membership == mmNamed
    case p[2]
    of "propose":
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "propose", intentId: id,
        accountable: true, what: "a proposal", detail: summarizeEffect(e.value),
        guarantee: "sealed to the room's epoch — only a member could have placed it; the materialization is re-derived by every client (F-4)",
        epoch: epoch)
    of "policy":
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "policy", intentId: id,
        accountable: true, what: "the policy this intent runs under", detail: e.value,
        guarantee: "sealed to the room's epoch; every member folds the identical driver (invariant 6)",
        epoch: epoch)
    of "sig":
      if p.len < 4 or (id & "/" & p[3]) in seenSig: continue
      seenSig.incl(id & "/" & p[3])
      result.add LogProvItem(seq: i, cls: icContribution, kind: "sig", intentId: id,
        account: (if named: p[3] else: ""), accountable: true, what: "an approval",
        detail: (if p.len >= 5 and p[4] != "1": "round " & p[4] else: ""),
        guarantee: "the driver verified this recovers to a configured member — a non-member never reaches the fold",
        epoch: epoch)
    of "decline":
      if p.len < 4 or (id & "/" & p[3]) in seenDecline: continue
      seenDecline.incl(id & "/" & p[3])
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "decline", intentId: id,
        account: (if named: p[3] else: ""), accountable: true, what: "a decline",
        detail: "", guarantee: "sealed to the room's epoch; informational — the threshold is unchanged",
        epoch: epoch)
    of "material":
      if p.len < 5: continue
      var field = ""
      try: field = parseJson(e.value){"field"}.getStr()
      except CatchableError: discard
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "material", intentId: id,
        account: (if named: p[4] else: ""), accountable: true,
        what: "shared material for '" & (if field.len > 0: field else: p[3]) & "'",
        detail: "",
        guarantee: "sealed to the room's epoch; the room learns the PUBLIC face the sharer chose (never a handle), not that it is theirs — only a driver-verified signature proves control (F-20)",
        epoch: epoch)
    of "binding":
      if p.len < 4: continue
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "binding", intentId: id,
        account: (if named: p[3] else: ""), accountable: true,
        what: "a key-binding for an approval",
        detail: "",
        guarantee: "the authorization key that signed is bound by a secp signature to the member's admitted encryption identity — the room can check the approval came from an admitted member, not merely a valid owner (F-14, F-9); scoped to this epoch (invariant 7)",
        epoch: epoch)
    of "submit":
      result.add LogProvItem(seq: i, cls: icExternalRead, kind: "submit", intentId: id,
        accountable: true, what: "submitted outside the room",
        detail: "", guarantee: "an external read: the submitting member's report of what it sent — the chain's answer arrives as final",
        epoch: epoch)
    of "final":
      result.add LogProvItem(seq: i, cls: icExternalRead, kind: "final", intentId: id,
        accountable: true, what: "settled outside the room",
        detail: "", guarantee: "an external read: observed from the chain (R-8), never asserted; graded attested unless proof-checked (F-10)",
        epoch: epoch)
    else: discard
