## A savings circle's rounds from the pot (exo-267.3; docs/design/logos-world-plan.md Phase 1,
## The circle): every member pays their share into the room's LEZ multisig vault from their
## own account each round, and the round's payout is a vault transfer the members vote on, to
## the member the charter's schedule names. On the fake v0.3 zone, through the room's own
## propose, vote and settle path:
##   1. the circle's terms come from the charter in force and the account it names: the vault,
##      the order, the share;
##   2. a pay-in counts only when the chain holds it: included, a transfer of exactly the share
##      into the vault, signed by an account its member shared with the room — a claim with
##      someone else's transaction, a wrong amount or an unknown hash counts for nothing;
##   3. round 1 stays open while a pay-in is missing, naming who has not paid, then pays out
##      by vote; a payout off the schedule is flagged on its card before anyone votes: out of
##      order, to an account no circle member shared, the wrong amount, a round already paid;
##   4. one transaction counts for one round only;
##   5. rounds 2 and 3: each member pays in each round and receives once;
##   6. the view is a function of the event set and the chain reads.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils, random]
import stint
import ../src/hashing/sha256
import ../src/crypto/keystore
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/charter
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                # toHex
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/session
import ../src/coordination/live
import ../src/coordination/vote
import ../src/coordination/accounts
import ../src/coordination/authorship
import ../src/coordination/member_accounts
import ../src/coordination/room_charter
import ../src/coordination/circle
import ./probes/live_room

proc encOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))

const Label = "lez-account/0"
let ids = @[encOf(aliceKs), encOf(bobKs), encOf(room3CarolKs)]
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let accts = kss.mapIt(publicAccountId(it.lezMemberKey(Label)))     # each member's own LEZ account
let outsider = id32("outsider")
let msProgram = id32("lez-multisig-v030-program")
let ck = id32("tuesday-circle")
let f = newFakeLezMultisig("lez:local", psLee02, msProgram, feePerTx = 1, layout = plV03)
for a in accts & @[outsider]: f.fund(a, 1_000)
let vault = vaultPda(psLee02, msProgram, ck)
doAssert f.submit(accts[0], createOp(ck, 2, accts)).ok and f.lastRefusal.len == 0

var r = newRoom3("/muster/1/circle-rounds/proto")
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() = (for s in sessions: s.poll())
proc evs(): seq[Event] = (pollAll(); r.alice.roomEvents())

# the circle's multisig, disclosed; each member's own account, shared and proved by its key
let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: "lez:local",
  address: toHex(statePda(psLee02, msProgram, ck)), label: "Circle pot", signers: accts.mapIt(toHex(it)),
  threshold: 2, config: cfg), encOf(aliceKs)))
for i, s in sessions: discard discloseAccount(s, kss[i], Label, "lez:local", name = "mine")
pollAll()
let roomAcct = reduceAccounts(evs())[0]
let policy = qualify("lez-multisig", roomAcct.id)

