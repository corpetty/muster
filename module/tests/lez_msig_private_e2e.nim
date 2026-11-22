## A PRIVATE lez-msig from a muster room, through the prover, against the real program on a
## LEZ v0.3 zone (exo-efa, docs/design/lez-msig.md §6).
##
##   infra/lez/localnet.sh                              # a dev-mode zone (RISC0_DEV_MODE=1)
##   (cd programs/lez-msig && cargo build --release -p msig_host --bin msig_exec)
##   MUSTER_LEZ_MSIG_PROGRAM=<the deployed program> module/tests/run-suite.sh e2e lez_msig_private
##
## The prover here is `msig_exec`, the lez_msig_module's own code as a CLI (CliMsigProver); the
## module calls the same function. In order:
##   1. the ceremony, private: Alice opens a 2-of-3 and seals a fresh group secret to each
##      member; each member opens the same secret, and no one else in the room can;
##   2. Alice creates it through the prover (one privacy-preserving transaction, signed by
##      nobody); once the chain includes it, her client seals the note into the room, and Bob
##      and Carol read the multisig's state from it; Alice discloses the account, private;
##   3. Alice deposits into the vault from her own public account: the prover proves it, her
##      keystore signs it, the prover sends it; the new note reaches everyone;
##   4. Bob proposes a payment, Carol approves, Carol's client settles: the prover proves the
##      program's execution over the note, the recipient is paid, and every member reads the
##      new balance from the note Carol sealed;
##   5. the chain's copy of that transaction names no member key and no approval;
##   6. a payment the vault cannot cover is refused while proving: nothing is sent;
##   7. below threshold, nothing reaches the prover;
##   8. a lost note: Carol settles a payment but her note never reaches the room. Alice reads the
##      stale note, recovers the newest from the chain with the group's viewing key, and seals it
##      into the room; Bob reads it there;
##   9. the recovered note is spendable: a further payment settles from it.
##
## On LEZ v0.4 (exo-05f; MUSTER_LEZ_VERSION=v0.4.0-rc3, the prover lez04's msig_exec04) every
## transaction pays its fee inside its proof from the group's fee account (D17): before Create,
## Alice tops it up from her own public account, and each transaction's new fee note is sealed
## into the room beside the multisig's. The payee is an account with a key, since v0.4 admits a
## fresh public account only by its key.

import std/[os, json, strutils, sequtils, times, options, httpclient]
import stint
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/lez_msig
import ../src/lez/msig
import ../src/lez/tx as leztx       # publicAccountId
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live   # LezRpc
import ../src/wallet/lez_msig_chain
import ../src/wallet/lez_msig_private
import ../src/wallet/msig_prover
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, accounts, authorship, msig_room]
import ./probes/live_room
import ./probes/lez_funding

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
const Chain = "lez:local"
const PayerLabel = "lez-member/0"
let v04 = getEnv("MUSTER_LEZ_VERSION").startsWith("v0.4")
let exe = getEnv("MUSTER_MSIG_EXEC", currentSourcePath.parentDir.parentDir.parentDir /
                 (if v04: "programs/lez-msig/lez04/target/release/msig_exec04" else: "programs/lez-msig/target/release/msig_exec"))
doAssert fileExists(exe), "build the prover CLI first: cargo build --release -p " &
  (if v04: "msig_host04 --bin msig_exec04 (in lez04)" else: "msig_host --bin msig_exec") & " (" & exe & ")"
let programText = getEnv("MUSTER_LEZ_MSIG_PROGRAM")
doAssert programText.len == 64, "name the deployed program: MUSTER_LEZ_MSIG_PROGRAM"
let program = hexToBytes(programText)
let prover = newCliMsigProver(exe, @[("RISC0_DEV_MODE", getEnv("RISC0_DEV_MODE", "1"))])

let rpc = newLezRpc(url)
var r = newRoom3("/muster/1/lez-msig-private-e2e/" & $epochTime().int & "/proto")
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() =
  for s in sessions: s.poll()
