## The information-flow view (M5): rows are placed where information actually
## leaves — inside rows on every action, the driver's outside rows only at submit /
## final — with the members who held the key at that epoch, and the store node on
## every single entry (FS-9). Undeclared drivers say so. Stub driver + libsodium.
## A parts-settled intent (a split) leaves at each counted "settled" report, never at
## propose, agree or confirm (exo-c7c).

import std/[strutils, algorithm, json, sequtils, sets]
import ./fixtures/parts_driver
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/flow

let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)
# an external-finality named stub: its manifest declares chain-observer rows + a write
let ext: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, finality = finExternal, verifyResult = true)
let (_, msg) = newMessageEvent("alice", 1, "hi", 1)
# a causal chain, so the canonical order is the story's order: carol is admitted AFTER
# the proposal and A's approval, BEFORE B's approval and the submit.
let ev1 = proposeEvent(id, effectJson)
let ev2 = contributeEvent(id, "A", "sa", parents = @[eventId(ev1)])
let ev3 = membershipEvent(1, "carol", parents = @[eventId(ev2)])
let ev4 = contributeEvent(id, "B", "sb", parents = @[eventId(ev3)])
let ev5 = submitEvent(id, parents = @[eventId(ev4)])
let ev6 = finalEvent(id, parents = @[eventId(ev5)])
let events = @[msg, ev1, ev2, ev3, ev4, ev5, ev6]

proc rowsOf(rows: seq[FlowRow], kind: string): seq[FlowRow] = (for r in rows: (if r.kind == kind: result.add r))
proc has(rows: seq[FlowRow], field: string, to: Observer): bool =
  for r in rows: (if r.field == field and r.to == to: return true)
  false

block:
  let rows = reduceFlow(events, ext, @["alice", "bob"])
  # the store node sees timing/topic on EVERY entry — no kind escapes it
  for k in ["message", "propose", "sig", "admit", "submit", "final"]:
    doAssert rows.rowsOf(k).has("timing", obStoreNode), k & " must name the store node"
  # nothing leaves to the chain at propose/sig; it does at submit/final
  doAssert not rows.rowsOf("propose").has("effect", obChainObserver)
  doAssert not rows.rowsOf("sig").has("effect", obChainObserver)
  doAssert rows.rowsOf("submit").has("effect", obChainObserver) and rows.rowsOf("final").has("effect", obChainObserver)
  echo "1. store node on every entry; the chain sees the effect only at submit/final OK"

block:
  let rows = reduceFlow(events, ext, @["alice", "bob"])
  # before carol's admit, room-member rows name alice+bob; after, carol too
  var before, after: seq[string]
  for r in rows.rowsOf("propose"): (if r.to == obRoomMember: before = r.members)
  for r in rows.rowsOf("final"): (if r.to == obRoomMember: after = r.members)
  doAssert before == @["alice", "bob"], $before
  doAssert after == @["alice", "bob", "carol"], $after
  let m = rows.observerMatrix()
  var chainFields: seq[string]
  # one chain's readers are one observer: the stub's chain (stub:0), not every chain's
  for f in m["chain-observer@stub:0"]: chainFields.add f.getStr()
  doAssert "effect" in chainFields, $m
  doAssert not m.hasKey("chain-observer"), "no chain-less observer when the driver names its chain: " & $m
  doAssert rows.filterIt(it.to == obChainObserver).allIt(it.chain == "stub:0")
  doAssert rows.filterIt(it.to == obRoomMember).allIt(it.chain == ""), "only rows bound for a chain name one"
  doAssert m["store-node"].len == 2 and m["room-member"].len >= 2
  echo "2. members who held the key at each point; the observer matrix summarises OK"

# a bare driver with no manifest override → its manifest is undeclared
type Bare = ref object of Driver
method describe(d: Bare): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: "bare", finality: finExternal, threshold: 1)
block:
  let bare: DriverFor = proc(kind: string): Driver = Bare()
  let rows = reduceFlow(@[proposeEvent(id, effectJson), submitEvent(id)], bare, @["x"])
  doAssert rows.rowsOf("submit").has("undeclared", obChainObserver)
  for r in rows.rowsOf("submit"): doAssert not r.declared
  echo "3. an undeclared driver yields an 'undeclared' row at the boundary, never silence OK"

block:
  var shuffled = events.reversed(); shuffled.add msg
  let a = reduceFlow(events, ext, @["alice", "bob"]).toJson()
  let b = reduceFlow(shuffled, ext, @["alice", "bob"]).toJson()
  doAssert $a == $b
  echo "4. reorder + duplicate → identical flow (inv 4) OK"

