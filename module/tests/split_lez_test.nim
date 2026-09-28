## The private split on the LEZ (exo-a90.9; docs/design/split-the-bill.md §4.6, §4.7): the
## same agreement as evm.split, settled so the chain names no payer, no payee and no
## amount. Three members in-process over the local transport, each with their OWN LEZ
## wallet on one shared fake chain (a private note lands in the recipient's wallet only,
## found by scan). Held here:
##   * payTo must be the creditor's shielded key node, the asset LEZ, and every share a
##     DIFFERENT amount — the chain names no payer, so distinct amounts are what let the
##     creditor's scan tell whose payment arrived (evenShares(distinctAmounts = true));
##   * a debtor pays on the PRIVATE rail only (shielded → shielded): paying from a public
##     account would name the payer, and is refused;
##   * the creditor confirms a part only when a private note of exactly that share has
##     arrived and is not already claimed for another share; a report without a note never
##     confirms; the reference published names a note hash, not the note;
##   * the manifest and the card say the chain learns only that a private transfer
##     happened; the room folds the split to final (invariant 4).
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils, sets, algorithm]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/split
import ../src/drivers/manifest
import ../src/drivers/profile
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/wallet/[types, lez_core, lez_adapter]
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/card_rows
import ../src/coordination/parts
import ../src/coordination/parts_lez
import ./probes/live_room

const Chain = "lez:testnet"
const Policy = "lez-split@" & Chain

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(LezSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

# one chain, three wallets: a private note lands in whoever holds its key node
let lez = newFakeLezChain()
let aliceW = newLezAdapter(newFakeLezCore(lez))
let bobW = newLezAdapter(newFakeLezCore(lez))
let carolW = newLezAdapter(newFakeLezCore(lez))
proc shielded(w: LezAdapter, ks: Keystore): Account =
  for a in w.accounts(ks):
    if a.form == afShielded: return a
proc public(w: LezAdapter, ks: Keystore): Account =
  for a in w.accounts(ks):
    if a.form == afPublic: return a
let payTo = block:
  var t = ""
  for (form, address) in aliceW.receiveAddresses(aliceKs):
    if form == "shielded": t = address
  t
doAssert payTo.startsWith("priv:"), payTo
lez.fund(shielded(bobW, bobKs).id, "5000000000")
lez.fund(shielded(carolW, room3CarolKs).id, "5000000000")
lez.fund(public(bobW, bobKs).id, "5000000000")

var r = newRoom3("/muster/1/split-lez/proto")
var seqNo = 0'u64
proc propose(effectJson: string): string =
  inc seqNo
  liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effectJson, int64(Now), seqNo,
                    account = Chain & ":" & alice, ttlSec = Ttl)
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc partOf(id, who: string): PartView =
  sync()
  for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
    if v.id == id:
      for p in v.parts:
        if p.part == partName(who): return p
  doAssert false, "no such part"
proc stateOn(s: CoordinationSession, id: string): string =
  sync()
  intentState(s.roomEvents(), splitFor, id)

const Total = "900000000"            # 0.9 LEZ (9 decimals)
let shares = evenShares(Total, alice, @[bob, carol], distinctAmounts = true)
let drv = newSplitDriver(LezSplitFamily, Chain, @[alice, bob, carol])

# ── 1. the private split's one spelling ──────────────────────────────────────────
block:
  doAssert shares.len == 2 and shares.mapIt(it.amount).deduplicate().len == 2,
           "every share a different amount: " & $shares
  doAssert shares.allIt(it.amount in ["300000000", "299999999"]), $shares
  let good = splitEffectJson(Chain, "LEZ", Total, alice, payTo, shares, "Lisbon offsite")
  doAssert drv.signRefusal(effectFromJson(good)) == "", drv.signRefusal(effectFromJson(good))
  let same = splitEffectJson(Chain, "LEZ", Total, alice, payTo, evenShares(Total, alice, @[bob, carol]), "x")
  doAssert "differ" in drv.signRefusal(effectFromJson(same)), "equal shares cannot be told apart by amount"
  let pub = splitEffectJson(Chain, "LEZ", Total, alice, public(aliceW, aliceKs).id, shares, "x")
  doAssert "payTo" in drv.signRefusal(effectFromJson(pub)), "the private split pays only a shielded key node"
  let eth = splitEffectJson(Chain, "ETH", Total, alice, payTo, shares, "x")
  doAssert "LEZ" in drv.signRefusal(effectFromJson(eth))
  echo "1. a private split: shielded payTo, LEZ, every share a distinct amount OK"

