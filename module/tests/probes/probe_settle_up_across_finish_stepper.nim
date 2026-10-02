## derived-exo-a90.17 s5: finishing across chains — each net payment is paid and confirmed on the
## payment chain, as in a settle-up in one asset; while the settle-up covers a share, on any
## chain, that share is paid only through it; once it is final, and not before, each creditor
## marks the shares it covered received on whatever chain they were — by their word, with no
## transaction on that chain (exo-a90.17).
##
## STEPPER: dinner in ETH (Alice owed 300 wei by Bob and by Carol) and a hotel in BTC on regtest
## (Bob owed 5000 sat by Carol), settled up by Alice in ETH at 7 wei per 3 sat — Carol pays
## Alice 600 and Bob 11366, Bob at the Ethereum address he shared (he is owed only on Bitcoin),
## and Bob's own 300 to Alice nets out. State = a bitmask over six events on the settle-up — Bob
## agrees, Carol agrees (Alice agreed by proposing), Carol reports the payment to Alice, Alice
## confirms it, Carol reports the payment to Bob, Bob confirms it — so the BFS from the empty set
## reaches all 64. Each state is built over the live path and four things are tried: Carol pays
## her BTC hotel share directly; Carol marks her own hotel share received (not hers to give);
## each member's client runs settleCovered, over one shared fake ledger; and every split's state
## is read. The rule, stated alone:
##   * the settle-up is agreed iff Bob and Carol agreed; its state then follows its parts (all
##     confirmed: final, any confirmed: settling, any reported: submitted) — before that, no
##     report counts;
##   * Carol's direct payment of the hotel is refused "covered-by-settle-up", sending nothing,
##     iff the settle-up is agreed;
##   * each covered share — the hotel on Bitcoin and both dinner shares — is marked received,
##     with no payment reference, iff the settle-up is final, and only by its own creditor;
##     Carol's own mark and her settleCovered never count;
##   * the hotel and the dinner are final iff the settle-up is;
##   * finishing sends nothing: the ledger every settleCovered ran over records no transfer.
## Run by hand (no argv), it checks all 64 with doAssert.

import std/[json, strutils, tables]
import ../../src/intents/materialization
import ./settle_across_room
import ./oracle_emit

const Bits = 6
const At = 1_790_000_000'i64

proc has(mask, b: int): bool = (mask and (1 shl b)) != 0

proc correct(mask: int): bool =
  var r = newRoom4("/muster/1/probe-across-finish-" & $mask & "/proto")
  let dinner = r.splitAgreed(EvmChain, "ETH", "alice", @["bob", "carol"], "900", "dinner")
  let hotel = r.splitAgreed(BtcChain, "BTC", "bob", @["carol"], "10000", "hotel")
  r.shareAddress("bob", "ETH", evmAddrOf["bob"], seqNo = 7)
  let rate = SettleRate(chain: BtcChain, asset: "BTC", rate: "7", per: "3", source: "Alice's BTC/ETH", at: $At)
  let composed = settleUpAcross(r.alice.roomEvents(), acrossFor, EvmChain, "ETH", @[rate], "lisbon", Now)
  if composed.why.len > 0 or composed.covers.len != 3: return false
  let su = r.proposeAs("alice", EvmPolicy, composed.effectJson, EvmChain, @[(field: "rates", source: "rates:proposer")])
  if not su.startsWith("0x"): return false
  r.sync()
  if mask.has(0): discard r.agreeAs("bob", su)
  if mask.has(1): discard r.agreeAs("carol", su)
  r.sync()
  # the net payments, and their reports, author-signed by who the rule says may make them
  var pA, pB = ""
  for t in settleUpOf(effectFromJson(composed.effectJson)).transfers:
    if t.frm == carol and t.to == alice and t.amount == "600": pA = settlePart(t)
    if t.frm == carol and t.to == bob and t.amount == "11366" and t.payTo == evmAddrOf["bob"]: pB = settlePart(t)
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
  if r.stateIn(su) != want: return false
  # 1. Carol pays her covered BTC share directly
  let direct = newFakeLedger()
  let (o, _) = liveSettlePartSend(r.carol, carolKs, acrossFor, hotel, newFakePartSeam(direct, "carol"), Now)
  if agreed != (o == "covered-by-settle-up"): return false
  if agreed and direct.sent.len != 0: return false
  # 2. Carol marks her own hotel share received: not hers to give
  r.carol.publishAuthored(carolKs, partEvent(hotel, partName(carol), "confirmed", carol, ""))
  r.sync()
  # 3. every member's client finishes what it may, over one ledger
  let finish = newFakeLedger()
  for who in ["alice", "bob", "carol", "dave"]:
    let (s, ks) = r.sessionOf(who)
    let marked = settleCovered(s, ks, acrossFor, newFakePartSeam(finish, who))
    if who in ["carol", "dave"] and marked.len > 0: return false
  r.sync()
  if finish.sent.len != 0: return false                 # finishing sends nothing, on any chain
  # 4. every covered share received iff final, with no payment reference
  let final = want == "final"
  for (id, debtor) in [(dinner, bob), (dinner, carol), (hotel, carol)]:
    var seen = false
    for v in reduceIntentViews(r.alice.roomEvents(), acrossFor):
      if v.id != id: continue
      for p in v.parts:
        if p.part == partName(debtor):
          seen = true
          if p.confirmed != final: return false
          if p.confirmed and p.tx.len != 0: return false
    if not seen: return false
  for id in [dinner, hotel]:
    if (r.stateIn(id) == "final") != final: return false
  true

proc state(mask: int): JsonNode = %*{"events": mask, "decision_correct": correct(mask)}

let arg = oracleStateArg()
if arg == nil:
  for mask in 0 ..< (1 shl Bits): doAssert correct(mask), "events " & $mask & " judged wrongly"
let here = oracleStateInt(arg, "events", 0)
var succ: seq[JsonNode]
for b in 0 ..< Bits:
  if not here.has(b): succ.add state(here or (1 shl b))
emitSuccessors(succ)
