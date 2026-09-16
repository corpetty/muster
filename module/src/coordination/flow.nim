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
## the transaction, not at propose). Undeclared manifests yield a row that says so.
## Nothing here is per-viewer; it is the room's shared truth (invariant 4).

import std/[json, tables, strutils, algorithm, sets]
import ../log/log
import ../drivers/driver
import ../drivers/manifest
import ../intents/disclosure
import ./intents
export disclosure

type
  FlowRow* = object
    seq*: int              ## canonical log position of the action
    kind*: string          ## message · propose · sig · decline · policy · submit · final · admit
    intentId*: string
    field*: string         ## what is visible
    to*: Observer          ## who can see it
    members*: seq[string]  ## for room-member rows: who held the key at that point (sorted)
    epoch*: int
    declared*: bool        ## false when the action's driver has not declared its disclosure

proc reduceFlow*(events: seq[Event], driverFor: DriverFor,
                 founders: seq[string]): seq[FlowRow] =
  ## `founders` are the members present at epoch 0 (the current roster minus every
  ## joiner the log admits — the caller derives it; the log does not name founders).
  let ordered = canonicalOrder(events)
  var epoch = 0
  var present = initHashSet[string]()
  for f in founders: present.incl f
  var manifests = initTable[string, ActionManifest]()   # intent id → manifest
  proc membersNow(): seq[string] =
    for m in present: result.add m
    result.sort()
  proc addRows(res: var seq[FlowRow], i: int, kind, intentId: string,
               rows: seq[DisclosureRow], declared: bool) =
    for d in rows:
      res.add FlowRow(seq: i, kind: kind, intentId: intentId, field: d.field, to: d.to,
                      members: (if d.to == obRoomMember: membersNow() else: @[]),
                      epoch: epoch, declared: declared)
  for i in 0 ..< ordered.len:
    let e = ordered[i]
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit":
      try: epoch = max(epoch, parseInt(p[1]))
      except ValueError: discard
      present.incl p[3]
      result.addRows(i, "admit", "", @[row("membership", obRoomMember), row("timing", obStoreNode),
                                        row("topic", obStoreNode)], true)
      continue
    if p.len >= 2 and p[0] == "message":
      result.addRows(i, "message", "", baselineDisclosure(), true)
      continue
    if p.len < 3 or p[0] != "intent": continue
    let id = p[1]
    if id notin manifests:
      let drv = driverFor(intentPolicyOf(events, id))
      manifests[id] = drv.manifest(effectFromJson(effectJsonOf(events, id)))
    let m = manifests[id]
    case p[2]
    of "propose", "policy", "sig", "decline":
      # inside the boundary + the store node's metadata; the driver's outside rows wait
      # for submit — nothing has left the room yet.
      result.addRows(i, p[2], id, baselineDisclosure(), m.declared)
    of "submit", "final":
      var rows = baselineDisclosure()
      if m.declared: rows.add m.discloses
      else: rows.add row("undeclared", obChainObserver)
      result.addRows(i, p[2], id, rows, m.declared)
    else: discard

proc toJson*(rows: seq[FlowRow]): JsonNode =
  result = newJArray()
  for r in rows:
    var ms = newJArray()
    for m in r.members: ms.add %m
    result.add %*{"seq": r.seq, "kind": r.kind, "intentId": r.intentId, "field": r.field,
                  "to": $r.to, "members": ms, "epoch": r.epoch, "declared": r.declared}

proc observerMatrix*(rows: seq[FlowRow]): JsonNode =
  ## The summary the view leads with: per observer class, the distinct fields it
  ## could see across the whole log — the "who sees what" square.
  var byObs = initOrderedTable[string, HashSet[string]]()
  for o in [obRoomMember, obStoreNode, obRpcProvider, obChainObserver, obTargetModule]:
    byObs[$o] = initHashSet[string]()
  for r in rows: byObs[$r.to].incl r.field
  result = newJObject()
  for o, fs in byObs:
    var arr: seq[string]
    for f in fs: arr.add f
    arr.sort()
    result[o] = %arr
