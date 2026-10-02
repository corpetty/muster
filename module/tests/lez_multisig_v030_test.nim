## The LEZ multisig on LEZ v0.3.0 (exo-eb6.4.4 L4d): muster's side of the port to v0.3's
## plan/apply program ABI (docs/design/lez-multisig-v03.md), with no chain.
##   1. the model is held to vectors from the port's own crate: the PDAs, the state, a call
##      proposal and a config proposal, every instruction (tests/vectors/lez-multisig-v030);
##   2. the in-process model reproduces the port's rules AND v0.3's rule for a refusal — the
##      transaction is included, the sender pays its fee and burns its nonce, nothing else
##      changes: an outsider's vote, fewer approvers than k, a substituted call, a second
##      Execute, another multisig naming this vault's seed, and an approval by a member
##      removed since (Execute counts only CURRENT members);
##   3. the driver's v2 effect commits the whole call (every row, the instruction bytes, the
##      seeds); S5 refuses an on-chain proposal whose call touches other accounts or carries
##      another instruction; a v1 effect is refused for a v0.3 account;
##   4. settlement names the approvers the chain holds from current members and carries the
##      call; a refused Execute — included, not Executed — is failed, never pending;
##   5. the room path on the model: propose on chain, a member's vote, settle — and a vote
##      the chain included and refused (a member removed on chain since the room's
##      disclosure) is reported refused, not left unconfirmed.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils, os]
import stint
import ../src/hashing/sha256
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                # toHex / hexToBytes
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/intent_events
import ../src/coordination/intents
import ../src/coordination/session
import ../src/coordination/live
import ../src/coordination/vote
import ../src/coordination/accounts
import ../src/coordination/authorship
import ./probes/live_room

proc encOf(ks: Keystore): string =
  ## a member's encryption identity, hex: what an author-bearing event of theirs names
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let v = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-multisig-v030" / "vectors.json"))
proc hb(k: string): seq[byte] = hexToBytes(v[k].getStr())

# ── 1. the vectors ─────────────────────────────────────────────────────────────
let P = hb("program")
let CK = hb("create_key")
let (A, B, C) = (hexToBytes(v["members"][0].getStr()), hexToBytes(v["members"][1].getStr()),
                 hexToBytes(v["members"][2].getStr()))
let R = hb("recipient")
let zero = newSeq[byte](32)
doAssert statePda(psLee02, P, CK) == hexToBytes(v["pdas"]["state"].getStr())
doAssert proposalPda(psLee02, P, CK, 1) == hexToBytes(v["pdas"]["proposal1"].getStr())
doAssert proposalPda(psLee02, P, CK, 2) == hexToBytes(v["pdas"]["proposal2"].getStr())
let vault = vaultPda(psLee02, P, CK)
doAssert vault == hexToBytes(v["pdas"]["vault"].getStr())
doAssert vaultSeed(CK) == hb("vault_seed")
doAssert nativeTransfer(100.stuint(128)) == hb("transfer_instruction")
let call = lezCallV03(NativeTokenProgram, @[(vault, zero), (R, zero)], nativeTransfer(100.stuint(128)), @[vaultSeed(CK)])
let st = MultisigState(createKey: CK, threshold: 2, members: @[A, B, C], transactionIndex: 1)
doAssert encodeState(st) == hb("state")
doAssert decodeState(hb("state")) == st
let callProp = Proposal(index: 1, proposer: A, createKey: CK, action: call, approved: @[A, B], rejected: @[C],
                        status: psActive)
doAssert encodeProposal(callProp, plV03) == hb("call_proposal")
let back = decodeProposal(hb("call_proposal"), plV03)
doAssert back.action.target == call.target and back.action.shards == call.shards and back.action.data == call.data and
         back.action.pdaSeeds == call.pdaSeeds and back.approved == @[A, B] and back.rejected == @[C] and
         back.status == psActive and not back.hasConfig
let three = ConfigAction(kind: caChangeThreshold, threshold: 3)
let cfgProp = Proposal(index: 2, proposer: B, createKey: CK, action: LezAction(target: zero), approved: @[B],
                       status: psExecuted, hasConfig: true, config: three)
