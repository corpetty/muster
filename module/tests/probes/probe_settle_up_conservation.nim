## derived-exo-a90.20 s3: a settle-up nets agreed, unpaid split shares on one chain and asset
## without changing what anyone is owed — every member's balance across the covered shares
## equals their balance across the net transfers; each cover says exactly what its split
## says, of an agreed split whose share is unpaid and not already covered; each recipient is
## paid only at an address a split owing them named; the private split is never netted
## (exo-3c6).
##
## METAMORPHIC (conservation). Seeded random rooms of four over the live path: several
## Ethereum splits among random members (each proposed by its creditor, every party agreed),
## some shares already paid over a fake ledger, some already covered by an agreed settle-up,
## and one private split. A settle-up is then composed with the REAL openParts and
## netTransfers, and five mutated settle-ups are proposed and put to a covered party's
## agreement: a cover's amount one higher, a transfer to an address no split named, a cover
## of a paid share, a cover of a share another settle-up already covers, and a settle-up on
## the private split's zone. Every flow is non-negative, so none can cancel:
##   * per member: |balance over the covers - balance over the net transfers|;
##   * per cover: 1 if it misstates its split (read independently from the log), or covers
##     an unagreed, paid, already-covered or private share;
##   * per transfer: 1 if it pays its recipient at an address no split owing them named;
##   * per mutation: 1 if the covered party's agreement is ACCEPTED;
##   * per trial: 1 if the honest settle-up's agreement is refused (a refuse-everything
##     client would otherwise pass the mutations vacuously).
## Conservation at zero: nothing moved between members, nothing misstated, nothing forged.

import std/[json, strutils, random, tables, sets, sequtils]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/settle_up
import ./split_room
import ./oracle_emit

const Members = ["alice", "bob", "carol", "dave"]
let payToOf = {"alice": AlicePayTo, "bob": "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
               "carol": "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
               "dave": "0x90f79bf6eb2c4f870365e785982e1f101e93b906"}.toTable
const Foreign = "0x1111111111111111111111111111111111111111"

var flows: seq[int]
var exercised = initCountTable[string]()   # each mutation must run at least once over the trials

proc nameOf(identity: string): string =
  for m in Members:
    if identityOf(m) == identity: return m
  ""