# ── parts (exo-c7c): fixtures/parts_driver — settles in parts, NOT the split
let pdrv = PartsDriver()
let pfor: DriverFor = proc(kind: string): Driver = pdrv
let pEffect = partsEffect(["alice", "bob"], "carol")
let pid = intentIdFor(pEffect, "parts")
let pp = proposeEvent(pid, pEffect)
let forged = partEvent(pid, "bob", "settled", "mallory", "0xforged") # not the part's author: never counts
let settledA = partEvent(pid, "alice", "settled", "alice", "0xa")
let confirmedA = partEvent(pid, "alice", "confirmed", "carol", "0xa")
let pevents = chain(@[policyDeclEvent(pid, "parts"), pp,
  contributeEvent(pid, "alice", hexName("alice")), contributeEvent(pid, "bob", hexName("bob")),
  forged, settledA, confirmedA])

proc seqOf(evs: seq[Event], e: Event): int =
  ## by key: `chain` re-parents events, which changes their ids
  let o = canonicalOrder(evs)
  for i in 0 ..< o.len: (if o[i].key == e.key: return i)
  doAssert false, "not in the log: " & e.key
proc atSeq(rows: seq[FlowRow], i: int): seq[FlowRow] = (for r in rows: (if r.seq == i: result.add r))

block:
  let rows = reduceFlow(pevents, pfor, @["alice", "bob", "carol"])
  let at = rows.atSeq(seqOf(pevents, settledA))
  doAssert at.has("payer", obChainObserver) and at.has("amount", obChainObserver), $at
  doAssert at.has("signed-tx", obRpcProvider), $at
  doAssert at.allIt(it.kind == "part-settled" and it.intentId == pid), $at
  # nothing leaves at propose, agree, or the counterparty's confirmation
  for e in [pp, confirmedA]:
    doAssert not rows.atSeq(seqOf(pevents, e)).has("payer", obChainObserver)
  doAssert rows.atSeq(seqOf(pevents, confirmedA)).allIt(it.kind == "part-confirmed")
  # a report that never counted put nothing on chain through the room
  doAssert not rows.atSeq(seqOf(pevents, forged)).has("payer", obChainObserver), "a refused report leaves nothing"
  # an intent the room never agreed: its reports count for nothing, so nothing left
  let unagreed = chain(@[policyDeclEvent(pid, "parts"), pp, contributeEvent(pid, "alice", hexName("alice")), settledA])
  doAssert not reduceFlow(unagreed, pfor, @["alice"]).anyIt(it.to == obChainObserver)
  doAssert rows.observerMatrix()["chain-observer"].getElems().mapIt(it.getStr()) == @["amount", "payer"]
  echo "5. a parts intent leaves at each counted settled report, never at propose, agree or confirm OK"

block:
  # every envelope reaches the store node: no prefix, no kind escapes it (FS-9)
  let id2 = intentIdFor(effectJson)
  let all = chain(@[msg, proposerEvent(id2, "alice"), proposeEvent(id2, effectJson),
    Event(key: "intent/" & id2 & "/context", value: "{}"),
    Event(key: "intent/" & id2 & "/read/nonce", value: "7"),
    contributeEvent(id2, "A", "sa"),
    Event(key: "intent/" & id2 & "/attest/A/1", value: "00"),
    Event(key: "account/eip155:1:0xabc/disclose/alice", value: "{}"),
    Event(key: "frost/c1/open", value: "{}"),
    Event(key: "something/new", value: "x"),
    membershipEvent(1, "carol"), submitEvent(id2), finalEvent(id2)]) & pevents
  let n = canonicalOrder(all).len
  let rowsAll = reduceFlow(all, proc(kind: string): Driver =
    (if kind == "parts": Driver(pdrv) else: newStubDriver(rounds = 1, threshold = 2, finality = finExternal, verifyResult = true)),
    @["alice", "bob"])
  var seen = initHashSet[int]()
  for r in rowsAll: (if r.field == "timing" and r.to == obStoreNode: seen.incl r.seq)
  for i in 0 ..< n: doAssert i in seen, "entry " & $i & " (" & canonicalOrder(all)[i].key & ") names no store node"
  # an account disclosure is seen by the room
  doAssert rowsAll.anyIt(it.kind == "account" and it.to == obRoomMember)
  echo "6. every envelope, of every prefix, names the store node OK"

block:
  # the host's roster is strutils.toHex (UPPERCASE); an admit names its joiner in lowercase.
  # A joiner is never a founder, whatever the case (exo-dde found every joiner counted as one).
  let admitted = membershipEvent(1, "cd34ef")
  doAssert foundersOf(@[admitted], @["AB12CD", "CD34EF"]) == @["AB12CD"]
  doAssert foundersOf(@[admitted], @["ab12cd", "cd34ef"]) == @["ab12cd"]
  echo "7. a joiner is never a founder, whatever the case of its id OK"

echo "flow_test: all OK"