let dfor = proc(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(p: string): Driver =
    if p == CharterKind: return newCharterDriver(ids)
    driverForPolicy(p, reduceAccounts(sess.roomEvents()), proc(k: string): Driver = liveDriverFor(k))
let dA = dfor(r.alice)

# the charter: the circle template naming the multisig, 100 each per round, in this order
var seqNo = 100'u64
block:
  let body = circleTemplate(name = "Tuesday circle", purpose = "", members = ids, amendK = 2,
                            account = roomAcct.id, share = "100", asset = "LEZ", cadenceSec = 604800)
  let fj = foundingEffect(body)
  inc seqNo
  let id = liveProposeIntent(r.alice, aliceKs, dA, CharterKind, fj, int64(Now), seqNo, account = r.topic, ttlSec = Ttl)
  for i, s in sessions:
    pollAll()
    discard liveContribute(s, kss[i], dfor(s), id, "", "", bindCtx(), Now)
  doAssert charterInForce(evs(), dA).found

let readTx: TxReader = proc(h: string): TxRead = f.readTx(h)
proc setup(): CircleSetup = circleSetupOf(charterInForce(evs(), dA), reduceAccounts(evs()))
proc view(): CircleView = circleView(evs(), dA, r.topic, setup(), readTx)

proc payIn(i, round: int, amount = 100'u64, report = -1): string =
  ## member i pays `amount` into the vault from their own account; member `report` (default i)
  ## reports it for `round`
  let tx = f.submitCall(accts[i], lezCallV03(NativeTokenProgram, @[(accts[i], newSeq[byte](32)), (vault, newSeq[byte](32))],
                                             nativeTransfer(amount.stuint(128)), @[]))
  doAssert tx.ok
  let who = (if report < 0: i else: report)
  sessions[who].publishAuthored(kss[who], payInEvent(roomAcct.id, round, ids[who], tx.hash))
  tx.hash

var nextIndex = 1'u64
proc proposePayout(to: seq[byte], amount: uint64): string =
  inc seqNo
  result = liveProposeOnChain(r.alice, aliceKs, dA, policy, payoutCall(setup(), to, amount),
                              newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result
proc agreeAndSettle(id: string) =
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), id, newLezVoteSeam(f, accts[1]), bindCtx(), Now) == "executable"
  let drv = LezMultisigDriver(dA(policy))
  let stl = settlementFor(drv, f, Account(chain: "lez:local", form: afPublic, id: toHex(accts[0])))
  r.alice.poll()
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  let txRef = stl.submit(built.tx, aliceKs)
  doAssert stl.watch(txRef).status == fsFinal
  # what the hosted submit then records in the room (coordinate_submit)
  r.alice.publish(submitEvent(id, chainRef = txRef.id))
  r.alice.publish(finalEvent(id, chainRef = txRef.id))

proc roundOf(v: CircleView, n: int): RoundView = v.rounds[n - 1]
proc payoutOf(v: CircleView, id: string): PayoutView =
  for p in v.payouts:
    if p.intent == id: return p
  doAssert false, "no payout " & id

# ── 1. the circle's terms come from its charter ─────────────────────────────────
block:
  let s = setup()
  doAssert s.ok, s.why
  doAssert s.vault == vault and s.order == ids and s.share == 100 and s.n == 3 and s.chain == "lez:local"
  doAssert payoutCall(s, accts[0], 300).shards[0].account == vault, "a payout moves out of the vault"
  let v = view()
  doAssert v.current == 1 and roundOf(v, 1).recipient == ids[0] and roundOf(v, 3).recipient == ids[2]
  doAssert roundOf(v, 1).missing == ids, "nobody has paid in yet"
  echo "1. the circle's vault, order and share come from the charter in force OK"

# ── 2. a pay-in counts only when the chain holds it ─────────────────────────────
block:
  discard payIn(0, 1, report = 1)                 # bob claims alice's payment as his
  discard payIn(1, 1, amount = 50)                # bob pays 50, not the share
  r.carol.publishAuthored(room3CarolKs, payInEvent(roomAcct.id, 1, ids[2], repeat("ab", 32)))   # no such tx
  let v = view()
  let paid = roundOf(v, 1).payIns
  doAssert paid.anyIt(it.member == ids[1] and it.standing == "not theirs"), $paid
  doAssert paid.anyIt(it.member == ids[1] and it.standing == "not a pay-in"), $paid
  doAssert paid.anyIt(it.member == ids[2] and it.standing == "not on chain"), $paid
  doAssert roundOf(v, 1).missing == ids, "none of those counts"
  echo "2. someone else's transaction, a wrong amount and an unknown hash count for nothing OK"

# ── 3. round 1; off-schedule payouts flagged before anyone votes ────────────────
var round1Tx = ""
block:
  round1Tx = payIn(0, 1)
  discard payIn(1, 1)
  var v = view()
  doAssert roundOf(v, 1).missing == @[ids[2]], "carol has not paid: the round stays open, naming her"
  let early = proposePayout(accts[0], 300)
  v = view()
  doAssert payoutOf(v, early).round == 1 and payoutOf(v, early).onSchedule
  doAssert payoutOf(v, early).missing == @[ids[2]], "its card names who has not paid in"
  discard payIn(2, 1)
  v = view()
  doAssert roundOf(v, 1).missing.len == 0
  # off the schedule, each said so before anyone votes
  let outOfOrder = proposePayout(accts[2], 300)         # carol is round 3
  let stranger = proposePayout(outsider, 300)
  let short = proposePayout(accts[0], 200)
  v = view()
  doAssert not payoutOf(v, outOfOrder).onSchedule and "round 1" in payoutOf(v, outOfOrder).why, payoutOf(v, outOfOrder).why
  doAssert not payoutOf(v, stranger).onSchedule and "shared" in payoutOf(v, stranger).why, payoutOf(v, stranger).why
  doAssert not payoutOf(v, short).onSchedule and "300" in payoutOf(v, short).why, payoutOf(v, short).why
  let before = f.balanceOf(accts[0])
  agreeAndSettle(early)
  v = view()
  doAssert roundOf(v, 1).settled and roundOf(v, 1).payout == early and v.current == 2
  doAssert f.balanceOf(accts[0]) == before + 300 - 1, "alice receives the pot, less her fee as the relayer who settles"
  let again = proposePayout(accts[0], 300)
  doAssert not payoutOf(view(), again).onSchedule and "already paid" in payoutOf(view(), again).why
  echo "3. round 1: open until carol paid; paid out to alice by vote; off-schedule payouts flagged OK"

# ── 4. one transaction counts for one round ─────────────────────────────────────
block:
  r.alice.publishAuthored(aliceKs, payInEvent(roomAcct.id, 2, ids[0], round1Tx))
  let v = view()
  doAssert roundOf(v, 2).payIns.anyIt(it.member == ids[0] and it.standing == "counted for round 1")
  doAssert ids[0] in roundOf(v, 2).missing
  echo "4. a round-1 payment reported again for round 2 counts for nothing OK"

# ── 5. rounds 2 and 3 ─────────────────────────────────────────────────────────────
block:
  for round in 2 .. 3:
    for i in 0 ..< 3: discard payIn(i, round)
    let p = proposePayout(accts[round - 1], 300)
    doAssert payoutOf(view(), p).onSchedule, payoutOf(view(), p).why
    agreeAndSettle(p)
  let v = view()
  doAssert v.rounds.allIt(it.settled) and v.current == 4 and v.complete
  for i in 0 ..< 3:
    doAssert v.rounds.countIt(it.recipient == ids[i]) == 1
  echo "5. three rounds: each member paid in each round and received once OK"

# ── 6. order-free ───────────────────────────────────────────────────────────────
block:
  let all = evs()
  let base = $circleJson(circleView(all, dA, r.topic, setup(), readTx))
  var rng = initRand(3)
  for i in 0 ..< 6:
    var sh = all & all[0 ..< all.len div 4]
    rng.shuffle(sh)
    doAssert $circleJson(circleView(sh, dA, r.topic, setup(), readTx)) == base, "trial " & $i
  echo "6. reordered and duplicated, the same rounds OK"

echo "circle_rounds_test: a circle's rounds from the pot — all OK"
