## The LEZ multisig, live (exo-3c9): the room drives the program deployed on a REAL LEZ
## v0.2.4 sequencer (infra/lez/localnet.sh, or the public testnet), through
## wallet/lez_multisig_live.nim. The chain is the arbiter; no model stands in anywhere.
##   1. the program is there (deploying it first when MUSTER_LEZ_MULTISIG_BIN names the guest
##      binary); three members each derive a FRESH LEZ account in their own keystore;
##   2. a 2-of-3 is created on chain; muster reads the state back at the PDA it derives;
##   3. a token (MusterTest) is minted to a holding muster signs for;
##   4. in the room: Alice discloses the multisig and proposes #1, "initialize the vault's
##      token holding" — her own Propose transaction puts it on chain. Bob re-reads the
##      proposal from the chain (S5), casts his own Approve transaction, and it is
##      confirmed back; the settlement seam counts the votes ON CHAIN and Executes — final
##      when the chain says Executed, and the vault now belongs to the token program;
##   5. the vault is funded (500);
##   6. #2 transfers 200 from the vault to Carol's holding. Before the room settles it,
##      Bob tries to Execute with a substituted recipient: the program refuses it on chain
##      (the transaction is never included) and nothing moves. Then the room settles #2 —
##      the vault holds 300 and Carol 200.
## Usage: lez_multisig_live_e2e [sequencerUrl] [blockSeconds]
##   defaults http://127.0.0.1:3040 and 15 (the local standalone config); the public
##   testnet is https://testnet.lez.logos.co with ~40.
## Env: MUSTER_LEZ_MULTISIG_BIN — deploy this guest binary first (optional; the program id
##   is the ImageID below, which the pinned build reproduces).
## Needs the web3 closure (chronos, json-rpc, bearssl) + libsodium — see tests/README.md.

import std/[os, json, strutils, sequtils, random, times]
import stint
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/wallet/types
import ../src/wallet/lez_multisig_live
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, vote, accounts]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
const Chain = "lez:local"
const ImageId = "2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7"
let program = hexToBytes(ImageId)
let vectors = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-tx-v024" / "vectors.json"))
proc words(n: JsonNode): seq[uint32] = n.getElems().mapIt(uint32(it.getBiggestInt()))
let tokenProgram = hexToBytes("ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b")

