## Member and threshold changes from the room (exo-267.6; docs/design/logos-world-plan.md
## Phase 1, The pieces). A removal is an org act in two places: on chain the member can no
## longer vote or be counted, and in the room they can no longer read. On the fake v0.3 zone,
## through the room's own propose, vote and settle path:
##   1. a config proposal (remove a member) goes on chain as the proposer's own ProposeConfig;
##      the room's intent points at it, and the card reads it in words, naming the member
##      whose shared account it removes;
##   2. a vote and the ExecuteConfig settle it: the chain's member set no longer holds them,
##      and their vote on the next proposal is refused (included, changing nothing);
##   3. the room follows: the member is removed from the room's encryption by the proposer's
##      client, once — re-keyed forward, so the next epoch is unreadable to them while the
##      others read it, and the room's view of who can read no longer names them;
##   4. a threshold change takes effect for the next proposal;
##   5. S5 holds for config proposals: an on-chain proposal that changes something other than
##      what the room reviewed is refused before any vote;
##   6. every member's view converges.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils]
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
import ../src/bitcoin/tx                # toHex
import ../src/wallet/types
import ../src/settlement/settlement
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/session
import ../src/coordination/live
import ../src/coordination/vote
import ../src/coordination/accounts
import ../src/coordination/authorship
import ../src/coordination/member_accounts
import ../src/coordination/member_changes
import ../src/coordination/flow
import ../src/intents/disclosure
import ./probes/live_room

proc encOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc encHexOf(m: EncIdentity): string =
  const d = "0123456789abcdef"
  for x in m.toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))

const Label = "lez-account/0"
let ids = @[encOf(aliceKs), encOf(bobKs), encOf(room3CarolKs)]
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let accts = kss.mapIt(publicAccountId(it.lezMemberKey(Label)))
let msProgram = id32("lez-multisig-v030-program")
let ck = id32("tuesday-circle")
let f = newFakeLezMultisig("lez:local", psLee02, msProgram, feePerTx = 1, layout = plV03)
for a in accts: f.fund(a, 1_000)
let vault = vaultPda(psLee02, msProgram, ck)
f.fund(vault, 500)
doAssert f.submit(accts[0], createOp(ck, 2, accts)).ok and f.lastRefusal.len == 0

var r = newRoom3("/muster/1/member-change/proto")
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() = (for s in sessions: s.poll())
proc evs(i = 0): seq[Event] = (pollAll(); sessions[i].roomEvents())

let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: "lez:local",
  address: toHex(statePda(psLee02, msProgram, ck)), label: "Circle pot", signers: accts.mapIt(toHex(it)),
  threshold: 2, config: cfg), encOf(aliceKs)))
