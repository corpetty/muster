## lez-msig from a muster room, against the REAL program on a LEZ v0.3 zone (epic exo-0d3).
##
##   infra/lez/localnet.sh
##   MUSTER_LEZ_MSIG_BIN=<programs/lez-msig target …/msig.bin> \
##     module/tests/run-suite.sh e2e lez_msig_live
##
## Three members share one room (Alice, Bob, Carol). In order:
##   1. the ceremony: Alice opens a 2-of-3; Bob's and Carol's clients join with their own
##      per-multisig approval keys, each proved by itself and author-signed;
##   2. Alice creates it ON CHAIN from her own funded LEZ account, and discloses it; the
##      disclosure re-derives the PDA, and the room resolves lez-msig@<CAIP-10> to it;
##   3. the vault is funded; Alice proposes a transfer (proposing is her approval), Bob
##      approves in-app; the intent is executable with 2 of 3; settlement reads the state,
##      sends ONE Execute carrying both approvals, and the program pays the recipient;
##   4. R.2: a payment approved under epoch 0 and not executed is refused once a config
##      change (a 30 s time lock) has executed: settlement names the stale epoch;
##   5. the time lock: a new payment is QUEUED, is not executable before its ETA, and
##      settlement's own watch executes it once the lock ends;
##   6. below threshold: a proposal only its proposer approved is never sent;
##   7. member accounts (exo-1f9): Bob discloses an account of his own to the room, a second
##      multisig is set up with it as his approval key, and the program pays on Bob's approval
##      signed with that account.
## Each member pays their own transaction's fee; approvals cost nothing on chain.

import std/[os, json, strutils, sequtils, times, options, tables]
import stint
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_msig
import ../src/lez/msig
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live   # LezRpc
import ../src/wallet/lez_msig_chain
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, accounts, authorship, msig_room, member_accounts]
import ./probes/live_room
import ./probes/lez_funding

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
const Chain = "lez:local"
const PayerLabel = "lez-member/0"

var programText = getEnv("MUSTER_LEZ_MSIG_PROGRAM")
let bin = getEnv("MUSTER_LEZ_MSIG_BIN")
if bin.len > 0: programText = deployFrom(url, bin)
doAssert programText.len > 0, "name the deployed program: MUSTER_LEZ_MSIG_PROGRAM, or MUSTER_LEZ_MSIG_BIN to deploy it"
let program = hexToBytes(programText)
echo "the lez-msig program: ", programText

let rpc = newLezRpc(url)
var r = newRoom3("/muster/1/lez-msig-e2e/" & $epochTime().int & "/proto")
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let sessions = @[r.alice, r.bob, r.carol]
proc chainFor(i: int): MsigLive = newMsigLive(rpc, kss[i], Chain, program, PayerLabel)
for i in 0 ..< 3:
  let payer = chainFor(i).payer()
  fundFrom(url, payer, e2eFund(), kss[i].lezMemberKey(PayerLabel))
echo "every member's own LEZ account is funded"

proc pollAll() =
  for s in sessions: s.poll()

proc waitFor(what: string, cond: proc(): bool, seconds = 120) =
  let until = epochTime() + float(seconds)
  while not cond():
    doAssert epochTime() < until, "timed out waiting for " & what
    sleep(3000)

