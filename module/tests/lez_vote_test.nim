## Voting in the room (exo-12a1, Phase C4): for a vote-locus family, approving IN THE ROOM
## is the member's OWN on-chain transaction — the live path reads the pointer's content
## back from the chain and refuses on any mismatch BEFORE anything is signed (S5), has the
## member's LEZ wallet cast the vote through the vote seam (never muster), confirms it by
## reading the chain back, and only then publishes a receipt with a room-key attestation.
##   1. proposing: the Propose transaction goes on chain (the proposer's own, which
##      auto-approves), the room intent points at it, and the proposer's vote is reported
##      as a receipt — counted, attested by the proposer's room key (graded committed);
##   2. voting: S5 read → vote transaction → confirmed by re-reading → receipt; the read
##      is recorded in the log as an external read (evidence) without moving P, so every
##      earlier attestation still verifies;
##   3. refusals publish nothing and cast nothing: content that differs from what the room
##      reviewed; a pointer to a proposal the chain does not have; a voter the chain
##      refuses (not a member / already voted); an expired intent; a non-vote-locus intent;
##   4. the fold is the driver's: a receipt pasted in for a non-member, or for another
##      pointer, never counts;
##   5. a receipt's attestation that does not verify over P is graded rejected, never
##      committed.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/log/log
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/bitcoin/tx                # toHex / hexToBytes
import ../src/coordination/session
import ../src/coordination/intent_events
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/vote
import ../src/coordination/attest
import ../src/coordination/accounts
import ./probes/live_room

proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))
let (A, B, C, D) = (id32("va"), id32("vb"), id32("vc"), id32("vd"))
let (pA, pB, pC, pD) = (id32("pa"), id32("pb"), id32("pc"), id32("pd"))
let program = id32("vote-program")
let K = id32("vote-room")
const Chain = "lez:local"

let chain = newFakeLezMultisig(Chain, psLee02, program, feePerTx = 1)
for p in [pA, pB, pC, pD]: chain.fund(p, 10)
doAssert chain.submit(A, createOp(K, 2, @[A, B, C]), payer = pA).ok
let config = $(%*{"program": toHex(program), "createKey": toHex(K), "pda": "lee-v0.2"})
var r = newRoom("/muster/1/lez-vote/proto")
r.alice.publish(accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: Chain,
  address: toHex(statePda(psLee02, program, K)), label: "T", signers: @[A, B, C].mapIt(toHex(it)),
  threshold: 2, config: config), "alice"))