proc trial(rng: var Rand, t: int) =
  var r = newRoom4("/muster/1/probe-settle-conserve-" & $t & "/proto")
  var seqNo = 0'u64
  proc propose(who, policy, effect: string, account: string): string =
    inc seqNo
    let (s, ks) = r.sessionOf(who)
    liveProposeIntent(s, ks, splitFor, policy, effect, int64(Now), seqNo, account = account, ttlSec = Ttl)
  let ledger = newFakeLedger()
  var splits: seq[tuple[id, creditor: string, debtors: seq[string]]]
  for n in 0 ..< 4 + rng.rand(2):
    let creditor = Members[rng.rand(3)]
    var debtors: seq[string]
    for m in Members:
      if m != creditor and rng.rand(1.0) < 0.6: debtors.add m
    if debtors.len == 0: debtors.add Members[(Members.find(creditor) + 1) mod 4]
    let total = $(100 * (debtors.len + 1) + rng.rand(99))
    let effect = splitEffectJson(EvmChain, "ETH", total, identityOf(creditor), payToOf[creditor],
                                 evenShares(total, identityOf(creditor), debtors.mapIt(identityOf(it))),
                                 "t" & $t & " split " & $n)
    let id = propose(creditor, EvmPolicy, effect, EvmChain & ":" & payToOf[creditor])
    doAssert id.startsWith("0x"), id
    r.sync()
    for d in debtors: discard r.agree(d, id)
    splits.add (id, creditor, debtors)
  r.sync()
  # some shares paid directly
  var paid: HashSet[string]
  for sp in splits:
    for d in sp.debtors:
      if rng.rand(1.0) < 0.25:
        let (s, ks) = r.sessionOf(d)
        let (o, pp) = liveSettlePartSend(s, ks, splitFor, sp.id, newFakePartSeam(ledger, d), Now)
        doAssert o == "", o
        ledger.mine()
        discard liveSettlePartComplete(s, ks, splitFor, newFakePartSeam(ledger, d), pp)
        paid.incl sp.id & "/" & partName(identityOf(d))
  r.sync()
  # the private split: agreed, on its own zone
  let lezPayTo = "priv:" & repeat("ab", 32) & ":" & repeat("cd", 33)
  let lezEffect = splitEffectJson(LezChain, "LEZ", "900000", identityOf("alice"), lezPayTo,
                                  evenShares("900000", identityOf("alice"), @[bob, carol], distinctAmounts = true),
                                  "t" & $t & " private")
  let lezId = propose("alice", LezPolicy, lezEffect, LezChain)
  flows.add (if lezId.startsWith("0x"): 0 else: 1)      # the private split exists to be refused below
  r.sync()
  if lezId.startsWith("0x"):
    discard r.agree("bob", lezId)
    discard r.agree("carol", lezId)
  r.sync()
  # an earlier settle-up already covers a slice of the open parts
  let open0 = openParts(r.alice.roomEvents(), splitFor, EvmChain, "ETH", Now)
  var preCovered: HashSet[string]
  if open0.len >= 2:
    let slice = open0[0 ..< 2]
    let pre = propose(nameOf(slice[0].debtor), EvmPolicy,
                      settleUpEffectJson(EvmChain, "ETH", slice, netTransfers(slice), "t" & $t & " earlier"), EvmChain)
    r.sync()
    var parties: HashSet[string]
    for c in slice: (parties.incl nameOf(c.debtor); parties.incl nameOf(c.creditor))
    for p in parties: discard r.agree(p, pre)
    r.sync()
    for c in slice: preCovered.incl c.intent & "/" & partName(c.debtor)
  # ── the settle-up, composed from the log ─────────────────────────────────────────
  r.sync()
  let events = r.alice.roomEvents()
  let covers = openParts(events, splitFor, EvmChain, "ETH", Now)
  let net = netTransfers(covers)
  # per member: the balance is kept
  var balC, balN = initTable[string, int]()
  for c in covers:
    balC.mgetOrPut(c.creditor, 0) += parseInt(c.amount)
    balC.mgetOrPut(c.debtor, 0) -= parseInt(c.amount)
  for n in net:
    balN.mgetOrPut(n.to, 0) += parseInt(n.amount)
    balN.mgetOrPut(n.frm, 0) -= parseInt(n.amount)
  for m in Members:
    flows.add abs(balC.getOrDefault(identityOf(m), 0) - balN.getOrDefault(identityOf(m), 0))
  # per cover: exactly what its split says, of an agreed, unpaid, uncovered, public share
  for c in covers:
    var bad = 1
    for v in reduceIntentViews(events, splitFor):
      if v.id != c.intent or v.policy != EvmPolicy: continue
      let j = parseJson(v.effectJson)
      var share = ""
      for sh in j["shares"]:
        if sh["who"].getStr() == c.debtor: share = sh["amount"].getStr()
      let key = c.intent & "/" & partName(c.debtor)
      if v.state in ["executable", "submitted", "settling"] and share == c.amount and
         j["creditor"].getStr() == c.creditor and j["payTo"].getStr() == c.payTo and
         key notin paid and key notin preCovered and c.intent != lezId:
        bad = 0
    flows.add bad
  # per transfer: paid only where a split owing that recipient said
  for n in net:
    var named = false
    for sp in splits:
      if identityOf(sp.creditor) == n.to and payToOf[sp.creditor] == n.payTo: named = true
    flows.add (if named and parseInt(n.amount) > 0: 0 else: 1)
  if covers.len == 0 or net.len == 0: return
  # ── the honest settle-up gets agreement; each mutation does not ───────────────────
  let proposer = nameOf(net[0].frm)
  let agreer = nameOf(net[0].to)
  proc agreementAccepted(effect: string, chain = EvmChain, policy = EvmPolicy): bool =
    let id = propose(proposer, policy, effect, chain)
    if not id.startsWith("0x"): return false        # refused at propose: not accepted
    r.sync()
    let outcome = r.agree(agreer, id)
    outcome in ["collecting", "executable"]
  flows.add (if agreementAccepted(settleUpEffectJson(EvmChain, "ETH", covers, net, "t" & $t & " honest")): 0 else: 1)
  exercised.inc "honest"
  var up = covers
  up[0].amount = $(parseInt(up[0].amount) + 1)
  flows.add (if agreementAccepted(settleUpEffectJson(EvmChain, "ETH", up, netTransfers(up), "t" & $t & " +1")): 1 else: 0)
  exercised.inc "misstated"
  var foreign = net
  foreign[0].payTo = Foreign
  flows.add (if agreementAccepted(settleUpEffectJson(EvmChain, "ETH", covers, foreign, "t" & $t & " foreign")): 1 else: 0)
  exercised.inc "foreign"
  for sp in splits:                                  # a cover of a paid share, if any was paid
    for d in sp.debtors:
      let key = sp.id & "/" & partName(identityOf(d))
      if key in paid:
        var withPaid = covers
        let j = parseJson(effectJsonOf(events, sp.id))
        var amt = ""
        for sh in j["shares"]:
          if sh["who"].getStr() == identityOf(d): amt = sh["amount"].getStr()
        withPaid.add Cover(intent: sp.id, debtor: identityOf(d), creditor: identityOf(sp.creditor),
                           amount: amt, payTo: payToOf[sp.creditor])
        flows.add (if agreementAccepted(settleUpEffectJson(EvmChain, "ETH", withPaid, netTransfers(withPaid),
                                                            "t" & $t & " paid")): 1 else: 0)
        exercised.inc "paid"
        break
  if preCovered.len > 0:                             # a cover of a share already covered
    let taken = open0[0]
    let twice = covers & @[taken]
    flows.add (if agreementAccepted(settleUpEffectJson(EvmChain, "ETH", twice, netTransfers(twice),
                                                        "t" & $t & " twice")): 1 else: 0)
    exercised.inc "twice"
  if lezId.startsWith("0x"):                         # the private split, netted on its zone
    var priv: seq[Cover]
    let j = parseJson(lezEffect)
    for sh in j["shares"]:
      priv.add Cover(intent: lezId, debtor: sh["who"].getStr(), creditor: alice, amount: sh["amount"].getStr(),
                     payTo: lezPayTo)
    flows.add (if agreementAccepted(settleUpEffectJson(LezChain, "LEZ", priv, netTransfers(priv), "t" & $t & " private"),
                                    LezChain, LezPolicy): 1 else: 0)
    exercised.inc "private"

for t in 0 ..< 8:
  var rng = initRand(0x3c6 + t)
  trial(rng, t)

for kind in ["honest", "misstated", "foreign", "paid", "twice", "private"]:
  flows.add (if exercised[kind] > 0: 0 else: 1)          # a mutation that never ran proves nothing
var total = 0
for f in flows: total += f
doAssert flows.len > 0 and total == 0, "a settle-up changed what someone is owed, or a forged one was agreed: " & $flows
emitMeasurement(%*{"flows": flows})