# ── 1. the ceremony ───────────────────────────────────────────────────────────
let zone = tagged("muster-msig/v1/zone", cast[seq[byte]]("lez:local"))
let members = kss.mapIt((id: memberId(it), roles: RoleAll, weight: 1'u16))
let ck = msigOpen(r.alice, aliceKs, Chain, program, zone, members, 2, 0, true)
pollAll()
r.alice.msigJoin(aliceKs, ck)
pollAll()
doAssert joinInvited(r.bob, bobKs) == 1 and joinInvited(r.carol, room3CarolKs) == 1
pollAll()
doAssert joinInvited(r.bob, bobKs) == 0, "a member joins once"
let cer = ceremonies(r.alice.roomEvents(), r.topic).filterIt(it.createKey == ck)[0]
doAssert cer.ready, "every invited member joined"
let config = configOf(cer)
doAssert config.members.mapIt(it.key) == kss.mapIt(it.lezMemberKey(msigLabel(hexToBytes(ck))))
echo "1. the ceremony: three approval keys, each proved by itself and author-signed OK"

# ── 2. create on chain, disclose ──────────────────────────────────────────────
let createKey = hexToBytes(ck)
let a = multisigPublic(program, createKey)
let alice = chainFor(0)
block:
  let ins = MsigInstruction(kind: ikCreate, zone: zone, config: config)
  let sent = alice.sendMsig(msigShards(program, a, ins), envelopePublic(createKey, ins))
  doAssert sent.ok, sent.error
  waitFor("the multisig on chain", proc(): bool = alice.readMsig(a).found)
let onChain = alice.readMsig(a)
doAssert onChain.state.config == config and onChain.state.epoch == 0 and onChain.state.zone == zone
let acct = LezMsigAccount(chain: Chain, program: program, createKey: createKey, zone: zone, address: a,
                          accountId: Chain & ":" & hexOf(a), epoch: 0, config: config)
let ra = RoomAccount(family: LezMsigFamily, chain: Chain, address: hexOf(a), label: "e2e treasury",
                     signers: config.members.mapIt(hexOf(it.key)), threshold: 2, config: configJsonOf(acct))
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(ra, memberId(aliceKs)))
pollAll()
let policy = "lez-msig@" & acct.accountId
let roomDriverFor: DriverFor = proc(kind: string): Driver =
  driverForPolicy(kind, reduceAccounts(r.alice.roomEvents()), proc(k: string): Driver = newUnsupportedDriver(k))
doAssert roomDriverFor(policy) of LezMsigDriver, "the room resolves the disclosed account"
doAssert lezMsigDisclosureCheck(reduceAccounts(r.alice.roomEvents())[0]).status == acVerified
echo "2. created on chain at its PDA from Alice's own account; disclosed and resolved OK"

# ── 3. fund, propose, approve, execute ────────────────────────────────────────
fundFrom(url, a, "5000")
waitFor("the funded vault", proc(): bool = alice.readMsig(a).balance >= 5000.u128)
# a recipient that exists: on LEZ v0.4 a credit to an account no one has used yet waits as a
# pending message until its owner claims it, so the balance below would not move
let recipient = publicAccountId(kss[0].lezMemberKey("lez-msig-e2e/recipient"))
fundFrom(url, recipient, "1", kss[0].lezMemberKey("lez-msig-e2e/recipient"))
waitFor("the recipient exists", proc(): bool = rpc.getAccount(recipient).balance >= 1.u128)
let before = rpc.getAccount(recipient).balance
let drv = LezMsigDriver(roomDriverFor(policy))
var seqNo = 100'u64
proc propose(i: int, action: MsigAction, st: MsigState): string =
  inc seqNo
  let p = newMsigProposal(sessions[i].roomEvents(), kss[i], drv, st, action, uint64(epochTime() * 1000) + 3_600_000)
  let (id, approval) = liveMsigPropose(sessions[i], kss[i], roomDriverFor, policy, drv, p, int64(epochTime()), seqNo, bindCtx())
  doAssert approval.len > 0 and not approval.startsWith("refused"), "the proposer's own approval: " & approval
  pollAll()
  id

proc approve(i: int, id: string) =
  let res = liveContribute(sessions[i], kss[i], roomDriverFor, id, "", "", bindCtx(), uint64(epochTime()))
  doAssert not res.startsWith("refused") and not res.startsWith("unknown"), res
  pollAll()

proc contributionsOf(id: string): seq[SettleContribution] =
  for e in r.alice.roomEvents():
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
      result.add (contributor: p[3], bytes: hexToBytes(e.value))

proc settle(id: string, slackMs = 0'u64): tuple[st: LezMsigSettlement, asm0: Assembled] =
  let st = LezMsigSettlement(settlementFor(drv, chainFor(0), Account(chain: Chain, form: afPublic, id: "")))
  st.queueSlackMs = slackMs
  (st, st.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), contributionsOf(id)))

proc settleAndWatch(id: string, seconds = 180, slackMs = 0'u64): Finality =
  let (st, asm0) = settle(id, slackMs)
  doAssert asm0.ok, asm0.error & ": " & asm0.detail
  let txRef = st.submit(asm0.tx, aliceKs)
  let until = epochTime() + float(seconds)
  while true:
    result = st.watch(txRef)
    if result.status != fsPending or epochTime() > until: return
    sleep(3000)

let pay1 = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 1200.u128), alice.readMsig(a).state)
doAssert intentState(r.alice.roomEvents(), roomDriverFor, pay1) != "executable", "1 of 2 is not executable"
approve(1, pay1)
doAssert intentState(r.alice.roomEvents(), roomDriverFor, pay1) == "executable", "2 of 3"
let f1 = settleAndWatch(pay1)
doAssert f1.status == fsFinal, $f1
doAssert rpc.getAccount(recipient).balance == before + 1200.u128, "the program paid the recipient"
doAssert alice.readMsig(a).balance == 3800.u128
doAssert not alice.readMsig(a).state.nonceFree(0), "the nonce is spent on chain"
echo "3. proposed, approved 2 of 3 in the room, executed in ONE transaction: the program paid OK"

