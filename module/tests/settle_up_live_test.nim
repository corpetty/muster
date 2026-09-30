## Settle up in a room (exo-3c6; docs/design/split-the-bill.md §4.11). Alice fronted dinner
## (Bob and Carol owe her 300 each); Bob fronted the taxi (Alice and Carol owe him 200 each).
## Four payments — or, settled up, two: Carol pays Alice 400 and Bob 100. Over the local
## transport and a fake ledger. Held here:
##   * a settle-up covers only agreed, unpaid parts of splits in the room, each exactly as
##     its split says: a cover that misstates a share is refused before anyone agrees;
##   * once everyone the covered parts name agrees, the covered parts are paid only through
##     the settle-up — paying one directly is refused;
##   * a payer who owes two people pays two parts; each recipient confirms their own;
##   * when the settle-up is final, each creditor's client marks the parts it covered
##     received — and the original splits are final on every member;
##   * the room's history says each covered part was paid through the settle-up, never
##     "received outside muster" (exo-a90.19: seen on a display).
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
import ../src/coordination/intent_events
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

var r = newRoom3("/muster/1/settle-up/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
proc stateOn(s: CoordinationSession, id: string): string =
  sync()
  intentState(s.roomEvents(), splitFor, id)

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
echo "0. two agreed splits: dinner (Alice owed 300 by Bob and Carol), taxi (Bob owed 200 by Alice and Carol) OK"

# ── 1. composing a settle-up from the room's open parts ──────────────────────────
sync()
let open = openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", Now)
doAssert open.len == 4, "four agreed, unpaid parts: " & $open.len
let net = netTransfers(open)
doAssert net.len == 2 and net.allIt(it.frm == carol)
let effect = settleUpEffectJson(Chain, "ETH", open, net, "Lisbon")
# a cover that misstates a share never gets anyone's agreement
var wrong = open
wrong[0].amount = $(parseInt(wrong[0].amount) + 1)
let forged = r.carol.propose(room3CarolKs, settleUpEffectJson(Chain, "ETH", wrong, netTransfers(wrong), "Forged"), PayA)
doAssert forged.startsWith("0x"), forged
doAssert agree(r.alice, aliceKs, forged).startsWith("refused"), "a cover must say exactly what its split says"
echo "1. a settle-up covers the room's agreed, unpaid parts, each exactly as its split says OK"

# ── 2. everyone agrees; the covered parts are then paid only through the settle-up ──
let su = r.alice.propose(aliceKs, effect, PayA)
doAssert su.startsWith("0x"), su
doAssert agree(r.bob, bobKs, su) == "collecting"
doAssert agree(r.carol, room3CarolKs, su) == "executable", "Alice by proposing, Bob and Carol by agreeing"
let ledger = newFakeLedger()
let (direct, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, dinner, newFakePartSeam(ledger, "carol"), Now)
doAssert direct == "covered-by-settle-up", "a covered part is paid through the settle-up: " & direct
echo "2. once agreed, a covered part is paid only through the settle-up OK"

# ── 3. Carol pays her two parts; each recipient confirms their own ─────────────────
let carolSeam = newFakePartSeam(ledger, "carol")
for _ in 0 ..< 2:
  let (outcome, pp) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, carolSeam, Now)
  doAssert outcome == "", outcome
  ledger.mine()
  doAssert liveSettlePartComplete(r.carol, room3CarolKs, splitFor, carolSeam, pp) in ["submitted", "settling", "final"]
let (third, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su, carolSeam, Now)
doAssert third == "already-settled", third
doAssert ledger.sent.mapIt(it.transfer.amount).sorted() == @["100", "400"], $ledger.sent.mapIt(it.transfer.amount)
sync()
doAssert liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice")).len == 1
doAssert liveConfirmParts(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob")).len == 1
doAssert stateOn(r.carol, su) == "final", "both net payments confirmed by their own recipients"
echo "3. Carol pays two parts (400 to Alice, 100 to Bob); each recipient confirms their own OK"

# ── 4. the settle-up final: each creditor marks what it covered received ──────────
doAssert settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice")).len == 2, "Alice's two covered parts"
doAssert settleCovered(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob")).len == 2, "Bob's two"
doAssert settleCovered(r.carol, room3CarolKs, splitFor, newFakePartSeam(ledger, "carol")).len == 0, "Carol is owed nothing"
for s in [r.alice, r.bob, r.carol]:
  doAssert stateOn(s, dinner) == "final" and stateOn(s, taxi) == "final", "both splits final on every member"
echo "4. once settled up, each creditor marks the covered parts received: both splits final on all three OK"

# ── 5. the history names the settle-up, never "received outside muster" ──────────
block:
  sync()
  var lines: seq[string]
  for a in reduceActivity(r.alice.roomEvents(), splitFor):
    if a.kind == "part-confirmed" and a.intentId in [dinner, taxi]: lines.add a.detail
  doAssert lines.len == 4, $lines
  for l in lines:
    doAssert l.startsWith("paid through a settle-up"), "a covered part names what paid it: " & l
  echo "5. the history says each covered part was paid through the settle-up OK"

echo "settle_up_live_test: all OK"
