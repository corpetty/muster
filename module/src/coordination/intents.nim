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
export lifecycle.Intent, lifecycle.LifecycleState
export provenance.InputClass    # so consumers can name a lineage entry's class

import ./intent_events
export intent_events
import ./attest                   # live attestations: the fold's gate + every surface's grade (exo-ef1)
export attest

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

# ── the fold: intent lifecycle = reduce(log) ──────────────────────────────────


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
  # The attestation gate (invariant 10 on the live path, exo-ef1): an approval that
  # carries muster attestations counts only if one of them verifies against the P this
  # fold re-derives from the log — a forged, mismatched, cross-intent or cross-room
  # attestation leaves the approval uncounted. An approval with NO attestation was
  # signed outside muster (pasted): it counts, and every surface grades it unattested.
  var payloads = initTable[string, seq[byte]]()
  proc payloadOf(id: string): seq[byte] =
    if id notin payloads: payloads[id] = attestationPayload(events, driverFor, id)
    payloads[id]
  var attests = initTable[string, seq[string]]()        # "<id>/<who>/<round>" -> attestation hex
  for e in ordered:
    let p = e.key.split('/')
    if p.len >= 5 and p[0] == "intent" and p[2] == "attest":
      attests.mgetOrPut(p[1] & "/" & p[3] & "/" & p[4], @[]).add e.value
  for s in sigs:
    let dedup = s.id & "/" & $s.round & "/" & s.who      # one contribution per (contributor, round)
    if dedup in seenSig: continue
    seenSig.incl dedup
    let ak = s.id & "/" & s.who & "/" & $s.round
    if ak in attests:
      var ok = false
      for a in attests[ak]:
        if verifyAttestation(s.who, payloadOf(s.id), a): ok = true
      if not ok: continue                                # rejected: attested, but not over P
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
  decliners*: seq[string] ## who declined, sorted
  schemaId*: string       ## the effect's declared schema id (v0 vocabulary, ADR-009)
  committed*: int         ## approvals whose muster attestation verifies over the re-derived P (exo-ef1)
  unattested*: int        ## approvals pasted from outside muster — counted, never shown as committed
  schemaKnown*: bool      ## whether muster recognizes that schema — false ⇒ the card renders a
                          ## NAMED "schema unknown" failure, never the effect body (exo-1ec.3)

proc reduceIntentViews*(events: seq[Event], driverFor: DriverFor): seq[IntentView] =
  ## Deterministic (sorted by id), so two instances render the identical list from
  ## the same event set (invariant 4). Approvals count DISTINCT contributors — the
  ## same dedup the fold applies — so a re-submitted owner signature never inflates
  ## the "M of N" a card shows. Each view carries the intent's own policy.
  let intents = reduceIntents(events, driverFor)
  var declined = initTable[string, HashSet[string]]()            # <id> -> distinct decliners
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[2] == "decline":
      declined.mgetOrPut(p[1], initHashSet[string]()).incl(p[3])
  for id, it in intents:
    let pol = intentPolicyOf(events, id)
    let desc = driverFor(pol).describe()
    let curRound = it.collection.round
    var decliners: seq[string]
    for w in declined.getOrDefault(id, initHashSet[string]()): decliners.add w
    decliners.sort()
    let ej = effectJsonOf(events, id)
    let sch = effectSchema(ej)
    # Approvals come from the grades, so a rejected (mis-attested) approval never
    # inflates the "M of N" — the card counts what the fold counts.
    var approvers, roundApprovers: HashSet[string]
    var committed, unattested = 0
    for g in approvalGrades(events, driverFor, id):
      if g.grade == agRejected: continue
      approvers.incl g.who
      if g.round == curRound: roundApprovers.incl g.who
      if g.grade == agCommitted: inc committed else: inc unattested
    result.add IntentView(id: id, state: $it.state,
                          effectJson: ej,
                          approvals: approvers.len,
                          committed: committed,
                          unattested: unattested,
                          txhash: bytesHex(it.materialization.bytes),
                          policy: pol,
                          round: curRound,
                          rounds: desc.rounds,
                          roundApprovals: roundApprovers.len,
                          declines: declined.getOrDefault(id, initHashSet[string]()).len,
                          decliners: decliners,
                          schemaId: sch.id,
                          schemaKnown: sch.known)
  result.sort(proc (a, b: IntentView): int = cmp(a.id, b.id))