# ── 4. R.2: a configuration change voids approvals gathered before it ──────────
let stale = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 1.u128), alice.readMsig(a).state)
approve(2, stale)                                         # Carol: 2 of 3 under epoch 0, not executed
let lock = propose(1, MsigAction(kind: akConfig, changes: @[MsigChange(kind: ccSetTimelock, timelockMs: 30_000)]),
                   alice.readMsig(a).state)
approve(2, lock)
doAssert settleAndWatch(lock).status == fsFinal
doAssert alice.readMsig(a).state.epoch == 1 and alice.readMsig(a).state.config.timelockMs == 30_000
let (_, staleAsm) = settle(stale)
doAssert not staleAsm.ok and "stale-epoch" in staleAsm.detail, staleAsm.detail
echo "4. R.2: approvals from epoch 0 are refused after the change, by name (", staleAsm.detail[0 ..< 40], "…) OK"

# ── 5. the time lock ─────────────────────────────────────────────────────────
let pay2 = propose(2, MsigAction(kind: akTransfer, to: recipient, amount: 300.u128), alice.readMsig(a).state)
approve(1, pay2)
let (qst, qasm) = settle(pay2, slackMs = 45_000)
doAssert qasm.ok, qasm.detail
doAssert parseJson(qasm.tx.payload)["msig"].getStr() == $ikQueue, "a time-locked multisig queues"
let qref = qst.submit(qasm.tx, aliceKs)
var qf = qst.watch(qref)
var sawQueued = false
let until = epochTime() + 240
while qf.status == fsPending and epochTime() < until:
  if "queued" in qf.detail and not sawQueued:
    sawQueued = true
    let (_, early) = settle(pay2)
    doAssert not early.ok and "time lock ends" in early.detail, early.detail
    echo "   queued; before its ETA settlement refuses: ", early.detail
  sleep(3000)
  qf = qst.watch(qref)
doAssert sawQueued and qf.status == fsFinal, $qf
doAssert rpc.getAccount(recipient).balance == before + 1500.u128
echo "5. the time lock: queued, refused before its ETA, executed by the watch after it OK"

# ── 6. below threshold, nothing is sent ───────────────────────────────────────
let lone = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 7.u128), alice.readMsig(a).state)
let (_, loneAsm) = settle(lone)
doAssert not loneAsm.ok and loneAsm.error == "insufficient-signatures", loneAsm.error
echo "6. one approval of two: settlement sends nothing (", loneAsm.detail, ") OK"