proc waitFor(what: string, cond: proc(): bool, seconds = 300) =
  let until = epochTime() + float(seconds)
  while not cond():
    doAssert epochTime() < until, "timed out waiting for " & what
    sleep(2000)

# ── 1. the ceremony, private ───────────────────────────────────────────────────
let zone = tagged("muster-msig/v1/zone", cast[seq[byte]]("lez:local"))
let members = kss.mapIt((id: memberId(it), roles: RoleAll, weight: 1'u16))
let ck = msigOpen(r.alice, aliceKs, Chain, program, zone, members, 2, 0, true, private = true)
pollAll()
r.alice.msigJoin(aliceKs, ck)
pollAll()
doAssert joinInvited(r.bob, bobKs) == 1 and joinInvited(r.carol, room3CarolKs) == 1
pollAll()
let cer = ceremonyOf(r.alice.roomEvents(), r.topic, ck).get
doAssert cer.ready and cer.private
let gms = groupSecretOf(r.alice.roomEvents(), aliceKs, r.topic, ck)
doAssert gms.isSome
for i in 1 .. 2:
  doAssert groupSecretOf(sessions[i].roomEvents(), kss[i], r.topic, ck) == gms, "every member opens the same secret"
var s71, s72: array[32, byte]
for j in 0 ..< 32: (s71[j] = 0x71; s72[j] = 0x72)
let outsider = newInMemoryKeystore(s71, s72)
doAssert groupSecretOf(r.alice.roomEvents(), outsider, r.topic, ck).isNone, "no one else opens it"
let config = configOf(cer)
echo "1. the ceremony, private: one group secret, sealed to each member and opened by each OK"

# every member's chain seam: their own keystore, the shared secret, the note the room carries
let createKey = hexToBytes(ck)
proc chainFor(i: int): MsigPrivate =
  result = newMsigPrivate(rpc, url, kss[i], Chain, program, PayerLabel, prover, gms.get, createKey)
  let s = sessions[i]
  let ks = kss[i]
  result.onNote = proc(n: int, note: seq[byte], hash: string) =
    s.publishNote(ks, cer, n, note, hash)
  result.onFeeNote = proc(n: int, note: seq[byte], hash: string) =
    s.publishNote(ks, cer, n, note, hash, kind = "feenote")
proc refresh(c: MsigPrivate, i: int) =
  pollAll()
  let ln = latestNote(sessions[i].roomEvents(), kss[i], r.topic, ck)
  if ln.found: c.learn(ln.n, ln.note)
  let fn = latestNote(sessions[i].roomEvents(), kss[i], r.topic, ck, kind = "feenote")
  if fn.found: c.learnFee(fn.n, fn.note)
let chains = @[chainFor(0), chainFor(1), chainFor(2)]

# ── 2. create through the prover; the note into the room; disclose ──────────
let a = chains[0].derive()
doAssert chains[1].derive() == a, "every member derives the same private PDA"
doAssert a != multisigPublic(program, createKey), "not the public posture's address"
fundFrom(url, chains[0].payer(), e2eFund(), kss[0].lezMemberKey(PayerLabel))
waitFor("Alice's account funded", proc(): bool = rpc.getAccount04(chains[0].payer()).balance > 0.u128)
if v04:
  # the group's fee account, topped up from Alice's own account; it pays its own first fee
  let sent = chains[0].topUp(50_000_000.u128)
  doAssert sent.ok, sent.error
  waitFor("the top-up included", proc(): bool = chains[0].included(sent.hash))
  doAssert chains[0].failure(sent.hash) == "", chains[0].failure(sent.hash)
  for i in 0 .. 2: chains[i].refresh(i)
  doAssert chains[2].feeNote.len > 0, "Carol reads the fee account's note from the room"
  echo "   v0.4: Alice topped up the group's fee account; its note sealed to every member"
block:
  let sent = chains[0].sendOp(borsh(MsigInstruction(kind: ikCreate, zone: zone, config: config)))
  doAssert sent.ok, sent.error
  waitFor("the Create included", proc(): bool = chains[0].included(sent.hash))
  doAssert chains[0].failure(sent.hash) == "", chains[0].failure(sent.hash)
for i in 0 .. 2: chains[i].refresh(i)
for i in 0 .. 2:
  let rd = chains[i].readMsig(a)
  doAssert rd.found and rd.state.config == config and rd.state.epoch == 0, "member " & $i & " reads the note"
doAssert (if v04: rpc.getAccount04(a) else: rpc.getAccount(a)).shards.len == 0, "the chain holds nothing in the clear at the PDA"
let acct = LezMsigAccount(chain: Chain, program: program, createKey: createKey, zone: zone, address: a,
                          accountId: Chain & ":" & hexOf(a), epoch: 0, config: config, private: true)
let ra = RoomAccount(family: LezMsigFamily, chain: Chain, address: hexOf(a), label: "private treasury",
                     signers: config.members.mapIt(hexOf(it.key)), threshold: 2, config: configJsonOf(acct))
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(ra, memberId(aliceKs)))
pollAll()
let policy = "lez-msig@" & acct.accountId
let roomDriverFor: DriverFor = proc(kind: string): Driver =
  driverForPolicy(kind, reduceAccounts(r.alice.roomEvents()), proc(k: string): Driver = newUnsupportedDriver(k))
doAssert roomDriverFor(policy) of LezMsigDriver, "the room resolves the disclosed account"
let drv = LezMsigDriver(roomDriverFor(policy))
doAssert drv.account.private and drv.profile.family == LezMsigPrivateFamily
doAssert lezMsigDisclosureCheck(reduceAccounts(r.alice.roomEvents())[0]).status == acUnknown,
  "the room alone cannot check a private address; a member's prover derives it (above)"
echo "2. created through the prover, the note sealed into the room and read by all three; disclosed, private OK"

# ── 3. a deposit, signed in the keystore ──────────────────────────────────────
block:
  let sent = chains[0].fund(5000.u128)
  doAssert sent.ok, sent.error
  waitFor("the deposit included", proc(): bool = chains[0].included(sent.hash))
  doAssert chains[0].failure(sent.hash) == "", chains[0].failure(sent.hash)
for i in 0 .. 2: chains[i].refresh(i)
doAssert chains[2].readMsig(a).balance == 5000.u128, "Carol reads the deposit from the note"
echo "3. Alice deposited 5000 from her own account, signed in her keystore; every member reads it OK"

# ── 4. propose, approve, settle ───────────────────────────────────────────────
let recipient = (if v04: leztx.publicAccountId(kss[0].lezMemberKey("lez-msig-e2e/recipient")) else: hexToBytes("0d".repeat(32)))
if v04:
  fundFrom(url, recipient, "1", kss[0].lezMemberKey("lez-msig-e2e/recipient"))
  waitFor("the payee exists", proc(): bool = rpc.getAccount04(recipient).balance > 0.u128)
let before = rpc.getAccount(recipient).balance
var seqNo = 100'u64
proc propose(i: int, action: MsigAction, payee: seq[byte] = @[]): string =
  inc seqNo
  chains[i].refresh(i)
  let p = newMsigProposal(sessions[i].roomEvents(), kss[i], drv, chains[i].readMsig(a).state, action,
                          uint64(epochTime() * 1000) + 3_600_000)
  let (id, approval) = liveMsigPropose(sessions[i], kss[i], roomDriverFor, policy, drv, p, int64(epochTime()), seqNo, bindCtx(),
                                       payee)
  doAssert approval.len > 0 and not approval.startsWith("refused"), "the proposer's own approval: " & approval
  pollAll()
  id
proc approve(i: int, id: string) =
  let res = liveContribute(sessions[i], kss[i], roomDriverFor, id, "", "", bindCtx(), uint64(epochTime()))
  doAssert not res.startsWith("refused") and not res.startsWith("unknown"), "approve " & $i & ": " & res
  pollAll()
proc contributionsOf(id: string): seq[SettleContribution] =
  for e in r.alice.roomEvents():
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
      result.add (contributor: p[3], bytes: hexToBytes(e.value))
proc settleBy(i: int, id: string): tuple[st: LezMsigSettlement, asm0: Assembled] =
  chains[i].refresh(i)
  let st = LezMsigSettlement(settlementFor(drv, chains[i], Account(chain: Chain, form: afPublic, id: "")))
  (st, st.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), contributionsOf(id)))
