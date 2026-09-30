## An expired settle-up (exo-a90.16; docs/design/split-the-bill.md §4.11). A settle-up covers
## other splits' shares: once it is agreed, those shares are paid only through it. Its own
## payments are refused after its expiry (invariant 2), so an agreed settle-up that expired
## unpaid used to lock the shares it covered for good: they could not be paid directly, through
## it, or through another settle-up. Held here:
##   * nothing paid: an expired settle-up releases the shares it covered once its expiry AND a
##     grace window have passed (a payment sent just before the expiry may still be reported
##     inside that window); after that they can be paid directly and a new settle-up may cover
##     them;
##   * partly paid: a settle-up whose payments have begun is finished, never abandoned. Its
##     remaining payments go ahead past the expiry, and the shares it covers stay covered,
##     because paying them directly would pay twice what the netting already moved;
##   * a settle-up with nothing to pay (debts that cancel exactly) is settled on agreement and
##     never releases anything;
##   * a plain split is untouched: a debtor's payment after its expiry is still refused,
##     whether or not a share was paid (derived-exo-a90 s1);
##   * Home asks a member to pay only what paying would go ahead with: never a covered share,
##     never an expired settle-up that paid nothing;
##   * the grace window outlasts every seam's deadline for a payment in flight.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils]
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
import ../src/coordination/parts_lez
import ../src/coordination/covers
import ../src/coordination/settle_up
import ../src/coordination/attest
import ../src/coordination/home
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const PayA = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const PayB = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
const Month = 30'i64 * 24 * 3600      # the splits outlive every clock below

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, effect, payTo: string, at: uint64, ttl: int64): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(at), seqNo, account = Chain & ":" & payTo, ttlSec = ttl)
proc agree(s: CoordinationSession, ks: Keystore, id: string, at: uint64): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), at)
proc homeAsks(s: CoordinationSession, ks: Keystore, id: string, at: uint64): string =
  ## What Home asks of this member on `id` at `at` ("" = nothing).
  s.poll()
  for it in homeItems(s.roomEvents(), splitFor, ks.encIdentity(), myContributorNames(ks), at):
    if it.id == id: return (if it.cls == hcNeedsYou: it.what else: "")

# ── 0. the grace window outlasts every in-flight payment's deadline ──────────────
block:
  doAssert float(CoverReleaseGraceS) > PartSeam().payDeadlineS(), "longer than a public payment may take to land"
  doAssert float(CoverReleaseGraceS) > LezPartSeam().payDeadlineS(), "longer than a proving payment may take to land"
  echo "0. the grace window (", CoverReleaseGraceS, " s) outlasts every seam's pay deadline OK"

