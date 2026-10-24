## The room map's projection (epic exo-dde, docs/design/room-map.md §4): the room as
## nodes and edges, folded from the log. It adds no truth of its own. It joins the folds
## that already exist — logProvenance (who placed each entry, on what guarantee),
## reduceFlow (who could see what, and where it left), reduceIntentViews (each
## intent's state), reduceAccounts and the membership events — into one graph a view
## can draw and replay.
##
## Rules it keeps:
##  * Every node and edge carries the canonical position (`seq`) it appears at, so a
##    view replays reduce(log[0..k]) by filtering on seq ≤ k and never computes state.
##  * Nodes are keyed by content id (an entry), intent id, CAIP-10 or member identity —
##    never by seq, which shifts when an earlier-sorting event arrives (exo-ef1).
##  * The content, all of it: the map is local, read by this member's own client, so each
##    entry carries its value, parsed — message text, the effect, context, read values,
##    signatures, chain references, payment reports, shared material, account details —
##    beside its structure. It carries nothing the member's client did not decrypt. One kind
##    is the exception: an entry under voice/ carries a voice note's metadata alone, never
##    its half of the clip (docs/design/voice-notes.md §10; voice.voiceContentOf, read off
##    the header the room's voice memo holds for a part), since any caller can read the map
##    (coordinate_graph; with the access policy off, any module). So no hosted method returns
##    a note's audio from this member's view: coordinate_proof, whose proof would carry every
##    value whole, refuses a room whose view holds a part of a note (voice-notes-present)
##    until the maintainer decides (§10, §18). An entry under voice/ that is no note's part
##    leaves with a proof whole, and so does junk that copies a note's bytes when this
##    member's view holds none of that note's parts (§10, "What is left").
##  * An actor is named only where the log proves it: an author-signed kind's author
##    (authorship.nim), a driver-counted approval's signer, a binding's verified link.
##    An entry the fold refused (an uncounted approval, a substitute proposal) stays in
##    the graph, unattributed and marked so (invariant 9). An uncounted entry of an
##    author-signed kind (an account disclosure, a ceremony join or a file/ entry, which
##    provenance never lists; a voice/ entry the voice fold does not stand) is still its
##    signer's, since authorship proved who signed it, and its facet says both.
##  * Nothing here is per-viewer but `viewer` and `readFrom`: two members' graphs of the
##    same log differ only there. The input is what the viewer's client could open, so a
##    later joiner's graph holds nothing from before its admission (invariant 7, F-16).
##
## The input must be the authenticated log (`roomEvents`), as for every other fold.

import std/[json, strutils, tables, sets, algorithm]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../intents/disclosure
import ./intents
import ./flow
import ./accounts
import ./attest
from ./voice import VoiceMemo, voiceContentOf   # a voice/ entry's content, off the room's memo (voice-notes.md §6, §10)

type
  GraphNode* = object
    id*: string         ## "e:<cid>" entry · "m:<hex>" member · "k:<key>" signer key ·
                        ## "i:<id>" intent · "a:<caip10>" account · "c:<cid>" ceremony ·
                        ## "o:<observer>" outside observer · "o:outside" the world a read came from
    kind*: string       ## entry · member · signer · intent · account · ceremony · observer · outside
    seq*: int           ## the canonical position it first appears at; -1 = before the log
    epoch*: int         ## the membership epoch it appears in (-1 = unknown)
    attrs*: JsonNode

  GraphEdge* = object
    src*, dst*: string
    kind*: string       ## parent · authored · bound · proposed · approved · declined · part ·
                        ## input · disclosed · joined · leaves · enters
    seq*: int
    attrs*: JsonNode

  RoomEpoch* = object
    epoch*: int
    fromSeq*: int       ## the admission that opened it (0 for the founding epoch)
    admitted*: string   ## the joiner's member id ("" for the founding epoch)

  RoomGraph* = object
    viewer*: string     ## this instance's member id (lowercase hex)
    readFrom*: int      ## the first epoch this instance holds (0 for a founder)
    seqMax*: int        ## the last canonical position (-1 for an empty log)
    epochs*: seq[RoomEpoch]
    nodes*: seq[GraphNode]
    edges*: seq[GraphEdge]
    crossings*: seq[JsonNode]     ## every boundary crossing, in causal order (exo-737)
    fingerprints*: seq[JsonNode]  ## per epoch: {fromEpoch, entries, digest} (exo-26a)

const AuthorSigned = ["message", "decline", "material", "account", "join", "part-settled",
                      "part-confirmed", "proposer", "voice"]
  ## kinds whose author signed the event (authorship.nim): the room may name them

proc norm(s: string): string =
  result = s.toLowerAscii()
  if result.startsWith("0x") and result.len == 130: result = result[2 .. ^1]   # a 0x-prefixed member id

