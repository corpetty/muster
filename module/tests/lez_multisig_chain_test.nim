## The LEZ multisig chain seam and its in-process model (exo-946, Phase C2): what muster
## needs from a chain running logos-co/lez-multisig — read an account (borsh bytes at a
## height), submit a MEMBER's transaction (their LEZ wallet signs; muster never does), know
## whether a transaction landed — and FakeLezMultisig, which reproduces the program's
## handlers (multisig_program/src/*.rs @ c45100b) so every path runs without a sequencer:
##   1. create: the fresh member accounts are claimed by the program; a used account, an
##      empty member list, a threshold of 0 or above n, and more than 10 members are refused
##      with the program's own reasons; the state is readable (borsh) at a height;
##   2. propose: a member proposes the NEXT index and auto-approves; a non-member, a stale
##      or skipped index are refused; the proposal PDA holds the action;
##   3. approve / reject: one vote per member, a vote flips, rejections that make k
##      unreachable kill the proposal, a vote on a dead or executed proposal is refused;
##   4. execute: below k refused; at k the proposal is Executed and the target program gets
##      a ChainedCall with the proposal's instruction and the executor's accounts (the
##      authorized ones marked); the wrong number of accounts is refused; config proposals
##      change the membership / threshold in place, within the program's limits;
##   5. fees and atomicity: every accepted transaction charges its payer; a refused one
##      changes nothing and charges nothing; a payer that cannot cover the fee is refused;
##   6. the ChainAdapter face (what the settlement seam holds): describe names the chain,
##      a prepared Execute submits from the relayer, finality reads the transaction.
## Pure Nim + libsodium-free (sha256 only), with the wallet types.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ./probes/live_room

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
proc hx(b: seq[byte]): string = (for x in b: result.add toLowerAscii(toHex(x, 2)))
let program = id32("program")
let K = id32("create-key")
let (A, B, C, D) = (id32("a"), id32("b"), id32("c"), id32("d"))
let pay = id32("payer")

proc newChain(): FakeLezMultisig =
  result = newFakeLezMultisig("lez:local", psLee02, program, feePerTx = 1)
  result.fund(pay, 100)

proc refusedWith(t: LezTx, why: string): bool = not t.ok and why in t.error

# ── 1. create ──────────────────────────────────────────────────────────────────
block:
  let c = newChain()
  let h0 = c.height()
  let t = c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay)
  doAssert t.ok and t.hash.len == 64 and t.height == h0 + 1, $t
  let st = c.readState(K)
  doAssert st.found and st.state.threshold == 2 and st.state.members == @[A, B, C] and st.height == t.height
  for m in [A, B, C]:
    doAssert c.readAccount(m).owner == program, "each member account is claimed by the program"
  doAssert c.submit(D, createOp(id32("k2"), 1, @[D, A]), payer = pay).refusedWith("must be uninitialized"),
    "a member account already used is not fresh"
  doAssert c.submit(D, createOp(id32("k3"), 1, @[]), payer = pay).refusedWith("at least one member")
  doAssert c.submit(D, createOp(id32("k4"), 0, @[D]), payer = pay).refusedWith("at least 1")
  doAssert c.submit(D, createOp(id32("k5"), 2, @[D]), payer = pay).refusedWith("cannot exceed member count")
  var eleven: seq[seq[byte]]
  for i in 0 ..< 11: eleven.add id32("m" & $i)
  doAssert c.submit(D, createOp(id32("k6"), 2, eleven), payer = pay).refusedWith("Maximum 10 members")
  doAssert c.submit(A, createOp(K, 1, @[D]), payer = pay).refusedWith("already exists"), "one multisig per create_key"
  echo "1. create: fresh members claimed; used accounts, bad thresholds, >10 members refused OK"

# ── 2. propose ─────────────────────────────────────────────────────────────────
let act = LezAction(target: id32("token"), instruction: @[7'u32, 8], accounts: @[id32("x"), id32("y")],
                    pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])
