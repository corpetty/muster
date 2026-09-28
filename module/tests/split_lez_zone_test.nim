## The private split against the zone as it really behaves (exo-a90.9's testnet run —
## exo-66e, exo-9b7, exo-15c). split_lez_test holds the private split on a fake that is
## kinder than the LEZ in three ways; this test takes each kindness away:
##   * a wallet's scan catches up in STEPS — a fresh wallet on testnet starts at block 0,
##     and one scan to a tip ~29k blocks away does not fit a call's budget (walkSync). While
##     it is behind, the creditor's scan and the debtor's payment both say so, and neither
##     guesses;
##   * money received privately — a shield to your own key node included — lands at a
##     DISCOVERED account, never the one muster created, so a debtor pays from whichever
##     one note of theirs covers the share, and is told honestly when none does;
##   * a proof runs in the BACKGROUND: the send returns a marker, the report waits for the
##     zone's answer, carries the zone's transaction hash rather than the marker, and the
##     pay deadline outlasts the proving budget.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils, sequtils]
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/wallet/[types, lez_core, lez_adapter]
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/authorship
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

# ── 1. a scan walks to the tip in bounded steps ──────────────────────────────────
block:
  var steps: seq[int]
  var t = 0.0
  let clock = proc(): float = t
  let ok = proc(b: int): bool = (steps.add b; t += 3.0; true)
  # a fresh wallet, far behind: 500-block steps, but only as many as the budget allows
  var (code, reached) = walkSync(0, 29083, 500, 4.0, ok, clock)
  doAssert code == LezSyncBehind and reached == 1000 and steps == @[500, 1000], $(code, reached, steps)
  # called again, it carries on from where it stopped, and reaches the tip exactly
  steps = @[]
  (code, reached) = walkSync(28000, 29083, 500, 1000.0, ok, clock)
  doAssert code == LezSyncOk and reached == 29083 and steps == @[28500, 29000, 29083], $(code, reached, steps)
  # at the tip already: nothing to do
  steps = @[]
  doAssert walkSync(29083, 29083, 500, 4.0, ok, clock) == (LezSyncOk, 29083) and steps.len == 0
  # a step that fails is a failed scan, reported at the last block that did sync
  let failAt = proc(b: int): bool = b < 1500
  doAssert walkSync(0, 29083, 500, 1000.0, failAt, clock) == (LezSyncFailed, 1000)
  echo "1. a scan walks to the tip in bounded steps, resumes, and reports failure honestly OK"

# three wallets on one chain, as in split_lez_test — but funded the zone's way
let lez = newFakeLezChain()
let aliceCore = newFakeLezCore(lez)
let bobCore = newFakeLezCore(lez)
let carolCore = newFakeLezCore(lez)
let aliceW = newLezAdapter(aliceCore)
let bobW = newLezAdapter(bobCore)
let carolW = newLezAdapter(carolCore)
proc form(w: LezAdapter, ks: Keystore, f: AccountForm): Account =
  for a in w.accounts(ks):
    if a.form == f: return a
proc keyNode(w: LezAdapter, ks: Keystore): string =
  for (f, address) in w.receiveAddresses(ks):
    if f == "shielded": return address
proc shieldToSelf(w: LezAdapter, ks: Keystore, raw: string) =
  ## The zone's funding path: faucet → public, then shield to MY OWN key node. The note
  ## lands at an account the scan discovers — not the shielded account muster created.
  let native = w.describe().nativeAsset
  let tx = w.prepareTransfer(form(w, ks, afPublic), keyNode(w, ks), Amount(asset: native, raw: raw))
  doAssert parseJson(tx.payload)["form"].getStr() == "shield"
  discard w.submit(tx, ks)
let payTo = keyNode(aliceW, aliceKs)

var r = newRoom3("/muster/1/split-lez-zone/proto")
proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
proc partOf(id, who: string): PartView =
  sync()
  for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
    if v.id == id:
      for p in v.parts:
        if p.part == partName(who): return p
  doAssert false, "no such part"

const Total = "900000000"
let shares = evenShares(Total, alice, @[bob, carol], distinctAmounts = true)
proc shareOf(who: string): string =
  for s in shares:
    if s.who == who: return s.amount
