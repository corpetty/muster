## The circle slice's exit test (exo-267.5; docs/design/logos-world-plan.md Phase 1): one
## circle's life, every step through the room's own propose, vote and settle path, on the fake
## v0.3 zone with the quest program plugged in:
##   1. three members found the circle from the template: a 2-of-3 LEZ multisig is the pot,
##      100 each per round, paid out in turn;
##   2. three rounds: every member pays in from their own account each round, the members vote
##      each payout, and each member receives the pot once;
##   3. a member change: carol leaves by the multisig's own vote — the chain no longer counts
##      her, and the room re-keys her out;
##   4. a quest: the circle issues it by vote, its bounty moving from the pot into the record;
##      carol takes it with her own account and bob confirms it; the circle closes it by vote
##      and the bounty pays her;
##   5. a fourth party, with no room key and nothing but chain reads, checks the closed quest:
##      issued by this circle's pot, taken by carol, confirmed by bob, the close approved by at
##      least the threshold of the multisig's current members.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils]
import stint
import ../src/hashing/sha256
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/charter
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/quest
import ../src/lez/quest_fake
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                # toHex
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/[intents, intent_events, session, live, vote, accounts, authorship, member_accounts,
                            room_charter, circle, member_changes]
import ../src/coordination/quest as roomquest
import ./probes/live_room

proc encOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc encHexOf(m: EncIdentity): string =
  const d = "0123456789abcdef"
  for x in m.toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))

const Label = "lez-account/0"
let ids = @[encOf(aliceKs), encOf(bobKs), encOf(room3CarolKs)]
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let accts = kss.mapIt(publicAccountId(it.lezMemberKey(Label)))
let msProgram = id32("lez-multisig-v030-program")
let Q = id32("lez-quest-program")
let ck = id32("the-tuesday-circle")
let f = newFakeLezMultisig("lez:local", psLee02, msProgram, feePerTx = 1, layout = plV03)
f.addProgram(Q, questFake(Q, psLee02))
for a in accts: f.fund(a, 2_000)
let vault = vaultPda(psLee02, msProgram, ck)
doAssert f.submit(accts[0], createOp(ck, 2, accts)).ok and f.lastRefusal.len == 0

var r = newRoom3("/muster/1/circle-exit/proto")
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() = (for s in sessions: s.poll())
proc evs(i = 0): seq[Event] = (pollAll(); sessions[i].roomEvents())

let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: "lez:local",
  address: toHex(statePda(psLee02, msProgram, ck)), label: "The pot", signers: accts.mapIt(toHex(it)),
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
var seqNo = 100'u64

proc settle(id: string) =
  let drv = LezMultisigDriver(dA(policy))
  let stl = settlementFor(drv, f, Account(chain: "lez:local", form: afPublic, id: toHex(accts[0])))
  r.alice.poll()
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  let txRef = stl.submit(built.tx, aliceKs)
  doAssert stl.watch(txRef).status == fsFinal
  r.alice.publish(submitEvent(id, chainRef = txRef.id))
  r.alice.publish(finalEvent(id, chainRef = txRef.id))
