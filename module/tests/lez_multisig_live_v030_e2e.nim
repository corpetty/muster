## The LEZ multisig on a REAL LEZ v0.3.0 chain (exo-eb6.4.4 L4d): the room drives the v0.3
## port (run_program(plan, apply), docs/design/lez-multisig-v03.md), deployed on
## infra/lez/localnet.sh's zone, through wallet/lez_multisig_live.nim. No model stands in.
##   1. the program is there (deployed first with `localnet.sh deploy` when
##      MUSTER_LEZ_MULTISIG_V03_BIN names the guest); three members derive LEZ accounts in
##      their own keystores, and the zone's funder sends each native LEZ — on v0.3 every
##      vote is a public transaction its member pays for;
##   2. a 2-of-3 is created: Alice's own transaction, her fee; the state is read back at the
##      PDA muster derives; the vault is funded by an ordinary transfer to its id;
##   3. in the room: Alice discloses the multisig and proposes #1, a native transfer of 200
##      from the vault to R — her own Propose puts it on chain. Bob re-reads #1 (S5), votes
##      with his own transaction (and pays for it), confirmed back; the settlement names the
##      approvals the chain holds and Executes: R holds 200, the vault 800;
##   4. #2 pays R 100. Bob tries to Execute it with a substituted recipient: on v0.3 the
##      chain INCLUDES that transaction and refuses it — Bob pays, nothing moves, #2 stays
##      active — so muster judges by the state, never by inclusion. Then the room settles
##      #2: R 300, the vault 700;
##   5. asynchronously, as the hosted surface drives it (a UI call never waits on a block):
##      Propose, Bob's vote and the Execute each return at once and complete when the chain
##      includes them. R 350, the vault 650.
## Usage: lez_multisig_live_v030_e2e [sequencerUrl] [blockSeconds] [programAccount]
##   defaults http://127.0.0.1:3040, 15, and $MUSTER_LEZ_MULTISIG_V03_PROGRAM (hex or base58).
## Env: MUSTER_LEZ_MULTISIG_V03_BIN — deploy this guest (the port's multisig.bin) first.
## Needs the web3 closure (chronos, json-rpc, bearssl) + libsodium, and the local zone up.

import std/[os, osproc, json, strutils, sequtils, random, times]
import stint
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/lez_multisig_live
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
const Chain = "lez:local"
let localnet = currentSourcePath.parentDir.parentDir.parentDir / "infra" / "lez" / "localnet.sh"

proc idOf(s: string): seq[byte] =
  let h = s.strip()
  if h.len == 64 and h.allCharsInSet(HexDigits): hexToBytes(h) else: accountIdFromBase58(h)

var programText = (if paramCount() >= 3: paramStr(3) else: getEnv("MUSTER_LEZ_MULTISIG_V03_PROGRAM"))
let bin = getEnv("MUSTER_LEZ_MULTISIG_V03_BIN")
if bin.len > 0:
  let (o, code) = execCmdEx(localnet & " deploy " & quoteShell(bin))
  doAssert code == 0, "the deploy failed: " & o
  let at = o.find("(hex ")
  doAssert at >= 0 and o.len >= at + 5 + 64, "the deploy names no program account: " & o
  programText = o[at + 5 ..< at + 5 + 64]
doAssert programText.len > 0, "name the deployed program: arg 3, MUSTER_LEZ_MULTISIG_V03_PROGRAM, or MUSTER_LEZ_MULTISIG_V03_BIN"
let program = idOf(programText)

proc fund(id: seq[byte], amount: string) =
  ## The genesis funder sends, as anyone holding native LEZ would (LEZ's own CLI).
  let (o, code) = execCmdEx(localnet & " fund " & toHex(id) & " " & amount)
  doAssert code == 0, "the funder could not send: " & o

