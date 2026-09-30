## Renewing an expired split (exo-a90.15; docs/design/split-the-bill.md §4.12). An agreement is
## bounded (invariant 2): past a split's expiry no share of it is paid. Before this, nothing got
## the room out — re-proposing the same split gave the same intent id, whose first (expired)
## context still bound it. Now:
##   * a renewal is a settle-up of that one split: it covers exactly its unpaid shares, as the
##     split says them, and every person those shares name agrees again, under a fresh expiry;
##     once it is paid and final, each creditor marks the shares it covered received and the
##     split is final — the settle-up path, unchanged (exo-3c6, exo-a90.16);
##   * a renewal names when it was made, so renewing again (after a renewal lapsed) is a new
##     intent with its own expiry, never the old one;
##   * the private split is never renewed this way (it is never netted): it is proposed again;
##   * proposing an intent identical to one that expired here is refused and says why —
##     never a silent no-op bound to the old expiry.
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
import ../src/coordination/covers
import ../src/coordination/settle_up
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const PayA = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

var r = newRoom3("/muster/1/split-renew/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc agree(s: CoordinationSession, ks: Keystore, id: string, at: uint64): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), at)
var seqNo = 0'u64
proc propose(s: CoordinationSession, ks: Keystore, effect: string, at: uint64): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(at), seqNo, account = Chain & ":" & PayA, ttlSec = Ttl)

let dinnerEffect = splitEffectJson(Chain, "ETH", "900", alice, PayA, evenShares("900", alice, @[bob, carol]), "Dinner")
let dinner = r.alice.propose(aliceKs, dinnerEffect, Now)
discard agree(r.bob, bobKs, dinner, Now)
doAssert agree(r.carol, room3CarolKs, dinner, Now) == "executable"
let ledger = newFakeLedger()
block:   # Bob pays in time
  let (o, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, dinner, newFakePartSeam(ledger, "bob"), Now)
  doAssert o == "", o
  ledger.mine()
  discard liveSettlePartComplete(r.bob, bobKs, splitFor, newFakePartSeam(ledger, "bob"), pp)
let late = Now + uint64(Ttl) + 1
block:   # Carol does not
  let (o, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, dinner, newFakePartSeam(ledger, "carol"), late)
  doAssert o == "expired", o
echo "0. a split agreed; Bob paid in time; past its expiry Carol's payment is refused OK"

# ── 1. proposing the identical split again is refused, and says why ───────────────
block:
  sync()
  let again = r.alice.propose(aliceKs, dinnerEffect, late)
  doAssert again == "expired-duplicate", "an identical intent that expired here: " & again
  echo "1. re-proposing the identical split: 'expired-duplicate', not a silent no-op OK"

# ── 2. a renewal: a settle-up of that one split, its unpaid shares only ────────────
var renewal = ""
block:
  sync()
  let rn = renewalOf(r.alice.roomEvents(), splitFor, dinner, late)
  doAssert rn.why == "", rn.why
  doAssert rn.covers.len == 1 and rn.covers[0].debtor == carol and rn.covers[0].amount == "300",
           "only Carol's unpaid share: " & $rn.covers.len
  let e = parseJson(rn.effectJson)
  doAssert e["effect"].getStr() == "settle-up" and e["transfers"].len == 1
  doAssert "Renewed" in e["memo"].getStr() and "Dinner" in e["memo"].getStr(), e["memo"].getStr()
  renewal = r.alice.propose(aliceKs, rn.effectJson, late)
  doAssert renewal.startsWith("0x"), renewal
  doAssert agree(r.carol, room3CarolKs, renewal, late) == "executable", "Alice by proposing, Carol by agreeing again"
  echo "2. a renewal covers exactly the split's unpaid share; everyone it names agrees again OK"

# ── 3. paid through the renewal; the split goes final ──────────────────────────────
block:
  let (direct, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, dinner, newFakePartSeam(ledger, "carol"), late)
  doAssert direct == "covered-by-settle-up", direct
  let (o, pp) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, renewal, newFakePartSeam(ledger, "carol"), late)
  doAssert o == "", "paid under the renewal's own, fresh expiry: " & o
  ledger.mine()
  discard liveSettlePartComplete(r.carol, room3CarolKs, splitFor, newFakePartSeam(ledger, "carol"), pp)
  sync()
  discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
  sync()
  doAssert intentState(r.alice.roomEvents(), splitFor, renewal) == "final"
  discard settleCovered(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))
  discard liveConfirmParts(r.alice, aliceKs, splitFor, newFakePartSeam(ledger, "alice"))   # Bob's, in time
  sync()
  for s in [r.alice, r.bob, r.carol]:
    doAssert intentState(s.roomEvents(), splitFor, dinner) == "final", "the split is final on every member"
  echo "3. Carol pays through the renewal; the split is final on all three OK"

# ── 4. renewing again after a renewal lapsed: a new intent, a fresh expiry ─────────
block:
  var q = newRoom3("/muster/1/split-renew-twice/proto")
  let lunch = q.alice.propose(aliceKs, splitEffectJson(Chain, "ETH", "600", alice, PayA,
                                evenShares("600", alice, @[bob]), "Lunch"), Now)
  doAssert agree(q.bob, bobKs, lunch, Now) == "executable"
  q.alice.poll()
  let first = renewalOf(q.alice.roomEvents(), splitFor, lunch, late)
  let r1 = q.alice.propose(aliceKs, first.effectJson, late)
  doAssert agree(q.bob, bobKs, r1, late) == "executable"
  # the renewal lapses unpaid (its expiry and the grace window pass)
  let later = late + uint64(Ttl) + CoverReleaseGraceS + 1
  q.alice.poll()
  let second = renewalOf(q.alice.roomEvents(), splitFor, lunch, later)
  doAssert second.why == "", second.why
  let r2 = q.alice.propose(aliceKs, second.effectJson, later)
  doAssert r2.startsWith("0x") and r2 != r1, "a new intent, never the lapsed one: " & r2
  doAssert agree(q.bob, bobKs, r2, later) == "executable", "agreed under its own, fresh expiry"
  echo "4. renewing again after a renewal lapsed is a new intent with its own expiry OK"

# ── 5. what cannot be renewed says why ──────────────────────────────────────────────
block:
  sync()
  doAssert renewalOf(r.alice.roomEvents(), splitFor, dinner, late + 10).why.len > 0, "a final split has nothing to renew"
  doAssert renewalOf(r.alice.roomEvents(), splitFor, "0xnope", late).why.len > 0
  echo "5. a final split, or none, has nothing to renew — and says so OK"

echo "split_renew_test: all OK"