proc seed32(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

randomize()
let run = toHex(@[byte(rand(255)), byte(rand(255)), byte(rand(255)), byte(rand(255))]) & $getTime().toUnix()
let carolKs = newInMemoryKeystore(seed32(3), seed32(4))
proc chainFor(ks: Keystore): LezMultisigLive =
  newLezMultisigLive(newLezRpc(url), ks, Chain, psLee02, program, plAccountIds, blockMs = blockSec * 1000)
let (ca, cb, cc) = (chainFor(aliceKs), chainFor(bobKs), chainFor(carolKs))

proc tokenBalance(c: LezMultisigLive, id: seq[byte]): uint64 =
  ## TokenHolding::Fungible { definition_id: [u8; 32], balance: u128 } — borsh.
  let r = c.readAccount(id)
  doAssert r.found and r.owner == tokenProgram and r.data.len == 49 and r.data[0] == 0, "not a fungible holding"
  for i in countdown(40, 33): result = (result shl 8) or uint64(r.data[i])

# ── 1. the program, and three fresh members ───────────────────────────────────
let bin = getEnv("MUSTER_LEZ_MULTISIG_BIN")
if bin.len > 0:
  let d = ca.deploy(cast[seq[byte]](readFile(bin)))
  echo "   deploy: ", (if d.ok: "included at " & $d.height else: "not included (already deployed?)")
let m1 = ca.addMember("e2e/" & run & "/alice")
let m2 = cb.addMember("e2e/" & run & "/bob")
let m3 = cc.addMember("e2e/" & run & "/carol")
doAssert m1 == publicAccountId(aliceKs.lezMemberKey("e2e/" & run & "/alice"))
doAssert not ca.readAccount(m1).found and not ca.readAccount(m2).found, "fresh accounts"
echo "1. ", url, " at height ", ca.height(), "; three fresh member accounts, keys in their own keystores OK"

# ── 2. create ─────────────────────────────────────────────────────────────────
var ck = newSeq[byte](32)
for i in 0 ..< 32: ck[i] = byte(rand(255))
let created = ca.submit(@[], createOp(ck, 2, @[m1, m2, m3]))
doAssert created.ok, created.error
let (found, st, _) = ca.readState(ck)
doAssert found and st.threshold == 2 and st.members == @[m1, m2, m3] and st.transactionIndex == 0
# The program asserts the members are fresh at create. On the SPEL v0.7.0 rebuild it does
# NOT claim them (its doc comment says it does): the chain shows them still unowned.
doAssert ca.readAccount(m1).owner.len == 0, "the rebuild leaves member accounts unowned"
echo "2. a 2-of-3 on chain (tx ", created.hash[0 .. 11], "…, height ", created.height, "); state read back at its PDA OK"

# ── 3. a token to move ────────────────────────────────────────────────────────
let def = ca.addMember("e2e/" & run & "/token-def")
let holding = ca.addMember("e2e/" & run & "/token-holding")
let minted = ca.sendSigned(tokenProgram, @[def, holding], @[def, holding],
                           words(vectors["token"]["new_fungible_definition_muster_test_1000000"]))
doAssert minted.ok, minted.error
doAssert ca.tokenBalance(holding) == 1_000_000
echo "3. MusterTest minted: 1,000,000 to a holding muster signs for OK"

# ── 4. the room: propose, vote, settle #1 (initialize the vault) ──────────────
let vault = vaultPda(psLee02, program, ck)
let cfg = $(%*{"program": ImageId, "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "account-ids"})
var r = newRoom("/muster/1/lez-live/" & run)
r.alice.publish(accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: Chain,
  address: toHex(statePda(psLee02, program, ck)), label: "live", signers: @[m1, m2, m3].mapIt(toHex(it)),
  threshold: 2, config: cfg), "alice"))
r.bob.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
let policy = qualify("lez-multisig", reduceAccounts(r.alice.log.allEvents())[0].id)
let initVault = LezAction(target: tokenProgram, instruction: words(vectors["token"]["initialize_account"]),
                          accounts: @[def, vault], pdaSeeds: @[vaultSeed(ck)], authorized: @[1'u8])
let id1 = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, initVault, newLezVoteSeam(ca, m1),
                             int64(Now), 1, ttlSec = Ttl)
doAssert id1.startsWith("0x"), id1
r.bob.poll()
doAssert liveVote(r.bob, bobKs, res(r.bob), id1, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
let drv = res(r.alice)(policy)
proc settle(effectJson: string) =
  let stl = settlementFor(drv, ca, Account(chain: Chain, form: afPublic, id: toHex(m1)))
  let asm0 = stl.assemble(drv, effectFromJson(effectJson), @[])
  doAssert asm0.ok and asm0.have == 2 and asm0.need == 2, asm0.error & " " & asm0.detail
  doAssert stl.watch(stl.submit(asm0.tx, aliceKs)).status == fsFinal
settle(lezProposalEffect(1, initVault))
doAssert ca.readAccount(vault).owner == tokenProgram, "the vault is a token holding now"
echo "4. in the room: #1 proposed on chain, Bob's own vote after an S5 re-read, settled on the chain's count — Executed OK"

# ── 5. fund the vault ─────────────────────────────────────────────────────────
let funded = ca.sendSigned(tokenProgram, @[holding, vault], @[holding], words(vectors["token"]["transfer_500"]))
doAssert funded.ok, funded.error
doAssert ca.tokenBalance(vault) == 500
echo "5. the vault holds 500 OK"

# ── 6. #2: a transfer; a substituted recipient refused on chain; then settled ─
let carol = cc.addMember("e2e/" & run & "/carol-holding")
doAssert cc.sendSigned(tokenProgram, @[def, carol], @[carol], words(vectors["token"]["initialize_account"])).ok
let pay = LezAction(target: tokenProgram, instruction: words(vectors["token"]["transfer_200"]),
                    accounts: @[vault, carol], pdaSeeds: @[vaultSeed(ck)], authorized: @[0'u8])
let id2 = liveProposeOnChain(r.alice, aliceKs, res(r.alice), policy, pay, newLezVoteSeam(ca, m1),
                             int64(Now), 2, ttlSec = Ttl)
doAssert id2.startsWith("0x"), id2
r.bob.poll()
doAssert liveVote(r.bob, bobKs, res(r.bob), id2, newLezVoteSeam(cb, m2), bindCtx(), Now) == "executable"
let thief = cb.addMember("e2e/" & run & "/thief")
doAssert cb.sendSigned(tokenProgram, @[def, thief], @[thief], words(vectors["token"]["initialize_account"])).ok
let swapped = cb.submit(m2, executeOp(ck, 2, @[vault, thief]))
doAssert not swapped.ok, "the program must refuse a substituted recipient"
doAssert ca.tokenBalance(vault) == 500 and ca.tokenBalance(thief) == 0
doAssert decodeProposal(ca.readAccount(proposalPda(psLee02, program, ck, 2)).data, plAccountIds).status == psActive
settle(lezProposalEffect(2, pay))
doAssert ca.tokenBalance(vault) == 300 and ca.tokenBalance(carol) == 200
echo "6. #2: a substituted recipient refused ON CHAIN (never included); settled — vault 300, Carol 200 OK"

echo "lez_multisig_live_e2e: the room drove the LEZ multisig on a real v0.2.4 chain — all OK"
