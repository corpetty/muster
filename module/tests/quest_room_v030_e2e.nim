## Quests in the room on a REAL LEZ v0.3.0 chain (exo-267.8): the room drives the LEZ
## multisig's v0.3 port and the quest record program (programs/lez-quest), both deployed on
## infra/lez/localnet.sh's zone, through wallet/lez_multisig_live.nim. No model stands in.
##   1. both programs are there; three members, a taker and a confirmer derive LEZ accounts in
##      their own keystores, each funded by the zone's funder for its own fees;
##   2. a 2-of-3 is created and its vault funded;
##   3. in the room: the terms go in, Alice proposes the quest's Open on chain, Bob votes, the
##      settlement Executes — the vault's grant carries into the quest program's transfer of
##      the bounty into the record;
##   4. the taker accepts and the confirmer confirms, each with their own transaction; an
##      Accept by someone the quest does not name is included and changes nothing;
##   5. the room proposes the Close, Bob votes, it settles: the taker holds the bounty;
##   6. a reader with no room key verifies the attestation from the chain alone.
## Usage: quest_room_v030_e2e [sequencerUrl] [blockSeconds] [multisigProgram] [questProgram]
##   defaults http://127.0.0.1:3040, 15, $MUSTER_LEZ_MULTISIG_V03_PROGRAM, $MUSTER_LEZ_QUEST_PROGRAM.
## Env: MUSTER_LEZ_MULTISIG_V03_BIN / MUSTER_LEZ_QUEST_BIN — deploy that guest first (the
##   multisig port's multisig.bin; programs/lez-quest's quest.bin), the zone's funder paying.
## Needs the web3 closure (chronos, json-rpc, bearssl) + libsodium, and the local zone up.

import std/[os, json, strutils, sequtils, random, times]
import stint
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/quest
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts]
import ../src/coordination/quest as roomquest
import ./probes/live_room
import ./probes/lez_funding

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
const Chain = "lez:local"

proc idOf(s: string): seq[byte] =
  let h = s.strip()
  if h.len == 64 and h.allCharsInSet(HexDigits): hexToBytes(h) else: accountIdFromBase58(h)
proc programArg(i: int, env, binEnv: string): seq[byte] =
  var text = (if paramCount() >= i: paramStr(i) else: getEnv(env))
  if getEnv(binEnv).len > 0: text = deployFrom(url, getEnv(binEnv))
  doAssert text.len > 0, "name the deployed program: arg " & $i & ", " & env & ", or " & binEnv
  idOf(text)
let msProgram = programArg(3, "MUSTER_LEZ_MULTISIG_V03_PROGRAM", "MUSTER_LEZ_MULTISIG_V03_BIN")
let Q = programArg(4, "MUSTER_LEZ_QUEST_PROGRAM", "MUSTER_LEZ_QUEST_BIN")