r.bob.poll()
proc resolver(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
let (resA, resB) = (resolver(r.alice), resolver(r.bob))
let acctId = reduceAccounts(r.alice.log.allEvents())[0].id
let policy = qualify("lez-multisig", acctId)
let act = LezAction(target: id32("token"), instruction: @[1'u32, 42, 0], accounts: @[id32("v"), id32("to")],
                    pdaSeeds: @[vaultSeed(K)], authorized: @[0'u8])
proc sigEvents(s: CoordinationSession, id: string): seq[Event] =
  s.log.allEvents().filterIt(it.key.startsWith("intent/" & id & "/sig/"))

# ── 1. proposing on chain ──────────────────────────────────────────────────────
let id = liveProposeOnChain(r.alice, aliceKs, resA, policy, act, newLezVoteSeam(chain, A, pA),
                            int64(Now), 1, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
doAssert chain.readProposal(K, 1).proposal.approved == @[A]
doAssert r.alice.sigEvents(id).mapIt(it.key.split('/')[3]) == @["lez:" & toHex(A)], "the proposer's vote, reported"
doAssert intentState(r.alice.log.allEvents(), resA, id) == "collecting"
doAssert gradeOf(approvalGrades(r.alice.log.allEvents(), resA, id), "lez:" & toHex(A), 1) == agCommitted
let p0 = attestationPayload(r.alice.log.allEvents(), resA, id)
echo "1. proposed on chain; the room points at #1; the proposer's vote reported, attested OK"

# ── 2. voting ──────────────────────────────────────────────────────────────────
r.bob.poll()
doAssert liveVote(r.bob, bobKs, resB, id, newLezVoteSeam(chain, B, pB), bindCtx(), Now) == "executable"
doAssert chain.readProposal(K, 1).proposal.approved == @[A, B] and chain.balanceOf(pB) == 9
let reads = r.bob.log.allEvents().filterIt(it.key.startsWith("intent/" & id & "/read/"))
doAssert reads.len == 1 and "lez:local@" in parseJson(reads[0].value)["source"].getStr(),
  "the S5 read is recorded, with where and at what height it was read"
r.alice.poll()
doAssert attestationPayload(r.alice.log.allEvents(), resA, id) == p0, "a recorded read does not move P"
let grades = approvalGrades(r.alice.log.allEvents(), resA, id)
doAssert gradeOf(grades, "lez:" & toHex(A), 1) == agCommitted and gradeOf(grades, "lez:" & toHex(B), 1) == agCommitted
echo "2. Bob voted: S5 read, his own transaction, confirmed on chain, receipt counted; P unmoved OK"

# ── 3. refusals: nothing cast, nothing published ──────────────────────────────
proc nothingHappens(s: CoordinationSession, res: DriverFor, intent: string, seam: VoteSeam,
                    payer: seq[byte], want: string, nowSec = Now) =
  let before = s.log.allEvents().len
  let bal = chain.balanceOf(payer)
  let h = chain.height()
  let got = liveVote(s, (if s == r.bob: bobKs else: aliceKs), res, intent, seam, bindCtx(), nowSec)
  doAssert got.startsWith(want), want & " expected, got: " & got
  doAssert s.log.allEvents().len == before, "nothing published: " & got
  doAssert chain.balanceOf(payer) == bal and chain.height() == h, "nothing cast: " & got
# (a) the on-chain #2 is not what the room is told
var decoy = act
decoy.instruction = @[1'u32, 999_999, 0]
doAssert chain.submit(C, proposeOp(K, 2, decoy), payer = pC).ok
let lying = liveProposeIntent(r.alice, aliceKs, resA, policy, lezProposalEffect(2, act), int64(Now), 2,
                              account = toHex(statePda(psLee02, program, K)), ttlSec = Ttl)
r.bob.poll()
nothingHappens(r.bob, resB, lying, newLezVoteSeam(chain, B, pB), pB, "refused: the on-chain proposal carries a different instruction")
# (b) a pointer to a proposal the chain does not have
let ghost = liveProposeIntent(r.alice, aliceKs, resA, policy, lezProposalEffect(9, act), int64(Now), 3,
                              account = toHex(statePda(psLee02, program, K)), ttlSec = Ttl)
r.bob.poll()
nothingHappens(r.bob, resB, ghost, newLezVoteSeam(chain, B, pB), pB, "refused: could not read")
# (c) the chain refuses the voter: already voted; not a member
nothingHappens(r.bob, resB, id, newLezVoteSeam(chain, B, pB), pB, "refused: the chain refused the vote")
nothingHappens(r.bob, resB, id, newLezVoteSeam(chain, D, pD), pD, "refused: the chain refused the vote")
# (d) expired
nothingHappens(r.bob, resB, id, newLezVoteSeam(chain, C, pC), pC, "expired", nowSec = Now + uint64(Ttl) + 10)
# (e) not a vote-locus intent
let thr = liveProposeIntent(r.alice, aliceKs, resA, "threshold", effectFor("threshold", 7), int64(Now), 4,
                            account = r.topic, ttlSec = Ttl)
r.bob.poll()
nothingHappens(r.bob, resB, thr, newLezVoteSeam(chain, B, pB), pB, "not-a-vote-locus")
echo "3. mismatch, missing proposal, chain refusal, expiry, wrong locus: nothing cast, nothing published OK"

# ── 4. the fold is the driver's ────────────────────────────────────────────────
let drv = resA(policy)
let m = canonicalize(drv, effectFromJson(lezProposalEffect(1, act)))
doAssert liveContribute(r.alice, aliceKs, resA, id, toHex(voteReceipt(D, 1, repeat("ee", 32), m).bytes), "",
                        bindCtx(), Now) == "rejected", "a receipt for a non-member never counts"
let m2 = canonicalize(drv, effectFromJson(lezProposalEffect(2, act)))
doAssert liveContribute(r.alice, aliceKs, resA, id, toHex(voteReceipt(C, 2, repeat("ee", 32), m2).bytes), "",
                        bindCtx(), Now) == "rejected", "a receipt for another pointer never counts"
echo "4. receipts pasted for a non-member or another pointer are rejected by the driver OK"

# ── 5. attestation ─────────────────────────────────────────────────────────────
let ev = r.alice.log.allEvents().filterIt(it.key.startsWith("intent/" & id & "/attest/lez:" & toHex(B)))
doAssert ev.len == 1
let sig = hexToBytes(ev[0].value)
doAssert sig.len == 96 and sig[0 ..< 32] == @(bobKs.encIdentity().ed), "attested by Bob's room key"
doAssert verifyAttestation("lez:" & toHex(B), p0, ev[0].value)
var bad = sig
bad[40] = bad[40] xor 1
doAssert not verifyAttestation("lez:" & toHex(B), p0, toHex(bad)), "a tampered attestation never verifies"
echo "5. a vote's attestation is the room member's key over P; tampered, it fails OK"

echo "lez_vote_test: approving in the room is the member's own on-chain vote — re-read, cast, confirmed, attested — all OK"
