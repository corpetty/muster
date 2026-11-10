## A savings circle's rounds from the pot on a REAL LEZ v0.3.0 chain (exo-267.3): the room drives
## the LEZ multisig's v0.3 port on infra/lez/localnet.sh's zone through
## wallet/lez_multisig_live.nim, and reads every pay-in back with getTransaction. No model stands in.
##   1. the multisig is there; three members derive their LEZ accounts in their own keystores,
##      share them with the room (each proved by its key), and are funded by the zone's funder;
##   2. a 2-of-3 is created from those accounts, the room discloses it, and all three found
##      the circle's charter: 10⁸ each per round, paid out in turn;
##   3. round 1: each member pays in with their own transaction; the room reads each one back
##      from the sequencer — a claim with someone else's transaction counts for nothing; a
##      payout to round 3's recipient now is flagged out of order before anyone votes;
##   4. rounds 1 to 3 pay out by vote, each to its recipient: each member receives the pot once,
##      and the vault ends where it began.
## Usage: circle_rounds_v030_e2e [sequencerUrl] [blockSeconds] [multisigProgram]
##   defaults http://127.0.0.1:3040, 15, $MUSTER_LEZ_MULTISIG_V03_PROGRAM.
## Env: MUSTER_LEZ_MULTISIG_V03_BIN — deploy that guest first (the multisig port's
##   multisig.bin), the zone's funder paying.
## Needs the web3 closure (chronos, json-rpc, bearssl) + libsodium, and the local zone up.

import std/[os, json, strutils, sequtils, random, times]
import stint
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/charter
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/lez/quest
import ../src/crypto/curve25519
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts, authorship,
                            member_accounts, room_charter, circle, member_changes]
import ../src/coordination/quest as roomquest
import ./probes/live_room
import ./probes/lez_funding

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
const Chain = "lez:local"

proc idOf(s: string): seq[byte] =
  let h = s.strip()
  if h.len == 64 and h.allCharsInSet(HexDigits): hexToBytes(h) else: accountIdFromBase58(h)
var progText = (if paramCount() >= 3: paramStr(3) else: getEnv("MUSTER_LEZ_MULTISIG_V03_PROGRAM"))
if getEnv("MUSTER_LEZ_MULTISIG_V03_BIN").len > 0: progText = deployFrom(url, getEnv("MUSTER_LEZ_MULTISIG_V03_BIN"))
doAssert progText.len > 0, "name the deployed multisig: arg 3, MUSTER_LEZ_MULTISIG_V03_PROGRAM, or MUSTER_LEZ_MULTISIG_V03_BIN"
let msProgram = idOf(progText)
var qText = (if paramCount() >= 4: paramStr(4) else: getEnv("MUSTER_LEZ_QUEST_PROGRAM"))
if getEnv("MUSTER_LEZ_QUEST_BIN").len > 0: qText = deployFrom(url, getEnv("MUSTER_LEZ_QUEST_BIN"))
doAssert qText.len > 0, "name the deployed quest program: arg 4, MUSTER_LEZ_QUEST_PROGRAM, or MUSTER_LEZ_QUEST_BIN"
let Q = idOf(qText)

