## Paying and confirming a share, on the live room path (exo-a90.4; docs/design/split-the-bill.md
## §4.4–§4.5). Three members in-process over the local transport: Alice fronted dinner and
## proposes the split; Bob and Carol each owe her. A fake ledger stands in for the chain
## (the PartSeam is the only thing that touches one). Held here:
##   * nobody pays before everyone named has agreed; only a party pays, once; a split is
##     never submitted whole ("settles-in-parts");
##   * the payment handed to the wallet is the one DERIVED from the agreed effect — share,
##     payTo, asset, chain — and nothing a caller supplies (invariant 1);
##   * a report is published only once the payer's own transfer landed;
##   * the creditor confirms only what her own read shows paying her the share; one
##     transaction settles at most one share; she can mark a share received outside muster;
##   * paying against an expired agreement is refused (invariant 2);
##   * all three members fold the same split to final (invariant 4).
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils, tables]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds      # newUnsupportedDriver
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/parts
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let roster = @[alice, bob, carol]

let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, roster) else: newUnsupportedDriver(policy)

var r = newRoom3("/muster/1/split-live/proto")
var seqNo = 0'u64
proc propose(effectJson: string, ttl = Ttl): string =
  inc seqNo
  liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effectJson, int64(Now), seqNo,
                    account = Chain & ":" & AlicePayTo, ttlSec = ttl)
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc stateOn(s: CoordinationSession, id: string): string =
  sync()
  intentState(s.roomEvents(), splitFor, id)
proc partOf(id, who: string): PartView =
  sync()
  for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
    if v.id == id:
      for p in v.parts:
        if p.part == partName(who): return p
  doAssert false, "no such part"

let ledger = newFakeLedger()
let bobSeam = newFakePartSeam(ledger, "bob")
let carolSeam = newFakePartSeam(ledger, "carol")
let aliceSeam = newFakePartSeam(ledger, "alice")

let dinner = splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                             evenShares("900", alice, @[bob, carol]), "Dinner at Tasca")
let id = propose(dinner)

# ── 1. proposing: a well-formed split among members; anything else refused ────────
block:
  doAssert id.startsWith("0x"), "the split is proposed: " & id
  let stranger = repeat("ab", 64)
  let bad = splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                            evenShares("900", alice, @[bob, stranger]), "Dinner")
  let refused = propose(bad)
  doAssert refused.startsWith("refused:") and "not a member" in refused, refused
  echo "1. a split among members is proposed; one naming a stranger is refused OK"

# ── 2. nobody pays before everyone named has agreed — the creditor at propose ─────
block:
  let (early, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, bobSeam, Now)
  doAssert early == "not-agreed", early
  # Alice proposed her own split: her agreement was made then (exo-770); again is a no-op
  doAssert agree(r.alice, aliceKs, id) == "collecting", "the creditor has agreed; the debtors have not"
  doAssert agree(r.bob, bobKs, id) == "collecting"
  doAssert agree(r.carol, room3CarolKs, id) == "executable"
  doAssert ledger.sent.len == 0, "nothing was sent before agreement"
  echo "2. no payment before every debtor agreed; the creditor agreed at propose, and cannot agree for them OK"

# ── 3. a split is never submitted whole, and only a party pays ────────────────────
block:
  doAssert liveSubmitPrecheck(r.alice, splitFor, id, Now) == "settles-in-parts"
  let (notParty, _) = liveSettlePartSend(r.alice, aliceKs, splitFor, id, aliceSeam, Now)
  doAssert notParty == "not-a-party", notParty
  echo "3. coordinate_submit refuses a split ('settles-in-parts'); a non-party cannot pay OK"