# ── 7. a multisig set up with an account Bob disclosed ─────────────────────────
block:
  let bobAcct = discloseAccount(r.bob, bobKs, nextFreeLabel(bobKs, r.bob.roomEvents(), r.topic), Chain, "bob's account")
  pollAll()
  var picks = initTable[string, string]()
  picks[memberId(bobKs)] = hexOf(bobAcct.key)
  let ck2 = msigOpen(r.alice, aliceKs, Chain, program, zone, members, 2, 0, true, accounts = picks)
  pollAll()
  doAssert joinInvited(r.alice, aliceKs) == 1 and joinInvited(r.carol, room3CarolKs) == 1 and joinInvited(r.bob, bobKs) == 0
  pollAll()
  let cer2 = ceremonyOf(r.alice.roomEvents(), r.topic, ck2).get
  doAssert cer2.ready
  let config2 = configOf(cer2)
  doAssert config2.members[1].key == bobAcct.key
  let createKey2 = hexToBytes(ck2)
  let a2 = multisigPublic(program, createKey2)
  let ins = MsigInstruction(kind: ikCreate, zone: zone, config: config2)
  let sent = alice.sendMsig(msigShards(program, a2, ins), envelopePublic(createKey2, ins))
  doAssert sent.ok, sent.error
  waitFor("the second multisig on chain", proc(): bool = alice.readMsig(a2).found)
  doAssert alice.readMsig(a2).state.config.members[1].key == bobAcct.key, "the program holds Bob's disclosed account"
  let acct2 = LezMsigAccount(chain: Chain, program: program, createKey: createKey2, zone: zone, address: a2,
                             accountId: Chain & ":" & hexOf(a2), epoch: 0, config: config2)
  r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMsigFamily, chain: Chain,
    address: hexOf(a2), label: "with bob's account", signers: config2.members.mapIt(hexOf(it.key)), threshold: 2,
    config: configJsonOf(acct2)), memberId(aliceKs)))
  pollAll()
  fundFrom(url, a2, "2000")
  waitFor("the second vault funded", proc(): bool = alice.readMsig(a2).balance >= 2000.u128)
  let policy2 = "lez-msig@" & acct2.accountId
  let drv2 = LezMsigDriver(roomDriverFor(policy2))
  doAssert myMsigLabel(bobKs, drv2.account) == ownLabelOf(bobKs, bobAcct.key).get, "Bob's client signs with his account"
  inc seqNo
  let p2 = newMsigProposal(r.alice.roomEvents(), aliceKs, drv2, alice.readMsig(a2).state,
                           MsigAction(kind: akTransfer, to: recipient, amount: 250.u128), uint64(epochTime() * 1000) + 3_600_000)
  let (pay3, ap) = liveMsigPropose(r.alice, aliceKs, roomDriverFor, policy2, drv2, p2, int64(epochTime()), seqNo, bindCtx())
  doAssert not ap.startsWith("refused"), ap
  pollAll()
  let res = liveContribute(r.bob, bobKs, roomDriverFor, pay3, "", "", bindCtx(), uint64(epochTime()))
  doAssert not res.startsWith("refused") and not res.startsWith("unknown"), res
  pollAll()
  doAssert intentState(r.alice.roomEvents(), roomDriverFor, pay3) == "executable"
  let before3 = rpc.getAccount(recipient).balance
  let st3 = LezMsigSettlement(settlementFor(drv2, chainFor(0), Account(chain: Chain, form: afPublic, id: "")))
  let asm3 = st3.assemble(drv2, effectFromJson(effectJsonOf(r.alice.roomEvents(), pay3)), contributionsOf(pay3))
  doAssert asm3.ok, asm3.error & ": " & asm3.detail
  let ref3 = st3.submit(asm3.tx, aliceKs)
  var f3 = st3.watch(ref3)
  let until3 = epochTime() + 180
  while f3.status == fsPending and epochTime() < until3:
    sleep(3000)
    f3 = st3.watch(ref3)
  doAssert f3.status == fsFinal, $f3
  doAssert rpc.getAccount(recipient).balance == before3 + 250.u128
  # Bob proposes from it: the proposer key is his shared account, which the program checks
  inc seqNo
  let p4 = newMsigProposal(r.bob.roomEvents(), bobKs, drv2, alice.readMsig(a2).state,
                           MsigAction(kind: akTransfer, to: recipient, amount: 75.u128), uint64(epochTime() * 1000) + 3_600_000)
  doAssert p4.proposer == bobAcct.key
  let (pay4, ap4) = liveMsigPropose(r.bob, bobKs, roomDriverFor, policy2, drv2, p4, int64(epochTime()), seqNo, bindCtx())
  doAssert not ap4.startsWith("refused"), ap4
  pollAll()
  doAssert not liveContribute(r.alice, aliceKs, roomDriverFor, pay4, "", "", bindCtx(), uint64(epochTime())).startsWith("refused")
  pollAll()
  let st4 = LezMsigSettlement(settlementFor(drv2, chainFor(0), Account(chain: Chain, form: afPublic, id: "")))
  let asm4 = st4.assemble(drv2, effectFromJson(effectJsonOf(r.alice.roomEvents(), pay4)), contributionsOf(pay4))
  doAssert asm4.ok, asm4.error & ": " & asm4.detail
  let ref4 = st4.submit(asm4.tx, aliceKs)
  var f4 = st4.watch(ref4)
  let until4 = epochTime() + 180
  while f4.status == fsPending and epochTime() < until4:
    sleep(3000)
    f4 = st4.watch(ref4)
  doAssert f4.status == fsFinal, $f4
  doAssert rpc.getAccount(recipient).balance == before3 + 325.u128
echo "7. a multisig set up with Bob's disclosed account: the program paid on his approval, and on his proposal, signed with it OK"

echo "lez_msig_live_e2e: all passed"