# Alice fronted dinner (Bob and Carol owe her 300 each); Bob fronted the taxi (Alice and Carol
# owe him 200 each). Both splits last a month; each settle-up below lasts Ttl (an hour).
var r = newRoom3("/muster/1/settle-up-expiry/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
let dinner = r.alice.propose(aliceKs, splitEffectJson(Chain, "ETH", "900", alice, PayA,
                              evenShares("900", alice, @[bob, carol]), "Dinner"), PayA, Now, Month)
let taxi = r.bob.propose(bobKs, splitEffectJson(Chain, "ETH", "600", bob, PayB,
                          evenShares("600", bob, @[alice, carol]), "Taxi"), PayB, Now, Month)
discard agree(r.bob, bobKs, dinner, Now)
doAssert agree(r.carol, room3CarolKs, dinner, Now) == "executable"
discard agree(r.alice, aliceKs, taxi, Now)
doAssert agree(r.carol, room3CarolKs, taxi, Now) == "executable"
let ledger = newFakeLedger()
let carolSeam = newFakePartSeam(ledger, "carol")
let bobSeam = newFakePartSeam(ledger, "bob")

# ── 1. nothing paid: the expired settle-up's covers hold through the grace window ─
sync()
let open0 = openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", Now)
doAssert open0.len == 4, $open0.len
let su1 = r.alice.propose(aliceKs, settleUpEffectJson(Chain, "ETH", open0, netTransfers(open0), "Lisbon"), PayA, Now, Ttl)
doAssert su1.startsWith("0x"), su1
discard agree(r.bob, bobKs, su1, Now)
doAssert agree(r.carol, room3CarolKs, su1, Now) == "executable"
doAssert homeAsks(r.carol, room3CarolKs, su1, Now) == "pay", "Carol pays through the settle-up"
doAssert homeAsks(r.carol, room3CarolKs, dinner, Now) == "", "never the covered share itself"
let expired = Now + uint64(Ttl) + 1
block:
  doAssert homeAsks(r.carol, room3CarolKs, su1, expired) == "", "an expired settle-up that paid nothing asks nothing"
  doAssert homeAsks(r.carol, room3CarolKs, dinner, expired) == "", "inside the grace window the share is still covered"
  let (own, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su1, carolSeam, expired)
  doAssert own == "expired", "the settle-up's own payment is refused past its expiry: " & own
  let (direct, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, dinner, carolSeam, expired)
  doAssert direct == "covered-by-settle-up", "inside the grace window the covers hold: " & direct
  sync()
  doAssert openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", expired).len == 0
  doAssert ledger.sent.len == 0
  echo "1. an expired, unpaid settle-up pays nothing; inside the grace window its covers still hold OK"

# ── 2. past the grace window: the covered shares are released ────────────────────
let released = Now + uint64(Ttl) + CoverReleaseGraceS + 1
block:
  sync()
  doAssert coveringIntent(r.alice.roomEvents(), splitFor, dinner, partName(bob), released) == "",
           "an expired settle-up that never paid covers nothing"
  doAssert coveringIntent(r.alice.roomEvents(), splitFor, dinner, partName(bob), expired) == su1,
           "the same settle-up, read inside the grace window, still covers it"
  doAssert openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", released).len == 4
  doAssert homeAsks(r.carol, room3CarolKs, dinner, released) == "pay", "a released share is Carol's to pay again"
  # Bob pays his dinner share directly again
  let (outcome, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, dinner, bobSeam, released)
  doAssert outcome == "", "a released share is payable directly: " & outcome
  ledger.mine()
  doAssert liveSettlePartComplete(r.bob, bobKs, splitFor, bobSeam, pp) in ["submitted", "settling"]
  let (again, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su1, carolSeam, released)
  doAssert again == "expired", "the lapsed settle-up itself stays unpayable: " & again
  echo "2. past its expiry and the grace window, the settle-up's shares are payable directly again OK"

# ── 3. a new settle-up may cover the released shares; once it pays, it finishes ──
sync()
let open1 = openParts(r.alice.roomEvents(), splitFor, Chain, "ETH", released)
doAssert open1.len == 3, "Bob's dinner share is paid; three remain: " & $open1.len
let net1 = netTransfers(open1)
doAssert net1.len == 2 and net1.allIt(it.frm == carol), $net1.len
let su2 = r.alice.propose(aliceKs, settleUpEffectJson(Chain, "ETH", open1, net1, "Lisbon again"), PayA, released, Ttl)
doAssert su2.startsWith("0x"), su2
doAssert agree(r.bob, bobKs, su2, released) == "collecting", "the lapsed settle-up no longer blocks the cover check"
doAssert agree(r.carol, room3CarolKs, su2, released) == "executable"
block:
  let (first, pp) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su2, carolSeam, released)
  doAssert first == "", first
  ledger.mine()
  doAssert liveSettlePartComplete(r.carol, room3CarolKs, splitFor, carolSeam, pp) == "submitted"
echo "3. a new settle-up covers the released shares; Carol pays the first of her two parts OK"