doAssert encodeProposal(cfgProp, plV03) == hb("config_proposal")
let cback = decodeProposal(hb("config_proposal"), plV03)
doAssert cback.hasConfig and cback.config == three and cback.status == psExecuted
proc ins(k: string): seq[byte] = hexToBytes(v["instructions"][k].getStr())
doAssert instructionBorsh(createOp(CK, 2, @[A, B, C])) == ins("create")
doAssert instructionBorsh(proposeOp(CK, 1, call)) == ins("propose")
doAssert instructionBorsh(proposeConfigOp(CK, 2, three)) == ins("propose-config")
doAssert instructionBorsh(proposeConfigOp(CK, 3, ConfigAction(kind: caAddMember, member: R))) == ins("propose-config-add")
doAssert instructionBorsh(proposeConfigOp(CK, 4, ConfigAction(kind: caRemoveMember, member: C))) == ins("propose-config-remove")
doAssert instructionBorsh(approveOp(CK, 1)) == ins("approve")
doAssert instructionBorsh(rejectOp(CK, 1)) == ins("reject")
doAssert instructionBorsh(executeOpV03(CK, 1, @[A, B], call)) == ins("execute")
doAssert instructionBorsh(executeConfigOp(CK, 2, @[A, B], three)) == ins("execute-config")
let rows = opShards(psLee02, P, executeOpV03(CK, 1, @[A, B], call), A)
doAssert rows.mapIt(it.account) == @[statePda(psLee02, P, CK), proposalPda(psLee02, P, CK, 1), vault, R]
doAssert rows.mapIt(it.program) == @[P, P, zero, zero], "the state and proposal select the program's shard, the call's own rows theirs"
echo "1. the PDAs, the state, both proposals and every instruction match the port's own bytes OK"

# ── 2. the port's rules, and v0.3's rule for a refusal ───────────────────────────
proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
let program = id32("lez-multisig-v030-program")
let ck = id32("room-treasury-v030")
let (mA, mB, mC, outsider, to) = (id32("m-alice"), id32("m-bob"), id32("m-carol"), id32("m-dave"), id32("to"))
const Fee = 10'u64
let f = newFakeLezMultisig("lez:local", psLee02, program, feePerTx = Fee, layout = plV03)
for m in [mA, mB, mC, outsider]: f.fund(m, 1_000)
let fv = vaultPda(psLee02, program, ck)
f.fund(fv, 1_000)
proc transfer(amount: uint64, dst = to): LezAction =
  lezCallV03(NativeTokenProgram, @[(fv, zero), (dst, zero)], nativeTransfer(amount.stuint(128)), @[vaultSeed(ck)])
proc took(t: LezTx): bool = t.ok and f.lastRefusal.len == 0
proc refusedWith(t: LezTx, why: string): bool = t.ok and why in f.lastRefusal
doAssert f.submit(mA, createOp(ck, 2, @[mA, mB, mC])).took
doAssert f.readState(ck).state.members == @[mA, mB, mC]
doAssert f.submit(mA, proposeOp(ck, 1, transfer(100))).took
let dBefore = f.balanceOf(outsider)
let dNonce = f.readAccount(outsider).nonce
let outsiderVote = f.submit(outsider, approveOp(ck, 1))
doAssert outsiderVote.refusedWith("not a member"), f.lastRefusal
doAssert f.txIncluded(outsiderVote.hash).known, "a refusal is included on v0.3"
doAssert f.balanceOf(outsider) == dBefore - Fee and f.readAccount(outsider).nonce == dNonce + 1.stuint(128),
  "and pays its fee and burns its nonce"
doAssert f.readProposal(ck, 1).proposal.approved == @[mA], "and changes nothing else"
doAssert f.submit(mB, approveOp(ck, 1)).took
doAssert f.submit(mB, approveOp(ck, 1)).refusedWith("already approved")
doAssert f.submit(mA, executeOpV03(ck, 1, @[mA], transfer(100))).refusedWith("fewer approvers than the threshold")
doAssert f.submit(mA, executeOpV03(ck, 1, @[mA, mB], transfer(100, outsider))).refusedWith("not the call this proposal commits to")
doAssert f.submit(mA, executeOpV03(ck, 1, @[mA, mC], transfer(100))).refusedWith("did not approve")
doAssert (f.balanceOf(fv), f.balanceOf(to)) == (1_000'u64, 0'u64), "nothing moved"
doAssert f.submit(mA, executeOpV03(ck, 1, @[mA, mB], transfer(100))).took
doAssert (f.balanceOf(fv), f.balanceOf(to)) == (900'u64, 100'u64)
doAssert f.readProposal(ck, 1).proposal.status == psExecuted
doAssert f.submit(mA, executeOpV03(ck, 1, @[mA, mB], transfer(100))).refusedWith("no longer active")
doAssert f.balanceOf(fv) == 900, "once only"
let ck2 = id32("daves-own")
doAssert f.submit(outsider, createOp(ck2, 1, @[outsider])).took
doAssert f.submit(outsider, proposeOp(ck2, 1, transfer(900))).refusedWith("own multisig's vault"),
  "another multisig naming this vault's seed"
