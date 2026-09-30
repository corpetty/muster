## derived-exo-a90.20 s5: a settle-up expires like any agreement — one that paid nothing pays
## nothing more past its expiry and releases the shares it covered once a grace window longer
## than any payment in flight has passed, after which they can be paid directly or covered
## again; one that began paying is finished past its expiry and keeps covering; a plain
## split past its expiry still pays nothing (exo-a90.16).
##
## STEPPER: state = one case of kind {a settle-up with payments — dinner and taxi netted
## into Carol paying Alice 400 and Bob 100; a settle-up of debts that cancel exactly — no
## payment at all; a plain split — lunch, Bob and Carol owing Alice 300 each} x payments
## made before its expiry {none, the first, all} x clock {before its expiry, inside the grace
## window, past it} x action {Carol pays her own next part, Carol pays a covered share
## directly, a new settle-up covers that share}: 81 cases (the cancelling kind has nothing
## to pay: its three "payments made" rows coincide), chained case -> case+1. The splits last
## a month; each settle-up and the plain split last an hour. Each case runs the REAL live
## path over a fake ledger, at the case's clock. The rule, stated alone:
##   * settle-up, nothing paid: its own payment goes only before its expiry; a direct payment
##     is refused until the grace window has passed, then goes; a new cover is accepted only
##     past the window;
##   * settle-up, begun: its remaining payment goes at any clock; a direct payment and a new
##     cover are refused at any clock;
##   * debts that cancel: a direct payment and a new cover are refused at any clock;
##   * plain split: Carol's payment goes only before its expiry, and only if unpaid; a new
##     settle-up may cover her unpaid share at any clock (that is how an expired split is
##     renewed, s6).
## Run by hand (no argv), it checks all 81 with doAssert.

import std/[json, strutils]
import ../../src/intents/materialization
import ../../src/coordination/parts
import ../../src/coordination/covers
import ../../src/coordination/settle_up
import ./split_room
import ./oracle_emit

const Kinds = ["settle-up", "cancelling", "plain split"]
const Paid = ["none", "first", "all"]
const Clocks = ["before", "within", "after"]
const Actions = ["own", "direct", "cover"]
const N = 81
const Month = 30'i64 * 24 * 3600
const BobPayTo = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"

proc decode(k: int): tuple[kind, paid, clock, action: string] =
  (Kinds[k div 27], Paid[(k mod 27) div 9], Clocks[(k mod 9) div 3], Actions[k mod 3])

proc clockOf(c: string): uint64 =
  case c
  of "before": Now
  of "within": Now + uint64(Ttl) + 1
  else: Now + uint64(Ttl) + CoverReleaseGraceS + 1

