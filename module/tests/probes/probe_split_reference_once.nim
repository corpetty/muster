## derived-exo-a90 s5/c5: one payment reference settles at most one part in a room — the
## creditor's client never confirms a transaction hash or a private note it already
## confirmed for another share, in this split or another.
##
## METAMORPHIC (conservation): seeded random rooms on BOTH rails — the fake EVM ledger and
## the shared fake LEZ chain. Each room holds several splits with the same creditor and
## the same debtors owing the SAME amount in each (the case a reused reference would fool):
## debtors pay some parts honestly (one fresh transaction / note each), then claim those
## payments for parts of other splits they never paid, and the creditor's pump runs to
## quiescence. Payments in must equal confirmations out, one for one:
##   per reference the creditor confirmed:   (parts confirmed with it) - 1
##   per honest payment made:                1 - (confirmed at least once ? 1 : 0)
## Every term is >= 0, so nothing cancels: the sum is zero iff no reference settled two
## parts AND every real payment settled one. A client that confirms nothing fails the
## second term; one that confirms a reused reference fails the first. Run by hand, it
## doAsserts the sum.

import std/[json, strutils, random, tables, sets]
import ../../src/intents/materialization
import ../../src/wallet/[types, lez_core, lez_adapter]
import ../../src/coordination/parts
import ../../src/coordination/parts_lez
import ./split_room
import ./oracle_emit

const Debtors = ["bob", "carol", "dave"]
var flows: seq[int]

proc pumpToQuiescence(r: Room4, seam: PartSeam) =
  for _ in 0 ..< 6:
    if liveConfirmParts(r.alice, aliceKs, splitFor, seam).len == 0: break

proc confirmedRefs(r: Room4, ids: seq[string]): CountTable[string] =
  r.sync()
  result = initCountTable[string]()
  for v in reduceIntentViews(r.alice.roomEvents(), splitFor):
    if v.id notin ids: continue
    for p in v.parts:
      if p.confirmed and p.tx.len > 0: result.inc p.tx

proc conserve(counts: CountTable[string], honest: seq[string]) =
  for r, c in counts: flows.add c - 1
  for h in honest: flows.add (if counts.getOrDefault(h, 0) >= 1: 0 else: 1)

proc evmTrial(rng: var Rand, trial: int) =
  var r = newRoom4("/muster/1/split-ref-evm-" & $trial & "/proto")
  let ledger = newFakeLedger()
  var ids: seq[string]
  for s in 0 ..< 2 + rng.rand(2):
    let e = splitEffectJson(EvmChain, "ETH", "400", alice, AlicePayTo,
                            evenShares("400", alice, @[bob, carol, dave]), "evm split " & $s)
    let id = r.propose(EvmPolicy, e)
    for d in Debtors: discard r.agree(d, id)
    ids.add id
  var paid: Table[string, seq[string]]          # debtor -> their honest references
  var honest: seq[string]
  var unpaid: seq[(string, string)]              # (split, debtor) never paid
  for id in ids:
    for d in Debtors:
      if rng.rand(1.0) < 0.5:
        let (s, ks) = r.sessionOf(d)
        let seam = newFakePartSeam(ledger, d)
        let (o, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, Now)
        doAssert o == "", o
        ledger.mine()
        doAssert liveSettlePartComplete(s, ks, splitFor, seam, pp) in ["submitted", "settling"]
        paid.mgetOrPut(d, @[]).add pp.tx
        honest.add pp.tx
      else: unpaid.add (id, d)
  for (id, d) in unpaid:                         # claim a payment made for another split
    if d in paid and rng.rand(1.0) < 0.7:
      let refs = paid[d]
      let (s, ks) = r.sessionOf(d)
      s.publishAuthored(ks, partEvent(id, partName(identityOf(d)), "settled", identityOf(d),
                                      refs[rng.rand(refs.high)]))
  r.pumpToQuiescence(newFakePartSeam(ledger, "alice"))
  conserve(confirmedRefs(r, ids), honest)

proc lezTrial(rng: var Rand, trial: int) =
  var r = newRoom4("/muster/1/split-ref-lez-" & $trial & "/proto")
  let chain = newFakeLezChain()
  var wallet: Table[string, LezAdapter]
  for who in ["alice", "bob", "carol", "dave"]:
    wallet[who] = newLezAdapter(newFakeLezCore(chain))
  proc ksOf(who: string): Keystore = r.sessionOf(who)[1]
  for d in Debtors:
    for a in wallet[d].accounts(ksOf(d)):
      if a.form == afShielded: chain.fund(a.id, "50000000000")
  var payTo = ""
  for (f, address) in wallet["alice"].receiveAddresses(aliceKs):
    if f == "shielded": payTo = address
  var ids: seq[string]
  for s in 0 ..< 2 + rng.rand(2):
    let e = splitEffectJson(LezChain, "LEZ", "900000000", alice, payTo,
                            evenShares("900000000", alice, @[bob, carol, dave], distinctAmounts = true),
                            "lez split " & $s)
    let id = r.propose(LezPolicy, e)
    for d in Debtors: discard r.agree(d, id)
    ids.add id
  var payers = initHashSet[string]()
  var unpaid: seq[(string, string)]
  var honestPayments = 0
  for id in ids:
    for d in Debtors:
      if rng.rand(1.0) < 0.5:
        let (s, ks) = r.sessionOf(d)
        let seam = newLezPartSeam(LezChain, wallet[d], ks)
        let (o, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, Now)
        doAssert o == "", o
        var st = liveSettlePartComplete(s, ks, splitFor, seam, pp)      # the proof settles on a scan
        if st.startsWith("unconfirmed"): st = liveSettlePartComplete(s, ks, splitFor, seam, pp)
        doAssert st in ["submitted", "settling"], st
        payers.incl d
        inc honestPayments
      else: unpaid.add (id, d)
  for (id, d) in unpaid:                         # claim a payment made for another split
    if d in payers and rng.rand(1.0) < 0.7:
      let (s, ks) = r.sessionOf(d)
      s.publishAuthored(ks, partEvent(id, partName(identityOf(d)), "settled", identityOf(d), "tx-claimed"))
  r.pumpToQuiescence(newLezPartSeam(LezChain, wallet["alice"], aliceKs))
  # every real payment is a note Alice received: each must settle exactly one part
  var honest: seq[string]
  for n in wallet["alice"].receivedNotes(aliceKs): honest.add noteRef(n.account.id)
  doAssert honest.len == honestPayments, "every private payment arrived as one note"
  conserve(confirmedRefs(r, ids), honest)

for trial in 0 ..< 10:
  var rng = initRand(0xa905 + trial)
  evmTrial(rng, trial)
  lezTrial(rng, trial)

var total = 0
for f in flows: total += f
doAssert flows.len > 0 and total == 0, "payments in != confirmations out: " & $flows
emitMeasurement(%*{"flows": flows})
