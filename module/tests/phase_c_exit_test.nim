## Phase C exit (exo-84f, epic exo-a50.3; docs/design/multisig-landscape.md §8): the LEZ
## multisig program — the VOTE locus on Logos's own chain — for a 2-of-3, against the
## in-process model of logos-co/lez-multisig (its handlers, its borsh state, its PDAs).
## The live chain is not in this test: the published program targets nssa v0.2.0-rc3,
## while lez_core speaks LEE v0.2.5 — see exo-3c9.
##   1. a member creates the multisig on chain (the fresh member accounts are claimed) and
##      discloses it into the room with its config (program, create_key); the room
##      re-derives the state PDA from the config and reads the chain — verified; a
##      disclosure naming another threshold disagrees;
##   2. proposing puts the action ON CHAIN (Propose — the proposer's own transaction,
##      which auto-approves) and points the room intent at proposal #i: the pointer plus
##      the content the room reviews; the proposer's vote is reported into the room;
##   3. a member approves IN THE ROOM: muster reads proposal #i from the chain and checks
##      it against what the room reviewed (S5) before anything is signed; the member's
##      own vote transaction goes on chain (their LEZ wallet signs, never muster; they pay
##      for it); it is confirmed by reading the chain back and the receipt counts — 2 of
##      3, executable; the approval carries a room-key attestation, graded committed;
##   4. an intent whose pointer names an on-chain proposal with DIFFERENT content is
##      refused before any vote: no transaction, no fee, nothing published;
##   5. settlement counts the approvals ON CHAIN (not the room's receipts), Executes from
##      a member's account, and the target program receives the proposal's call; final
##      when the chain says Executed — and a proposal short of k on chain is refused,
##      naming have / need from the chain;
##   6. the card says it: every approval is its own public transaction, approving costs a
##      transaction, the pointer is only as good as the read (motivational), and the chain
##      binds no network (exposed) — muster binds it in the room.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/profile
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/bitcoin/tx                # toHex / hexToBytes
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/intent_events
import ../src/coordination/intents
import ../src/coordination/session
import ../src/coordination/live
import ../src/coordination/vote
import ../src/coordination/attest
import ../src/coordination/accounts
import ../src/coordination/card_rows
import ./probes/live_room

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
let A = id32("lez-member-alice")        # the members' LEZ accounts (in their LEZ wallets)
let B = id32("lez-member-bob")
let C = id32("lez-member-carol")
let program = id32("lez-multisig-program")   # the deployed program's account id (LEE v0.2)
let tokenProgram = id32("lez-token-program")
let recipient = id32("lez-recipient")
let createKey = id32("room-treasury")
const Chain = "lez:local"

let chain = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 1)
for m in [A, B, C]: chain.fund(m, 10)

# ── 1. create on chain, disclose into the room, verify ─────────────────────────
doAssert chain.submit(A, createOp(createKey, 2, @[A, B, C])).ok
doAssert not chain.submit(A, createOp(id32("another"), 1, @[A])).ok,
  "a member account already claimed by a multisig is not fresh"
let statePda = statePda(psLee02, program, createKey)
let config = $(%*{"program": toHex(program), "createKey": toHex(createKey), "pda": $psLee02})
proc disclosure(threshold: int): RoomAccount =
  RoomAccount(family: LezMultisigFamily, chain: Chain, address: toHex(statePda), label: "Treasury",
              signers: @[A, B, C].mapIt(toHex(it)), threshold: threshold, config: config)
var r = newRoom("/muster/1/lez-multisig-exit/proto")
r.alice.publish(accountDiscloseEvent(disclosure(2), "alice"))
r.bob.poll()
let acct = reduceAccounts(r.alice.log.allEvents())[0]
doAssert acct.config == config, "the disclosure carries its config"
doAssert checkAccount(acct, lezChainView(chain, acct)).status == acVerified
doAssert checkAccount(disclosure(3), lezChainView(chain, disclosure(3))).status == acDisagrees
echo "1. created on chain; disclosed with its config; the room re-derives the PDA and the chain agrees OK"

