## The information-flow view (M5, exo-002.5): who could see what, for every action
## the room took — folded from the log × each action's manifest disclosure × the
## membership at that point (docs/design/action-manifest.md §4 want 3).
##
## Each log entry yields rows: one per (field, observer). Inside-the-boundary rows
## name the members who held the epoch key at that position — founders plus every
## joiner admitted at or before it — because that is who could open the envelope.
## Outside rows (store node, RPC provider, chain observer, target module) are placed
## at the entry where the information actually leaves: the baseline metadata rows
## on every entry (the store node sees timing/topic for all of them, FS-9), the
## driver's declared rows at SUBMIT/FINAL (that is when the chain and the RPC see
## the transaction, not at propose); for an intent that settles in parts (a split), at
## each COUNTED "settled" report — that payment is when its payer, payee and amount reach
## the chain (exo-c7c). Undeclared manifests yield a row that says so. Every entry of every
## prefix names the store node, since every entry is an envelope it keeps.
## Nothing here is per-viewer; it is the room's shared truth (invariant 4).

import std/[json, tables, strutils, algorithm, sets]
import ../log/log
import ../drivers/manifest
import ../intents/disclosure
import ./intents
from ./voice import voiceStanding, VoiceMemo   # what a voice note's part is: the fold's header pass
export disclosure

type
  FlowRow* = object
    seq*: int              ## canonical log position of the action
    kind*: string          ## message · propose · sig · decline · policy · submit · final · admit · voice
    intentId*: string
    field*: string         ## what is visible
    to*: Observer          ## who can see it
    members*: seq[string]  ## for room-member rows: who held the key at that point (sorted)
    epoch*: int
    declared*: bool        ## false when the action's driver has not declared its disclosure

proc foundersOf*(events: seq[Event], roster: seq[string]): seq[string] =
  ## The members present at epoch 0: the roster minus every joiner the log admits. The
  ## log names admits, not the founding set, so the caller supplies the roster.
  var admitted = initHashSet[string]()
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit": admitted.incl p[3].toLowerAscii()
  for m in roster:
    if m.toLowerAscii() notin admitted: result.add m