# ── 4. partly paid and expired: it finishes, and its covers never lapse ──────────
let late = released + uint64(Ttl) + CoverReleaseGraceS + 1
block:
  sync()
  doAssert coveringIntent(r.carol.roomEvents(), splitFor, taxi, partName(carol), late) == su2,
           "a settle-up that has paid keeps covering, however late"
  let (direct, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, taxi, carolSeam, late)
  doAssert direct == "covered-by-settle-up", "paying a covered share directly would pay twice: " & direct
  doAssert openParts(r.carol.roomEvents(), splitFor, Chain, "ETH", late).len == 0
  doAssert homeAsks(r.carol, room3CarolKs, su2, late) == "pay", "the rest of a started settle-up is still hers to pay"
  doAssert homeAsks(r.carol, room3CarolKs, taxi, late) == "", "the share it covers is not"
  let (second, pp) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, su2, carolSeam, late)
  doAssert second == "", "a settle-up that began paying is finished past its expiry: " & second
  ledger.mine()
  doAssert liveSettlePartComplete(r.carol, room3CarolKs, splitFor, carolSeam, pp) == "submitted"
  sync()
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice")).len >= 1
  doAssert liveConfirmParts(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob")).len >= 1
  sync()
  doAssert intentState(r.carol.roomEvents(), splitFor, su2) == "final"
  discard settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
  discard settleCovered(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob"))
  sync()
  for s in [r.alice, r.bob, r.carol]:
    doAssert intentState(s.roomEvents(), splitFor, dinner) == "final", "dinner final on every member"
    doAssert intentState(s.roomEvents(), splitFor, taxi) == "final", "taxi final on every member"
  let paid = ledger.sent.mapIt(parseInt(it.transfer.amount))
  doAssert paid.foldl(a + b) == 300 + 500, "Bob's 300 directly, then Carol's 500 net; nothing twice: " & $paid
  echo "4. a partly-paid settle-up finishes past its expiry; its covered shares are never paid twice OK"

# ── 5. debts that cancel exactly: settled on agreement, nothing to release ───────
block:
  var q = newRoom3("/muster/1/settle-up-expiry-cancel/proto")
  proc qsync() = (q.alice.poll(); q.bob.poll(); q.carol.poll())
  let ab = q.alice.propose(aliceKs, splitEffectJson(Chain, "ETH", "200", alice, PayA,
                            evenShares("200", alice, @[bob]), "Coffee"), PayA, Now, Month)
  let ba = q.bob.propose(bobKs, splitEffectJson(Chain, "ETH", "200", bob, PayB,
                          evenShares("200", bob, @[alice]), "Tea"), PayB, Now, Month)
  doAssert agree(q.bob, bobKs, ab, Now) == "executable"
  doAssert agree(q.alice, aliceKs, ba, Now) == "executable"
  qsync()
  let open = openParts(q.alice.roomEvents(), splitFor, Chain, "ETH", Now)
  doAssert open.len == 2 and netTransfers(open).len == 0, "the two debts cancel"
  let su = q.alice.propose(aliceKs, settleUpEffectJson(Chain, "ETH", open, @[], "Even"), PayA, Now, Ttl)
  doAssert agree(q.bob, bobKs, su, Now) == "executable"
  qsync()
  let farLate = Now + uint64(Ttl) + CoverReleaseGraceS + 1
  doAssert coveringIntent(q.bob.roomEvents(), splitFor, ab, partName(bob), farLate) == su,
           "a settle-up with nothing to pay is settled on agreement: it never lapses"
  let (direct, _) = liveSettlePartSend(q.bob, bobKs, splitFor, ab, newFakePartSeam(newFakeLedger(), "bob"), farLate)
  doAssert direct == "covered-by-settle-up", direct
  echo "5. a settle-up with nothing to pay never lapses: the debts it cancelled stay cancelled OK"

# ── 6. a plain split is untouched: past its expiry, no share is paid ──────────────
block:
  var q = newRoom3("/muster/1/split-expiry/proto")
  let lunch = q.alice.propose(aliceKs, splitEffectJson(Chain, "ETH", "900", alice, PayA,
                               evenShares("900", alice, @[bob, carol]), "Lunch"), PayA, Now, Ttl)
  discard agree(q.bob, bobKs, lunch, Now)
  doAssert agree(q.carol, room3CarolKs, lunch, Now) == "executable"
  let l = newFakeLedger()
  let (paid, pp) = liveSettlePartSend(q.bob, bobKs, splitFor, lunch, newFakePartSeam(l, "bob"), Now)
  doAssert paid == "", paid
  l.mine()
  doAssert liveSettlePartComplete(q.bob, bobKs, splitFor, newFakePartSeam(l, "bob"), pp) == "submitted"
  let (late, _) = liveSettlePartSend(q.carol, room3CarolKs, splitFor, lunch, newFakePartSeam(l, "carol"),
                                     Now + uint64(Ttl) + CoverReleaseGraceS + 1)
  doAssert late == "expired", "a split's payment after its expiry is refused, one share paid or not: " & late
  echo "6. a plain split's payment after its expiry is still refused, even once a share is paid OK"

echo "settle_up_expiry_test: all OK"
