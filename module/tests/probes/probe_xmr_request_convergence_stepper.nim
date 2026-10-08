## derived-exo-dcc.5 s5: the request is final only when every part is confirmed, and every
## member's client folds the room's events to the same state whatever the order or
## duplication of events; a report alone never finalizes.
##
## STEPPER: over the eight events of a two-debtor XMR request — the proposal, Bob's, Carol's
## and Alice's agreements, Bob's and Carol's "I paid" reports (each with a txid), and Alice's
## two confirmations (each naming its transfer's txid) — folded through the REAL fold
## (reduceIntentViews) under the monero-split driver, on three members' clients (Alice's,
## Bob's and Carol's, each its own driver instance). State = which event is delivered FIRST
## (eight states, chained head -> head+1); each state folds EVERY order of the remaining
## seven (5040), as-is AND with every event delivered twice — all 8! = 40320 orders at eight
## grader calls rather than 40320 (each call is a separate `nim r`). The clients take the
## orders in turn: the i-th order as-is on client i mod 3 and doubled on client (i+1) mod 3,
## so every client folds a third of all orders each way (a fold costs ~3.5 ms; all three on
## every order would triple a grade that already folds 80640 times). Every state also folds
## every SUBSET of the eight (256) on all three clients.
## The rule, stated alone:
##   * every order, duplicated or not, on every client, folds to the identity order's view:
##     final, three of three agreed, both parts confirmed with their own txids;
##   * a subset folds to final iff it holds the proposal, all three agreements and both
##     confirmations; one with the reports but not both confirmations is never final, and
##     the reports alone never confirm a part.
## Run by hand (no argv), it checks all 40320 orders and 256 subsets with doAssert.

import std/[json, algorithm]
import ./xmr_room
import ./oracle_emit

let chain = XmrStage
let w = newFakeMonero("wallet-alice", "stagenet")
let payTo = w.mint("muster:conv").address
let effect = splitEffectJson(chain, "XMR", "500000000000", alice, payTo,
                             @[SplitShare(who: bob, amount: "300000000000"),
                               SplitShare(who: carol, amount: "200000000000")], "convergence")
# three clients: each folds every intent under its own monero-split driver
let clients = @[newSplitDriver(MoneroSplitFamily, chain, roster), newSplitDriver(MoneroSplitFamily, chain, roster),
                newSplitDriver(MoneroSplitFamily, chain, roster)]
proc dforOf(d: Driver): DriverFor = (proc(p: string): Driver = d)
let id = intentIdFor(effect)
let mat = canonicalize(clients[0], effectFromJson(effect))
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc agreement(ks: Keystore): Event =
  let s = hx(ks.edSign(mat.bytes))
  contributeEvent(id, contributorOf(clients[0], effect, s), s)
let t1 = txidOf(1)
let t2 = txidOf(2)

let events = @[
  proposeEvent(id, effect),                                     # 0
  agreement(bobKs),                                             # 1
  agreement(carolKs),                                           # 2
  agreement(aliceKs),                                           # 3 the creditor vouches for payTo
  partEvent(id, partName(bob), "settled", bob, t1),             # 4 Bob: "I paid"
  partEvent(id, partName(carol), "settled", carol, t2),         # 5 Carol: "I paid"
  partEvent(id, partName(bob), "confirmed", alice, t1),         # 6 Alice's wallet saw Bob's
  partEvent(id, partName(carol), "confirmed", alice, t2)]       # 7 …and Carol's

type View = tuple[state: string, approvals, threshold: int, parts: seq[PartView]]
proc viewOf(evs: seq[Event], c: int): View =
  for v in reduceIntentViews(evs, dforOf(clients[c])):
    if v.id == id: return (v.state, v.approvals, v.threshold, v.parts)
  ("absent", 0, 0, @[])

let reference = viewOf(events, 0)
doAssert reference.state == "final" and reference.approvals == 3 and reference.threshold == 3 and
         reference.parts.len == 2 and reference.parts[0].confirmed and reference.parts[1].confirmed,
         "the reference view is the one the rule gives: " & reference.state

proc subsetsCorrect(): bool =
  for mask in 0 ..< 256:
    var evs: seq[Event]
    for i in 0 ..< 8:
      if (mask and (1 shl i)) != 0: evs.add events[i]
    let need: set[0 .. 7] = {0, 1, 2, 3, 6, 7}
    var has: set[0 .. 7]
    for i in 0 ..< 8:
      if (mask and (1 shl i)) != 0: has.incl i
    let final = need <= has
    for c in 0 ..< clients.len:
      let v = viewOf(evs, c)
      if (v.state == "final") != final: return false
      # reports never confirm: a part is confirmed only with its confirmation in the log
      for p in v.parts:
        let conf = (if p.part == partName(bob): 6 else: 7)
        if p.confirmed and conf notin has: return false
      if v != viewOf(evs, 0): return false
  true

proc correct(perm: seq[int], i: int): bool =
  ## the i-th order: as-is on one client, doubled on the next
  var order: seq[Event]
  for e in perm: order.add events[e]
  viewOf(order, i mod 3) == reference and viewOf(order & order, (i + 1) mod 3) == reference

proc headCorrect(h: int): bool =
  ## every order that delivers event h first, and every subset
  if not subsetsCorrect(): return false
  var rest: seq[int]
  for i in 0 ..< events.len:
    if i != h: rest.add i
  var i = 0
  while true:
    if not correct(@[h] & rest, i): return false
    inc i
    if not rest.nextPermutation(): break
  true

proc state(h: int): JsonNode = %*{"case": h, "decision_correct": headCorrect(h)}

let arg = oracleStateArg()
if arg == nil:
  doAssert subsetsCorrect(), "a subset folds to the wrong finality"
  var p = @[0, 1, 2, 3, 4, 5, 6, 7]
  var n = 0
  while true:
    doAssert correct(p, n), "order " & permString(p) & " folds to a different view"
    inc n
    if not p.nextPermutation(): break
  doAssert n == 40320
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod events.len)])