for i, s in sessions: discard discloseAccount(s, kss[i], Label, "lez:local", name = "mine")
pollAll()
let roomAcct = reduceAccounts(evs())[0]
let policy = qualify("lez-multisig", roomAcct.id)
let dfor = proc(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(p: string): Driver =
    driverForPolicy(p, reduceAccounts(sess.roomEvents()), proc(k: string): Driver = liveDriverFor(k))
let dA = dfor(r.alice)
proc state(): MultisigState = f.readState(ck).state

var seqNo = 100'u64
proc settleAs(id: string) =
  let drv = LezMultisigDriver(dA(policy))
  let stl = settlementFor(drv, f, Account(chain: "lez:local", form: afPublic, id: toHex(accts[0])))
  r.alice.poll()
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  let txRef = stl.submit(built.tx, aliceKs)
  doAssert stl.watch(txRef).status == fsFinal
  r.alice.publish(submitEvent(id, chainRef = txRef.id))
  r.alice.publish(finalEvent(id, chainRef = txRef.id))

# ── 1. a removal proposed on chain, read in words ─────────────────────────────
var removeId = ""
block:
  inc seqNo
  removeId = liveProposeConfigOnChain(r.alice, aliceKs, dA, policy,
                                      ConfigAction(kind: caRemoveMember, member: accts[2]),
                                      newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert removeId.startsWith("0x"), removeId
  let e = parseJson(effectJsonOf(evs(), removeId))
  doAssert e["effect"].getStr() == "lez-multisig-config" and e["change"].getStr() == "remove"
  let (ok, reading) = configReadingOf(evs(), effectJsonOf(evs(), removeId), r.topic)
  doAssert ok and reading["change"].getStr() == "remove" and reading["member"].getStr() == ids[2], $reading
  doAssert reading["account"].getStr() == toHex(accts[2])
  echo "1. a removal goes on chain as ProposeConfig; the room's card names the member whose account it removes OK"

# ── 2. voted, executed: the chain no longer counts them ───────────────────────
block:
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), removeId, newLezVoteSeam(f, accts[1]), bindCtx(), Now) == "executable"
  settleAs(removeId)
  doAssert state().members == accts[0 .. 1] and state().threshold == 2, $state().members.len
  # the next proposal: carol's vote is included and refused
  inc seqNo
  let pay = liveProposeOnChain(r.alice, aliceKs, dA, policy,
                               lezCallV03(NativeTokenProgram, @[(vault, newSeq[byte](32)), (accts[0], newSeq[byte](32))],
                                          nativeTransfer(10.stuint(128)), @[vaultSeed(ck)]),
                               newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert pay.startsWith("0x"), pay
  let idx = lezActionOf(effectFromJson(effectJsonOf(evs(), pay))).index
  let t = f.submit(accts[2], approveOp(ck, idx))
  doAssert t.ok and f.lastRefusal.len > 0, "carol's vote is included and changes nothing"
  doAssert f.readProposal(ck, idx).proposal.approved == @[accts[0]]
  echo "2. voted and executed: the chain's members are alice and bob; carol's vote is refused OK"

# ── 3. the room follows: carol is re-keyed out, once, by the proposer ─────────
block:
  let before = r.alice.epoch()
  doAssert removalsDue(evs(), dA, r.topic, r.alice.members().mapIt(encHexOf(it)), ids[0]) ==
           @[(ids[2], removeId)], "the proposer's client owes the room-side removal"
  doAssert removalsDue(evs(1), dfor(r.bob), r.topic, r.bob.members().mapIt(encHexOf(it)), ids[1]).len == 0,
           "only the proposer's client re-keys, so the room forks no epoch"
  for (who, _) in removalsDue(evs(), dA, r.topic, r.alice.members().mapIt(encHexOf(it)), ids[0]):
    doAssert who == ids[2]
    r.alice.expel(kss[2].encIdentity())
  pollAll()
  doAssert r.alice.epoch() == before + 1 and r.bob.epoch() == before + 1
  doAssert ids[2] notin r.alice.members().mapIt(encHexOf(it)) and
           ids[2] notin r.bob.members().mapIt(encHexOf(it))
  doAssert removalsDue(evs(), dA, r.topic, r.alice.members().mapIt(encHexOf(it)), ids[0]).len == 0,
           "done once"
  r.alice.publishAuthored(aliceKs, Event(key: "message/after-removal", value: $(%*{"author": ids[0], "text": "carol cannot read this"})))
  pollAll()
  doAssert r.bob.roomEvents().anyIt(it.key == "message/after-removal"), "bob reads the new epoch"
  doAssert not r.carol.log.allEvents().anyIt(it.key == "message/after-removal"), "carol cannot open it"
  # the room's own view of who can read follows the removal
  let all = evs()
  doAssert all.anyIt(it.key.startsWith("membership/") and "/remove/" & ids[2] in it.key)
  let fl = reduceFlow(all, dA, ids, r.alice.sealedIn)
  let at = canonicalOrder(all).mapIt(it.key).find("message/after-removal")
  let readers = fl.filterIt(it.seq == at and it.to == obRoomMember)
  doAssert readers.len > 0 and readers.allIt(ids[2] notin it.members and ids[0] in it.members), $readers
  echo "3. the proposer re-keys carol out once; bob reads the next epoch, carol cannot; who-can-read follows OK"

# ── 4. a threshold change takes effect for the next proposal ──────────────────
block:
  inc seqNo
  let tid = liveProposeConfigOnChain(r.alice, aliceKs, dA, policy, ConfigAction(kind: caChangeThreshold, threshold: 1),
                                     newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  doAssert tid.startsWith("0x"), tid
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, dfor(r.bob), tid, newLezVoteSeam(f, accts[1]), bindCtx(), Now) == "executable"
  settleAs(tid)
  doAssert state().threshold == 1
  # the next proposal settles on the proposer's vote alone
  inc seqNo
  let pay = liveProposeOnChain(r.alice, aliceKs, dA, policy,
                               lezCallV03(NativeTokenProgram, @[(vault, newSeq[byte](32)), (accts[1], newSeq[byte](32))],
                                          nativeTransfer(20.stuint(128)), @[vaultSeed(ck)]),
                               newLezVoteSeam(f, accts[0]), int64(Now), seqNo, ttlSec = Ttl)
  let drv = LezMultisigDriver(dA(policy))
  let stl = settlementFor(drv, f, Account(chain: "lez:local", form: afPublic, id: toHex(accts[0])))
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(evs(), pay)), @[])
  doAssert built.ok and built.need == 1, built.error & " " & built.detail
  echo "4. the threshold falls to 1 by vote; the next proposal settles on one approval OK"

# ── 5. S5 for config: what goes on chain must be what the room reviews ─────────
block:
  let drv = LezMultisigDriver(dA(policy))
  let reviewed = effectFromJson(lezConfigEffect(9, ConfigAction(kind: caRemoveMember, member: accts[1])))
  let onChain = Proposal(index: 9, proposer: accts[0], createKey: ck, hasConfig: true, config: ConfigAction(kind: caRemoveMember, member: accts[0]),
                         status: psActive)
  doAssert "different" in drv.checkRead(reviewed, "proposal", encodeProposal(onChain, plV03)), "another member"
  let call = Proposal(index: 9, proposer: accts[0], createKey: ck, status: psActive,
                      action: lezCallV03(NativeTokenProgram, @[(vault, newSeq[byte](32))], @[0'u8], @[]))
  doAssert drv.checkRead(reviewed, "proposal", encodeProposal(call, plV03)).len > 0, "a call, not a config change"
  let same = Proposal(index: 9, proposer: accts[0], createKey: ck, hasConfig: true, config: ConfigAction(kind: caRemoveMember, member: accts[1]),
                      status: psActive)
  doAssert drv.checkRead(reviewed, "proposal", encodeProposal(same, plV03)) == ""
  echo "5. a config proposal is re-read before a vote: another member, or a call instead, is refused OK"

# ── 6. converge ───────────────────────────────────────────────────────────────
block:
  doAssert $configReadingOf(evs(0), effectJsonOf(evs(0), removeId), r.topic)[1] ==
           $configReadingOf(evs(1), effectJsonOf(evs(1), removeId), r.topic)[1]
  doAssert r.alice.members() == r.bob.members()
  echo "6. alice and bob agree on the change and on who is in the room OK"

echo "member_change_test: member and threshold changes from the room — all OK"
