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
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts, authorship,
                            member_accounts, room_charter, circle]
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
echo "1. ", url, " (LEZ v0.3): multisig ", toHex(msProgram)[0 .. 11], "…; three members' own accounts, funded OK"

# ── 2. the 2-of-3, disclosed; the charter founded by all three ────────────────
var ck = newSeq[byte](32)
for i in 0 ..< 32: ck[i] = byte(rand(255))
doAssert chains[0].submit(accts[0], createOp(ck, 2, accts)).ok
let vault = vaultPda(psLee02, msProgram, ck)
waitUntil("the multisig's state", proc(): bool = chains[0].readState(ck).found)
var r = newRoom3("/muster/1/circle-live-v030/" & run)
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

proc payIn(i, round: int, report = -1): string =
  chains[i].waitForInclusion = false          # three pay-ins in one block; the caller waits
  let tx = chains[i].submitCall(accts[i], payInCall(setup, accts[i]))
  chains[i].waitForInclusion = true           # a proposal or vote reads back what it sent
  doAssert tx.ok, tx.error
  let who = (if report < 0: i else: report)
  sessions[who].publishAuthored(kss[who], payInEvent(roomAcct.id, round, ids[who], tx.hash))
  tx.hash
proc payoutOf(v: CircleView, id: string): PayoutView =
  for p in v.payouts:
    if p.intent == id: return p
  doAssert false, "no payout " & id
proc propose(to: seq[byte]): string =
  inc seqNo
  result = liveProposeOnChain(r.alice, aliceKs, dA, policy, payoutCall(setup, to, setup.share * 3),
                              newLezVoteSeam(chains[0], accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result
proc agreeAndSettle(id: string) =
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), id, newLezVoteSeam(chains[1], accts[1]), bindCtx(), Now) == "executable"
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

# ── 3. round 1's pay-ins, read back from the sequencer ────────────────────────
block:
  let t0 = payIn(0, 1, report = 1)                    # bob claims alice's payment
  waitUntil("alice's pay-in", proc(): bool = readTx(t0).known)
  let rt = readTx(t0)
  doAssert rt.signer == accts[0], "the sequencer's transaction names its signer"
  var v = view()
  doAssert v.rounds[0].payIns.anyIt(it.member == ids[1] and it.standing == "not theirs"), $v.rounds[0].payIns
  r.alice.publishAuthored(aliceKs, payInEvent(roomAcct.id, 1, ids[0], t0))   # now her own report
  let hs = @[payIn(1, 1), payIn(2, 1)]
  waitUntil("bob's and carol's pay-ins", proc(): bool = hs.allIt(readTx(it).known))
  waitUntil("the pot", proc(): bool = native(vault) == (setup.share * 3).stuint(128))
  v = view()
  doAssert v.rounds[0].missing.len == 0, $v.rounds[0].payIns
  doAssert v.rounds[0].payIns.filterIt(it.standing == "included").len == 3
  let early = propose(accts[2])                       # carol is round 3
  doAssert not payoutOf(view(), early).onSchedule and "round 1" in payoutOf(view(), early).why
  echo "3. round 1: three pay-ins read back from the sequencer and counted, a borrowed one refused; ",
       "a payout to round 3's recipient flagged out of order OK"

# ── 4. three rounds paid out by vote ──────────────────────────────────────────
block:
  for round in 1 .. 3:
    if round > 1:
      let hs = (0 ..< 3).toSeq.mapIt(payIn(it, round))
      waitUntil("round " & $round & "'s pay-ins", proc(): bool = hs.allIt(readTx(it).known))
      waitUntil("the pot", proc(): bool = native(vault) == (setup.share * 3).stuint(128))
    let before = native(accts[round - 1])
    let p = propose(accts[round - 1])
    doAssert payoutOf(view(), p).onSchedule, payoutOf(view(), p).why
    agreeAndSettle(p)
    doAssert native(vault) == 0.stuint(128), "the pot is paid out"
    # the pot (3 × 10⁸) far exceeds what the round's own transactions cost its recipient in fees
    doAssert native(accts[round - 1]) > before, "round " & $round & "'s recipient was paid"
    doAssert view().rounds[round - 1].settled
  let v = view()
  doAssert v.complete and v.rounds.allIt(it.settled)
  echo "4. three rounds paid out by vote, each member once; the vault is back to 0 OK"

echo "circle_rounds_v030_e2e: a circle's rounds from the pot on a real LEZ v0.3.0 chain — all OK"
