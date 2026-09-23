## Intent events and the pure helpers over them — what a participant publishes and
## how a single event is read back (split out of intents.nim for exo-ef1, so the
## attestation layer can use them while the fold in intents.nim uses attestations).
## intents.nim re-exports all of this; import intents, not this, from outside.

import std/[json, sets, strutils, algorithm]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ../drivers/invoke          # invokeDomain — the invoke effect's schema id
import ../dcbor/dcbor
import ../hashing/keccak256

type DriverFor* = proc(kind: string): Driver
  ## Resolve a policy kind to its driver. Each intent folds under the driver of the
  ## policy it was proposed with — the intent is the policy boundary.

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

proc effectSchema*(effectJson: string): tuple[id: string, known: bool] =
  ## The declared schema id of an activity, and whether muster RECOGNIZES it (exo-1ec.3).
  ## An activity renders only from a declared, versioned schema; an unrecognized one must
  ## get a NAMED "schema unknown" failure, never a silent fallback that renders it as
  ## something it is not. v0 uses hand-assigned ids (ADR-009), so "known" means the id is
  ## in the v0 vocabulary — not a parsed CDDL root; this is the rendering gate, and does
  ## not touch the signing/fold path (effectFromJson still canonicalizes for the driver).
  ## A malformed effect, or an `effect` value we don't have a schema for, is `known:false`
  ## and the id names what was declared so the failure can say exactly what it saw.
  try:
    let j = parseJson(effectJson)
    if j.kind != JObject: return ("muster.effect.unknown.v0", false)
    if not j.hasKey("effect"): return ("muster.effect.transfer.v1", true)  # legacy plain {to,value,nonce}
    let kind = j["effect"].getStr()
    case kind
    of "transfer": return ("muster.effect.transfer.v1", true)
    of "statement": return ("muster.effect.statement.v1", true)
    of "add-driver": return ("muster.effect.governance.add-driver.v1", true)
    of "invoke":
      let m = j{"module"}.getStr()
      let meth = j{"method"}.getStr()
      # the invoke FAMILY is a declared schema; a missing module/method is malformed → named.
      if m.len > 0 and meth.len > 0: return (invokeDomain(m, meth), true)
      return ("muster.invoke.?.?.v1", false)
    else:
      # an `effect` value muster has no schema for — name it, do not coerce it to a transfer.
      return ("muster.effect." & (if kind.len > 0: kind else: "?") & ".v?", false)
  except CatchableError:
    return ("muster.effect.unknown.v0", false)

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

proc submitEvent*(intentId: string, parents: seq[EventId] = @[], chainRef = ""): Event =
  ## `chainRef` is what the settlement can be looked up by outside the room (the tx
  ## hash). Older events carry "1": the chain reference is then unknown (exo-403).
  Event(parents: parents, key: "intent/" & intentId & "/submit",
        value: (if chainRef.len > 0: chainRef else: "1"))

proc declineEvent*(intentId, who: string, parents: seq[EventId] = @[]): Event =
  ## A member declines to take part in an intent (the card's Deny, exo-002.3). It is
  ## informational: it never blocks the driver's threshold — whether a decline by a
  ## required signer should DROP the intent is driver policy, not core policy. `who`
  ## dedups one decline per member, and the view names who declined.
  Event(parents: parents, key: "intent/" & intentId & "/decline/" & who, value: "1")

proc finalEvent*(intentId: string, parents: seq[EventId] = @[], chainRef = ""): Event =
  ## Published once the on-chain execution is observed final (R-8) — folds the intent
  ## to `final` so every member's card converges on "paid", not just "submitted".
  Event(parents: parents, key: "intent/" & intentId & "/final",
        value: (if chainRef.len > 0: chainRef else: "1"))

proc materialShareEvent*(intentId, reqName, who, public, form, class, field: string,
                         parents: seq[EventId] = @[]): Event =
  ## A participant SHARES a chosen material into the room, bound to an intent
  ## (exo-45e K5, docs/design/material-and-disclosure.md §3.4). This is how counterparty
  ## material — a payee's receiving address, say — enters the log: only its PUBLIC face
  ## and class travel (never a handle, s1), and only on this explicit act (rule s2). It
  ## generalizes the address-share card into a fold-bound event: the value names which
  ## effect `field` it fills, so the composer proposes the complete effect with it bound
  ## in. `who` dedups one share per (requirement, member) and names the sharer, so the
  ## room sees who shared.
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
    who*: string         ## the sharer
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