proc seed32(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

randomize()
let run = toHex(@[byte(rand(255)), byte(rand(255)), byte(rand(255)), byte(rand(255))]) & $getTime().toUnix()
let carolKs = newInMemoryKeystore(seed32(3), seed32(4))
proc chainFor(ks: Keystore): LezMultisigLive =
  newLezMultisigLive(newLezRpc(url), ks, Chain, psLee02, program, plV03, blockMs = blockSec * 1000)
let (ca, cb, cc) = (chainFor(aliceKs), chainFor(bobKs), chainFor(carolKs))
proc native(id: seq[byte]): UInt128 = ca.rpc.getAccount(id).balance
proc waitUntil(what: string, cond: proc(): bool) =
  for _ in 0 ..< blockSec * 4:
    if cond(): return
    sleep(1000)
  doAssert false, "not within four blocks: " & what

# ── 1. the program, three funded members ──────────────────────────────────────
doAssert ca.rpc.getAccount(program).v3, "the zone runs LEZ v0.3"
let m1 = ca.addMember("e2e3/" & run & "/alice")
let m2 = cb.addMember("e2e3/" & run & "/bob")
let m3 = cc.addMember("e2e3/" & run & "/carol")
for m in [m1, m2, m3]: fund(m, "1000000000")
waitUntil("the members' funding", proc(): bool = [m1, m2, m3].allIt(native(it) == 1_000_000_000.stuint(128)))
echo "1. ", url, " (LEZ v0.3) at height ", ca.height(), "; program ", toHex(program)[0 .. 11],
     "…; three members, each funded for its own fees OK"

# ── 2. create; fund the vault ─────────────────────────────────────────────────
var ck = newSeq[byte](32)
for i in 0 ..< 32: ck[i] = byte(rand(255))
let aliceBefore = native(m1)
let created = ca.submit(m1, createOp(ck, 2, @[m1, m2, m3]))
doAssert created.ok, created.error
let (found, st, _) = ca.readState(ck)
doAssert found and st.threshold == 2 and st.members == @[m1, m2, m3] and st.transactionIndex == 0
doAssert native(m1) < aliceBefore, "Alice paid for the create"
let vault = vaultPda(psLee02, program, ck)
fund(vault, "1000")
waitUntil("the vault's funding", proc(): bool = native(vault) == 1000.stuint(128))
echo "2. a 2-of-3 on chain (Alice's own transaction, her fee ", aliceBefore - native(m1), "); the vault holds 1000 OK"

# ── 3. the room: propose, vote, settle #1 ─────────────────────────────────────
let zero = newSeq[byte](32)
let R = publicAccountId(carolKs.lezMemberKey("e2e3/" & run & "/recipient"))
proc payR(amount: uint64, to = R): LezAction =
  lezCallV03(NativeTokenProgram, @[(vault, zero), (to, zero)], nativeTransfer(amount.stuint(128)), @[vaultSeed(ck)])
let cfg = $(%*{"program": toHex(program), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
var r = newRoom("/muster/1/lez-live-v030/" & run)
r.discloseAs("alice", RoomAccount(family: LezMultisigFamily, chain: Chain,
  address: toHex(statePda(psLee02, program, ck)), label: "live v0.3", signers: @[m1, m2, m3].mapIt(toHex(it)),
  threshold: 2, config: cfg))
r.bob.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
let acct = reduceAccounts(r.alice.log.allEvents())[0]
doAssert checkAccount(acct, lezChainView(ca, acct)).status == acVerified, "the room reads the multisig off the chain"
let policy = qualify("lez-multisig", acct.id)
let id1 = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, payR(200), newLezVoteSeam(ca, m1),
                             int64(Now), 1, ttlSec = Ttl)
doAssert id1.startsWith("0x"), id1
r.bob.poll()
let bobBefore = native(m2)
doAssert liveVote(r.bob, bobKs, res(r.bob), id1, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
let voteFee = bobBefore - native(m2)
doAssert voteFee > 0.stuint(128), "Bob paid for his vote"
let drv = res(r.alice)(policy)
proc settle(effectJson: string) =
  let stl = settlementFor(drv, ca, Account(chain: Chain, form: afPublic, id: toHex(m1)))
  let asm0 = stl.assemble(drv, effectFromJson(effectJson), @[])
  doAssert asm0.ok and asm0.have == 2 and asm0.need == 2, asm0.error & " " & asm0.detail
  let w = stl.watch(stl.submit(asm0.tx, aliceKs))
  doAssert w.status == fsFinal, $w.status & " " & w.detail
settle(lezProposalEffect(1, payR(200), plV03))
doAssert native(R) == 200.stuint(128) and native(vault) == 800.stuint(128)
echo "3. in the room: #1 proposed on chain, Bob's own vote (fee ", voteFee, ") after an S5 re-read, settled — ",
     "R 200, vault 800 OK"

# ── 4. #2: a substituted recipient, included and refused; then settled ───────
let id2 = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, payR(100), newLezVoteSeam(ca, m1),
                             int64(Now), 2, ttlSec = Ttl)
doAssert id2.startsWith("0x"), id2
r.bob.poll()
doAssert liveVote(r.bob, bobKs, res(r.bob), id2, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
let thief = publicAccountId(bobKs.lezMemberKey("e2e3/" & run & "/thief"))
let bobPaid = native(m2)
let swapped = cb.submit(m2, executeOpV03(ck, 2, @[m1, m2], payR(100, thief)))
doAssert swapped.ok and cb.txIncluded(swapped.hash).known, "on v0.3 the chain includes it: " & swapped.error
doAssert native(thief) == 0.stuint(128) and native(vault) == 800.stuint(128), "and nothing moves"
doAssert native(m2) < bobPaid, "Bob paid for the refused transaction"
doAssert decodeProposal(ca.readAccount(proposalPda(psLee02, program, ck, 2)).data, plV03).status == psActive
settle(lezProposalEffect(2, payR(100), plV03))
doAssert native(R) == 300.stuint(128) and native(vault) == 700.stuint(128)
echo "4. #2: a substituted recipient INCLUDED and refused (Bob paid ", bobPaid - native(m2),
     ", nothing moved); settled — R 300, vault 700 OK"

# ── 5. asynchronously: start now, complete when the chain includes it ─────────
proc tick() = sleep(2000)
let (aa, ab) = (chainFor(aliceKs), chainFor(bobKs))
aa.waitForInclusion = false
ab.waitForInclusion = false
discard aa.addMember("e2e3/" & run & "/alice")
discard ab.addMember("e2e3/" & run & "/bob")
let (started, pp) = liveProposeOnChainStart(r.alice, aliceKs, res(r.alice), policy, payR(50), newLezVoteSeam(aa, m1),
                                            int64(Now), 3, ttlSec = Ttl)
doAssert started.len == 0 and pp.index == 3'u64, started
var id3 = liveProposeOnChainComplete(r.alice, aliceKs, res(r.alice), newLezVoteSeam(aa, m1), pp)
doAssert id3 == "pending", "nothing is published before the chain has #3: " & id3
var waited = 0
while id3 == "pending" and waited < blockSec * 2:
  tick(); inc waited
  id3 = liveProposeOnChainComplete(r.alice, aliceKs, res(r.alice), newLezVoteSeam(aa, m1), pp)
doAssert id3.startsWith("0x"), id3
r.bob.poll()
let (cast3, pv) = liveVoteCast(r.bob, bobKs, res(r.bob), id3, newLezVoteSeam(ab, m2), bindCtx(), Now)
doAssert cast3.len == 0, cast3
var voted = liveVoteComplete(r.bob, bobKs, res(r.bob), newLezVoteSeam(ab, m2), pv)
doAssert voted.startsWith("unconfirmed"), "no receipt before the chain shows the vote: " & voted
waited = 0
while voted.startsWith("unconfirmed") and waited < blockSec * 2:
  tick(); inc waited
  voted = liveVoteComplete(r.bob, bobKs, res(r.bob), newLezVoteSeam(ab, m2), pv)
doAssert voted == "executable", voted
let stl3 = settlementFor(drv, aa, Account(chain: Chain, form: afPublic, id: toHex(m1)))
let asm3 = stl3.assemble(drv, effectFromJson(lezProposalEffect(3, payR(50), plV03)), @[])
doAssert asm3.ok, asm3.error & " " & asm3.detail
let ref3 = stl3.submit(asm3.tx, aliceKs)
doAssert stl3.watch(ref3).status == fsPending, "an Execute not yet included is pending, never final"
var fin = fsPending
waited = 0
while fin == fsPending and waited < blockSec * 2:
  tick(); inc waited
  fin = stl3.watch(ref3).status
doAssert fin == fsFinal
doAssert native(R) == 350.stuint(128) and native(vault) == 650.stuint(128)
echo "5. asynchronously: Propose, vote and Execute each return at once and complete when the chain includes them — ",
     "R 350, vault 650 OK"

echo "lez_multisig_live_v030_e2e: the room drove the LEZ multisig on a real v0.3.0 chain — all OK"