let effect = splitEffectJson(Chain, "LEZ", Total, alice, payTo, shares, "Lisbon offsite")
let id = propose(effect)
doAssert id.startsWith("0x"), id
doAssert agree(r.bob, bobKs, id) == "collecting" and agree(r.carol, room3CarolKs, id) == "executable"
proc shareOf(who: string): string =
  for s in shares:
    if s.who == who: return s.amount

# ── 2. the chain learns nothing that names anyone ───────────────────────────────
block:
  let man = drv.manifest(effectFromJson(effect))
  doAssert man.declared and consistent(man, effectFromJson(effect)), $consistencyFailures(man, effectFromJson(effect))
  let outside = man.discloses.filterIt(it.to == obChainObserver).mapIt(it.field)
  doAssert outside == @["a-private-transfer"], "only that a private transfer happened: " & $outside
  let p = drv.profile()
  doAssert p.revealsEffect == evShielded and p.revealsSigners == rvNever
  doAssert "Nothing that names a payer" in cardRows(p)[6].text
  echo "2. manifest + card: the chain learns only that a private transfer happened OK"

# ── 3. paying: private rail only, the derived share ─────────────────────────────
block:
  # paying from a PUBLIC account would take the shield rail and name the payer: refused
  let loud = newLezPartSeam(Chain, bobW, bobKs, payFrom = public(bobW, bobKs))
  let (refused, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, loud, Now)
  doAssert refused.startsWith("refused:") and "shielded" in refused, refused
  let seam = newLezPartSeam(Chain, bobW, bobKs)
  let (outcome, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, id, seam, Now)
  doAssert outcome == "", outcome
  doAssert seam.lastRail == tfPrivate, "shielded → shielded: " & $seam.lastRail
  doAssert pp.transfer.amount == shareOf(bob) and pp.transfer.to == payTo
  var st = liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp)
  doAssert st.startsWith("unconfirmed"), "a private transfer settles after a scan: " & st
  st = liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp)
  doAssert st == "submitted", st
  echo "3. Bob pays his share on the private rail only; the report waits for it to settle OK"

# ── 4. the creditor's scan confirms by exact amount — never a report alone ───────
block:
  let aliceSeam = newLezPartSeam(Chain, aliceW, aliceKs)
  # Carol reports a payment she never made
  r.carol.publishAuthored(room3CarolKs, partEvent(id, partName(carol), "settled", carol, "tx-made-up"))
  let confirmed = liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  doAssert confirmed == @[id & "/" & partName(bob)], "only Bob's note arrived: " & $confirmed
  doAssert partOf(id, bob).confirmed and partOf(id, bob).tx.startsWith("note:"), partOf(id, bob).tx
  doAssert "recv" notin partOf(id, bob).tx and partOf(id, bob).tx.len == "note:".len + 32,
           "a note HASH, never the note's account id: " & partOf(id, bob).tx
  doAssert not partOf(id, carol).confirmed, "a report without a note never confirms"
  echo "4. the creditor's scan matched Bob's note by its exact amount; Carol's claim alone confirms nothing OK"

# ── 5. Carol pays; the split is final on every member ───────────────────────────
block:
  # her made-up report stands as her claim, so her client says so rather than pay twice…
  let (again, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, id, newLezPartSeam(Chain, carolW, room3CarolKs), Now)
  doAssert again == "already-settled", again
  # …but the payment she then really makes is what the creditor's scan finds
  let seam = newLezPartSeam(Chain, carolW, room3CarolKs)
  let sent = seam.sendPart(drv.partTransfer(effectFromJson(effect), partName(carol)))
  doAssert sent.ok, sent.detail
  let aliceSeam = newLezPartSeam(Chain, aliceW, aliceKs)
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam) == @[id & "/" & partName(carol)]
  for s in [r.alice, r.bob, r.carol]:
    doAssert stateOn(s, id) == "final", "final on every member"
  echo "5. Carol's note arrives; every share confirmed; final on all three OK"

# ── 6. a note settles at most one share ─────────────────────────────────────────
block:
  let id2 = propose(splitEffectJson(Chain, "LEZ", Total, alice, payTo, shares, "Lisbon, again"))
  doAssert agree(r.bob, bobKs, id2) == "collecting" and agree(r.carol, room3CarolKs, id2) == "executable"
  # Bob claims the dinner payment for the second split too: the note is already claimed
  r.bob.publishAuthored(bobKs, partEvent(id2, partName(bob), "settled", bob, "tx-old"))
  let aliceSeam = newLezPartSeam(Chain, aliceW, aliceKs)
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam).len == 0
  let why = liveConfirmPart(r.alice, aliceKs, splitFor, id2, partName(bob), aliceSeam, "tx-old")
  doAssert why.startsWith("unconfirmed") and "no unclaimed" in why, why
  echo "6. an already-claimed note never confirms a second share OK"

echo "split_lez_test: all OK"