proc rawKind(p: seq[string]): string =
  ## A short kind for an entry the provenance fold does not describe.
  if p.len == 0: return "entry"
  case p[0]
  of "intent": (if p.len >= 3: p[2] else: "intent")
  of "account": "account"
  of "frost": (if p.len >= 3: p[2] else: "ceremony")
  of "membership": (if p.len >= 3: p[2] else: "membership")
  else: p[0]

# ── credibility: what each entry and connection guarantees, against whom, and how ──
# The vocabulary is the claims registry's (docs/design/action-manifest.md §2): imperative
# — the discretion to defect is removed structurally; motivational — a named party could
# defect but has a reason not to; exposed — the information reaches an unbound observer;
# not-applicable — nothing is promised. Muster classifies; it never scores. Every line
# below restates a guarantee the code already enforces (the guarantee strings in
# intents.logProvenance, the drivers, authorship.nim); none adds one (exo-f2d).

proc facet(about, class, party, mechanism: string): JsonNode =
  %*{"about": about, "class": class, "party": party, "mechanism": mechanism}

proc facetsFor(kind, attestation, source: string, counted, attributed: bool, epoch: int): JsonNode =
  ## `attributed`: the map names the entry's signer (an author-signed kind, by authorship.nim)
  result = newJArray()
  result.add facet("who could read it", "imperative", "",
    "sealed under epoch " & $epoch & "'s key: only the members of that epoch could open it")
  if kind == "voice":
    # every voice/ frame a client sends is padded to one size (voice-notes.md §4, §10)
    result.add facet("that it exists", "exposed", "the store node",
      "it keeps every envelope, so it sees when this one arrived, which topic it is on and its one fixed size, " &
      "which marks a voice note but not its length; never what it says")
  else:
    result.add facet("that it exists", "exposed", "the store node",
      "it keeps every envelope, so it sees when this one arrived and which topic it is on, never what it says")
  if not counted:
    result.add facet("this entry", "not-applicable", "",
      (if attributed: "the fold counts it for nothing; its author signed it, bound to this room"
       else: "the fold refused it, so it counts for nothing and names no one"))
    return
  case kind
  of "message":
    result.add facet("who wrote it", "imperative", "", "its author signed it, bound to this room; the room's views drop one whose signature fails")
    result.add facet("what it says", "motivational", "its author", "a member's word, as any message is")
  of "voice":
    result.add facet("who sent it", "imperative", "", "its author signed each part, bound to this room; the room's views drop a part whose signature fails")
    result.add facet("what it says", "motivational", "its author", "a member's word, as any message is")
  of "propose":
    result.add facet("who could place it", "imperative", "", "sealed under the epoch key: only a member could have placed it")
    result.add facet("what is signed", "imperative", "", "every device re-derives the materialization from the effect and refuses on mismatch (F-4)")
  of "proposer":
    result.add facet("who proposed it", "imperative", "", "the proposer's signed claim, bound to this room and to exactly what was proposed")
  of "policy":
    result.add facet("how it is decided", "imperative", "", "every member folds the identical driver (invariant 6)")
  of "context":
    result.add facet("where an approval counts", "imperative", "", "every approval commits to it, so one is worthless in another environment, account or slot, or after expiry (invariant 2)")
  of "read":
    result.add facet("what it says", "motivational", (if source.len > 0: source else: "the proposer's source"),
      "what the source reported; recorded, not proof the world agrees (F-10)")
    result.add facet("where it came from", "imperative", "", "recorded with its source before any approval, and every approval names it (invariant 10)")
  of "sig":
    result.add facet("who approved", "imperative", "", "the driver verified the signature recovers to a configured signer; a non-member never reaches the fold")
    case attestation
    of "committed":
      result.add facet("what the approver saw", "imperative", "", "signed over the context, the materialization and the origin of every input (invariants 2 and 10)")
    of "unattested":
      result.add facet("what the approver saw", "motivational", "the approver",
        "counted, but signed outside muster: the approver committed to no inputs here")
    else: discard
  of "attest":
    result.add facet("what the approver saw", "imperative", "", "the approving key signed the context, the materialization and the provenance of every input; every member re-derives what it must cover")
  of "binding":
    result.add facet("whose key approved", "imperative", "", "the key's own signature ties it to the member's admitted identity (F-14)")
  of "decline":
    result.add facet("who declined", "imperative", "", "signed by the decliner, bound to this room")
    result.add facet("what it does", "imperative", "", "final: the decliner's approval counts for nothing")
  of "admit":
    result.add facet("who reads what", "imperative", "", "the room re-keyed forward: the joiner reads from here on, nothing before (F-16)")
    result.add facet("who was let in", "motivational", "the admitting member", "any member may decide to admit; the room trusts that judgment")
  of "part-settled":
    result.add facet("who wrote it", "imperative", "", "signed by the party it names, bound to this room")
    result.add facet("that it was paid", "motivational", "the payer", "a claim until the counterparty confirms it from their own read")
  of "part-confirmed":
    result.add facet("that it arrived", "motivational", "the counterparty and their own endpoint",
      "their own read of their own infrastructure, or their word that it arrived outside muster (F-10)")
  of "submit":
    result.add facet("what was sent", "motivational", "the submitting member", "their report of what they sent; the chain's answer arrives as final")
  of "final":
    result.add facet("that it settled", "motivational", "the reader's endpoint", "observed from the chain through the reader's own endpoint; attested unless proof-checked (F-10)")
  of "account":
    result.add facet("who disclosed it", "imperative", "", "signed by the member who disclosed it")
    result.add facet("that it is as disclosed", "motivational", "each reader's endpoint", "each client checks it against the chain before acting from it")
  of "material":
    result.add facet("who shared it", "imperative", "", "signed by the sharer")
    result.add facet("that it is theirs", "motivational", "the sharer", "only a driver-verified signature proves control of what was shared")
  of "join", "open", "pmsg1", "pmsg2":
    result.add facet("the ceremony step", "imperative", "", "public ceremony data every member checks and computes from the log")
  else:
    result.add facet("what it means", "not-applicable", "", "no guarantee is declared for this kind of entry")