proc settleAndWatch(i: int, id: string): tuple[f: Finality, txRef: TxRef] =
  let (st, asm0) = settleBy(i, id)
  doAssert asm0.ok, asm0.error & ": " & asm0.detail
  result.txRef = st.submit(asm0.tx, kss[i])
  let until = epochTime() + 300
  while true:
    result.f = st.watch(result.txRef)
    if result.f.status == fsFinal:
      # the room records the transaction's hash, never the prover's job id
      doAssert st.chainRefOf(result.txRef).len == 64 and st.chainRefOf(result.txRef) == chains[i].txHashOf(result.txRef.id),
        "chainRefOf: " & st.chainRefOf(result.txRef)
    if result.f.status != fsPending or epochTime() > until: return
    sleep(2000)

let pay = propose(1, MsigAction(kind: akTransfer, to: recipient, amount: 1200.u128))
approve(2, pay)
doAssert intentState(r.alice.roomEvents(), roomDriverFor, pay) == "executable", "2 of 3"
let (f, payRef) = settleAndWatch(2, pay)
doAssert f.status == fsFinal, $f
doAssert payRef.id.startsWith("job:")
doAssert chains[2].txHashOf(payRef.id).len == 64, "the room records the transaction's hash, never the job"
waitFor("the payee credited " & "1200", proc(): bool = rpc.getAccount(recipient).balance == before + 1200.u128, 60)   # a deferred public effect
for i in 0 .. 2: chains[i].refresh(i)
doAssert chains[0].readMsig(a).balance == 3800.u128 and not chains[0].readMsig(a).state.nonceFree(0),
  "Alice reads the payment from the note Carol sealed"