proc seed32(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
randomize()
let run = toHex(@[byte(rand(255)), byte(rand(255)), byte(rand(255)), byte(rand(255))]) & $getTime().toUnix()
let label = "lez-account/" & $rand(1_000_000)                       # a fresh account each run
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
proc encOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let ids = kss.mapIt(encOf(it))
let chains = kss.mapIt(newLezMultisigLive(newLezRpc(url), it, Chain, psLee02, msProgram, plV03, blockMs = blockSec * 1000))
let accts = (0 ..< 3).toSeq.mapIt(chains[it].addMember(label))
proc native(id: seq[byte]): UInt128 = chains[0].rpc.getAccount(id).balance
proc waitUntil(what: string, cond: proc(): bool) =
  for _ in 0 ..< blockSec * 4:
    if cond(): return
    sleep(1000)
  doAssert false, "not within four blocks: " & what

# ── 1. the multisig; three members' own accounts, funded ──────────────────────
doAssert chains[0].rpc.getAccount(msProgram).v3, "the zone runs LEZ v0.3 and the multisig is there"
let each = e2eFund()
for a in accts: fundFrom(url, a, each)
waitUntil("the funding", proc(): bool = accts.allIt(native(it) == parse(each, UInt128)))
doAssert chains[0].rpc.getAccount(Q).v3, "the quest program is there"
echo "1. ", url, " (LEZ v0.3): multisig ", toHex(msProgram)[0 .. 11], "…, quest ", toHex(Q)[0 .. 11], "…; three members' own accounts, funded OK"

# ── 2. the 2-of-3, disclosed; the charter founded by all three ────────────────
var ck = newSeq[byte](32)
for i in 0 ..< 32: ck[i] = byte(rand(255))
doAssert chains[0].submit(accts[0], createOp(ck, 2, accts)).ok
let vault = vaultPda(psLee02, msProgram, ck)
waitUntil("the multisig's state", proc(): bool = chains[0].readState(ck).found)
var r = newRoom3("/muster/1/circle-exit-v030/" & run)
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() = (for s in sessions: s.poll())
proc evs(): seq[Event] = (pollAll(); r.alice.roomEvents())
let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: Chain,
  address: toHex(statePda(psLee02, msProgram, ck)), label: "Circle pot", signers: accts.mapIt(toHex(it)),
  threshold: 2, config: cfg), encOf(aliceKs)))
for i, s in sessions: discard discloseAccount(s, kss[i], label, Chain, name = "mine")
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
block:
  let fj = foundingEffect(circleTemplate(name = "Tuesday circle", purpose = "", members = ids, amendK = 2,
                                         account = roomAcct.id, share = "100000000", asset = "LEZ", cadenceSec = 604800))
  inc seqNo
  let id = liveProposeIntent(r.alice, aliceKs, dA, CharterKind, fj, int64(Now), seqNo, account = r.topic, ttlSec = Ttl)
  for i, s in sessions:
    pollAll()
    discard liveContribute(s, kss[i], dfor(s), id, "", "", bindCtx(), Now)
let setup = circleSetupOf(charterInForce(evs(), dA), reduceAccounts(evs()))
doAssert setup.ok and setup.vault == vault, setup.why
let readTx: TxReader = proc(h: string): TxRead = chains[0].readTx(h)
proc view(): CircleView = circleView(evs(), dA, r.topic, setup, readTx)
echo "2. a 2-of-3 on chain from the members' own accounts; the circle's charter founded by all three OK"

proc encHexOf(m: EncIdentity): string =
  const d = "0123456789abcdef"
  for x in m.toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc settle(id: string) =
  let drv = dA(policy)
  let stl = settlementFor(drv, chains[0], Account(chain: Chain, form: afPublic, id: toHex(accts[0])))
  r.alice.poll()
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  let txRef = stl.submit(built.tx, aliceKs)
  let w = stl.watch(txRef)
  doAssert w.status == fsFinal, $w.status & " " & w.detail
  r.alice.publish(submitEvent(id, chainRef = txRef.id))
  r.alice.publish(finalEvent(id, chainRef = txRef.id))
