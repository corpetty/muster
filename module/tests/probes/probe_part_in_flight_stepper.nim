## derived-exo-a90.20 s7: a share in flight is never paid twice — while a payment of it has
## been sent and not seen to land, paying it again sends nothing, across a restart of the
## payer's client and past any deadline; the share is released only when the chain says that
## payment can never land; and a Bitcoin payment never spends a coin a pending payment
## already spends (exo-a90.18, exo-a90.23).
##
## STEPPER: state = a rail {the fake ledger; a Bitcoin node — fake_bitcoind, a child process
## the Bitcoin seam talks to over JSON-RPC, unmodified} and a history of at most five
## actions by Bob, a debtor of two agreed splits (dinner and lunch; five coins on Bitcoin):
##   S  pay my dinner share: liveSettlePartSend with the book's in-flight payments; a sent
##      payment enters the book (coordination/pending_parts)
##   T  pay my lunch share, the same way — a second share, so two payments can be in flight
##   R  restart: the book round-trips through its saved form, and the seam is rebuilt
##   P  time passes the pay deadline, then the pump runs (pumpBook — the hosted pump's step)
##   M  the chain mines what is pending
##   X  the chain drops the latest pending payment unmined
##   C  (Bitcoin) another transaction spends the latest pending payment's first coin
## Successors add one action that can change something (at most three dinner and two lunch
## sends; a restart, mine, drop or conflict only once something was sent; no two pumps in a
## row), chosen from the rule's own account of the history, never from the system's. Each
## history is replayed from scratch; the probe keeps its OWN model of the chain and the book
## and checks the system against it at every step. A grader state is a history of at most two
## actions, and a two-action state stands for itself AND every continuation of it to five
## actions, each replayed and checked (a failing one is named on stderr): every history to
## five, about 3,800 over both rails, in some thirty stepper calls. The rule, stated alone:
##   * S and T send iff the book holds no payment of that share and none was reported; otherwise
##     it answers "paying" (in flight) or "already-settled", and sends nothing;
##   * P reports a landed payment and drops it from the book; releases a payment the chain
##     can never land (the fake ledger dropped it; on Bitcoin, another transaction spent its
##     coin); keeps every other one — pending, or dropped from a Bitcoin mempool with its
##     coins unspent — however late;
##   * no history lands two payments of one share, and on Bitcoin no payment is sent
##     spending a coin that a payment still pending in the mempool spends (a coin a dropped
##     payment spent is free again: spending it makes the dropped payment unlandable).
## Run by hand (no argv), it walks every history to depth four on both rails with doAssert.

import std/[json, strutils, sequtils, sets]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/parts_btc
import ../../src/coordination/pending_parts
import ../../src/wallet/btc_adapter
import ../../src/bitcoin/script
import ./split_room
import ./fake_bitcoind
import ./oracle_emit

fakeBitcoindMain()                      # when invoked as the fake node, serve and never return

const Regtest = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const BtcPolicy = "btc-split@" & Regtest
const MaxDepth = 5
const Frontier = 2                      # a grader state: a history of at most this many actions

let driverFor: DriverFor = proc(p: string): Driver =
  if p == BtcPolicy: newSplitDriver(BtcSplitFamily, Regtest, roster) else: splitFor(p)

type
  Status = enum psPending, psLanded, psDropped, psConflicted
  Model = object
    payments: seq[tuple[share: int, tx: string, status: Status, spends: seq[string]]]
    reported: array[2, bool]

proc ruleModel(hist: string, btc: bool): Model =
  ## What the rule says the history leads to, without running anything: which payments
  ## exist and where each stands. Used only to choose a state's successors; every
  ## successor is then replayed on the real system and checked.
  var book: seq[int]
  for a in hist:
    case a
    of 'S', 'T':
      let k = (if a == 'S': 0 else: 1)
      if not book.anyIt(result.payments[it].share == k) and not result.reported[k]:
        result.payments.add (k, "", psPending, newSeq[string]())
        book.add result.payments.high
    of 'P':
      var keep: seq[int]
      for i in book:
        let st = result.payments[i].status
        if st == psLanded or st == psConflicted or (st == psDropped and not btc):
          if st == psLanded: result.reported[result.payments[i].share] = true
        else: keep.add i
      book = keep
    of 'M':
      for p in result.payments.mitems:
        if p.status == psPending: p.status = psLanded
    of 'X', 'C':
      var last = -1
      for i, p in result.payments:
        if p.status == psPending: last = i
      if last >= 0: result.payments[last].status = (if a == 'X': psDropped else: psConflicted)
    else: discard