echo "4. Bob proposed, Carol approved and settled: proved over the note, the recipient paid, every member reads 3800 OK"

# ── 5. what the chain shows ───────────────────────────────────────────────────
block:
  let txHash = chains[2].txHashOf(payRef.id)
  doAssert txHash.len == 64
  let c = newHttpClient()
  defer: c.close()
  c.headers = newHttpHeaders({"Content-Type": "application/json"})
  let body = c.postContent(url, $(%*{"jsonrpc": "2.0", "id": 1, "method": "getTransaction", "params": [txHash]})).toLowerAscii()
  doAssert body.len > 200, "the transaction is on chain"
  for m in config.members: doAssert hexOf(m.key) notin body, "a member's approval key is on chain"
  doAssert hexOf(createKey) notin body, "the create key is on chain"
echo "5. the chain's copy of the payment names no member key, no approval and no create key OK"

# ── 6. refused while proving ──────────────────────────────────────────────────
let tooMuch = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 1_000_000.u128))
approve(1, tooMuch)
let (f6, _) = settleAndWatch(0, tooMuch)
doAssert f6.status == fsFailed and "while proving" in f6.detail, $f6
waitFor("the payee credited " & "1200", proc(): bool = rpc.getAccount(recipient).balance == before + 1200.u128, 60)   # a deferred public effect
echo "6. more than the vault holds: refused while proving, nothing sent (", f6.detail[0 ..< min(70, f6.detail.len)], "…) OK"

