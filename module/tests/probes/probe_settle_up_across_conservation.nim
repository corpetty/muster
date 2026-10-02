## derived-exo-a90.17 s2: a settle-up across assets conserves every balance in the payment
## asset — each member's balance across the converted covers equals their balance across the
## net transfers, and anything else is refused — while each cover still states exactly what its
## own split says, in its own asset on its own chain, for a split that is agreed, unpaid and not
## already covered, checked by every client before agreeing (exo-a90.17).
##
## METAMORPHIC (conservation). Eight seeded rooms of four over the live path: splits in ETH and
## in a 6-decimal token on eip155:31337 and in BTC on regtest, among random members, every party
## agreed; one split one debtor never agreed to; some ETH shares already paid over a fake
## ledger; a slice of the ETH shares already covered by an agreed settle-up; one agreed private
## split. Every member has shared an Ethereum address. The payment rail is ETH or the token
## (Bitcoin is a covered asset only, so no net payment can fall below Bitcoin's dust limit). A
## rate per ONE unit is given for every other asset (settleRate), and the settle-up is composed
## with the REAL settleUpAcross. Mutated settle-ups are proposed, the rates recorded as the
## proposer's read, and put to a covered party's agreement: a BTC cover one sat higher, netted
## consistently; a net transfer one unit higher; a rate changed after netting; a cover of a paid
## share, of a share another settle-up covers, of an unagreed split, and of the private split
## with a rate for its zone. Every flow is non-negative, so none can cancel:
##   * per member: 1 if their balance over the covers, each converted by the probe's OWN
##     512-bit arithmetic at its signed rate, differs from their balance over the transfers;
##   * per cover: 1 if it misstates its split (read independently from the log) or covers an
##     unagreed, paid, already-covered or private share;
##   * per transfer: 1 if it pays nothing, or pays its recipient anywhere but an address a split
##     owing them on the payment chain agreed or, owed only elsewhere, the one they shared;
##   * per mutation: 1 if the covered party's agreement is ACCEPTED;
##   * per trial: 1 if the honest settle-up is not composed, or its agreement is refused;
##   * per mutation kind: 1 if it never ran over the eight trials.
## Conservation at zero: nothing moved between members, nothing misstated, nothing forged.

import std/[json, strutils, random, tables, sets, sequtils]
import ./settle_across_room
import ./oracle_emit

const At = 1_790_000_000'i64
let Kinds = ["honest", "btc+1", "transfer+1", "rate-after", "paid", "twice", "unagreed", "private"]

var flows: seq[int]
var exercised = initCountTable[string]()

proc decimalsOf(asset: string): int =
  if asset == "BTC": 8 elif asset == Token: 6 else: 18

