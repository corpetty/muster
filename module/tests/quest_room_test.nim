## Quests in the room (exo-267.8; docs/design/logos-world-plan.md Phase 1): a circle's LEZ
## multisig issues a quest by vote, its taker accepts and its confirmer confirms with their
## own transactions, and the circle closes it by a second vote, paying the bounty — then
## anyone outside the room checks the attestation from the chain alone.
##   1. the terms: hashed as a domain-separated record, the quest id from the issuer and that
##      hash, and the Open call the room proposes (every row, the vault's seed) recognized
##      back from its bytes;
##   2. the room issues it on the fake v0.3 chain with the quest program plugged in: the
##      vault's grant carries into the bounty's transfer, and the room's fold finds the
##      terms only under their hash;
##   3. the taker and the confirmer act with their own transactions; others are included
##      and refused, as v0.3 does;
##   4. the circle closes it by a second vote; the taker is paid;
##   5. an outsider with the record's id, the multisig's create key and the closing
##      proposal's index verifies issuer, taker, confirmer and the threshold; a wrong
##      proposal, or a quest someone else issued, is refused.
## Needs the secp closure + libsodium.

import std/[json, strutils, sequtils]
import stint
import ../src/hashing/sha256
import ../src/crypto/keystore
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_multisig
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/quest
import ../src/lez/quest_fake
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
import ../src/coordination/quest as roomquest
import ./probes/live_room

proc encOf(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc id32(label: string): seq[byte] = @(sha256(cast[seq[byte]](label)))

let msProgram = id32("lez-multisig-v030-program")
let Q = id32("lez-quest-program")
let ck = id32("tuesday-circle")
let (mA, mB, mC) = (id32("m-alice"), id32("m-bob"), id32("m-carol"))
let (taker, confirmer, outsider) = (id32("q-taker"), id32("q-confirmer"), id32("q-outsider"))
const Fee = 10'u64
let f = newFakeLezMultisig("lez:local", psLee02, msProgram, feePerTx = Fee, layout = plV03)
f.addProgram(Q, questFake(Q, psLee02))
for m in [mA, mB, mC, taker, confirmer, outsider]: f.fund(m, 1_000)
let vault = vaultPda(psLee02, msProgram, ck)
f.fund(vault, 1_000)
proc took(t: LezTx): bool = t.ok and f.lastRefusal.len == 0
proc refusedWith(t: LezTx, why: string): bool = t.ok and why in f.lastRefusal
doAssert f.submit(mA, createOp(ck, 2, @[mA, mB, mC])).took

# ── 1. the terms, the id, the Open call ───────────────────────────────────────
let terms = QuestTerms(task: "Walk a newcomer through their first split", bounty: 200.stuint(128),
                       confirmer: toHex(confirmer), taker: toHex(taker), salt: "0011223344556677")
let th = questTermsHash(terms)
block:
  var other = terms
  other.task = "Walk two newcomers through their first split"
  doAssert questTermsHash(other) != th and questTermsHash(terms) == th
  doAssert parseQuestTerms(questTermsJson(terms)).terms == terms, "the terms round-trip through their JSON"
let qid = questIdFor(vault, th)
let record = questRecordPda(psLee02, Q, vault, qid)
let openCall = questOpenCall(Q, msProgram, psLee02, ck, terms)
block:
  doAssert openCall.target == Q and openCall.pdaSeeds == @[vaultSeed(ck)]
  let zero = newSeq[byte](32)
  doAssert openCall.shards == @[(record, Q), (vault, Q), (vault, zero), (record, zero)]
  let (ok, qc) = questCallOf(openCall, Q)
  doAssert ok and qc.kind == qkOpen and qc.questId == qid and qc.termsHash == th and qc.bounty == 200.stuint(128) and
           qc.confirmer == confirmer and qc.taker == taker
  doAssert not questCallOf(lezCallV03(NativeTokenProgram, @[(vault, zero), (taker, zero)],
                                      nativeTransfer(5.stuint(128)), @[vaultSeed(ck)]), Q).ok, "a payment is no quest"
  echo "1. the terms hash as a domain-separated record; the Open call carries every row and the vault's seed OK"

# ── 2. the room issues it ─────────────────────────────────────────────────────
let cfg = $(%*{"program": toHex(msProgram), "createKey": toHex(ck), "pda": "lee-v0.2", "layout": "v0.3"})
var r = newRoom3("/muster/1/quest-room/proto")
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMultisigFamily, chain: "lez:local",
  address: toHex(statePda(psLee02, msProgram, ck)), label: "Circle pot", signers: @[mA, mB, mC].mapIt(toHex(it)),
  threshold: 2, config: cfg), encOf(aliceKs)))
r.bob.poll()
r.carol.poll()
let acct = reduceAccounts(r.alice.roomEvents())[0]
let resolve = proc(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.roomEvents()), proc(k: string): Driver = liveDriverFor(k))
let (resA, resB) = (resolve(r.alice), resolve(r.bob))
let policy = qualify("lez-multisig", acct.id)
proc settle(id: string) =
  let drv = LezMultisigDriver(resA(policy))
  let stl = settlementFor(drv, f, Account(chain: "lez:local", form: afPublic, id: toHex(mA)))
  r.alice.poll()
  let built = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.roomEvents(), id)), @[])
  doAssert built.ok, built.error & " " & built.detail
  doAssert stl.watch(stl.submit(built.tx, aliceKs)).status == fsFinal