# ── 7. below threshold ────────────────────────────────────────────────────────
let lone = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 7.u128))
let (_, loneAsm) = settleBy(0, lone)
doAssert not loneAsm.ok and loneAsm.error == "insufficient-signatures", loneAsm.error
echo "7. one approval of two: nothing reaches the prover (", loneAsm.detail, ") OK"

# ── 8. a lost note, recovered from the chain ───────────────────────────────────
let lost = propose(1, MsigAction(kind: akTransfer, to: recipient, amount: 300.u128))
approve(0, lost)
let (carolOnNote, carolOnFeeNote) = (chains[2].onNote, chains[2].onFeeNote)
chains[2].onNote = nil                                    # Carol goes away before sealing her notes
chains[2].onFeeNote = nil
let (f8, _) = settleAndWatch(2, lost)
doAssert f8.status == fsFinal, $f8
chains[2].onNote = carolOnNote
chains[2].onFeeNote = carolOnFeeNote
waitFor("the payee credited " & "1500", proc(): bool = rpc.getAccount(recipient).balance == before + 1500.u128, 60)   # a deferred public effect
chains[0].refresh(0)
doAssert chains[0].readMsig(a).balance == 3800.u128, "Alice's room still carries the old note: " & $chains[0].readMsig(a).balance
block:
  let sent = chains[0].recover()
  doAssert sent.ok, sent.error
  waitFor("the scan", proc(): bool = chains[0].included(sent.hash))
  doAssert chains[0].failure(sent.hash) == "", chains[0].failure(sent.hash)
doAssert chains[0].readMsig(a).balance == 3500.u128, "the chain's newest note: 3500"
chains[1].refresh(1)
doAssert chains[1].readMsig(a).balance == 3500.u128, "Bob reads the recovered note in the room"
echo "8. a note that never reached the room: recovered from the chain by the group's viewing key, sealed in OK"

# ── 9. the recovered note is spendable ───────────────────────────────────────
let after = propose(0, MsigAction(kind: akTransfer, to: recipient, amount: 100.u128))
approve(1, after)
let (f9, _) = settleAndWatch(1, after)
doAssert f9.status == fsFinal, $f9
waitFor("the payee credited " & "1600", proc(): bool = rpc.getAccount(recipient).balance == before + 1600.u128, 60)   # a deferred public effect
echo "9. a payment settles from the recovered note OK"

# ── 10. a private payee (LEZ v0.4, exo-ea3) ──────────────────────────────────
if v04:
  # the recipient a payee shares (fixed keys, from LEZ's own crates: tests/vectors/lez-msig/v04-recipients.json)
  let vec = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-msig" / "v04-recipients.json"))
  let rec = hexToBytes(vec["recipients"][1]["recipient"].getStr())
  let paidTo = recipientAddress(decodeRecipient(rec))
  let priv = propose(1, MsigAction(kind: akTransfer, to: paidTo, amount: 1000.u128), rec)
  doAssert payeeOf(effectFromJson(effectJsonOf(r.alice.roomEvents(), priv))) == rec, "the room carries the recipient"
  approve(2, priv)
  let (f10, ref10) = settleAndWatch(2, priv)
  doAssert f10.status == fsFinal, $f10
  for i in 0 .. 2: chains[i].refresh(i)
  doAssert chains[0].readMsig(a).balance == 2400.u128, "the vault paid: " & $chains[0].readMsig(a).balance
  block:
    let c = newHttpClient()
    defer: c.close()
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    let body = c.postContent(url, $(%*{"jsonrpc": "2.0", "id": 1, "method": "getTransaction",
                                       "params": [chains[2].txHashOf(ref10.id)]})).toLowerAscii()
    doAssert body.len > 200 and hexOf(paidTo) notin body, "the chain's copy does not name the private payee"
  echo "10. a private payee: proposed with its recipient, settled sealed to it; the chain's copy names no payee OK"

echo "lez_msig_private_e2e: all passed"