proc seed32(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
randomize()
let run = toHex(@[byte(rand(255)), byte(rand(255)), byte(rand(255)), byte(rand(255))]) & $getTime().toUnix()
let carolKs = newInMemoryKeystore(seed32(3), seed32(4))
let takerKs = newInMemoryKeystore(seed32(5), seed32(6))
let confirmerKs = newInMemoryKeystore(seed32(7), seed32(8))
proc chainFor(ks: Keystore): LezMultisigLive =
  newLezMultisigLive(newLezRpc(url), ks, Chain, psLee02, msProgram, plV03, blockMs = blockSec * 1000)
let (ca, cb, cc, ct, cf) = (chainFor(aliceKs), chainFor(bobKs), chainFor(carolKs), chainFor(takerKs), chainFor(confirmerKs))
proc native(id: seq[byte]): UInt128 = ca.rpc.getAccount(id).balance
proc waitUntil(what: string, cond: proc(): bool) =
  for _ in 0 ..< blockSec * 4:
    if cond(): return
    sleep(1000)
  doAssert false, "not within four blocks: " & what
proc record(id: seq[byte]): QuestRecord = decodeQuestRecord(ca.readShard(id, Q).data)

# ── 1. both programs; five funded accounts ────────────────────────────────────
doAssert ca.rpc.getAccount(msProgram).v3 and ca.rpc.getAccount(Q).v3, "the zone runs LEZ v0.3 and both programs are there"
let m1 = ca.addMember("q3/" & run & "/alice")
let m2 = cb.addMember("q3/" & run & "/bob")
let m3 = cc.addMember("q3/" & run & "/carol")
let taker = ct.addMember("q3/" & run & "/taker")
let confirmer = cf.addMember("q3/" & run & "/confirmer")
let outsider = cc.addMember("q3/" & run & "/outsider")
let each = e2eFund()
for m in [m1, m2, m3, taker, confirmer, outsider]: fundFrom(url, m, each)
waitUntil("the funding", proc(): bool = [m1, m2, m3, taker, confirmer, outsider].allIt(native(it) == parse(each, UInt128)))
echo "1. ", url, " (LEZ v0.3): multisig ", toHex(msProgram)[0 .. 11], "…, quest ", toHex(Q)[0 .. 11],
     "…; three members, a taker, a confirmer, an outsider, each funded OK"

# ── 2. a 2-of-3, its vault funded ─────────────────────────────────────────────
var ck = newSeq[byte](32)
for i in 0 ..< 32: ck[i] = byte(rand(255))
doAssert ca.submit(m1, createOp(ck, 2, @[m1, m2, m3])).ok
let vault = vaultPda(psLee02, msProgram, ck)
fundFrom(url, vault, "1000")
waitUntil("the vault's funding", proc(): bool = native(vault) == 1000.stuint(128))
echo "2. a 2-of-3 on chain; its vault holds 1000 OK"

# ── 3. the room issues a quest ────────────────────────────────────────────────
let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
var r = newRoom("/muster/1/quest-live-v030/" & run)
r.discloseAs("alice", RoomAccount(family: LezMultisigFamily, chain: Chain,
  address: toHex(statePda(psLee02, msProgram, ck)), label: "Circle pot", signers: @[m1, m2, m3].mapIt(toHex(it)),
  threshold: 2, config: cfg))
r.bob.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
let acct = reduceAccounts(r.alice.log.allEvents())[0]
let policy = qualify("lez-multisig", acct.id)
let drv = res(r.alice)(policy)
proc settle(id: string) =
  let stl = settlementFor(drv, ca, Account(chain: Chain, form: afPublic, id: toHex(m1)))
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.log.allEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  let w = stl.watch(stl.submit(built.tx, aliceKs))
  doAssert w.status == fsFinal, $w.status & " " & w.detail
var salt = ""
for _ in 0 ..< 8: salt.add toHex(byte(rand(255)))
let terms = QuestTerms(task: "Walk a newcomer through their first split", bounty: 200.stuint(128),
                       confirmer: toHex(confirmer), taker: toHex(taker), salt: salt.toLowerAscii())
let qid = questIdFor(vault, questTermsHash(terms))
let rec = questRecordPda(psLee02, Q, vault, qid)
r.alice.publish(questTermsEvent(qid, questTermsJson(terms)))
let openId = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, questOpenCall(Q, msProgram, psLee02, ck, terms),
                                newLezVoteSeam(ca, m1), int64(Now), 1, ttlSec = Ttl)
doAssert openId.startsWith("0x"), openId
r.bob.poll()
doAssert liveVote(r.bob, bobKs, res(r.bob), openId, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
settle(openId)
doAssert record(rec).status == qsOpen and record(rec).issuer == vault
doAssert native(vault) == 800.stuint(128) and native(rec) == 200.stuint(128)
let qs = questsOf(r.bob.log.allEvents(), Q)
doAssert qs.len == 1 and qs[0].termsFound and qs[0].terms == terms
echo "3. the room issued it by vote: the record is open; the vault's grant moved 200 into it OK"

# ── 4. the taker and the confirmer ────────────────────────────────────────────
discard cc.submitCall(outsider, questAcceptCall(Q, psLee02, vault, qid, outsider))
doAssert record(rec).status == qsOpen, "an Accept by someone the quest does not name changes nothing"
doAssert ct.submitCall(taker, questAcceptCall(Q, psLee02, vault, qid, taker)).ok
waitUntil("the taker's accept", proc(): bool = record(rec).status == qsAccepted)
doAssert cf.submitCall(confirmer, questConfirmCall(Q, psLee02, vault, qid, confirmer)).ok
waitUntil("the confirmer's confirm", proc(): bool = record(rec).status == qsConfirmed)
echo "4. the outsider's Accept included and refused; taken and confirmed by their own transactions OK"

# ── 5. the room closes it ─────────────────────────────────────────────────────
let before = native(taker)
let closeId = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy,
                                 questCloseCall(Q, msProgram, psLee02, ck, qid, taker, 200.stuint(128)),
                                 newLezVoteSeam(ca, m1), int64(Now), 2, ttlSec = Ttl)
r.bob.poll()
doAssert liveVote(r.bob, bobKs, res(r.bob), closeId, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
settle(closeId)
doAssert record(rec).status == qsClosed and native(taker) - before == 200.stuint(128) and native(rec) == 0.stuint(128)
echo "5. closed by a second vote: the taker holds the 200 OK"

# ── 6. from outside ───────────────────────────────────────────────────────────
let reader = newLezMultisigLive(newLezRpc(url), newInMemoryKeystore(seed32(9), seed32(10)), Chain, psLee02,
                                msProgram, plV03, blockMs = blockSec * 1000)
let a = verifyQuestAttestation(reader, Q, rec, ck, 2)
doAssert a.ok, a.why
doAssert a.issuer == vault and a.taker == taker and a.confirmer == confirmer and a.approvals >= 2
echo "6. a reader with no room key verified issuer, taker, confirmer and ", a.approvals, " of ", a.threshold, " OK"
echo "quest_room_v030_e2e: quests in the room on a real LEZ v0.3.0 chain — all OK"