proc edgeCredibility(e: GraphEdge, obsLabel: proc (id: string): string): tuple[class, party, mechanism: string] =
  case e.kind
  of "leaves":
    if e.src.startsWith("e:"):
      ("exposed", obsLabel(e.dst), "a member's storage node serves the sealed blob: the storage network sees what it always shows of a served dataset, never the file or its key")
    else:
      ("exposed", obsLabel(e.dst), "the driver's manifest declares it; it leaves when the room settles, and cannot be taken back")
  of "enters":
    ("motivational", "the source it came from", "an outside read, recorded so its origin is accountable; not proof the world agrees (F-10)")
  of "approved":
    if e.attrs{"attestation"}.getStr() == "committed": ("imperative", "", "a driver-verified signature over the inputs it commits to")
    else: ("motivational", "the approver", "a driver-verified signature, made outside muster, committing to no inputs here")
  of "part":
    if e.attrs{"step"}.getStr() == "settled": ("motivational", "the payer", "a signed claim until the counterparty confirms it")
    else: ("motivational", "the counterparty", "their own read, or their word")
  of "input":
    if e.attrs{"kind"}.getStr() == "read": ("motivational", "the source", "an outside read the signature names (invariant 10)")
    else: ("imperative", "", "a member's sealed entry the signature names (invariant 10)")
  of "parent": ("imperative", "", "a hash link: the child's id commits to it")
  else: ("imperative", "", "a signed entry by the member it names")

proc parseOrEmpty(s: string): JsonNode =
  ## a value parsed as JSON, or a JSON string of it when it is not JSON
  try: parseJson(s) except CatchableError: %s

proc contentOf(e: Event, p: seq[string], id: EventId, memo: VoiceMemo): JsonNode =
  ## An entry's content: its value parsed (a JSON object as is, anything else under
  ## "value"), with what its key says spelled out — the read's field, the part and step,
  ## the requirement a material fills, the admitted member and epoch. An entry under voice/
  ## is the exception, a part or not: a note's metadata alone (voice.voiceContentOf, which
  ## reads a part's off the header the room's memo holds).
  if p.len > 0 and p[0] == "voice": return voiceContentOf(e.value, id, memo)
  result = newJObject()
  try:
    let j = parseJson(e.value)
    if j.kind == JObject:
      for k, v in j: result[k] = v
    else: result["value"] = j
  except CatchableError:
    result["value"] = %e.value
  if p.len >= 3 and p[0] == "intent":
    case p[2]
    of "read": (if p.len >= 4: result["field"] = %p[3])
    of "submit", "final": result["chainRef"] = %e.value
    of "sig": (if p.len >= 5: (result["signer"] = %p[3]; result["round"] = %p[4]); result["signature"] = %e.value)
    of "attest": (if p.len >= 5: (result["signer"] = %p[3]; result["round"] = %p[4]); result["signature"] = %e.value)
    of "binding": (if p.len >= 4: result["key"] = %p[3]); result["link"] = %e.value
    of "part":
      if p.len >= 5: (result["part"] = %p[3 .. ^2].join("/"); result["step"] = %p[^1])
    of "material": (if p.len >= 5: (result["requirement"] = %p[3]; result["sharer"] = %p[4]))
    of "decline": (if p.len >= 4: result["who"] = %p[3])
    of "proposer": (if p.len >= 4: result["proposer"] = %p[3])
    of "policy": result["policy"] = %e.value
    else: discard
  elif p.len >= 4 and p[0] == "membership" and p[2] == "admit":
    result["joiner"] = %p[3]; result["epoch"] = %p[1]
  elif p.len >= 3 and p[0] == "frost":
    result["ceremony"] = %p[1]; result["step"] = %p[2]

