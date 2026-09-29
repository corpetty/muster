## A part already being paid is never paid again (exo-a90.18). Paying sends and returns; the
## "settled" report is published only once the payment lands, so until then the log still
## shows the part unpaid. Before this, asking to pay again in that window chose the SAME part
## and sent a second payment of it: the share paid twice. The host keeps what it has in flight
## and passes it in. Held here, over a fake ledger:
##   * a debtor's share in flight: asking again sends nothing and answers "paying";
##   * a settle-up payer owing two people: with the first in flight the second is paid, then
##     "paying"; each part is sent exactly once, and the settle-up goes final;
##   * a payment in flight for ANOTHER intent does not hold this one back.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils, algorithm]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ../src/coordination/settle_up
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const PayA = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const PayB = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

var r = newRoom3("/muster/1/part-in-flight/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, effect, payTo: string): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(Now), seqNo, account = Chain & ":" & payTo, ttlSec = Ttl)

let dinner = r.alice.propose(aliceKs, splitEffectJson(Chain, "ETH", "900", alice, PayA,
                              evenShares("900", alice, @[bob, carol]), "Dinner"), PayA)
let taxi = r.bob.propose(bobKs, splitEffectJson(Chain, "ETH", "600", bob, PayB,
                          evenShares("600", bob, @[alice, carol]), "Taxi"), PayB)
discard agree(r.bob, bobKs, dinner)
doAssert agree(r.carol, room3CarolKs, dinner) == "executable"
discard agree(r.alice, aliceKs, taxi)
doAssert agree(r.carol, room3CarolKs, taxi) == "executable"
let ledger = newFakeLedger()

# ── 1. a debtor's share in flight is not paid again ───────────────────────────────
block:
  let seam = newFakePartSeam(ledger, "bob")
  let (first, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, dinner, seam, Now)
  doAssert first == "", first
  let (again, _) = liveSettlePartSend(r.bob, bobKs, splitFor, dinner, seam, Now, inFlight = @[pp])
  doAssert again == "paying", "a share already being paid is not paid twice: " & again
  doAssert ledger.sent.len == 1, "one payment sent, not two: " & $ledger.sent.len
  # a payment in flight for another intent does not hold this one back
  let (otherPay, otherPp) = liveSettlePartSend(r.alice, aliceKs, splitFor, taxi, newFakePartSeam(ledger, "alice"), Now,
                                               inFlight = @[pp])
  doAssert otherPay == "", "another intent's payment in flight is no reason: " & otherPay
  ledger.mine()
  doAssert liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp) in ["submitted", "settling"]
  doAssert liveSettlePartComplete(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"), otherPp) in
           ["submitted", "settling"]
  echo "1. a share already in flight is not paid again: 'paying', nothing sent OK"

# ── 2. a settle-up payer owing two people: the second is paid while the first flies ─
# (a fresh room: the two splits above are partly paid, so settle up Carol's two open shares)
block:
  sync()
  let open = openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", Now)
  doAssert open.len == 2 and open.allIt(it.debtor == carol), $open.len
  let su = r.alice.propose(aliceKs, settleUpEffectJson(Chain, "ETH", open, netTransfers(open), "Carol's two"), PayA)
  discard agree(r.bob, bobKs, su)
  doAssert agree(r.carol, room3CarolKs, su) == "executable"
  let seam = newFakePartSeam(ledger, "carol")
  let before = ledger.sent.len
  let (p1, pp1) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now)
  doAssert p1 == "", p1
  let (p2, pp2) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now, inFlight = @[pp1])
  doAssert p2 == "", "the other part is paid while the first is in flight: " & p2
  doAssert pp2.part != pp1.part, "a different part: " & pp1.part & " / " & pp2.part
  let (p3, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, seam, Now, inFlight = @[pp1, pp2])
  doAssert p3 == "paying", "both in flight: " & p3
  doAssert ledger.sent.len == before + 2
  let paid = ledger.sent[before .. ^1].mapIt(it.transfer.amount).sorted()
  doAssert paid == @["200", "300"], "each part once: " & $paid
  ledger.mine()
  for pp in [pp1, pp2]:
    doAssert liveSettlePartComplete(r.carol, room3CarolKs, splitFor, seam, pp) in ["submitted", "settling", "final"]
  sync()
  discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
  discard liveConfirmParts(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob"))
  sync()
  doAssert intentState(r.carol.roomEvents(), splitFor, su) == "final"
  echo "2. a payer owing two pays the second while the first is in flight; each part exactly once OK"

echo "part_in_flight_test: all OK"
