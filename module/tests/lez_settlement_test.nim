## LEZ multisig settlement (exo-0c9, Phase C5): the settlement seam for the vote locus.
## Nothing is assembled from signatures: the program already holds the votes, so settling
## is counting them ON CHAIN and asking the program to Execute.
##   1. dispatch by profile: lez.multisig-program gets the LEZ multisig settlement; it
##      needs the chain seam — any other adapter cannot settle it;
##   2. assemble counts the approvals the CHAIN holds (the room's receipts are not the
##      tally), against the threshold the chain holds: below it, refused with have / need
##      from the chain — whatever the room claims;
##   3. assemble re-reads the pointer at settle (S5 again): on-chain content that differs
##      from the effect, or a proposal no longer active, is not settled;
##   4. at k it prepares an Execute with the effect's target accounts, from the relayer
##      member; submitted through the adapter, it is final only when the chain says the
##      proposal is Executed; the target program receives the call;
##   5. a relayer the program refuses (not a member) raises — never a false landed.
## Pure Nim + the wallet types.

import std/[json, strutils]
import ../src/hashing/sha256
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/bitcoin/tx                # toHex
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/settlement/settlement
import ../src/coordination/intent_events
import ./probes/live_room

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
let (A, B, C, D) = (id32("sa"), id32("sb"), id32("sc"), id32("sd"))
let pay = id32("s-payer")
let program = id32("s-program")
let K = id32("s-room")
const Chain = "lez:local"
let chain = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 1)
chain.fund(pay, 100)
doAssert chain.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
let cfg = $(%*{"program": toHex(program), "createKey": toHex(K), "pda": "lee-v0.2"})
let (ok, acct, _) = lezMultisigAccountFromParts(Chain, toHex(statePda(psLee02, program, K)), cfg,
                                                @[toHex(A), toHex(B), toHex(C)], 2)
doAssert ok
let drv = newLezMultisigDriver(acct)
let act = LezAction(target: id32("token"), instruction: @[3'u32, 77], accounts: @[id32("vault"), id32("to")],
                    pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])
doAssert chain.submit(A, proposeOp(K, 1, act), payer = pay).ok
let effect = effectFromJson(lezProposalEffect(1, act))
let relayer = Account(chain: Chain, form: afPublic, id: toHex(A) & ":" & toHex(pay))

# ── 1. dispatch ────────────────────────────────────────────────────────────────
let stl = settlementFor(drv, chain, relayer)
doAssert stl != nil and stl of LezMultisigSettlement and stl.family == LezMultisigFamily
let noSeam = settlementFor(drv, ChainAdapter(), relayer)
let r0 = noSeam.assemble(drv, effect, @[])
doAssert not r0.ok and r0.error == "not-settleable", "without the chain seam nothing is settled"
echo "1. the LEZ multisig settlement is chosen by profile and needs the chain seam OK"

# ── 2. the chain's count, not the room's ───────────────────────────────────────
let m = canonicalize(drv, effect)
let claimed = @[(contributor: "lez:" & toHex(B), bytes: voteReceipt(B, 1, repeat("0", 64), m).bytes),
                (contributor: "lez:" & toHex(C), bytes: voteReceipt(C, 1, repeat("0", 64), m).bytes)]
let low = stl.assemble(drv, effect, claimed)
doAssert not low.ok and low.error == "insufficient-approvals" and low.have == 1 and low.need == 2, $low
echo "2. receipts the chain does not hold count for nothing: have 1 of 2, from the chain OK"

# ── 3. S5 again at settle ──────────────────────────────────────────────────────
var other = act
other.instruction = @[3'u32, 78]
let mism = stl.assemble(drv, effectFromJson(lezProposalEffect(1, other)), @[])
doAssert not mism.ok and mism.error == "not-settleable" and "instruction" in mism.detail, $mism
echo "3. the pointer is re-read at settle: different content is not settled OK"

# ── 4. at k: Execute, final when the chain says Executed ──────────────────────
doAssert chain.submit(B, approveOp(K, 1), payer = pay).ok
let asm0 = stl.assemble(drv, effect, @[])
doAssert asm0.ok and asm0.have == 2 and asm0.need == 2, asm0.error & " " & asm0.detail
let pl = parseJson(asm0.tx.payload)
doAssert pl["op"].getStr() == "execute" and pl["index"].getInt() == 1 and pl["accounts"].len == 2
let txRef = stl.submit(asm0.tx, aliceKs)
doAssert stl.watch(txRef).status == fsFinal
doAssert chain.readProposal(K, 1).proposal.status == psExecuted
doAssert chain.chainedCalls[^1].program == act.target and chain.chainedCalls[^1].accounts == act.accounts
let again = stl.assemble(drv, effect, @[])
doAssert not again.ok and "executed" in again.detail, "an executed proposal is not settled twice"
echo "4. Executed from the relayer member; final when the chain says so; the target got the call OK"

# ── 5. a refused relayer raises ────────────────────────────────────────────────
doAssert chain.submit(A, proposeOp(K, 2, act), payer = pay).ok
doAssert chain.submit(C, approveOp(K, 2), payer = pay).ok
let outsider = settlementFor(drv, chain, Account(chain: Chain, form: afPublic, id: toHex(D) & ":" & toHex(pay)))
let asm2 = outsider.assemble(drv, effectFromJson(lezProposalEffect(2, act)), @[])
doAssert asm2.ok
var raised = false
try: discard outsider.submit(asm2.tx, aliceKs)
except WalletError: raised = true
doAssert raised and chain.readProposal(K, 2).proposal.status == psActive, "never a false landed"
echo "5. a relayer the program refuses raises; nothing lands OK"

echo "lez_settlement_test: settle on the chain's count, re-read at settle, final when Executed — all OK"