proc intentViewJson*(v: IntentView, desc: DriverDescriptor): JsonNode =
  ## The driver-generic part of a card's JSON (coordinate_intents): what every intent
  ## renders regardless of rail. The glue adds the rail-specific extras (n, chain id,
  ## Safe address). Lifted out of the glue so the card's payload is probeable (exo-ef1).
  %*{"id": v.id, "state": v.state,
     "threshold": desc.threshold, "approvals": v.approvals,
     "policy": v.policy, "domain": desc.serializationDomain,
     "txhash": v.txhash,
     # multi-round (FROST): the round being collected, the total, and the distinct
     # approvals THIS round. For single-round drivers rounds == 1 and the UI ignores it.
     "round": v.round, "rounds": v.rounds, "roundApprovals": v.roundApprovals,
     # who declined to take part
     "declines": v.declines, "decliners": v.decliners,
     # the declared schema id + whether muster recognizes it. false ⇒ the card renders
     # a NAMED "schema unknown" failure, never the effect body (exo-1ec.3).
     "schemaId": v.schemaId, "schemaKnown": v.schemaKnown,
     # how many approvals commit to their inputs (a verified muster attestation) vs
     # were signed outside muster and pasted in (exo-ef1) — never shown as committed.
     "committed": v.committed, "unattested": v.unattested}

# ── activity: how the room reached its state (the education seam) ──────────────
# A human-readable narrative of every state transition on the coordination log, in
# canonical (causal) order — proposed, each approval (running count, and who),
# threshold reached, submitted on-chain, settled. This is not a new
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
    account*: string     ## the contributor (approve / decline), else ""
    title*: string       ## the plain-language headline
    detail*: string      ## a supporting line (may be "")
    attestation*: string ## approve entries: "committed" | "unattested" (exo-ef1); "" otherwise

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

proc gradeLookup(events: seq[Event], driverFor: DriverFor): proc (id, who, round: string): string =
  ## Memoized per-intent approval grades, keyed "<who>/<round>" (exo-ef1).
  var cache = initTable[string, Table[string, string]]()
  result = proc (id, who, round: string): string =
    if id notin cache:
      var t = initTable[string, string]()
      for g in approvalGrades(events, driverFor, id): t[g.who & "/" & $g.round] = $g.grade
      cache[id] = t
    cache[id].getOrDefault(who & "/" & round, "")