let resolve = proc(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
let resolverA = resolve(r.alice)
let resolverB = resolve(r.bob)
let policy = qualify("lez-multisig", acct.id)
doAssert resolverA(policy).supported()
let drv = LezMultisigDriver(resolverA(policy))

# ── 2. propose on chain, point the room at it ──────────────────────────────────
let vault = vaultPda(psLee02, program, createKey)
let action = LezAction(target: tokenProgram, instruction: @[1'u32, 500, 0], accounts: @[vault, recipient],
                       pdaSeeds: @[vaultSeed(createKey)], authorized: @[0'u8])
let aliceSeam = newLezVoteSeam(chain, A)
let id = liveProposeOnChain(r.alice, aliceKs, resolverA, policy, action, aliceSeam,
                            int64(Now), 1, ttlSec = Ttl)
doAssert id.len > 0 and not id.startsWith("refused"), id
let onChain = chain.readProposal(createKey, 1)
doAssert onChain.found and onChain.proposal.approved == @[A], "the proposer's Propose is their vote"
doAssert intentState(r.alice.log.allEvents(), resolverA, id) == "collecting"
echo "2. proposed on chain as #1 (the proposer's own transaction); the room points at it OK"

# ── 3. a member approves in the room: their own vote transaction ───────────────
r.bob.poll()
let bobSeam = newLezVoteSeam(chain, B)
doAssert liveVote(r.bob, bobKs, resolverB, id, bobSeam, bindCtx(), Now) == "executable"
doAssert chain.readProposal(createKey, 1).proposal.approved == @[A, B], "Bob's vote is on chain"
doAssert chain.balanceOf(B) == 9, "Bob paid for his own vote"
r.alice.poll()
let grades = approvalGrades(r.alice.log.allEvents(), resolverA, id)
doAssert gradeOf(grades, "lez:" & toHex(B), 1) == agCommitted, "the room member committed to what the room reviewed"
doAssert gradeOf(grades, "lez:" & toHex(A), 1) == agCommitted
echo "3. Bob approved in the room: muster read #1 back, his own vote went on chain, he paid, it counts OK"

# ── 4. a pointer to different content is refused before any vote ──────────────
let decoy = LezAction(target: tokenProgram, instruction: @[1'u32, 9_000, 0], accounts: @[vault, recipient],
                      pdaSeeds: @[vaultSeed(createKey)], authorized: @[0'u8])
doAssert chain.submit(C, proposeOp(createKey, 2, decoy)).ok        # what is really on chain as #2
let id2 = liveProposeIntent(r.alice, aliceKs, resolverA, policy, lezProposalEffect(2, action),
                            int64(Now), 2, account = toHex(statePda), ttlSec = Ttl)  # what the room is told
r.bob.poll()
let before = r.bob.log.allEvents().len
let refused = liveVote(r.bob, bobKs, resolverB, id2, bobSeam, bindCtx(), Now)
doAssert refused.startsWith("refused") and "instruction" in refused, refused
doAssert chain.readProposal(createKey, 2).proposal.approved == @[C], "no vote was cast"
doAssert chain.balanceOf(B) == 9, "no fee was paid"
doAssert r.bob.log.allEvents().len == before, "nothing was published"
echo "4. an intent pointing at different on-chain content: refused before any vote, nothing paid or published OK"

# ── 5. settle on the chain's count ─────────────────────────────────────────────
let stl = settlementFor(drv, chain, Account(chain: Chain, form: afPublic, id: toHex(A)))
doAssert stl != nil and stl of LezMultisigSettlement
var contribs: seq[SettleContribution]
for e in r.alice.log.allEvents():
  let p = e.key.split('/')
  if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
    contribs.add (contributor: p[3], bytes: hexToBytes(e.value))
let short = stl.assemble(drv, effectFromJson(lezProposalEffect(2, decoy)), @[])
doAssert not short.ok and short.error == "insufficient-approvals" and short.have == 1 and short.need == 2, $short
let asm0 = stl.assemble(drv, effectFromJson(lezProposalEffect(1, action)), contribs)
doAssert asm0.ok and asm0.have == 2 and asm0.need == 2, asm0.error & " " & asm0.detail
let txRef = stl.submit(asm0.tx, aliceKs)
doAssert stl.watch(txRef).status == fsFinal
doAssert chain.readProposal(createKey, 1).proposal.status == psExecuted
let call = chain.chainedCalls[^1]
doAssert call.program == tokenProgram and call.instruction == action.instruction and call.accounts == action.accounts,
  "the target program received exactly the proposal's call"
echo "5. settled on the chain's count: Executed from a member account; the target program got the call OK"

# ── 6. the card says it ────────────────────────────────────────────────────────
proc rowOf(rows: seq[CardRow], key: string): CardRow =
  for x in rows:
    if x.key == key: return x
let rows = cardRows(drv.profile())
doAssert "Each approval is its own public transaction on " & Chain in rowOf(rows, "where").text
doAssert rowOf(rows, "cost").text == "A transaction you pay for."
doAssert rowOf(rows, "sign").credibility == "motivational", "a pointer is only as good as the read"
doAssert rowOf(rows, "binding").credibility == "exposed", "the chain binds no network; muster binds it in the room"
echo "6. the card: every approval public, approving costs a transaction, pointer motivational, binding exposed OK"

echo "phase_c_exit_test: the vote locus on Logos's own chain — approvals are the members' own public transactions — all OK"