proc reduceRoomGraph*(events: seq[Event], driverFor: DriverFor, founders: seq[string],
                      viewer: string, sealedIn = initTable[string, int](),
                      memo: VoiceMemo = nil): RoomGraph =
  ## `sealedIn` is the session's record of which epoch's key opened each event
  ## (CoordinationSession.sealedIn). An entry's epoch comes from it; only an event it does
  ## not name falls back to the admissions before it in canonical order, which is right
  ## only for a log whose events carry their parents. `memo` is the room's VoiceMemo
  ## (voice_live.graphOf passes it): its provenance, its flow and each voice part's content
  ## read through it, so a poll parses no part it has read before (voice-notes.md §6).
  # Positions are CAUSAL (log.causalOrder: parents, then the `after` each publisher
  # stamped), so a view replays the room in the order it happened, up to concurrency
  # (docs/design/causal-parents.md §4). The folds this joins index the CANONICAL order;
  # `pos` maps one of their positions to this one, through the event's id.
  let ordered = causalOrder(events)
  let canon = canonicalOrder(events)
  var posOf = initTable[EventId, int]()
  for i, e in ordered: posOf[eventId(e)] = i
  proc pos(canonSeq: int): int = posOf[eventId(canon[canonSeq])]
  result.viewer = norm(viewer)
  result.seqMax = ordered.len - 1
  var nodeAt = initTable[string, int]()
  var edgeSeen = initHashSet[string]()
  var g = addr result
  proc addNode(id, kind: string, seq, epoch: int, attrs: JsonNode = newJObject()) =
    if id in nodeAt: return
    nodeAt[id] = g.nodes.len
    g.nodes.add GraphNode(id: id, kind: kind, seq: seq, epoch: epoch, attrs: attrs)
  proc addEdge(src, dst, kind: string, seq: int, attrs: JsonNode = newJObject()) =
    let k = src & "|" & dst & "|" & kind & "|" & $seq
    if k in edgeSeen: return
    edgeSeen.incl k
    g.edges.add GraphEdge(src: src, dst: dst, kind: kind, seq: seq, attrs: attrs)

  # ── members and epochs ──────────────────────────────────────────────────────
  var members = initHashSet[string]()
  var sortedFounders: seq[string]
  for f in founders: sortedFounders.add norm(f)
  sortedFounders.sort()
  for f in sortedFounders:
    members.incl f
    addNode("m:" & f, "member", -1, 0, %*{"joined": 0})
  result.epochs.add RoomEpoch(epoch: 0, fromSeq: 0, admitted: "")
  var epochAt = newSeq[int](ordered.len)
  var epoch = 0
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      var ep = epoch
      try: ep = max(epoch, parseInt(p[1]))
      except ValueError: discard
      epoch = ep
      let who = norm(p[3])
      if ep > result.epochs[^1].epoch: result.epochs.add RoomEpoch(epoch: ep, fromSeq: i, admitted: who)
      if who notin members:
        members.incl who
        addNode("m:" & who, "member", i, ep, %*{"joined": ep})
      if who == result.viewer: result.readFrom = ep
    epochAt[i] = sealedIn.getOrDefault(eventId(e), epoch)
  # an admission names its joiner, but what that member did before is not in THIS
  # graph unless this client could open it — so readFrom is simply the viewer's own
  # admission epoch, read from the log it holds

  proc actor(account: string, seq: int, signed: bool): string =
    ## The node an attributed entry hangs from: a member, or an authorization key
    ## (an approval's signer that no verified binding ties to a member yet).
    let a = norm(account)
    if a.len == 0: return ""
    if a in members: return "m:" & a
    if a.startsWith("ed:") and a.len == 67:
      # a room-key approval names the member's Ed25519 key, the first half of the member's
      # identity (ed25519 ++ x25519): the driver verified that key signed, so it is them
      for m in members:
        if m.len == 128 and m.startsWith(a[3 .. ^1]): return "m:" & m
    if signed:
      # an author-signed event proves a room identity even if the roster missed it
      members.incl a
      addNode("m:" & a, "member", seq, epochAt[max(0, seq)], %*{"joined": -1})
      return "m:" & a
    addNode("k:" & a, "signer", seq, epochAt[max(0, seq)], newJObject())
    "k:" & a

  # ── entries: every event the client holds, attributed where the log proves it ──
  let prov = logProvenance(events, driverFor, sealedIn, memo)
  var provAt = initTable[int, LogProvItem]()
  for it in prov:
    var item = it
    item.seq = pos(it.seq)
    provAt[item.seq] = item
  var idAt = initTable[EventId, string]()
  for i, e in ordered: idAt[eventId(e)] = "e:" & eventId(e)
  for i, e in ordered:
    let p = e.key.split('/')
    let eid = eventId(e)
    let id = idAt[eid]
    var attrs = newJObject()
    var author = ""
    var basis = "sealed"
    if i in provAt:
      let it = provAt[i]
      attrs["kind"] = %it.kind
      attrs["cls"] = %($it.cls)
      attrs["counted"] = %true
      attrs["guarantee"] = %it.guarantee
      if it.intentId.len > 0: attrs["intent"] = %it.intentId
      if it.attestation.len > 0: attrs["attestation"] = %it.attestation
      case it.kind
      of "sig": (basis = "driver-verified"; author = it.account)
      of "attest", "binding": (basis = "key-signed"; author = it.account)
      of "admit": attrs["subject"] = %("m:" & norm(it.account))   # who was admitted; no author
      else:
        if it.kind in AuthorSigned and it.account.len > 0: (basis = "author-signed"; author = it.account)
    else:
      let k = rawKind(p)
      attrs["kind"] = %k
      attrs["counted"] = %false
      if p.len >= 2 and p[0] == "intent": attrs["intent"] = %p[1]
      # author-signed kinds outside the provenance fold: the author is proven by authorship
      if p.len == 4 and p[0] == "account" and p[2] == "disclose": (basis = "author-signed"; author = p[3])
      elif p.len >= 4 and p[0] == "frost" and p[2] == "join": (basis = "author-signed"; author = p[3])
      elif p.len >= 2 and p[0] == "file":
        # the room swarm (exo-4d0.4): a seed names its member in the key, a share or a
        # retract in the value's "author" (authorship.nim)
        if p.len >= 4 and p[2] == "seed": (basis = "author-signed"; author = p[3])
        else:
          try:
            let a = parseJson(e.value){"author"}.getStr()
            if a.len > 0: (basis = "author-signed"; author = a)
          except CatchableError: discard
      elif p.len >= 4 and p[0] == "intent" and p[2] == "proposer":
        basis = "author-signed"; author = p[3]; attrs["counted"] = %true
      elif p.len >= 3 and p[0] == "voice":
        # an entry under voice/ that is no note's part (voice-notes.md §6 rules 2 to 4:
        # provenance lists only the parts the fold stands, so a key or value of the wrong
        # shape, an equivocating later copy or a squatted note id lands here): it counts for
        # nothing, but authorship proved the member its key names signed it
        basis = "author-signed"; author = p[2]
    attrs["basis"] = %basis
    attrs["content"] = contentOf(e, p, eid, memo)
    var source = ""
    if attrs["kind"].getStr() == "read":
      try: source = parseJson(e.value){"source"}.getStr()
      except CatchableError: discard
      if source.len > 0: attrs["source"] = %source
    attrs["facets"] = facetsFor(attrs["kind"].getStr(), attrs{"attestation"}.getStr(), source,
                                attrs["counted"].getBool(), basis == "author-signed" and author.len > 0,
                                epochAt[i])
    addNode(id, "entry", i, epochAt[i], attrs)
    for par in e.parents:
      if par in idAt: addEdge(idAt[par], id, "parent", i)
    if author.len > 0:
      let a = actor(author, i, basis == "author-signed")
      if a.len > 0:
        attrs["account"] = %a
        addEdge(a, id, "authored", i, %*{"basis": basis})

  # ── signer keys tied to members by a verified binding (F-14) ─────────────────
  for i, e in ordered:
    let bl = bindingLink(e)
    if not bl.ok: continue
    let m = norm(bl.member)
    if m notin members: continue        # a binding to no one this room admitted names no one
    let k = actor(bl.who, i, false)
    if k.startsWith("k:"): addEdge("m:" & m, k, "bound", i)

  # ── intents ──────────────────────────────────────────────────────────────────
  var firstSeq = initTable[string, int]()
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len >= 3 and p[0] == "intent" and p[1] notin firstSeq: firstSeq[p[1]] = i
  # each intent's state after each of its entries: the fold over the causal prefix, kept
  # where (state, approvals) changes — a pure function of a set of events, so honest. An
  # intent's view reads only its own `intent/<id>/…` entries, so the prefix folded is
  # that intent's entries up to this one, not the whole log (G7: quadratic in one
  # intent's entries, not in the room's).
  var steps = initTable[string, JsonNode]()
  var lastStep = initTable[string, string]()
  var own = initTable[string, seq[Event]]()
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len < 3 or p[0] != "intent": continue
    own.mgetOrPut(p[1], @[]).add e
    for v in reduceIntentViews(own[p[1]], driverFor):
      if v.id != p[1] or v.effectJson.len == 0: continue
      let sig = v.state & "/" & $v.approvals
      if lastStep.getOrDefault(v.id, "") == sig: continue
      lastStep[v.id] = sig
      if v.id notin steps: steps[v.id] = newJArray()
      steps[v.id].add %*{"seq": i, "state": v.state, "approvals": v.approvals}
  var effectOf = initTable[string, JsonNode]()
  for v in reduceIntentViews(events, driverFor):
    if v.effectJson.len == 0: continue
    let s = firstSeq.getOrDefault(v.id, -1)
    var parts = newJArray()
    for pv in v.parts:
      parts.add %*{"part": pv.part, "settled": pv.settled, "confirmed": pv.confirmed}
    addNode("i:" & v.id, "intent", s, (if s >= 0: epochAt[s] else: -1), %*{
      "state": v.state, "family": v.policy.split('@')[0], "threshold": v.threshold,
      "approvals": v.approvals, "rounds": v.rounds, "round": v.round, "declines": v.declines,
      "committed": v.committed, "unattested": v.unattested, "parts": parts,
      "steps": steps.getOrDefault(v.id, newJArray()),
      # its content: the effect as proposed, in words and in full, and what is signed
      "effect": (try: parseJson(v.effectJson) except CatchableError: %v.effectJson),
      "summary": summarizeEffect(v.effectJson), "policy": v.policy, "txhash": v.txhash,
      "schemaId": v.schemaId, "proposers": v.proposers, "decliners": v.decliners})
    effectOf[v.id] = (try: parseJson(v.effectJson) except CatchableError: newJObject())
  for it in provAt.values:
    if it.intentId.len == 0 or "i:" & it.intentId notin nodeAt: continue
    let dst = "i:" & it.intentId
    let entry = "e:" & eventId(ordered[it.seq])
    case it.kind
    of "propose", "policy", "context", "read":
      addEdge(entry, dst, "input", it.seq, %*{"cls": $it.cls, "kind": it.kind})
      if it.kind == "read": addEdge("o:outside", dst, "enters", it.seq, %*{"kind": "read"})
    of "sig":
      let a = actor(it.account, it.seq, false)
      if a.len > 0: addEdge(a, dst, "approved", it.seq, %*{"attestation": it.attestation})
    of "decline":
      let a = actor(it.account, it.seq, true)
      if a.len > 0: addEdge(a, dst, "declined", it.seq)
    of "part-settled", "part-confirmed":
      let a = actor(it.account, it.seq, true)
      if a.len > 0: addEdge(a, dst, "part", it.seq, %*{"step": it.kind[5 .. ^1]})
      if it.kind == "part-confirmed": addEdge("o:outside", dst, "enters", it.seq, %*{"kind": it.kind})
    of "final":
      addEdge("o:outside", dst, "enters", it.seq, %*{"kind": "final"})
    else: discard
  for i, e in ordered:   # who proposed, by their signed claim (exo-770)
    let p = e.key.split('/')
    if p.len == 4 and p[0] == "intent" and p[2] == "proposer" and "i:" & p[1] in nodeAt:
      let a = actor(p[3], i, true)
      if a.len > 0: addEdge(a, "i:" & p[1], "proposed", i)

  # ── accounts disclosed into the room, and key ceremonies ─────────────────────
  for a in reduceAccounts(events):
    for i, e in ordered:
      let p = e.key.split('/')
      if p.len != 4 or p[0] != "account" or p[2] != "disclose" or p[1] != a.id: continue
      addNode("a:" & a.id, "account", i, epochAt[i], %*{"family": a.family, "chain": a.chain,
        "threshold": a.threshold, "signers": a.signers.len, "conflict": a.conflict,
        "address": a.address, "label": a.label, "signerList": a.signers, "config": a.config,
        "disclosedBy": a.disclosedBy})
      let m = actor(p[3], i, true)
      if m.len > 0: addEdge(m, "a:" & a.id, "disclosed", i)
  for i, e in ordered:
    let p = e.key.split('/')
    if p.len < 3 or p[0] != "frost": continue
    addNode("c:" & p[1], "ceremony", i, epochAt[i], newJObject())
    if p[2] == "join" and p.len >= 4:
      let m = actor(p[3], i, true)
      if m.len > 0: addEdge(m, "c:" & p[1], "joined", i)

  # ── what left, and to whom (reduceFlow, outside rows only) ───────────────────
  addNode("o:" & $obStoreNode, "observer", -1, 0, newJObject())   # every envelope reaches it (FS-9)
  var leaves = initOrderedTable[string, tuple[src, obs: string, seq: int, fields: seq[string], declared: bool]]()
  for r in reduceFlow(events, driverFor, founders, sealedIn, memo):
    if r.to in {obRoomMember, obStoreNode}: continue
    let at = pos(r.seq)
    var src = ""
    if r.intentId.len > 0:
      if "i:" & r.intentId notin nodeAt: continue
      src = "i:" & r.intentId
    elif r.to in {obStoragePeer, obStorageDht}:
      # a room-swarm entry (exo-4d0.4): the blob it put on a storage node, from the entry itself
      src = "e:" & eventId(ordered[at])
      if src notin nodeAt: continue
    else: continue
    let k = src & "|" & $r.to & "|" & $at
    if k notin leaves: leaves[k] = (src, "o:" & $r.to, at, @[], r.declared)
    if r.field notin leaves[k].fields: leaves[k].fields.add r.field
  for _, l in leaves:
    addNode(l.obs, "observer", l.seq, epochAt[l.seq], newJObject())
    var fs = l.fields
    fs.sort()
    addEdge(l.src, l.obs, "leaves", l.seq, %*{"fields": fs, "declared": l.declared})
  var outsideAt = -1
  for e in result.edges:
    if e.src == "o:outside" and (outsideAt < 0 or e.seq < outsideAt): outsideAt = e.seq
  if outsideAt >= 0: addNode("o:outside", "outside", outsideAt, epochAt[outsideAt], newJObject())

  # ── every connection's credibility (exo-f2d) ──────────────────────────────────
  proc obsLabel(id: string): string =
    case id
    of "o:store-node": "the store node"
    of "o:rpc-provider": "the RPC provider"
    of "o:chain-observer": "anyone reading the chain"
    of "o:target-module": "the module the call reaches"
    of "o:storage-peer": "the storage nodes that serve or fetch it"
    of "o:storage-dht": "anyone reading the storage network"
    else: id
  for e in result.edges.mitems:
    let c = edgeCredibility(e, obsLabel)
    e.attrs["credibility"] = %c.class
    e.attrs["party"] = %c.party
    e.attrs["mechanism"] = %c.mechanism

  # ── crossings: what left the room, what came in, who joined (exo-737) ────────────
  result.crossings.add %*{"seq": -1, "dir": "out", "kind": "envelopes", "observer": "o:store-node",
    "fields": ["timing", "topic"], "entries": ordered.len, "credibility": "exposed", "party": "the store node",
    "mechanism": "every entry is an envelope the store node keeps: it sees when each arrived and its topic, never what it says"}
  for e in result.edges:
    if e.kind != "leaves": continue
    # what left, with the values the effect gives those fields and the chain reference of
    # the entry that sent it — the transaction anyone outside can look up
    let intentId = e.src[2 .. ^1]
    let eff = effectOf.getOrDefault(intentId, newJObject())
    var values = newJObject()
    for f in e.attrs["fields"]:
      let k = f.getStr()
      if eff.kind == JObject and eff.hasKey(k): values[k] = eff[k]
      elif k == "payee" and eff.kind == JObject and eff.hasKey("payTo"): values[k] = eff["payTo"]
      elif k == "to" and eff.kind == JObject and eff.hasKey("payTo"): values[k] = eff["payTo"]
    let sent = parseOrEmpty(ordered[e.seq].value)
    let chainRef =
      if sent.kind == JObject and sent.hasKey("tx"): sent["tx"].getStr()
      elif sent.kind != JObject: ordered[e.seq].value
      else: ""
    result.crossings.add %*{"seq": e.seq, "dir": "out", "kind": "leaves", "observer": e.dst,
      "fields": e.attrs["fields"], "values": values, "chainRef": chainRef,
      "intent": intentId, "entry": "e:" & eventId(ordered[e.seq]),
      "declared": e.attrs{"declared"}.getBool(true),
      "credibility": "exposed", "party": obsLabel(e.dst), "mechanism": e.attrs["mechanism"]}
  for n in result.nodes:
    if n.kind != "entry" or not n.attrs["counted"].getBool(): continue
    let k = n.attrs["kind"].getStr()
    let intent = n.attrs{"intent"}.getStr()
    case k
    of "read":
      result.crossings.add %*{"seq": n.seq, "dir": "in", "kind": "read", "source": n.attrs{"source"}.getStr(),
        "intent": intent, "entry": n.id, "credibility": "motivational",
        "party": (if n.attrs{"source"}.getStr().len > 0: n.attrs{"source"}.getStr() else: "the proposer's source"),
        "mechanism": "recorded before any approval; every approval names it (invariant 10)"}
    of "final", "part-confirmed":
      result.crossings.add %*{"seq": n.seq, "dir": "in", "kind": k, "source": "the chain, through the reader's own endpoint",
        "intent": intent, "entry": n.id, "credibility": "motivational",
        "party": (if k == "final": "the reader's endpoint" else: "the counterparty and their own endpoint"),
        "mechanism": "an external read, graded attested unless proof-checked (F-10)"}
    of "admit":
      result.crossings.add %*{"seq": n.seq, "dir": "join", "kind": "admit", "member": n.attrs{"subject"}.getStr(),
        "epoch": n.epoch, "entry": n.id, "credibility": "imperative", "party": "",
        "mechanism": "the room re-keyed forward: they read from epoch " & $n.epoch & " on, nothing before (F-16)"}
    of "account", "material":
      result.crossings.add %*{"seq": n.seq, "dir": "in", "kind": k, "member": n.attrs{"account"}.getStr(),
        "intent": intent, "entry": n.id, "credibility": "imperative", "party": "",
        "mechanism": (if k == "account": "a member brought an account in, signed; each client checks it against the chain"
                      else: "a member shared its public face, signed; only that face, never a handle")}
    else: discard
  result.crossings.sort(proc (a, b: JsonNode): int =
    cmp((a["seq"].getInt(), a["dir"].getStr(), a{"observer"}.getStr()), (b["seq"].getInt(), b["dir"].getStr(), b{"observer"}.getStr())))

  # ── fingerprints: what a member holds from each epoch on, comparable aloud (exo-26a) ──
  # Offered from an epoch only when an entry of that very epoch is held, so the list is a
  # function of what is held, never of who is looking: a joiner holds nothing from before
  # its admission and so offers no fingerprint from then.
  for ep in result.epochs:
    var ids: seq[string]
    var holdsEpoch = false
    for n in result.nodes:
      if n.kind == "entry" and n.epoch >= ep.epoch: ids.add n.id[2 .. ^1]
      if n.kind == "entry" and n.epoch == ep.epoch: holdsEpoch = true
    if not holdsEpoch: continue
    ids.sort()
    var arr: seq[CborValue]
    for x in ids: arr.add cbText(x)
    let d = toHex(digest(hashInput("muster.room-fingerprint.v1", @[
      ("fromEpoch", cbUint(uint64(ep.epoch))), ("ids", cbArray(arr))])))
    result.fingerprints.add %*{"fromEpoch": ep.epoch, "entries": ids.len, "digest": d}

  # a stable order for the wire: nodes by (seq, id), edges by (seq, src, dst, kind)
  result.nodes.sort(proc (a, b: GraphNode): int = cmp((a.seq, a.id), (b.seq, b.id)))
  result.edges.sort(proc (a, b: GraphEdge): int = cmp((a.seq, a.src, a.dst, a.kind), (b.seq, b.src, b.dst, b.kind)))