proc bobVotes(id: string) =
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), id, newLezVoteSeam(f, accts[1]), bindCtx(), Now) == "executable"
proc propose(call: LezAction): string =
  inc seqNo
  result = liveProposeOnChain(r.alice, aliceKs, dA, policy, call, newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result

# ── 1. the circle is founded ──────────────────────────────────────────────────
block:
  let p = charterProposal(charterInForce(evs(), dA),
    %*{"template": "circle", "name": "Tuesday circle", "purpose": "save together, paid out in turn", "amendK": 2,
       "account": roomAcct.id, "share": "100", "asset": "LEZ", "cadence": 604800}, ids)
  doAssert p.ok and p.founding, p.why
  inc seqNo
  let id = liveProposeIntent(r.alice, aliceKs, dA, CharterKind, p.effectJson, int64(Now), seqNo, account = r.topic, ttlSec = Ttl)
  for i, s in sessions:
    pollAll()
    discard liveContribute(s, kss[i], dfor(s), id, "", "", bindCtx(), Now)
  for i in 0 ..< 3: doAssert charterInForce(evs(i), dfor(sessions[i])).found
  echo "1. three members found the Tuesday circle: a 2-of-3 pot, 100 each per round OK"

let setup = circleSetupOf(charterInForce(evs(), dA), reduceAccounts(evs()))
doAssert setup.ok and setup.vault == vault, setup.why
let readTx: TxReader = proc(h: string): TxRead = f.readTx(h)

# ── 2. three rounds ───────────────────────────────────────────────────────────
block:
  let start = accts.mapIt(f.balanceOf(it))
  for round in 1 .. 3:
    for i in 0 ..< 3:
      let tx = f.submitCall(accts[i], payInCall(setup, accts[i]))
      doAssert tx.ok and f.lastRefusal.len == 0
      sessions[i].publishAuthored(kss[i], payInEvent(roomAcct.id, round, ids[i], tx.hash))
    let v = circleView(evs(), dA, r.topic, setup, readTx)
    doAssert v.rounds[round - 1].missing.len == 0 and v.current == round
    let p = propose(payoutCall(setup, accts[round - 1], 300))
    doAssert circleReadingOf(circleView(evs(), dA, r.topic, setup, readTx), p).reading["onSchedule"].getBool()
    bobVotes(p)
    settle(p)
  let v = circleView(evs(), dA, r.topic, setup, readTx)
  doAssert v.complete and v.rounds.allIt(it.settled) and f.balanceOf(vault) == 0
  # each member paid 300 in and received 300 once; what is left is fees
  for i in 0 ..< 3: doAssert f.balanceOf(accts[i]) < start[i] and f.balanceOf(accts[i]) > start[i] - 50
  echo "2. three rounds paid in and paid out by vote; each member received the pot once; the pot is empty OK"

# ── 3. carol leaves by the multisig's vote; the room follows ──────────────────
block:
  inc seqNo
  let id = liveProposeConfigOnChain(r.alice, aliceKs, dA, policy, ConfigAction(kind: caRemoveMember, member: accts[2]),
                                    newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  bobVotes(id)
  settle(id)
  doAssert f.readState(ck).state.members == accts[0 .. 1]
  for (who, _) in removalsDue(evs(), dA, r.topic, r.alice.members().mapIt(encHexOf(it)), ids[0]):
    doAssert who == ids[2]
    r.alice.expel(room3CarolKs.encIdentity())
  pollAll()
  doAssert ids[2] notin r.bob.members().mapIt(encHexOf(it))
  echo "3. carol leaves by the multisig's own vote; the chain and the room no longer count her OK"

# ── 4. a quest: issued, taken, confirmed, closed ──────────────────────────────
let terms = QuestTerms(task: "Teach the next circle how rounds work", bounty: 150.stuint(128),
                       confirmer: toHex(accts[1]), taker: toHex(accts[2]), salt: "a1b2c3d4e5f60718")
let qid = questIdFor(vault, questTermsHash(terms))
let record = questRecordPda(psLee02, Q, vault, qid)
var closeIndex = 0'u64
block:
  for i in 0 ..< 2:      # the pot is empty after the cycle: alice and bob put the bounty in
    doAssert f.submitCall(accts[i], payInCall(CircleSetup(vault: vault, share: 75), accts[i])).ok
  r.alice.publish(questTermsEvent(qid, questTermsJson(terms)))
  let open = propose(questOpenCall(Q, msProgram, psLee02, ck, terms))
  bobVotes(open)
  settle(open)
  doAssert decodeQuestRecord(f.readShard(record, Q).data).status == qsOpen and f.balanceOf(record) == 150
  doAssert f.submitCall(accts[2], questAcceptCall(Q, psLee02, vault, qid, accts[2])).ok and f.lastRefusal.len == 0
  doAssert f.submitCall(accts[1], questConfirmCall(Q, psLee02, vault, qid, accts[1])).ok and f.lastRefusal.len == 0
  let before = f.balanceOf(accts[2])
  let close = propose(questCloseCall(Q, msProgram, psLee02, ck, qid, accts[2], 150.stuint(128)))
  bobVotes(close)
  settle(close)
  doAssert decodeQuestRecord(f.readShard(record, Q).data).status == qsClosed
  doAssert f.balanceOf(accts[2]) == before + 150
  closeIndex = questsOf(evs(1), Q)[0].closeIndex
  echo "4. a quest issued by vote, taken by carol with her own key, confirmed by bob, closed by vote: carol is paid OK"

# ── 5. a fourth party checks it from the chain alone ──────────────────────────
block:
  let a = verifyQuestAttestation(f, Q, record, ck, closeIndex)
  doAssert a.ok, a.why
  doAssert a.issuer == vault and a.taker == accts[2] and a.confirmer == accts[1]
  doAssert a.threshold == 2 and a.approvals >= a.threshold, "approved by at least the current threshold"
  echo "5. with no room key, from chain reads alone: issued by the circle's pot, taken by carol, confirmed by bob, ",
       a.approvals, " of ", a.threshold, " current members approved the close OK"

echo "circle_exit_test: the circle slice, end to end — all OK"