proc trial(rng: var Rand, t: int) =
  var r = newRoom4("/muster/1/probe-across-conserve-" & $t & "/proto")
  let payAsset = (if t mod 2 == 0: "ETH" else: Token)
  for i, m in Members: r.shareAddress(m, "ETH", evmAddrOf[m], seqNo = 100 + i)
  # ── the splits ─────────────────────────────────────────────────────────────────
  var splits: seq[tuple[id, chain, asset, creditor: string, debtors: seq[string]]]
  for n in 0 ..< 5 + rng.rand(2):
    let rail = (if n < 3: n else: rng.rand(2))     # every rail at least once
    let (chain, asset) = (if rail == 0: (EvmChain, "ETH") elif rail == 1: (EvmChain, Token) else: (BtcChain, "BTC"))
    let creditor = Members[rng.rand(3)]
    var debtors: seq[string]
    for m in Members:
      if m != creditor and rng.rand(1.0) < 0.6: debtors.add m
    if debtors.len == 0: debtors.add Members[(Members.find(creditor) + 1) mod 4]
    let total = (if rail == 0: $(10_000_000_000_000_000'u64 + uint64(rng.rand(999_999_999)))
                 elif rail == 1: $(10_000_000 + rng.rand(9_999_999))
                 else: $(100_000 + rng.rand(99_999)))
    let id = r.splitAgreed(chain, asset, creditor, debtors, total, "t" & $t & " split " & $n)
    splits.add (id, chain, asset, creditor, debtors)
  # one split a debtor never agreed to: none of its shares is open
  let unagreedEffect = splitEffectJson(EvmChain, "ETH", "30000000000000000", identityOf("dave"), evmAddrOf["dave"],
                                       evenShares("30000000000000000", identityOf("dave"), @[alice, bob]),
                                       "t" & $t & " unagreed")
  let unagreed = r.proposeAs("dave", EvmPolicy, unagreedEffect, EvmChain & ":" & evmAddrOf["dave"])
  r.sync()
  discard r.agreeAs("alice", unagreed)               # Bob never agrees
  r.sync()
  # some ETH shares paid directly
  let ledger = newFakeLedger()
  var paid: HashSet[string]
  for sp in splits:
    if sp.asset != "ETH": continue
    for d in sp.debtors:
      if rng.rand(1.0) < 0.3:
        let (s, ks) = r.sessionOf(d)
        let (o, pp) = liveSettlePartSend(s, ks, acrossFor, sp.id, newFakePartSeam(ledger, d), Now)
        doAssert o == "", o
        ledger.mine()
        discard liveSettlePartComplete(s, ks, acrossFor, newFakePartSeam(ledger, d), pp)
        paid.incl sp.id & "/" & identityOf(d)
  r.sync()
  # the private split: agreed, on its own zone
  let lezPayTo = "priv:" & repeat("ab", 32) & ":" & repeat("cd", 33)
  let lezEffect = splitEffectJson(LezChain, "LEZ", "900000", alice, lezPayTo,
                                  evenShares("900000", alice, @[bob, carol], distinctAmounts = true), "t" & $t & " private")
  let lezId = r.proposeAs("alice", LezPolicy, lezEffect, LezChain)
  flows.add (if lezId.startsWith("0x"): 0 else: 1)
  r.sync()
  discard r.agreeAs("bob", lezId)
  discard r.agreeAs("carol", lezId)
  r.sync()
  # an earlier settle-up, in one asset, covers a slice of the ETH shares
  let openEth = openParts(r.alice.roomEvents(), acrossFor, EvmChain, "ETH", Now)
  var preCovered: HashSet[string]
  var taken: Cover
  if openEth.len >= 2:
    let slice = openEth[0 ..< 2]
    taken = slice[0]
    let pre = r.proposeAs(nameOf(slice[0].debtor), EvmPolicy,
                          settleUpEffectJson(EvmChain, "ETH", slice, netTransfers(slice), "t" & $t & " earlier"), EvmChain)
    r.sync()
    var parties: HashSet[string]
    for c in slice: (parties.incl nameOf(c.debtor); parties.incl nameOf(c.creditor))
    for p in parties: discard r.agreeAs(p, pre)
    r.sync()
    for c in slice: preCovered.incl c.intent & "/" & c.debtor
  # ── the rates and the honest settle-up ─────────────────────────────────────────
  r.sync()
  let events = r.alice.roomEvents()
  let open = openPartsAll(events, acrossFor, Now)
  var rates: seq[SettleRate]
  var seen: HashSet[(string, string)]
  for c in open:
    if (c.chain == EvmChain and c.asset == payAsset) or (c.chain, c.asset) in seen: continue
    seen.incl (c.chain, c.asset)
    let typed = (if payAsset == "ETH": (if c.asset == "BTC": ["21.4", "19.875", "23"][rng.rand(2)] else: ["0.0004", "0.00035"][rng.rand(1)])
                 else: (if c.asset == "BTC": ["60000.25", "58123"][rng.rand(1)] else: ["2500.5", "2611.125"][rng.rand(1)]))
    let sr = settleRate(c.chain, c.asset, typed, decimalsOf(payAsset), decimalsOf(c.asset), "t" & $t & " quote", At)
    doAssert sr.ok, sr.why
    rates.add sr.rate
  let composed = settleUpAcross(events, acrossFor, EvmChain, payAsset, rates, "t" & $t & " across", Now)
  if composed.why.len > 0:
    stderr.writeLine "trial " & $t & ": the honest settle-up was not composed: " & composed.why
    flows.add 1
    return
  let su = settleUpOf(effectFromJson(composed.effectJson))
  let covers = su.covers
  let net = su.transfers
  proc rateFor(c: Cover): SettleRate =
    for x in rates:
      if x.chain == c.chain and x.asset == c.asset: return x
  # per member: the balance is kept, by the probe's own conversion
  var inC, outC, inN, outN = initTable[string, U512]()
  for c in covers:
    var v = big(c.amount).v
    if not (c.chain == EvmChain and c.asset == payAsset):
      let x = rateFor(c)
      let conv = ownConversion(c.amount, x.rate, x.per)
      if not conv.ok: (flows.add 1; continue)
      v = conv.v
    inC[c.creditor] = inC.getOrDefault(c.creditor) + v
    outC[c.debtor] = outC.getOrDefault(c.debtor) + v
  for n in net:
    inN[n.to] = inN.getOrDefault(n.to) + big(n.amount).v
    outN[n.frm] = outN.getOrDefault(n.frm) + big(n.amount).v
  for m in Members:
    let w = identityOf(m)
    # owed in − owe out over the covers == received − paid over the transfers, without a sign
    flows.add (if inC.getOrDefault(w) + outN.getOrDefault(w) == outC.getOrDefault(w) + inN.getOrDefault(w): 0 else: 1)
  # per cover: exactly what its split says, of an agreed, unpaid, uncovered, public share
  let views = reduceIntentViews(events, acrossFor)
  for c in covers:
    var bad = 1
    for v in views:
      if v.id != c.intent: continue
      let j = parseJson(v.effectJson)
      var share = ""
      for sh in j["shares"]:
        if sh["who"].getStr() == c.debtor: share = sh["amount"].getStr()
      let key = c.intent & "/" & c.debtor
      if v.state in ["executable", "submitted", "settling"] and share == c.amount and
         j["creditor"].getStr() == c.creditor and j["payTo"].getStr() == c.payTo and
         j["chain"].getStr() == c.chain and j["asset"].getStr() == c.asset and
         key notin paid and key notin preCovered and c.intent notin [lezId, unagreed]:
        bad = 0
    flows.add bad
  # per transfer: something, paid where the recipient's split on this chain agreed, else where they said
  for n in net:
    let here = covers.filterIt(it.creditor == n.to and it.chain == EvmChain)
    let ok = (if here.len > 0: here.anyIt(it.payTo == n.payTo) else: n.payTo == evmAddrOf[nameOf(n.to)])
    flows.add (if ok and big(n.amount).v != 0.stuint(512): 0 else: 1)
  # ── the honest settle-up is agreed to; each mutation is not ────────────────────
  let proposer = nameOf(net[0].frm)
  let agreer = nameOf(net[0].to)
  var vouched = initTable[string, string]()
  for c in covers:
    if not covers.anyIt(it.creditor == c.creditor and it.chain == EvmChain):
      vouched[c.creditor] = evmAddrOf[nameOf(c.creditor)]
  proc accepted(effect, memo: string): bool =
    let id = r.proposeAs(proposer, EvmPolicy, effect, EvmChain, @[(field: "rates", source: "rates:proposer")])
    if not id.startsWith("0x"): return false
    r.sync()
    r.agreeAs(agreer, id) in ["collecting", "executable"]
  proc mutant(cs: seq[Cover], rs: seq[SettleRate], memo: string): string =
    settleUpEffectJson(EvmChain, payAsset, cs, netTransfers(cs, rs, EvmChain, payAsset, vouched), memo, rs)
  flows.add (if accepted(composed.effectJson, "honest"): 0 else: 1)
  exercised.inc "honest"
  for i, c in covers:                                # a BTC cover one sat higher, netted consistently
    if c.asset == "BTC":
      var up = covers
      up[i].amount = $(big(c.amount).v + 1.stuint(512))
      flows.add (if accepted(mutant(up, rates, "t" & $t & " btc+1"), "btc+1"): 1 else: 0)
      exercised.inc "btc+1"
      break
  var more = net
  more[0].amount = $(big(more[0].amount).v + 1.stuint(512))
  flows.add (if accepted(settleUpEffectJson(EvmChain, payAsset, covers, more, "t" & $t & " transfer+1", rates),
                         "transfer+1"): 1 else: 0)
  exercised.inc "transfer+1"
  if rates.len > 0:                                  # a rate changed after netting: the transfers stay
    var rs = rates
    rs[0].rate = $(big(rs[0].rate).v * 2.stuint(512))
    flows.add (if accepted(settleUpEffectJson(EvmChain, payAsset, covers, net, "t" & $t & " rate-after", rs),
                           "rate-after"): 1 else: 0)
    exercised.inc "rate-after"
  for sp in splits:                                  # a cover of a paid share
    var done = false
    for d in sp.debtors:
      if sp.id & "/" & identityOf(d) in paid:
        let j = parseJson(effectJsonOf(events, sp.id))
        var amt = ""
        for sh in j["shares"]:
          if sh["who"].getStr() == identityOf(d): amt = sh["amount"].getStr()
        let withPaid = covers & @[Cover(intent: sp.id, debtor: identityOf(d), creditor: identityOf(sp.creditor),
                                        amount: amt, payTo: evmAddrOf[sp.creditor], chain: EvmChain, asset: "ETH")]
        flows.add (if accepted(mutant(withPaid, rates, "t" & $t & " paid"), "paid"): 1 else: 0)
        exercised.inc "paid"
        done = true
        break
    if done: break
  if preCovered.len > 0:                             # a cover of a share another settle-up covers
    var again = taken
    again.chain = EvmChain
    again.asset = "ETH"
    var rs = rates
    if payAsset != "ETH" and not rs.anyIt(it.chain == EvmChain and it.asset == "ETH"):
      rs.add settleRate(EvmChain, "ETH", "2500.5", 6, 18, "t" & $t & " quote", At).rate
    flows.add (if accepted(mutant(covers & @[again], rs, "t" & $t & " twice"), "twice"): 1 else: 0)
    exercised.inc "twice"
  block:                                             # a cover of the split Bob never agreed to
    var rs = rates
    if payAsset != "ETH" and not rs.anyIt(it.chain == EvmChain and it.asset == "ETH"):
      rs.add settleRate(EvmChain, "ETH", "2500.5", 6, 18, "t" & $t & " quote", At).rate
    let share = parseJson(unagreedEffect)["shares"][0]
    let c = Cover(intent: unagreed, debtor: share["who"].getStr(), creditor: identityOf("dave"),
                  amount: share["amount"].getStr(), payTo: evmAddrOf["dave"], chain: EvmChain, asset: "ETH")
    flows.add (if accepted(mutant(covers & @[c], rs, "t" & $t & " unagreed"), "unagreed"): 1 else: 0)
    exercised.inc "unagreed"
  block:                                             # the private split, with a rate for its zone
    let sh = parseJson(lezEffect)["shares"][0]
    let priv = Cover(intent: lezId, debtor: sh["who"].getStr(), creditor: alice, amount: sh["amount"].getStr(),
                     payTo: lezPayTo, chain: LezChain, asset: "LEZ")
    let rs = rates & @[SettleRate(chain: LezChain, asset: "LEZ", rate: "1", per: "1", source: "t" & $t, at: $At)]
    let cs = covers & @[priv]
    flows.add (if accepted(settleUpEffectJson(EvmChain, payAsset, cs, net, "t" & $t & " private", rs), "private"): 1 else: 0)
    exercised.inc "private"

for t in 0 ..< 8:
  var rng = initRand(0xa17 + t)
  trial(rng, t)

for kind in Kinds:
  flows.add (if exercised[kind] > 0: 0 else: 1)          # a mutation that never ran proves nothing
var total = 0
for f in flows: total += f
doAssert flows.len > 0 and total == 0, "a settle-up across assets moved what someone is owed, or a forged one was agreed: " & $flows
emitMeasurement(%*{"flows": flows})