proc bobVotes(id: string) =
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), id, newLezVoteSeam(chains[1], accts[1]), bindCtx(), Now) == "executable"
proc propose(call: LezAction): string =
  inc seqNo
  result = liveProposeOnChain(r.alice, aliceKs, dA, policy, call, newLezVoteSeam(chains[0], accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result
proc sendOwn(i: int, call: LezAction): string =
  chains[i].waitForInclusion = false
  let tx = chains[i].submitCall(accts[i], call)
  chains[i].waitForInclusion = true
  doAssert tx.ok, tx.error
  tx.hash

# ── 3. three rounds ───────────────────────────────────────────────────────────
block:
  let pot = (setup.share * 3).stuint(128)
  for round in 1 .. 3:
    let hs = (0 ..< 3).toSeq.mapIt(sendOwn(it, payInCall(setup, accts[it])))
    for i in 0 ..< 3: sessions[i].publishAuthored(kss[i], payInEvent(roomAcct.id, round, ids[i], hs[i]))
    waitUntil("round " & $round & "'s pay-ins", proc(): bool = hs.allIt(readTx(it).known))
    waitUntil("the pot", proc(): bool = native(vault) == pot)
    doAssert view().rounds[round - 1].missing.len == 0, $view().rounds[round - 1].payIns
    let p = propose(payoutCall(setup, accts[round - 1], setup.share * 3))
    doAssert circleReadingOf(view(), p).reading["onSchedule"].getBool()
    bobVotes(p)
    settle(p)
    doAssert native(vault) == 0.stuint(128)
  doAssert view().complete
  echo "3. three rounds: every pay-in read back from the sequencer, each payout voted and executed OK"

# ── 4. carol leaves by ProposeConfig / ExecuteConfig ──────────────────────────
block:
  inc seqNo
  let id = liveProposeConfigOnChain(r.alice, aliceKs, dA, policy, ConfigAction(kind: caRemoveMember, member: accts[2]),
                                    newLezVoteSeam(chains[0], accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  bobVotes(id)
  settle(id)
  let st = chains[0].readState(ck)
  doAssert st.found and st.state.members == accts[0 .. 1], "the chain's members are alice and bob"
  for (who, _) in removalsDue(evs(), dA, r.topic, r.alice.members().mapIt(encHexOf(it)), ids[0]):
    r.alice.expel(room3CarolKs.encIdentity())
  pollAll()
  doAssert ids[2] notin r.bob.members().mapIt(encHexOf(it))
  echo "4. carol leaves by the multisig's ProposeConfig and ExecuteConfig on the real program; the room re-keys her out OK"

# ── 5. a quest ────────────────────────────────────────────────────────────────
var salt = ""
for _ in 0 ..< 8: salt.add toHex(byte(rand(255)))
let bounty = setup.share
let terms = QuestTerms(task: "Teach the next circle how rounds work", bounty: bounty.stuint(128),
                       confirmer: toHex(accts[1]), taker: toHex(accts[2]), salt: salt.toLowerAscii())
let qid = questIdFor(vault, questTermsHash(terms))
let record = questRecordPda(psLee02, Q, vault, qid)
proc rec(): QuestRecord = decodeQuestRecord(chains[0].readShard(record, Q).data)
var closeIndex = 0'u64
block:
  let fund = sendOwn(0, payInCall(setup, accts[0]))      # alice puts the bounty in
  waitUntil("the bounty in the pot", proc(): bool = readTx(fund).known and native(vault) == bounty.stuint(128))
  r.alice.publish(questTermsEvent(qid, questTermsJson(terms)))
  let open = propose(questOpenCall(Q, msProgram, psLee02, ck, terms))
  bobVotes(open)
  settle(open)
  doAssert rec().status == qsOpen and native(record) == bounty.stuint(128)
  discard sendOwn(2, questAcceptCall(Q, psLee02, vault, qid, accts[2]))
  waitUntil("carol's accept", proc(): bool = rec().status == qsAccepted)
  discard sendOwn(1, questConfirmCall(Q, psLee02, vault, qid, accts[1]))
  waitUntil("bob's confirm", proc(): bool = rec().status == qsConfirmed)
  let before = native(accts[2])
  let close = propose(questCloseCall(Q, msProgram, psLee02, ck, qid, accts[2], bounty.stuint(128)))
  bobVotes(close)
  settle(close)
  doAssert rec().status == qsClosed and native(accts[2]) == before + bounty.stuint(128)
  closeIndex = questsOf(evs(), Q)[0].closeIndex
  echo "5. a quest issued by vote, taken by carol, confirmed by bob, closed by vote: the bounty paid her OK"

# ── 6. a fourth party, chain reads alone ──────────────────────────────────────
block:
  let reader = newLezMultisigLive(newLezRpc(url), newInMemoryKeystore(seed32(9), seed32(10)), Chain, psLee02,
                                  msProgram, plV03, blockMs = blockSec * 1000)
  let a = verifyQuestAttestation(reader, Q, record, ck, closeIndex)
  doAssert a.ok, a.why
  doAssert a.issuer == vault and a.taker == accts[2] and a.confirmer == accts[1] and a.threshold == 2 and a.approvals >= 2
  echo "6. a reader with no room key and a fresh keystore verified issuer, taker, confirmer and ", a.approvals, " of ",
       a.threshold, " OK"

echo "circle_exit_v030_e2e: the circle slice on a real LEZ v0.3.0 chain — all OK"
