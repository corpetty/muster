## Who is owed must say so (exo-770). A split names its creditor and where to pay them, but
## a proposal is not author-signed: any member can publish one. Until now only the debtors
## agreed, so a member could propose "Alice paid — pay 0x<mine>": the card said Alice paid,
## the debtors agreed and paid whoever wrote the address. Held here:
##   * a split is never executable until its CREDITOR has agreed too — their signature over
##     the materialization (which carries payTo) is their word that payTo is theirs;
##   * proposed by someone else in the creditor's name, it waits for the creditor, and a
##     creditor who never agrees leaves it unpayable — nobody pays the impostor's address;
##   * the creditor's agreement is by the creditor's own room key; nobody else's counts.
## Needs libsodium + secp256k1 (the keystores).

import std/[json, strutils]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/parts
import ../src/coordination/intent_events
import ./probes/live_room

const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
const CarolPayTo = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let alice = idHex(aliceKs)
let bob = idHex(bobKs)
let carol = idHex(room3CarolKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)

var r = newRoom3("/muster/1/split-creditor/proto")
var seqNo = 0'u64
proc proposeBy(s: CoordinationSession, ks: Keystore, effect, payTo: string): string =
  inc seqNo
  liveProposeIntent(s, ks, splitFor, Policy, effect, int64(Now), seqNo,
                    account = Chain & ":" & payTo, ttlSec = Ttl)
proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
  liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
proc stateOn(s: CoordinationSession, id: string): string =
  r.alice.poll(); r.bob.poll(); r.carol.poll()
  intentState(s.roomEvents(), splitFor, id)

# ── 1. a split in someone else's name, paid to the proposer: never payable ───────
block:
  # Carol writes a split saying ALICE fronted it — paid to Carol's own address
  let forged = splitEffectJson(Chain, "ETH", "600", alice, CarolPayTo, evenShares("600", alice, @[bob]), "forged")
  let id = r.carol.proposeBy(room3CarolKs, forged, CarolPayTo)
  doAssert id.startsWith("0x"), id
  discard agree(r.bob, bobKs, id)
  doAssert stateOn(r.bob, id) notin ["executable", "submitted", "settling", "final"],
           "the debtor's agreement alone never makes a split payable: " & stateOn(r.bob, id)
  let (out1, _) = liveSettlePartSend(r.bob, bobKs, splitFor, id, newFakePartSeam(newFakeLedger(), "bob"), Now)
  doAssert out1 == "not-agreed" or out1.startsWith("refused"), "nothing is paid to the impostor: " & out1
  echo "1. a split naming Alice but paid to Carol waits for Alice; the debtor cannot pay it OK"

# ── 2. the creditor agrees: then, and only then, it is payable ────────────────────
block:
  let e = splitEffectJson(Chain, "ETH", "600", alice, AlicePayTo, evenShares("600", alice, @[bob]), "dinner")
  let id = r.carol.proposeBy(room3CarolKs, e, AlicePayTo)     # proposed on Alice's behalf
  discard agree(r.bob, bobKs, id)
  doAssert stateOn(r.alice, id) notin ["executable", "submitted", "settling", "final"]
  # Carol cannot agree in Alice's place
  discard agree(r.carol, room3CarolKs, id)
  doAssert stateOn(r.alice, id) notin ["executable", "submitted", "settling", "final"],
           "an agreement by anyone but the creditor never stands for the creditor's"
  discard agree(r.alice, aliceKs, id)
  doAssert stateOn(r.alice, id) == "executable", stateOn(r.alice, id)
  echo "2. proposed on Alice's behalf: payable once Alice herself agrees — nobody agrees for her OK"

# ── 3. the creditor proposing: their agreement is made at propose, by their own key ──
block:
  let e = splitEffectJson(Chain, "ETH", "600", alice, AlicePayTo, evenShares("600", alice, @[bob]), "taxi")
  let id = r.alice.proposeBy(aliceKs, e, AlicePayTo)
  r.alice.poll(); r.bob.poll(); r.carol.poll()
  var v: IntentView
  for x in reduceIntentViews(r.bob.roomEvents(), splitFor):
    if x.id == id: v = x
  doAssert v.threshold == 2 and v.approvals == 1, "the creditor is a party, and agreed by proposing: " &
           $v.approvals & "/" & $v.threshold
  doAssert agree(r.bob, bobKs, id) == "executable", "then the debtors' agreement makes it payable"
  echo "3. Alice proposing her own split has agreed to it (her key, at propose); Bob's agreement completes it OK"

# ── 4. every proposal names its proposer, signed; a forged claim never stands ────
block:
  let e = splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo, evenShares("900", alice, @[bob]), "hotel")
  let id = r.carol.proposeBy(room3CarolKs, e, AlicePayTo)
  r.alice.poll(); r.bob.poll(); r.carol.poll()
  # Carol also tries to claim Alice proposed it: a claim only Alice's key could sign
  r.carol.publish(proposerEvent(id, alice))
  r.alice.poll(); r.bob.poll(); r.carol.poll()
  var v: IntentView
  for x in reduceIntentViews(r.bob.roomEvents(), splitFor):
    if x.id == id: v = x
  doAssert v.proposers == @[carol], "the room reads only the signed claim: " & $v.proposers
  doAssert stateOn(r.bob, id) notin ["executable", "submitted", "settling", "final"]
  echo "4. a proposal names its proposer by their signature; a claim in another's name is dropped OK"

echo "split_creditor_test: all OK"