block:
  r.alice.publish(questTermsEvent(qid, questTermsJson(terms)))
  var junk = terms
  junk.task = "Something else entirely"
  r.alice.publish(questTermsEvent(qid, questTermsJson(junk)))      # filed under the id, hashing elsewhere
  let id = liveProposeOnChain(r.alice, aliceKs, resA, policy, openCall, newLezVoteSeam(f, mA), int64(Now), 1, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, resB, id, newLezVoteSeam(f, mB), bindCtx(), Now) == "executable"
  settle(id)
  let rec = decodeQuestRecord(f.readAccount(record).data)
  doAssert rec.status == qsOpen and rec.issuer == vault and rec.termsHash == th
  doAssert f.balanceOf(vault) == 800 and f.balanceOf(record) == 200, "the vault's grant moved the bounty into the record"
  r.bob.poll()
  let qs = questsOf(r.bob.roomEvents(), Q)
  doAssert qs.len == 1 and qs[0].questId == qid and qs[0].issuer == vault and qs[0].openIntent == id
  doAssert qs[0].termsFound and qs[0].terms == terms, "the fold finds the terms only under their hash"
  doAssert qs[0].closeIntent == "", "no close proposed yet"
  let (rok, rtext, rq) = questReadingOf(r.bob.roomEvents(), effectJsonOf(r.bob.roomEvents(), id), Q)
  doAssert rok and "issue a quest" in rtext and "Walk a newcomer" in rtext and "bounty 200" in rtext, rtext
  doAssert rq["step"].getStr() == "open" and rq["termsFound"].getBool()
  doAssert not questReadingOf(r.bob.roomEvents(), effectJsonOf(r.bob.roomEvents(), id), id32("other-program")).ok,
           "read as a quest only when it is the quest program's"
  echo "2. issued by vote: the record is open, the pot paid 200 into it; the room's fold shows the terms OK"

# ── 3. the taker and the confirmer, with their own transactions ───────────────
block:
  doAssert f.submitCall(outsider, questAcceptCall(Q, psLee02, vault, qid, outsider)).refusedWith("not the taker this quest names")
  doAssert f.submitCall(confirmer, questConfirmCall(Q, psLee02, vault, qid, confirmer)).refusedWith("not accepted")
  doAssert f.submitCall(taker, questAcceptCall(Q, psLee02, vault, qid, taker)).took
  doAssert f.submitCall(taker, questConfirmCall(Q, psLee02, vault, qid, taker)).refusedWith("not this quest's confirmer")
  doAssert f.submitCall(confirmer, questConfirmCall(Q, psLee02, vault, qid, confirmer)).took
  let rec = decodeQuestRecord(f.readAccount(record).data)
  doAssert rec.status == qsConfirmed and rec.statusTaker == taker
  echo "3. the outsider's Accept and the taker's Confirm included and refused; taken and confirmed by their own keys OK"

# ── 4. the circle closes it by a second vote ──────────────────────────────────
let closeCall = questCloseCall(Q, msProgram, psLee02, ck, qid, taker, 200.stuint(128))
block:
  let (ok, qc) = questCallOf(closeCall, Q)
  doAssert ok and qc.kind == qkClose and qc.questId == qid and qc.taker == taker
  let before = f.balanceOf(taker)
  let id = liveProposeOnChain(r.alice, aliceKs, resA, policy, closeCall, newLezVoteSeam(f, mA), int64(Now), 2, ttlSec = Ttl)
  r.bob.poll()
  doAssert liveVote(r.bob, bobKs, resB, id, newLezVoteSeam(f, mB), bindCtx(), Now) == "executable"
  settle(id)
  doAssert decodeQuestRecord(f.readAccount(record).data).status == qsClosed
  doAssert f.balanceOf(taker) == before + 200 and f.balanceOf(record) == 0
  r.bob.poll()
  let qs = questsOf(r.bob.roomEvents(), Q)
  doAssert qs[0].closeIntent == id and qs[0].closeIndex == 2, "the room knows which proposal closed it"
  let (cok, ctext, _) = questReadingOf(r.bob.roomEvents(), effectJsonOf(r.bob.roomEvents(), id), Q)
  doAssert cok and "close the quest" in ctext and "Walk a newcomer" in ctext, ctext
  echo "4. closed by a second vote: the taker holds the 200; the card reads the close in words OK"

# ── 5. outside the room: the attestation from the chain alone ─────────────────
block:
  let a = verifyQuestAttestation(f, Q, record, ck, 2)
  doAssert a.ok, a.why
  doAssert a.issuer == vault and a.taker == taker and a.confirmer == confirmer and a.termsHash == th
  doAssert a.approvals >= a.threshold and a.threshold == 2
  let wrong = verifyQuestAttestation(f, Q, record, ck, 1)
  doAssert not wrong.ok and "not a Close of this quest" in wrong.why, wrong.why
  # a quest a person issued from their own account: no multisig attests to it
  let pid = questIdFor(mC, th)
  doAssert f.submitCall(mC, questPersonalOpenCall(Q, psLee02, mC, pid, terms)).took
  let mine = verifyQuestAttestation(f, Q, questRecordPda(psLee02, Q, mC, pid), ck, 2)
  doAssert not mine.ok and "not this multisig's vault" in mine.why, mine.why
  echo "5. an outsider verified issuer, taker, confirmer and 2 of 2 from chain reads; a wrong proposal and ",
       "another issuer's quest refused OK"

echo "quest_room_test: all OK"