# a member removed since: their approval no longer counts
doAssert f.submit(mA, proposeOp(ck, 2, transfer(50))).took
doAssert f.submit(mC, approveOp(ck, 2)).took
doAssert f.readProposal(ck, 2).proposal.approved == @[mA, mC]
let removeC = ConfigAction(kind: caRemoveMember, member: mC)
doAssert f.submit(mB, proposeConfigOp(ck, 3, removeC)).took
doAssert f.submit(mA, approveOp(ck, 3)).took
doAssert f.submit(mA, executeConfigOp(ck, 3, @[mB, mA], removeC)).took
doAssert f.readState(ck).state.members == @[mA, mB]
doAssert f.submit(mA, executeOpV03(ck, 2, @[mA, mC], transfer(50))).refusedWith("not a current member")
doAssert f.balanceOf(fv) == 900
echo "2. the port's rules on the model; every refusal included, paid for, nothing else changed; ",
     "a removed member's approval not counted OK"

# ── 3. the driver: the v2 effect, S5 ─────────────────────────────────────────────
let cfg = $(%*{"program": toHex(program), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
let (aok, acct, adetail) = lezMultisigAccountFromParts("lez:local", toHex(statePda(psLee02, program, ck)), cfg,
                                                       @[mA, mB].mapIt(toHex(it)), 2)
doAssert aok and acct.layout == plV03, adetail
let d = newLezMultisigDriver(acct)
let e2 = effectFromJson(lezProposalEffect(2, transfer(50), plV03))
doAssert e2.schemaId == "muster.effect.lez-multisig-proposal.v2"
doAssert d.signRefusal(e2) == "", d.signRefusal(e2)
doAssert "another build" in d.signRefusal(effectFromJson(lezProposalEffect(2, LezAction(target: NativeTokenProgram,
  instruction: @[1'u32], accounts: @[fv, to], pdaSeeds: @[vaultSeed(ck)])))), "a v1 effect for a v0.3 account"
doAssert d.canonicalize(e2).bytes == d.canonicalize(effectFromJson(lezProposalEffect(2, transfer(50), plV03))).bytes
doAssert d.canonicalize(e2).bytes != d.canonicalize(effectFromJson(lezProposalEffect(2, transfer(51), plV03))).bytes
let onChain2 = f.readAccount(proposalPda(psLee02, program, ck, 2)).data
doAssert d.checkRead(e2, "proposal", onChain2) == ""
doAssert "different accounts" in d.checkRead(effectFromJson(lezProposalEffect(2, transfer(50, outsider), plV03)),
                                             "proposal", onChain2)
doAssert "different instruction" in d.checkRead(effectFromJson(lezProposalEffect(2, transfer(49), plV03)),
                                                "proposal", onChain2)
doAssert "no longer open" in d.checkRead(effectFromJson(lezProposalEffect(1, transfer(100), plV03)), "proposal",
                                         f.readAccount(proposalPda(psLee02, program, ck, 1)).data)
doAssert d.profile().bypasses.len == 0, "the call's rows are committed: no #40"
echo "3. the v2 effect commits the whole call; S5 refuses other accounts, another instruction, a closed proposal OK"

# ── 4. settlement ───────────────────────────────────────────────────────────────
doAssert f.submit(mA, proposeOp(ck, 4, transfer(70))).took
doAssert f.submit(mB, approveOp(ck, 4)).took
let stl = settlementFor(d, f, Account(chain: "lez:local", form: afPublic, id: toHex(mA)))
let e4 = effectFromJson(lezProposalEffect(4, transfer(70), plV03))
let asm4 = stl.assemble(d, e4, @[])
doAssert asm4.ok and asm4.have == 2 and asm4.need == 2, asm4.error & " " & asm4.detail
let pay = parseJson(asm4.tx.payload)
doAssert pay["lez"].getStr() == "v0.3" and pay["approvers"].getElems().mapIt(it.getStr()) == @[toHex(mA), toHex(mB)]
doAssert stl.watch(stl.submit(asm4.tx, aliceKs)).status == fsFinal
doAssert f.balanceOf(to) == 170
# a refused Execute (fewer approvers than k) is included and not Executed: failed, never pending
doAssert f.submit(mA, proposeOp(ck, 5, transfer(5))).took
var short = asm4.tx
let sp = parseJson(short.payload)
sp["index"] = %5
sp["approvers"] = %[toHex(mA)]
sp["call"]["data"] = %toHex(nativeTransfer(5.stuint(128)))
sp["proposal"] = %toHex(proposalPda(psLee02, program, ck, 5))
short.payload = $sp
let w = stl.watch(stl.submit(short, aliceKs))
doAssert w.status == fsFailed and "refused" in w.detail, $w.status & " " & w.detail
echo "4. settlement names the approvals the chain holds and carries the call; a refused Execute is failed OK"

# ── 5. the room path on the model ─────────────────────────────────────────────────
let ck3 = id32("room-v030")
let rf = newFakeLezMultisig("lez:local", psLee02, program, feePerTx = Fee, layout = plV03)
for m in [mA, mB, mC]: rf.fund(m, 1_000)
let rv = vaultPda(psLee02, program, ck3)
rf.fund(rv, 500)
doAssert rf.submit(mA, createOp(ck3, 2, @[mA, mB, mC])).ok and rf.lastRefusal == ""
let cfg3 = $(%*{"program": toHex(program), "createKey": toHex(ck3), "pda": "lee-v0.2", "layout": "v0.3"})
var r = newRoom3("/muster/1/lez-multisig-v030/proto")
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: "lez:local",
  address: toHex(statePda(psLee02, program, ck3)), label: "Treasury", signers: @[mA, mB, mC].mapIt(toHex(it)),
  threshold: 2, config: cfg3), encOf(aliceKs)))
r.bob.poll()
r.carol.poll()
let racct = reduceAccounts(r.alice.roomEvents())[0]
doAssert checkAccount(racct, lezChainView(rf, racct)).status == acVerified
let resolve = proc(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.roomEvents()), proc(k: string): Driver = liveDriverFor(k))
let (resA, resB, resC) = (resolve(r.alice), resolve(r.bob), resolve(r.carol))
let policy = qualify("lez-multisig", racct.id)
let pay3 = lezCallV03(NativeTokenProgram, @[(rv, zero), (to, zero)], nativeTransfer(200.stuint(128)), @[vaultSeed(ck3)])
let id = liveProposeOnChain(r.alice, aliceKs, resA, policy, pay3, newLezVoteSeam(rf, mA), int64(Now), 1, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
# on chain, outside the room, Carol is removed (the room's disclosure still lists her)
let dropC = ConfigAction(kind: caRemoveMember, member: mC)
doAssert rf.submit(mB, proposeConfigOp(ck3, 2, dropC)).ok and rf.lastRefusal == ""
doAssert rf.submit(mA, approveOp(ck3, 2)).ok and rf.lastRefusal == ""
doAssert rf.submit(mA, executeConfigOp(ck3, 2, @[mA, mB], dropC)).ok and rf.lastRefusal == ""
r.carol.poll()
let carolFee = rf.balanceOf(mC)
let carolVote = liveVote(r.carol, room3CarolKs, resC, id, newLezVoteSeam(rf, mC), bindCtx(), Now)
doAssert carolVote.startsWith("refused") and "included" in carolVote, carolVote
doAssert rf.balanceOf(mC) == carolFee - Fee, "the refused vote was included and paid for"
doAssert rf.readProposal(ck3, 1).proposal.approved == @[mA], "and counted for nothing"
r.bob.poll()
doAssert liveVote(r.bob, bobKs, resB, id, newLezVoteSeam(rf, mB), bindCtx(), Now) == "executable"
let rdrv = LezMultisigDriver(resA(policy))
let rstl = settlementFor(rdrv, rf, Account(chain: "lez:local", form: afPublic, id: toHex(mA)))
r.alice.poll()
let rasm = rstl.assemble(rdrv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
doAssert rasm.ok, rasm.error & " " & rasm.detail
doAssert rstl.watch(rstl.submit(rasm.tx, aliceKs)).status == fsFinal
doAssert rf.balanceOf(to) == 200 and rf.balanceOf(rv) == 300
echo "5. the room on the model: proposed on chain; a removed member's vote included, paid and reported refused; ",
     "Bob's vote counted; settled — the vault paid 200 OK"

echo "lez_multisig_v030_test: muster on the LEZ multisig's v0.3 port — all OK"