proc allowed(m: Model, hist: string, btc: bool): seq[char] =
  if hist.len >= MaxDepth: return
  let sends = hist.count('S') + hist.count('T')
  let anyPending = m.payments.anyIt(it.status == psPending)
  if hist.count('S') < 3: result.add 'S'
  if hist.count('T') < 2: result.add 'T'
  if sends > 0 and (hist.len == 0 or hist[^1] != 'R'): result.add 'R'
  if sends > 0 and (hist.len == 0 or hist[^1] != 'P'): result.add 'P'
  if anyPending: (result.add 'M'; result.add 'X')
  if anyPending and btc: result.add 'C'

proc replay(btc: bool, hist: string, n: int): tuple[ok: bool, model: Model] =
  ## Run `hist` from scratch; ok = the system matched the rule at every step.
  var r = newRoom4("/muster/1/probe-in-flight-" & (if btc: "b" else: "f") & hist & "-" & $n & "/proto")
  let topic = r.topic
  var node: FakeNode
  var ledger: FakeLedger
  let payTo = (if btc: p2wpkhAddress("bcrt", aliceKs.btcPubKey()) else: AlicePayTo)
  let policy = (if btc: BtcPolicy else: EvmPolicy)
  var ids: array[2, string]
  for k, memo in ["dinner", "lunch"]:
    let effect = (if btc: splitEffectJson(Regtest, "BTC", "900000", alice, payTo, evenShares("900000", alice, @[bob, carol]), memo & " " & hist)
                  else: splitEffectJson(EvmChain, "ETH", "900", alice, payTo, evenShares("900", alice, @[bob, carol]), memo & " " & hist))
    inc r.seqNo
    ids[k] = liveProposeIntent(r.alice, aliceKs, driverFor, policy, effect, int64(Now), r.seqNo,
                               account = policy.split('@')[1] & ":" & payTo, ttlSec = 30 * 86_400)
    if not ids[k].startsWith("0x"): return (false, Model())
    r.sync()
    for who in ["bob", "carol"]:
      let (s, ks) = r.sessionOf(who)
      discard liveContribute(s, ks, driverFor, ids[k], "", "", LinkContext(account: "probe", slot: "0", expiry: Now + 86_400 * 60), Now)
    r.sync()
  var adapterUrl = ""
  if btc:
    node = startFakeNode(Regtest)
    adapterUrl = node.url
    let n0 = newBitcoindAdapter("regtest", adapterUrl, "u", "p")
    let bobAddr = p2wpkhAddress("bcrt", bobKs.btcPubKey())
    for _ in 0 ..< 5: discard n0.call("fake_fund", %*[bobAddr, 500_000])
  else:
    ledger = newFakeLedger()
  proc freshSeam(): PartSeam =
    if btc: PartSeam(newBtcPartSeam(Regtest, newBitcoindAdapter("regtest", adapterUrl, "u", "p"), bobKs, feeRate = 2))
    else: PartSeam(newFakePartSeam(ledger, "bob"))
  var seam = freshSeam()
  var book: PendingBook
  var m: Model
  var now = Now
  var ok = true
  defer:
    if btc: node.stop()
  let ctl = (if btc: newBitcoindAdapter("regtest", adapterUrl, "u", "p") else: nil)
  proc latestPending(): int =
    result = -1
    for i, p in m.payments:
      if p.status == psPending: result = i
  for a in hist:
    case a
    of 'S', 'T':
      let k = (if a == 'S': 0 else: 1)
      let expectSend = not book.inFlight(topic).anyIt(it.intentId == ids[k]) and not m.reported[k]
      let (o, pp) = liveSettlePartSend(r.bob, bobKs, driverFor, ids[k], seam, now, inFlight = book.inFlight(topic))
      let sent = o == ""
      if sent != expectSend: ok = false
      if not sent:
        let want = (if m.reported[k]: "already-settled" else: "paying")
        if expectSend or o != want: ok = false
      else:
        # on Bitcoin: never a coin a payment still pending in the mempool spends
        for p in m.payments:
          if p.status == psPending:
            for c in pp.spends:
              if c in p.spends: ok = false
        book.add(topic, pp, float(now), seam.payDeadlineS())
        m.payments.add (k, pp.tx, psPending, pp.spends)
    of 'R':
      book = bookFromJson(parseJson($book.toJson()))
      seam = freshSeam()
    of 'P':
      now += uint64(seam.payDeadlineS()) + 1
      let before = book.entries.mapIt(it.pp.tx)
      var s2 = seam
      let seamOf = proc (pp: PendingPart): PartSeam = s2
      let outs = book.pumpBook(topic, r.bob, bobKs, driverFor, seamOf, float(now))
      let after = book.entries.mapIt(it.pp.tx).toHashSet()
      for tx in before:
        var st = psPending
        var share = 0
        for p in m.payments:
          if p.tx == tx: (st = p.status; share = p.share)
        let shouldLeave = st == psLanded or st == psConflicted or (st == psDropped and not btc)
        if shouldLeave == (tx in after): ok = false
        if st == psLanded and tx notin after: m.reported[share] = true
      for o in outs:
        if o.outcome.startsWith("unresolved"): continue
        var st = psPending
        for p in m.payments:
          if p.tx == o.pp.tx: st = p.status
        if o.outcome == "reported" and st != psLanded: ok = false
        if "never land" in o.outcome and st notin {psDropped, psConflicted}: ok = false
      r.sync()
    of 'M':
      if btc: discard ctl.call("fake_mine", %*[1])
      else: ledger.mine()
      for p in m.payments.mitems:
        if p.status == psPending: p.status = psLanded
    of 'X':
      let i = latestPending()
      if i >= 0:
        if btc: discard ctl.call("fake_drop", %*[m.payments[i].tx])
        else: ledger.drop(m.payments[i].tx)
        m.payments[i].status = psDropped
    of 'C':
      let i = latestPending()
      if i >= 0:
        discard ctl.call("fake_conflict", %*[m.payments[i].tx, p2wpkhAddress("bcrt", daveKs.btcPubKey())])
        m.payments[i].status = psConflicted
    else: ok = false
  # never two landed payments of one share — on the model and on the chain
  for k in 0 .. 1:
    if m.payments.countIt(it.share == k and it.status == psLanded) > 1: ok = false
  if btc:
    for k in 0 .. 1:
      var landed = 0
      for p in m.payments:
        if p.share != k: continue
        try:
          if ctl.call("getrawtransaction", %*[p.tx, true]){"confirmations"}.getInt(0) >= 1: inc landed
        except CatchableError: discard
      if landed > 1: ok = false
  else:
    for k in 0 .. 1:
      var landed = 0
      for p in m.payments:
        if p.share == k:
          for t in ledger.sent:
            if t.tx == p.tx and t.landed: inc landed
      if landed > 1: ok = false
  (ok, m)