block:
  let c = newChain()
  doAssert c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
  doAssert c.submit(D, proposeOp(K, 1, act), payer = pay).refusedWith("not a multisig member")
  doAssert c.submit(A, proposeOp(K, 2, act), payer = pay).refusedWith("next"), "an index that skips ahead"
  doAssert c.submit(A, proposeOp(K, 1, act), payer = pay).ok
  doAssert c.submit(B, proposeOp(K, 1, act), payer = pay).refusedWith("next"), "a stale index"
  let p = c.readProposal(K, 1)
  doAssert p.found and p.proposal.index == 1 and p.proposal.proposer == A and p.proposal.approved == @[A]
  doAssert p.proposal.action.target == act.target and p.proposal.action.instruction == act.instruction
  doAssert p.proposal.action.accountCount == 2 and p.proposal.action.pdaSeeds == act.pdaSeeds
  doAssert c.readAccount(proposalPda(psLee02, program, K, 1)).found, "the proposal lives at its PDA"
  doAssert c.readState(K).state.transactionIndex == 1
  doAssert not c.readProposal(K, 2).found
  echo "2. propose: a member proposes the next index and auto-approves; the PDA holds the action OK"

# ── 3. approve / reject ────────────────────────────────────────────────────────
block:
  let c = newChain()
  doAssert c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
  doAssert c.submit(A, proposeOp(K, 1, act), payer = pay).ok
  doAssert c.submit(A, approveOp(K, 1), payer = pay).refusedWith("already approved")
  doAssert c.submit(D, approveOp(K, 1), payer = pay).refusedWith("not a multisig member")
  doAssert c.submit(B, rejectOp(K, 1), payer = pay).ok
  doAssert c.submit(B, approveOp(K, 1), payer = pay).ok
  let p = c.readProposal(K, 1).proposal
  doAssert p.approved == @[A, B] and p.rejected.len == 0, "a vote flips"
  doAssert c.submit(A, proposeOp(K, 2, act), payer = pay).ok
  doAssert c.submit(B, rejectOp(K, 2), payer = pay).ok
  doAssert c.readProposal(K, 2).proposal.status == psActive
  doAssert c.submit(C, rejectOp(K, 2), payer = pay).ok
  doAssert c.readProposal(K, 2).proposal.status == psRejected, "2 rejections of 3 make 2 unreachable"
  doAssert c.submit(A, approveOp(K, 2), payer = pay).refusedWith("not active")
  echo "3. approve / reject: one vote each, votes flip, dead proposals are rejected and closed OK"

