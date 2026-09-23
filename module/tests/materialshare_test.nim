## material-share (exo-45e K5, docs/design/material-and-disclosure.md §3.4): a chosen
## material enters the log ONLY through an explicit share act (rule s2), carrying its
## PUBLIC face and class but never a handle (rule s1). It folds once per (requirement,
## sharer), is idempotent under reorder/duplication (invariant 4), is classed peer-message
## in provenance (F-20) naming the sharer, and discloses its public face to the room in the flow view (rule s6),
## the outside rows waiting for submit. Pure Nim (stub driver).

import std/[strutils, algorithm]
import ../src/drivers/driver
import ../src/coordination/intents
import ../src/coordination/flow

let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)
let named: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, verifyResult = true)

# ── 1. a share folds once per (requirement, sharer); reorder + duplicate are idempotent ─
block:
  let share = materialShareEvent(id, "payee", "bob", "0xBOBADDR", "public", "address", "to")
  var events = @[proposeEvent(id, effectJson), share, share,
                 materialShareEvent(id, "payee", "alice", "0xALICE", "public", "address", "to")]
  let shares = reduceShares(events, id)
  doAssert shares.len == 2, "one per (requirement, sharer), duplicate folded: " & $shares.len
  # first write wins, canonical order — bob and alice each once, with their public faces.
  var pubs: seq[string]
  for s in shares: (doAssert s.reqName == "payee" and s.field == "to"; pubs.add s.public)
  pubs.sort()
  doAssert pubs == @["0xALICE", "0xBOBADDR"]
  # only the public face travels — never a handle (s1).
  for s in shares: doAssert not s.public.contains("keystore") and not s.public.contains("adapter")
  # reorder → identical fold (inv 4).
  var reordered = @[events[3], events[1], events[0], events[2]]
  doAssert $reduceShares(reordered, id) == $reduceShares(events, id)
  echo "1. a share folds once per (requirement, sharer); reorder + dup idempotent (inv 4) OK"

# ── 2. provenance: a share is peer-message, named under a named driver ────────────
block:
  let events = @[proposeEvent(id, effectJson),
                 materialShareEvent(id, "payee", "bob", "0xBOBADDR", "public", "address", "to")]
  var found = false
  for it in logProvenance(events, named):
    if it.kind == "material":
      found = true
      doAssert it.cls == icPeerMessage, "a share is peer-shared room data"
      doAssert it.account == "bob", "named driver names the sharer"
      doAssert it.what.contains("'to'"), "names the effect field it fills: " & it.what
      doAssert it.guarantee.contains("PUBLIC face") and it.guarantee.contains("proves control")
  doAssert found, "the material share appears in provenance"
  echo "2. provenance: a share is peer-message, named, guarantee is honest about control OK"

# ── 3. flow: a share discloses its public face to the ROOM; outside rows wait for submit ─
block:
  let events = @[policyDeclEvent(id, "stub"), proposeEvent(id, effectJson),
                 materialShareEvent(id, "payee", "bob", "0xBOBADDR", "public", "address", "to")]
  let rows = reduceFlow(events, named, @["me"])
  var sawRoomTo, sawOutsideAtShare = false
  for r in rows:
    if r.kind == "material" and r.field == "to" and r.to == obRoomMember: sawRoomTo = true
    if r.kind == "material" and r.to == obChainObserver: sawOutsideAtShare = true
  doAssert sawRoomTo, "the shared 'to' value is disclosed to the room at the share"
  doAssert not sawOutsideAtShare, "nothing leaves the room at the share — outside rows wait for submit"
  echo "3. flow: a share discloses its public face to the room; outside rows wait for submit OK"

echo "materialshare_test: all OK"