proc subtreeOk(btc: bool, hist: string, n: var int): bool =
  ## `hist`, and every continuation of it the successor rule allows up to MaxDepth actions,
  ## each replayed and checked.
  inc n
  if not replay(btc, hist, n).ok:
    stderr.writeLine "judged wrongly: " & (if btc: "btc" else: "fake") & " history " & hist
    return false
  for a in allowed(ruleModel(hist, btc), hist, btc):
    if not subtreeOk(btc, hist & a, n): return false
  true

proc state(rail, hist: string, n: var int): JsonNode =
  let btc = rail == "btc"
  var ok: bool
  if hist.len < Frontier:
    inc n
    ok = replay(btc, hist, n).ok
    if not ok: stderr.writeLine "judged wrongly: " & rail & " history " & hist
  else: ok = subtreeOk(btc, hist, n)
  %*{"rail": rail, "hist": hist, "decision_correct": ok}

let arg = oracleStateArg()
if arg == nil:
  # by hand: every history to depth four, both rails
  for rail in ["fake", "btc"]:
    var frontier = @[""]
    var n = 0
    for depth in 0 ..< 4:
      var next: seq[string]
      for h in frontier:
        let m = ruleModel(h, rail == "btc")
        for a in allowed(m, h, rail == "btc"):
          inc n
          let (ok, _) = replay(rail == "btc", h & a, n)
          doAssert ok, rail & " history " & h & a & " — judged wrongly"
          next.add h & a
      frontier = next
  quit(0)
let rail = oracleStateStr(arg, "rail", "fake")
let hist = oracleStateStr(arg, "hist", "")
var succ: seq[JsonNode]
var n = 0
if hist.len < Frontier:
  for a in allowed(ruleModel(hist, rail == "btc"), hist, rail == "btc"):
    succ.add state(rail, hist & a, n)
emitSuccessors(succ)