# ── 4. Bob pays: the transfer is DERIVED, the report waits for his own tx ─────────
block:
  let (outcome, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, id, bobSeam, Now)
  doAssert outcome == "", outcome
  doAssert ledger.sent.len == 1
  let t = ledger.sent[0].transfer
  doAssert t.chain == Chain and t.asset == "ETH" and t.to == AlicePayTo and t.amount == "300",
           "the payment is the agreed share, to the agreed address: " & $t
  doAssert ledger.sent[0].payer == "bob"
  let pending = liveSettlePartComplete(r.bob, bobKs, splitFor, bobSeam, pp)
  doAssert pending.startsWith("unconfirmed"), "no report until Bob's own transfer landed: " & pending
  doAssert not partOf(id, bob).settled
  ledger.mine()
  doAssert liveSettlePartComplete(r.bob, bobKs, splitFor, bobSeam, pp) == "submitted"
  doAssert partOf(id, bob).settled and partOf(id, bob).tx == pp.tx
  doAssert stateOn(r.carol, id) == "submitted", "every member sees Bob's report"
  let (twice, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, bobSeam, Now)
  doAssert twice == "already-settled", twice
  echo "4. Bob pays exactly his agreed share; the report waits for his tx to land; never twice OK"

# ── 5. the creditor confirms what her own read shows — nothing else ──────────────
block:
  let confirmed = liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  doAssert confirmed == @[id & "/" & partName(bob)], $confirmed
  doAssert partOf(id, bob).confirmed and stateOn(r.bob, id) == "settling"
  # Carol reports a payment that does not pay the share (one short), made outside the path
  let short = carolSeam.sendPart(PartTransfer(ok: true, chain: Chain, asset: "ETH", to: AlicePayTo, amount: "299")).tx
  ledger.mine()
  r.carol.publishAuthored(room3CarolKs, partEvent(id, partName(carol), "settled", carol, short))
  doAssert partOf(id, carol).settled, "Carol's own report counts as HER claim…"
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam).len == 0
  doAssert not partOf(id, carol).confirmed, "…but the creditor's read does not confirm a short payment"
  doAssert "amount" in liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, short)
  echo "5. the creditor confirms Bob from her own read; a short payment is never confirmed OK"

# ── 6. one transaction settles at most one share ─────────────────────────────────
block:
  let lunch = splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                              evenShares("900", alice, @[bob, carol]), "Lunch")
  let id2 = propose(lunch)
  doAssert agree(r.bob, bobKs, id2) == "collecting" and agree(r.carol, room3CarolKs, id2) == "executable"
  # Bob claims the payment he already made for dinner — the same amount, the same payee
  r.bob.publishAuthored(bobKs, partEvent(id2, partName(bob), "settled", bob, partOf(id, bob).tx))
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam).len == 0
  let why = liveConfirmPart(r.alice, aliceKs, splitFor, id2, partName(bob), aliceSeam, partOf(id, bob).tx)
  doAssert "already settled another share" in why, why
  # received outside muster: the creditor's word, no chain reference
  doAssert liveConfirmPart(r.alice, aliceKs, splitFor, id2, partName(bob), aliceSeam, "") in ["settling", "submitted"]
  doAssert partOf(id2, bob).confirmed and partOf(id2, bob).tx == ""
  # only the creditor can confirm
  doAssert liveConfirmPart(r.bob, bobKs, splitFor, id2, partName(carol), bobSeam, "") == "not-the-counterparty"
  echo "6. one payment settles one share; the creditor can mark one received outside muster OK"

# ── 7. Carol pays properly; the split is final on every member ───────────────────
block:
  let (outcome, pp) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, id, carolSeam, Now)
  doAssert outcome == "already-settled", "Carol's short report stands as her claim: " & outcome
  # the room sees her claim unconfirmed; she settles the difference outside muster and the
  # creditor marks it received — the creditor's word is the authority on what she received
  doAssert liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, "") == "final"
  for s in [r.alice, r.bob, r.carol]:
    doAssert stateOn(s, id) == "final", "every member folds the split to final (inv 4)"
  echo "7. every share confirmed: final on all three members OK"

# ── 8. paying against an expired agreement is refused (invariant 2) ──────────────
block:
  let quick = splitEffectJson(Chain, "ETH", "60", alice, AlicePayTo,
                              evenShares("60", alice, @[bob, carol]), "Coffee")
  let id3 = propose(quick, ttl = 60)
  doAssert agree(r.bob, bobKs, id3) == "collecting" and agree(r.carol, room3CarolKs, id3) == "executable"
  let (late, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id3, bobSeam, Now + 61)
  doAssert late == "expired", late
  let (onTime, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id3, bobSeam, Now + 59)
  doAssert onTime == "", onTime
  echo "8. a payment against an expired agreement is refused OK"

echo "split_live_test: all OK"