proc toJson*(g: RoomGraph): JsonNode =
  ## The map as the view reads it. Every entry of a kind shares its facets and guarantee,
  ## so each distinct facet set is sent once in `facetSets` and each guarantee once in
  ## `texts`, an attr holding the index where the value was (exo-dde.19: two fifths of a
  ## 420-entry map was those repeats). Indices follow first use in node, then edge,
  ## order, so the same graph gives the same bytes. The view expands them on parse.
  var facetSets = newJArray()
  var texts = newJArray()
  var setAt = initTable[string, int]()
  var textAt = initTable[string, int]()
  proc interned(attrs: JsonNode): JsonNode =
    if attrs.kind != JObject or not (attrs.hasKey("facets") or attrs.hasKey("guarantee")): return attrs
    result = attrs.copy()
    if result.hasKey("facets"):
      let k = $result["facets"]
      if k notin setAt: (setAt[k] = facetSets.len; facetSets.add result["facets"])
      result["facets"] = %setAt[k]
    if result.hasKey("guarantee") and result["guarantee"].kind == JString:
      let k = result["guarantee"].getStr()
      if k notin textAt: (textAt[k] = texts.len; texts.add %k)
      result["guarantee"] = %textAt[k]
  var nodes = newJArray()
  for n in g.nodes:
    nodes.add %*{"id": n.id, "kind": n.kind, "seq": n.seq, "epoch": n.epoch, "attrs": interned(n.attrs)}
  var edges = newJArray()
  for e in g.edges:
    edges.add %*{"src": e.src, "dst": e.dst, "kind": e.kind, "seq": e.seq, "attrs": interned(e.attrs)}
  var epochs = newJArray()
  for ep in g.epochs:
    epochs.add %*{"epoch": ep.epoch, "fromSeq": ep.fromSeq, "admitted": ep.admitted}
  %*{"viewer": g.viewer, "readFrom": g.readFrom, "seqMax": g.seqMax, "epochs": epochs,
     "nodes": nodes, "edges": edges, "crossings": g.crossings, "fingerprints": g.fingerprints,
     "facetSets": facetSets, "texts": texts}