proc correct(k: int): bool =
  let (kind, paid, clock, action) = decode(k)
  let at = clockOf(clock)
  var r = newRoom4("/muster/1/probe-settle-expiry-" & $k & "/proto")
  var seqNo = 0'u64
  proc propose(who, effect, account: string, ttl: int64, atTime = Now): string =
    inc seqNo
    let (s, ks) = r.sessionOf(who)
    liveProposeIntent(s, ks, splitFor, EvmPolicy, effect, int64(atTime), seqNo, account = account, ttlSec = ttl)
  proc agreeAt(who, id: string, atTime: uint64): string =
    let (s, ks) = r.sessionOf(who)
    liveContribute(s, ks, splitFor, id, "", "", LinkContext(account: "probe", slot: "0", expiry: Now + 86_400 * 60), atTime)
  let ledger = newFakeLedger()
  proc pay(who, id: string, atTime: uint64): string =
    let (s, ks) = r.sessionOf(who)
    let seam = newFakePartSeam(ledger, who)
    let (o, pp) = liveSettlePartSend(s, ks, splitFor, id, seam, atTime)
    if o.len > 0: return o
    ledger.mine()
    discard liveSettlePartComplete(s, ks, splitFor, seam, pp)
    r.sync()
    ""
  # what a new settle-up covering Carol's share of `split` gets, at the case's clock
  proc coverAccepted(split: string, creditorName, creditorId, payTo, amount: string): bool =
    let c = @[Cover(intent: split, debtor: carol, creditor: creditorId, amount: amount, payTo: payTo)]
    let id = propose(creditorName, settleUpEffectJson(EvmChain, "ETH", c, netTransfers(c), "again " & $k),
                     EvmChain, Ttl, at)
    if not id.startsWith("0x"): return false
    r.sync()
    agreeAt("carol", id, at) in ["collecting", "executable"]
  case kind
  of "settle-up", "cancelling":
    let cancelling = kind == "cancelling"
    var dinner, taxi: string
    if cancelling:
      dinner = propose("alice", splitEffectJson(EvmChain, "ETH", "200", alice, AlicePayTo,
                       evenShares("200", alice, @[carol], creditorShares = false), "coffee"), EvmChain & ":" & AlicePayTo, Month)
      taxi = propose("carol", splitEffectJson(EvmChain, "ETH", "200", carol, "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
                     evenShares("200", carol, @[alice], creditorShares = false), "tea"),
                     EvmChain & ":0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc", Month)
      r.sync()
      discard agreeAt("carol", dinner, Now)
      discard agreeAt("alice", taxi, Now)
    else:
      dinner = propose("alice", splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                       evenShares("900", alice, @[bob, carol]), "dinner"), EvmChain & ":" & AlicePayTo, Month)
      taxi = propose("bob", splitEffectJson(EvmChain, "ETH", "600", bob, BobPayTo,
                     evenShares("600", bob, @[alice, carol]), "taxi"), EvmChain & ":" & BobPayTo, Month)
      r.sync()
      for (who, id) in [("bob", dinner), ("carol", dinner), ("alice", taxi), ("carol", taxi)]: discard agreeAt(who, id, Now)
    r.sync()
    let covers = openParts(r.alice.roomEvents(), splitFor, EvmChain, "ETH", Now)
    let net = netTransfers(covers)
    if cancelling != (net.len == 0): return false
    let su = propose("alice", settleUpEffectJson(EvmChain, "ETH", covers, net, "su " & $k), EvmChain, Ttl)
    r.sync()
    for who in ["bob", "carol"]:
      if not cancelling or who == "carol": discard agreeAt(who, su, Now)
    r.sync()
    if intentState(r.alice.roomEvents(), splitFor, su) != "executable": return false
    let effectivePaid = (if cancelling: "none" else: paid)
    if effectivePaid in ["first", "all"]: (if pay("carol", su, Now) != "": return false)
    if effectivePaid == "all": (if pay("carol", su, Now) != "": return false)
    let carolShare = (if cancelling: "200" else: "300")
    case action
    of "own":
      if cancelling:
        # nothing to pay: its covers hold at any clock
        return coveringIntent(r.alice.roomEvents(), splitFor, dinner, partName(carol), at) == su
      let o = pay("carol", su, at)
      let want = (if effectivePaid == "all": "already-settled"
                  elif effectivePaid == "first": ""
                  elif clock == "before": "" else: "expired")
      return o == want
    of "direct":
      let o = pay("carol", dinner, at)
      let released = effectivePaid == "none" and not cancelling and clock == "after"
      return (if released: o == "" else: o == "covered-by-settle-up")
    else:
      let released = effectivePaid == "none" and not cancelling and clock == "after"
      return coverAccepted(dinner, "alice", alice, AlicePayTo, carolShare) == released
  else:
    let lunch = propose("alice", splitEffectJson(EvmChain, "ETH", "900", alice, AlicePayTo,
                        evenShares("900", alice, @[bob, carol]), "lunch"), EvmChain & ":" & AlicePayTo, Ttl)
    r.sync()
    discard agreeAt("bob", lunch, Now)
    discard agreeAt("carol", lunch, Now)
    r.sync()
    if paid in ["first", "all"]: (if pay("bob", lunch, Now) != "": return false)
    if paid == "all": (if pay("carol", lunch, Now) != "": return false)
    let carolPaid = paid == "all"
    case action
    of "own", "direct":
      let o = pay("carol", lunch, at)
      let want = (if carolPaid: "already-settled" elif clock == "before": "" else: "expired")
      return o == want
    else:
      return coverAccepted(lunch, "alice", alice, AlicePayTo, "300") == not carolPaid

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (kind, paid, clock, action) = decode(k)
    doAssert correct(k), "case " & $k & ": " & kind & ", paid " & paid & ", clock " & clock & ", action " &
                         action & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