proc reduceFlow*(events: seq[Event], driverFor: DriverFor,
                 founders: seq[string], sealedIn = initTable[string, int](),
                 memo: VoiceMemo = nil): seq[FlowRow] =
  ## `founders` are the members present at epoch 0 (the current roster minus every
  ## joiner the log admits — the caller derives it; the log does not name founders).
  ## `sealedIn` is the session's record of which epoch's key opened each event
  ## (CoordinationSession.sealedIn). An entry's epoch comes from it, and its readers are
  ## the founders plus everyone admitted at or before that epoch. Only an event it does
  ## not name falls back to the admissions before it in canonical order — right only
  ## for a log whose events carry their parents (exo-dde.9). `memo` is the room's VoiceMemo
  ## (voice_live.flowRows passes it), so a poll parses no voice part it has read before
  ## (voice-notes.md §6).
  let ordered = canonicalOrder(events)
  var epoch = 0
  var admittedAt = initTable[string, int]()   # joiner → the epoch its admission opened
  for e in ordered:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      try:
        let ep = parseInt(p[1])
        admittedAt[p[3]] = min(admittedAt.getOrDefault(p[3], ep), ep)
      except ValueError: discard
  var manifests = initTable[string, ActionManifest]()   # intent id → manifest
  let partsAt = countedPartIndexes(events, driverFor)
  proc membersAt(ep: int): seq[string] =
    var present = initHashSet[string]()
    for f in founders: present.incl f
    for j, at in admittedAt: (if at <= ep: present.incl j)
    for m in present: result.add m
    result.sort()
  var entryEpoch = 0
  proc addRows(res: var seq[FlowRow], i: int, kind, intentId: string,
               rows: seq[DisclosureRow], declared: bool) =
    for d in rows:
      res.add FlowRow(seq: i, kind: kind, intentId: intentId, field: d.field, to: d.to,
                      members: (if d.to == obRoomMember: membersAt(entryEpoch) else: @[]),
                      epoch: entryEpoch, declared: declared)
  let envelope = @[row("timing", obStoreNode), row("topic", obStoreNode)]
  let standing = voiceStanding(events, memo)   # the voice fold's parts, by event id, through the room's memo
  for i in 0 ..< ordered.len:
    let e = ordered[i]
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      try: epoch = max(epoch, parseInt(p[1]))
      except ValueError: discard
      entryEpoch = sealedIn.getOrDefault(eventId(e), epoch)
      result.addRows(i, "admit", "", @[row("membership", obRoomMember)] & envelope, true)
      continue
    entryEpoch = sealedIn.getOrDefault(eventId(e), epoch)
    if p.len >= 2 and p[0] == "message":
      result.addRows(i, "message", "", baselineDisclosure(), true)
      continue
    if p.len >= 4 and p[0] == "account" and p[^2] == "disclose":
      # a member discloses an account into the room (accounts.nim): the room learns it
      result.addRows(i, "account", "", @[row("account", obRoomMember)] & envelope, true)
      continue
    if p.len >= 3 and p[0] == "frost":
      # a key ceremony's step: public ceremony data, inside the room
      result.addRows(i, "ceremony", "", @[row("ceremony", obRoomMember)] & envelope, true)
      continue
    if p.len >= 2 and p[0] == "file":
      # the room swarm (exo-4d0.4, room-swarm.md §5.5): a share tells the room the file
      # (name, size, sharer) and its key; a seed tells it how to reach the seeder's storage
      # node. Both mean a node now serves the sealed blob, so the storage network learns
      # what a served dataset always shows it: the DHT, the ciphertext's CID and the peer
      # providing it; a peer that fetches, the ciphertext and the serving node's address.
      # A stop (on: false) and a retract tell Storage nothing new.
      let serving = @[row("ciphertext-cid", obStorageDht), row("provider", obStorageDht),
                      row("ciphertext", obStoragePeer), row("node-address", obStoragePeer)]
      var on = false
      if p.len >= 4 and p[2] == "seed":
        try: on = parseJson(e.value){"on"}.getBool()
        except CatchableError: discard
      let rows = (if p.len >= 4 and p[2] == "seed":
                    @[row("storage-address", obRoomMember)] & (if on: serving else: @[])
                  elif p.len == 2: @[row("file", obRoomMember), row("file-key", obRoomMember)] & serving
                  else: @[row("file", obRoomMember)])
      result.addRows(i, "file", "", rows & envelope, true)
      continue
    if p[0] == "voice":
      # docs/design/voice-notes.md §10. A part is one the fold stands (voiceStanding, the
      # header pass: rules 2 to 4), as in provenance and so the room map: the members who
      # held its epoch's key can play its note and learn its length. An entry under voice/
      # that is no note's part tells the room nothing. Either way the store node keeps the
      # envelope and sees one fixed size, which marks a voice note but not its length: the
      # sending client's session.publish pads every voice/ frame (§4), whatever its shape.
      # Ingest does not check the size of a frame another member sent, so for theirs this
      # is what an honest client sends.
      let inside = (if eventId(e) in standing: @[row("voice-note", obRoomMember),
                      row("voice-note-length", obRoomMember)] else: @[])
      result.addRows(i, "voice", "", inside & envelope & @[row("fixed-size", obStoreNode)], true)
      continue
    if p.len < 3 or p[0] != "intent":
      # an entry this fold does not know still reached the store node as an envelope
      result.addRows(i, (if p.len > 0: p[0] else: "entry"), "", envelope, true)
      continue
    let id = p[1]
    if id notin manifests:
      let drv = driverFor(intentPolicyOf(events, id))
      manifests[id] = drv.manifest(effectFromJson(effectJsonOf(events, id)))
    let m = manifests[id]
    proc outside(m: ActionManifest): seq[DisclosureRow] =
      if m.declared: m.discloses else: @[row("undeclared", obChainObserver)]
    case p[2]
    of "material":
      # a shared material discloses its PUBLIC face to the room now (the sharer's explicit
      # act, exo-45e K5); the field it fills reaches the OUTSIDE observers only at submit,
      # via the manifest's declared rows — so nothing extra leaves the room here.
      var field = if p.len >= 4: p[3] else: "material"
      try: (let f = parseJson(e.value){"field"}.getStr(); (if f.len > 0: field = f))
      except CatchableError: discard
      result.addRows(i, "material", id, baselineDisclosure() & @[row(field, obRoomMember)], m.declared)
    of "binding":
      # a key-binding discloses to the room the link between the signing authorization
      # key and the member's encryption identity (F-14/F-9, exo-45e K5). Like the sig
      # itself it stays inside the room — nothing leaves until submit.
      result.addRows(i, "binding", id, baselineDisclosure() & @[row("key-binding", obRoomMember)], m.declared)
    of "submit", "final":
      result.addRows(i, p[2], id, baselineDisclosure() & m.outside, m.declared)
    of "part":
      # a part report (exo-a90.2). Its payment left when a COUNTED settled report says so:
      # that is when this part's payer, payee and amount reach the chain. A confirmation is
      # the counterparty's own read; a report the fold refused put nothing on chain.
      # the part's name may hold a '/': split on the last one, as countedParts does
      let rest = if p.len >= 4: e.key["intent/".len + id.len + "/part/".len .. ^1] else: ""
      let slash = rest.rfind('/')
      let step = if slash > 0: rest[slash + 1 .. ^1] else: ""
      var rows = baselineDisclosure()
      if step == "settled" and partsAt.getOrDefault(id).getOrDefault(rest, -1) == i:
        rows.add m.outside
      result.addRows(i, (if step.len > 0: "part-" & step else: "part"), id, rows, m.declared)
    else:
      # propose · policy · sig · decline · context · read · attest · proposer · …: inside
      # the boundary + the store node's metadata; nothing has left the room yet.
      result.addRows(i, p[2], id, baselineDisclosure(), m.declared)

proc toJson*(rows: seq[FlowRow]): JsonNode =
  result = newJArray()
  for r in rows:
    var ms = newJArray()
    for m in r.members: ms.add %m
    result.add %*{"seq": r.seq, "kind": r.kind, "intentId": r.intentId, "field": r.field,
                  "to": $r.to, "members": ms, "epoch": r.epoch, "declared": r.declared}

proc observerMatrix*(rows: seq[FlowRow], introduced: seq[Observer] = @[]): JsonNode =
  ## The summary the view leads with: per observer class, the distinct fields it
  ## could see across the whole log — the "who sees what" square. The room and the
  ## store node are always observers (the conversation's own baseline, FS-9); an
  ## outside observer (RPC provider, chain, target module) is listed only once a
  ## proposal INTRODUCES it — `introduced` (room_infra.introducedObservers) — or a row
  ## already names it. A room that only talks never lists an RPC provider (exo-428).
  var byObs = initOrderedTable[string, HashSet[string]]()
  for o in [obRoomMember, obStoreNode, obRpcProvider, obChainObserver, obTargetModule,
            obStoragePeer, obStorageDht]:
    if o in {obRoomMember, obStoreNode} or o in introduced:
      byObs[$o] = initHashSet[string]()
  for r in rows: byObs.mgetOrPut($r.to, initHashSet[string]()).incl r.field
  result = newJObject()
  for o, fs in byObs:
    var arr: seq[string]
    for f in fs: arr.add f
    arr.sort()
    result[o] = %arr
