## The information-flow view (M5): rows are placed where information actually
## leaves — inside rows on every action, the driver's outside rows only at submit /
## final — with the members who held the key at that epoch, and the store node on
## every single entry (FS-9). Undeclared drivers say so. Stub driver + libsodium.

import std/[strutils, tables, algorithm, json]
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
  for f in m["chain-observer"]: chainFields.add f.getStr()
  doAssert "effect" in chainFields, $m
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

echo "flow_test: all OK"
