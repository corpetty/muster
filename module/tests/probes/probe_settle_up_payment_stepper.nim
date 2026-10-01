## derived-exo-a90.20 s4: once a settle-up is agreed the shares it covers are paid only through
## it — paying one directly is refused — and a covered share is marked received only once the
## settle-up is final, and only by that share's own creditor; nothing is paid twice (exo-3c6).
##
## STEPPER: dinner (Alice owed 300 by Bob and by Carol) and a taxi (Bob owed 200 by Alice and
## by Carol), both agreed, settled up by Alice into two net payments: Carol pays Alice 400 and
## Bob 100. State = a bitmask over six events on the settle-up — Bob agrees, Carol agrees
## (Alice agreed by proposing), Carol reports the payment to Alice, Alice confirms it, Carol
## reports the payment to Bob, Bob confirms it — so the BFS from the empty set reaches all
## 64. Each state is built over the live path and three things are tried: Carol pays her
## dinner share directly; each creditor's client runs settleCovered; and Carol marks her own
## dinner share received (an author-signed "confirmed" that is not hers to give). The rule,
## stated alone:
##   * the settle-up is agreed iff Bob and Carol agreed; its state then follows its parts
##     (all confirmed: final, any confirmed: settling, any reported: submitted) — before
##     that, no report counts;
##   * the direct payment is refused "covered-by-settle-up" iff the settle-up is agreed;
##   * each covered share is marked received — with no payment reference, since the net
##     payments moved the money — iff the settle-up is final; Carol's own mark never counts.
## Run by hand (no argv), it checks all 64 with doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/settle_up
import ./split_room
import ./oracle_emit

const Bits = 6
const BobPayTo = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc has(mask, b: int): bool = (mask and (1 shl b)) != 0

proc correct(mask: int): bool =
  var r = newRoom4("/muster/1/probe-settle-pay-" & $mask & "/proto")
  var seqNo = 0'u64
  proc propose(who, effect, account: string): string =
    inc seqNo
    let (s, ks) = r.sessionOf(who)
    liveProposeIntent(s, ks, splitFor, EvmPolicy, effect, int64(Now), seqNo, account = account, ttlSec = Ttl)
  let dinner = propose("alice", splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                       evenShares("900", alice, @[bob, carol]), "dinner"), EvmChain & ":" & AlicePayTo)
  let taxi = propose("bob", splitEffectJson(EvmChain, "ETH", "600", bob, BobPayTo,
                     evenShares("600", bob, @[alice, carol]), "taxi"), EvmChain & ":" & BobPayTo)
  r.sync()
  for (who, id) in [("bob", dinner), ("carol", dinner), ("alice", taxi), ("carol", taxi)]: discard r.agree(who, id)
  r.sync()
  let covers = openParts(r.alice.roomEvents(), splitFor, EvmChain, "ETH", Now)
  if covers.len != 4: return false
  let net = netTransfers(covers)
  let su = propose("alice", settleUpEffectJson(EvmChain, "ETH", covers, net, "lisbon"), EvmChain)
  if not su.startsWith("0x"): return false
  r.sync()
  if mask.has(0): discard r.agree("bob", su)
  if mask.has(1): discard r.agree("carol", su)
  r.sync()
  # the net payments' reports, author-signed by who the rule says may make them
  var pA, pB = ""
  for t in net:
    if t.frm == carol and t.to == alice: pA = settlePart(t)
    if t.frm == carol and t.to == bob: pB = settlePart(t)
  if pA.len == 0 or pB.len == 0: return false
  if mask.has(2): r.carol.publishAuthored(carolKs, partEvent(su, pA, "settled", carol, "0xpaidalice"))
  if mask.has(3): r.alice.publishAuthored(aliceKs, partEvent(su, pA, "confirmed", alice, "0xpaidalice"))
  if mask.has(4): r.carol.publishAuthored(carolKs, partEvent(su, pB, "settled", carol, "0xpaidbob"))
  if mask.has(5): r.bob.publishAuthored(bobKs, partEvent(su, pB, "confirmed", bob, "0xpaidbob"))
  r.sync()
  # the rule, stated alone
  let agreed = mask.has(0) and mask.has(1)
  let aConf = agreed and mask.has(3)
  let bConf = agreed and mask.has(5)
  let anySet = agreed and (mask.has(2) or mask.has(4) or mask.has(3) or mask.has(5))
  let want = (if not agreed: "collecting" elif aConf and bConf: "final" elif aConf or bConf: "settling"
              elif anySet: "submitted" else: "executable")
  if intentState(r.alice.roomEvents(), splitFor, su) != want: return false
  # 1. a covered share paid directly
  let ledger = newFakeLedger()
  let (direct, _) = liveSettlePartSend(r.carol, carolKs, splitFor, dinner, newFakePartSeam(ledger, "carol"), Now)
  if agreed != (direct == "covered-by-settle-up"): return false
  if agreed and ledger.sent.len != 0: return false
  # 2. Carol marks her own dinner share received: not hers to give
  r.carol.publishAuthored(carolKs, partEvent(dinner, partName(carol), "confirmed", carol, ""))
  # 3. each creditor's client marks what the settle-up covered
  discard settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(newFakeLedger(), "alice"))
  discard settleCovered(r.bob, bobKs, splitFor, newFakePartSeam(newFakeLedger(), "bob"))
  r.sync()
  let final = want == "final"
  for (id, debtor) in [(dinner, bob), (dinner, carol), (taxi, alice), (taxi, carol)]:
    var seen = false
    for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
      if v.id != id: continue
      for p in v.parts:
        if p.part == partName(debtor):
          seen = true
          if p.confirmed != final: return false
          if p.confirmed and p.tx.len != 0: return false      # no money moved for a covered share
    if not seen: return false
  for id in [dinner, taxi]:
    if (intentState(r.alice.roomEvents(), splitFor, id) == "final") != final: return false
  true

proc state(mask: int): JsonNode = %*{"events": mask, "decision_correct": correct(mask)}

let arg = oracleStateArg()
if arg == nil:
  for mask in 0 ..< (1 shl Bits):
    doAssert correct(mask), "events " & $mask & " — judged wrongly"
let here = oracleStateInt(arg, "events", 0)
var succ: seq[JsonNode]
for b in 0 ..< Bits:
  if not here.has(b): succ.add state(here or (1 shl b))
emitSuccessors(succ)