# ── 4. execute ─────────────────────────────────────────────────────────────────
block:
  let c = newChain()
  doAssert c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
  doAssert c.submit(A, proposeOp(K, 1, act), payer = pay).ok
  doAssert c.submit(A, executeOp(K, 1, act.accounts), payer = pay).refusedWith("threshold")
  doAssert c.submit(B, approveOp(K, 1), payer = pay).ok
  doAssert c.submit(B, executeOp(K, 1, @[act.accounts[0]]), payer = pay).refusedWith("target accounts")
  doAssert c.submit(D, executeOp(K, 1, act.accounts), payer = pay).refusedWith("not a multisig member")
  doAssert c.submit(B, executeOp(K, 1, act.accounts), payer = pay).ok
  doAssert c.readProposal(K, 1).proposal.status == psExecuted
  let call = c.chainedCalls[^1]
  doAssert call.program == act.target and call.instruction == act.instruction and call.accounts == act.accounts
  doAssert call.authorized == @[0'u8] and call.pdaSeeds == act.pdaSeeds
  doAssert c.submit(B, executeOp(K, 1, act.accounts), payer = pay).refusedWith("not active"), "once"
  # config proposals
  doAssert c.submit(A, proposeConfigOp(K, 2, ConfigAction(kind: caAddMember, member: D)), payer = pay).ok
  doAssert c.submit(C, approveOp(K, 2), payer = pay).ok
  doAssert c.submit(C, executeOp(K, 2, @[]), payer = pay).ok
  doAssert c.readState(K).state.members == @[A, B, C, D], "added in place — the address stays"
  # the program checks a new threshold only against 1 when proposed; against n at execute
  doAssert c.submit(D, proposeConfigOp(K, 3, ConfigAction(kind: caChangeThreshold, threshold: 5)), payer = pay).ok
  doAssert c.submit(A, approveOp(K, 3), payer = pay).ok
  doAssert c.submit(A, executeOp(K, 3, @[]), payer = pay).refusedWith("cannot exceed member count")
  doAssert c.readProposal(K, 3).proposal.status == psActive and c.readState(K).state.threshold == 2
  doAssert c.submit(D, proposeConfigOp(K, 4, ConfigAction(kind: caChangeThreshold, threshold: 4)), payer = pay).ok
  doAssert c.submit(A, approveOp(K, 4), payer = pay).ok
  doAssert c.submit(A, executeOp(K, 4, @[]), payer = pay).ok
  doAssert c.readState(K).state.threshold == 4
  doAssert c.submit(A, proposeConfigOp(K, 5, ConfigAction(kind: caRemoveMember, member: D)), payer = pay).ok
  for m in [B, C, D]: doAssert c.submit(m, approveOp(K, 5), payer = pay).ok
  doAssert c.submit(A, executeOp(K, 5, @[]), payer = pay).refusedWith("less than threshold"),
    "removing a member may not leave fewer members than k"
  echo "4. execute: at k only, once, the target gets the call; config changes in place within limits OK"

# ── 5. fees and atomicity ──────────────────────────────────────────────────────
block:
  let c = newChain()
  let before = c.balanceOf(pay)
  doAssert c.submit(A, createOp(K, 2, @[A, B, C]), payer = pay).ok
  doAssert c.balanceOf(pay) == before - 1, "an accepted transaction charges its payer"
  let h = c.height()
  let stateBytes = c.readAccount(statePda(psLee02, program, K)).data
  doAssert not c.submit(D, proposeOp(K, 1, act), payer = pay).ok
  doAssert c.balanceOf(pay) == before - 1 and c.height() == h, "a refused one charges nothing and lands nowhere"
  doAssert c.readAccount(statePda(psLee02, program, K)).data == stateBytes, "and changes nothing"
  let broke = id32("broke")
  doAssert c.submit(A, proposeOp(K, 1, act), payer = broke).refusedWith("fee")
  doAssert c.readState(K).state.transactionIndex == 0
  echo "5. fees: accepted transactions charge the payer; refused ones change and charge nothing OK"

# ── 6. the ChainAdapter face ───────────────────────────────────────────────────
block:
  let c = newChain()
  doAssert c.describe().chain == "lez:local"
  doAssert c.submit(A, createOp(K, 1, @[A, B]), payer = pay).ok
  doAssert c.submit(A, proposeOp(K, 1, act), payer = pay).ok
  let prepared = PreparedTx(chain: "lez:local", frm: Account(chain: "lez:local", form: afPublic, id: hx(A) & ":" & hx(pay)),
                            payload: $(%*{"op": "execute", "createKey": hx(K), "index": 1,
                                          "accounts": act.accounts.mapIt(hx(it))}))
  let r = ChainAdapter(c).submit(prepared, aliceKs)
  doAssert r.id.len == 64 and ChainAdapter(c).finality(r).status == fsFinal
  doAssert c.readProposal(K, 1).proposal.status == psExecuted
  doAssert ChainAdapter(c).finality(TxRef(chain: "lez:local", id: repeat("0", 64))).status == fsFailed, "unknown: never final"
  var raised = false
  try: discard ChainAdapter(c).submit(prepared, aliceKs)
  except WalletError: raised = true
  doAssert raised, "a refused settlement raises — never a false landed"
  echo "6. the ChainAdapter face: a prepared Execute from the relayer; finality read from the chain OK"

echo "lez_multisig_chain_test: the chain seam and the program model — all OK"