let effect = splitEffectJson(Chain, "LEZ", Total, alice, payTo, shares, "Lisbon offsite")
let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, effect, int64(Now), 1,
                           account = Chain & ":" & alice, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
doAssert liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now) == "collecting"
doAssert liveContribute(r.carol, room3CarolKs, splitFor, id, "", "", bindCtx(), Now) == "executable"

# ── 2. a debtor pays from the one note that covers the share ─────────────────────
lez.fund(form(bobW, bobKs, afPublic).id, "2000000000")
shieldToSelf(bobW, bobKs, "1000000000")
block:
  # Bob's wallet is behind the tip: it cannot see the note it would spend, so it says so
  bobCore.lagSyncs = 1
  let behind = newLezPartSeam(Chain, bobW, bobKs)
  let (refused, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, behind, Now)
  doAssert refused.startsWith("refused:") and "scanning" in refused, refused
  doAssert aliceW.receivedNotes(aliceKs).len == 0, "nothing was sent"
  # caught up: the self-shielded note is a discovered account, and it is what pays
  bobCore.asyncTransfers = true          # and the proof runs in the background, as the zone's does
  let seam = newLezPartSeam(Chain, bobW, bobKs)
  let (outcome, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, id, seam, Now)
  doAssert outcome == "", "pays from the discovered note: " & outcome
  doAssert seam.lastRail == tfPrivate and pp.transfer.amount == shareOf(bob)
  doAssert bobW.balance(form(bobW, bobKs, afShielded), bobW.describe().nativeAsset).raw == "0",
           "the account muster created never held the money"
  echo "2. Bob's wallet says it is still scanning, then pays from the discovered note that covers his share OK"

  # ── 3. the proof runs in the background; the report carries the zone's hash ─────
  doAssert pp.tx == "pending", "an async send returns a marker at once: " & pp.tx
  var st = liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp)
  doAssert st.startsWith("unconfirmed") and "proving" in st, st
  for _ in 0 ..< 4:
    if not st.startsWith("unconfirmed"): break
    st = liveSettlePartComplete(r.bob, bobKs, splitFor, seam, pp)
  doAssert st == "submitted", st
  let reported = partOf(id, bob).tx
  doAssert reported.len > 0 and reported != "pending", "the zone's transaction hash, not the marker: " & reported
  doAssert seam.payDeadlineS() > float(LezProveBudgetMs) / 1000.0,
           "the pay deadline outlasts the proving budget: " & $seam.payDeadlineS()
  doAssert newFakePartSeam(newFakeLedger(), "x").payDeadlineS() == 600.0, "a public rail keeps its deadline"
  echo "3. the proof lands in the background; Bob's report names the zone's transaction; the deadline outlasts the proof OK"

# ── 4. the creditor's scan, behind the tip, says so — then confirms ──────────────
block:
  let aliceSeam = newLezPartSeam(Chain, aliceW, aliceKs)
  aliceCore.lagSyncs = 2
  let why = liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(bob), aliceSeam, partOf(id, bob).tx)
  doAssert why.startsWith("unconfirmed") and "scanning" in why, "behind the tip is not 'nothing arrived': " & why
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam).len == 0    # the second lagging scan
  doAssert liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam) == @[id & "/" & partName(bob)]
  doAssert partOf(id, bob).confirmed and partOf(id, bob).tx.startsWith("note:")
  echo "4. Alice's scan says it is still catching up, then finds Bob's note of exactly his share OK"

# ── 5. no single note covers the share: refused, and nothing moves ───────────────
block:
  lez.fund(form(carolW, room3CarolKs, afPublic).id, "600000000")
  shieldToSelf(carolW, room3CarolKs, "200000000")
  shieldToSelf(carolW, room3CarolKs, "200000000")       # 400000000 private, in two notes
  let seam = newLezPartSeam(Chain, carolW, room3CarolKs)
  let (refused, _) = liveSettlePartSend(r.carol, room3CarolKs, splitFor, id, seam, Now)
  doAssert refused.startsWith("refused:") and "one note" in refused, refused
  doAssert aliceW.receivedNotes(aliceKs).len == 1, "only Bob's payment ever arrived"
  echo "5. two notes that only together cover Carol's share: refused, since a transfer draws on one note OK"

echo "split_lez_zone_test: all OK"