proc reduceActivity*(events: seq[Event], driverFor: DriverFor): seq[ActivityEntry] =
  ## The room's coordination history as reduce(log). See the section note above.
  let ordered = canonicalOrder(events)
  let folded = reduceIntents(events, driverFor)
  let gradeOf = gradeLookup(events, driverFor)
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
      let grade = gradeOf(id, who, rnd)
      if grade == $agRejected: continue      # the fold didn't count it; neither does the story
      approvers[id].incl dkey
      lastSig[id] = i
      var distinctWho = initHashSet[string]()
      for k in approvers[id]: distinctWho.incl k.split('/')[0]
      result.add ActivityEntry(seq: i, order: 0, kind: "approve", intentId: id,
        account: who, attestation: grade,
        title: "Approved by " & shortId(who),
        detail: $distinctWho.len & " of " & $desc.threshold & " needed" &
                (if desc.rounds > 1: "  ·  round " & rnd & " of " & $desc.rounds else: ""))
    of "decline":
      if p.len < 4: continue
      result.add ActivityEntry(seq: i, order: 0, kind: "decline", intentId: id,
        account: p[3],
        title: "Declined by " & shortId(p[3]),
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
  account*: string      ## the contributing account ("" for the proposal)
  accountable*: bool    ## can this input's origin be accounted for? (always true in a live fold)
  what*: string         ## a plain-language label for the reader
  detail*: string       ## the concrete content — the effect summary for a proposal, the round for a signature
  guarantee*: string    ## WHY this input can be trusted, by class — the guarantee the code enforces
  attestation*: string    ## sig entries: "committed" | "unattested" | "rejected" (exo-ef1); "" otherwise

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
  ## member (a non-owner never reaches the fold), and names that member — the trail
  ## stays inside the room's epoch, which is the boundary (invariant 7).
  ## Everything here is accountable by construction — an input whose origin could not
  ## be accounted for would have been refused before signing (invariant 10), so it
  ## would never appear. A duplicate owner signature folds once, exactly as it counts.
  let ordered = canonicalOrder(events)
  let gradeOf = gradeLookup(events, driverFor)
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
      let round = (if p.len >= 5: p[4] else: "1")
      let grade = gradeOf(intentId, p[3], round)
      if grade == $agRejected: continue      # attested, but not over P: it never reached the decision
      seenSig.incl p[3]
      result.add ProvItem(cls: icContribution, logPos: i,
                          account: p[3], attestation: grade,
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
# signature proves WHO.

type LogProvItem* = object
  seq*: int               ## canonical log position
  cls*: InputClass
  kind*: string           ## message · propose · sig · decline · policy · submit · final · admit
  intentId*: string       ## "" for a message / membership entry
  account*: string        ## who: a verified signer, or the author/sharer a sealed entry claims
  accountable*: bool
  what*: string
  detail*: string
  guarantee*: string
  epoch*: int             ## the membership epoch the entry belongs to (0 = the founding epoch)
  attestation*: string    ## sig entries: "committed" | "unattested" | "rejected" (exo-ef1); "" otherwise

proc membershipEvent*(epoch: int, joinerHex: string, parents: seq[EventId] = @[]): Event =
  ## Recorded by the admitting member right after re-keying (exo-275): sealed under
  ## the NEW epoch, so the joiner reads its own admission and nothing before it (F-16).
  Event(parents: parents, key: "membership/" & $epoch & "/admit/" & joinerHex, value: "1")

proc logProvenance*(events: seq[Event], driverFor: DriverFor): seq[LogProvItem] =
  let ordered = canonicalOrder(events)
  let gradeOf = gradeLookup(events, driverFor)
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
        account: p[3], accountable: true, what: "an approval",
        attestation: gradeOf(id, p[3], (if p.len >= 5: p[4] else: "1")),
        detail: (if p.len >= 5 and p[4] != "1": "round " & p[4] else: ""),
        guarantee: "the driver verified this recovers to a configured member — a non-member never reaches the fold",
        epoch: epoch)
    of "decline":
      if p.len < 4 or (id & "/" & p[3]) in seenDecline: continue
      seenDecline.incl(id & "/" & p[3])
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "decline", intentId: id,
        account: p[3], accountable: true, what: "a decline",
        detail: "", guarantee: "sealed to the room's epoch; informational — the threshold is unchanged",
        epoch: epoch)
    of "material":
      if p.len < 5: continue
      var field = ""
      try: field = parseJson(e.value){"field"}.getStr()
      except CatchableError: discard
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "material", intentId: id,
        account: p[4], accountable: true,
        what: "shared material for '" & (if field.len > 0: field else: p[3]) & "'",
        detail: "",
        guarantee: "sealed to the room's epoch; the room learns the PUBLIC face the sharer chose (never a handle), not that it is theirs — only a driver-verified signature proves control (F-20)",
        epoch: epoch)
    of "binding":
      if p.len < 4: continue
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "binding", intentId: id,
        account: p[3], accountable: true,
        what: "a key-binding for an approval",
        detail: "",
        guarantee: "the authorization key that signed is bound by a secp signature to the member's admitted encryption identity — the room can check the approval came from an admitted member, not merely a valid owner (F-14, F-9); scoped to this epoch (invariant 7)",
        epoch: epoch)
    of "context":
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "context", intentId: id,
        accountable: true, what: "the context approvals bind to", detail: e.value,
        guarantee: "sealed to the room's epoch by the proposer; every attestation commits to it, so an approval is worthless in any other environment, account, slot, or after expiry (invariant 2)",
        epoch: epoch)
    of "read":
      result.add LogProvItem(seq: i, cls: icExternalRead, kind: "read", intentId: id,
        accountable: true, what: "an outside read that reached the proposal",
        detail: (if p.len >= 4: p[3] else: ""),
        guarantee: "an external read: what the proposer's source reported, recorded so its origin is accountable — not proof the world agrees (F-10)",
        epoch: epoch)
    of "attest":
      if p.len < 5: continue
      result.add LogProvItem(seq: i, cls: icPeerMessage, kind: "attest", intentId: id,
        account: p[3], accountable: true, what: "a member's commitment to an approval's inputs",
        attestation: gradeOf(id, p[3], p[4]),
        detail: "", guarantee: "signed by the approving key over the context, the materialization, and the provenance of every input (invariants 2 and 10); every member re-derives what it must cover",
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
