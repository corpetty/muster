## "Waiting on you" means you (exo-ed5; F-18: the home surface is a query over intents —
## needs-you, waiting-on-others, settled). Home used to mark a room "needs" only when its
## LAST intent was executable, and read only the active room: B's Home said "Nothing
## waiting on you" while a split proposed on B's behalf waited on B's own Agree.
##
## `homeItems` classes every intent in a room's authentic log for THIS member — from the
## log and their own keys alone (invariant 9: what it says of anyone else is only what
## they disclosed). Held here:
##   * an intent still collecting needs you only if your contribution would count (the
##     driver says so — `mayContribute` — never guessed) and you have neither agreed nor
##     declined; a split names its parties, so each debtor and the creditor;
##   * an agreed split needs each debtor until their own part is paid; the creditor's
##     confirmation is their client's own read, so it waits on no one's click;
##   * an agreed whole-account intent needs settling when its finality is outside the
##     room; one final in the room is settled; anything final is settled;
##   * a member the policy does not name is never asked.
## Needs libsodium + secp256k1 (the keystores).

import std/[strutils]
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/split
import ../src/drivers/safe
import ../src/drivers/threshold
import ../src/drivers/eip191
import ../src/drivers/kinds
import ../src/intents/materialization
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/crypto/secp256k1
import ../src/coordination/session
import ../src/coordination/intents
import ../src/coordination/intent_events
import ../src/coordination/live
import ../src/coordination/authorship
import ../src/coordination/attest
import ../src/coordination/parts
import ../src/coordination/home
import ./probes/live_room

proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# someone outside every policy here: not in the room, not an owner, not named
proc filled(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let daveKs = newInMemoryKeystore(filled(0x44), filled(9))

proc homeFor(events: seq[Event], dfor: DriverFor, ks: Keystore, id: string): HomeItem =
  for it in homeItems(events, dfor, ks.encIdentity(), myContributorNames(ks)):
    if it.id == id: return it
  doAssert false, "no home item for " & id

proc says(it: HomeItem, cls: HomeClass, what = ""): bool = it.cls == cls and it.what == what

# ── 1. a split: who it waits on, step by step ───────────────────────────────────
block:
  const Chain = "eip155:31337"
  const Policy = "evm-split@" & Chain
  const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  let alice = idHex(aliceKs)
  let bob = idHex(bobKs)
  let carol = idHex(room3CarolKs)
  let splitFor: DriverFor = proc(policy: string): Driver =
    if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob, carol]) else: newUnsupportedDriver(policy)
  var r = newRoom3("/muster/1/home-split/proto")
  proc sync() = (r.alice.poll(); r.bob.poll(); r.carol.poll())
  proc agree(s: CoordinationSession, ks: Keystore, id: string): string =
    liveContribute(s, ks, splitFor, id, "", "", bindCtx(), Now)
  proc home(ks: Keystore, id: string): HomeItem =
    sync()
    homeFor(r.alice.roomEvents(), splitFor, ks, id)

  let dinner = splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo, evenShares("900", alice, @[bob, carol]), "Dinner")
  let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy, dinner, int64(Now), 1,
                             account = Chain & ":" & AlicePayTo, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  doAssert home(aliceKs, id).says(hcWaiting), "the creditor agreed by proposing: " & $home(aliceKs, id)
  doAssert home(bobKs, id).says(hcNeedsYou, "agree") and home(room3CarolKs, id).says(hcNeedsYou, "agree")
  doAssert home(daveKs, id).says(hcWaiting), "a member the split does not name is never asked"
  discard agree(r.bob, bobKs, id)
  doAssert home(bobKs, id).says(hcWaiting) and home(room3CarolKs, id).says(hcNeedsYou, "agree")
  doAssert agree(r.carol, room3CarolKs, id) == "executable"
  doAssert home(bobKs, id).says(hcNeedsYou, "pay") and home(room3CarolKs, id).says(hcNeedsYou, "pay")
  doAssert home(aliceKs, id).says(hcWaiting), "confirming is the creditor's own read, not a click"
  echo "1a. a split asks each debtor to agree, then to pay; the creditor waits OK"

  let ledger = newFakeLedger()
  let bobSeam = newFakePartSeam(ledger, "bob")
  let (outcome, pp) = liveSettlePartSend(r.bob, bobKs, splitFor, id, bobSeam, Now)
  doAssert outcome == "", outcome
  ledger.mine()
  doAssert liveSettlePartComplete(r.bob, bobKs, splitFor, bobSeam, pp) == "submitted"
  doAssert home(bobKs, id).says(hcWaiting), "Bob's part is paid: " & $home(bobKs, id)
  doAssert home(room3CarolKs, id).says(hcNeedsYou, "pay")
  let aliceSeam = newFakePartSeam(ledger, "alice")
  discard liveConfirmParts(r.alice, aliceKs, splitFor, aliceSeam)
  doAssert liveConfirmPart(r.alice, aliceKs, splitFor, id, partName(carol), aliceSeam, "") == "final"
  for ks in [Keystore(aliceKs), bobKs, room3CarolKs, daveKs]:
    doAssert home(ks, id).says(hcSettled), "final is settled for everyone"
  echo "1b. a paid part waits; every part confirmed is settled for all OK"

  # on Alice's behalf: Carol proposes, Alice (the creditor) must agree; Bob declines
  let lunch = splitEffectJson(Chain, "ETH", "600", alice, AlicePayTo, evenShares("600", alice, @[bob, carol]), "Lunch")
  let id2 = liveProposeIntent(r.carol, room3CarolKs, splitFor, Policy, lunch, int64(Now), 2,
                              account = Chain & ":" & AlicePayTo, ttlSec = Ttl)
  doAssert home(aliceKs, id2).says(hcNeedsYou, "agree"), "the creditor is asked: " & $home(aliceKs, id2)
  doAssert home(room3CarolKs, id2).says(hcNeedsYou, "agree"), "proposing is not agreeing for a debtor"
  r.bob.publishAuthored(bobKs, declineEvent(id2, "0x" & bob))
  doAssert home(bobKs, id2).says(hcWaiting), "a member who declined is not asked again"
  echo "1c. on the creditor's behalf the creditor is asked; a decline is never asked again OK"

# ── 2. a room statement (threshold, final in the room) ───────────────────────────
block:
  var r = newRoom("/muster/1/home-threshold/proto")
  let id = r.propose("threshold", effectFor("threshold", 1))
  proc home(ks: Keystore): HomeItem =
    r.alice.poll(); r.bob.poll()
    homeFor(r.events(), liveDriverFor, ks, id)
  doAssert home(aliceKs).says(hcNeedsYou, "approve") and home(bobKs).says(hcNeedsYou, "approve")
  doAssert home(daveKs).says(hcWaiting), "not an endorser: never asked"
  discard r.approveAs("alice", id)
  doAssert home(aliceKs).says(hcWaiting) and home(bobKs).says(hcNeedsYou, "approve")
  discard r.approveAs("bob", id)
  doAssert home(aliceKs).says(hcSettled) and home(bobKs).says(hcSettled),
           "agreed and final in the room: settled — " & $home(aliceKs)
  echo "2. a room statement asks each endorser once, then is settled OK"

# ── 3. a Safe (finality outside the room) ────────────────────────────────────────
block:
  var r = newRoom("/muster/1/home-safe/proto")
  let id = r.propose("safe", effectFor("safe", 7))
  proc home(ks: Keystore): HomeItem =
    r.alice.poll(); r.bob.poll()
    homeFor(r.events(), liveDriverFor, ks, id)
  doAssert home(aliceKs).says(hcNeedsYou, "approve") and home(bobKs).says(hcNeedsYou, "approve")
  doAssert home(daveKs).says(hcWaiting), "not an owner: never asked to approve"
  discard r.approveAs("alice", id)
  discard r.approveAs("bob", id)
  doAssert home(aliceKs).says(hcNeedsYou, "submit"), "agreed, not yet on chain: " & $home(aliceKs)
  doAssert home(daveKs).says(hcNeedsYou, "submit"), "anyone in the room may settle an agreed intent"
  echo "3. a Safe asks its owners to approve, then the room to settle it OK"

# ── 4. mayContribute: each driver says from its own signer set; unknown is never yes ──
block:
  let names = myContributorNames(aliceKs)
  let daveNames = myContributorNames(daveKs)
  let statement = effectFromJson(effectFor("threshold", 1))
  let pay = effectFromJson(effectFor("safe", 1))
  doAssert safeDrv.mayContribute(pay, names) == elYes and safeDrv.mayContribute(pay, daveNames) == elNo
  doAssert thrDrv.mayContribute(statement, names) == elYes and thrDrv.mayContribute(statement, daveNames) == elNo
  let ps = newPersonalSignDriver(@[aliceKs.address()], 1)
  doAssert ps.mayContribute(statement, names) == elYes and ps.mayContribute(statement, daveNames) == elNo
  let alice = idHex(aliceKs)
  let bob = idHex(bobKs)
  let sd = newSplitDriver(EvmSplitFamily, "eip155:31337", @[alice, bob])
  let se = effectFromJson(splitEffectJson("eip155:31337", "ETH", "10", alice,
    "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", evenShares("10", alice, @[bob]), "x"))
  doAssert sd.mayContribute(se, names) == elYes, "the creditor"
  doAssert sd.mayContribute(se, myContributorNames(bobKs)) == elYes, "a debtor"
  doAssert sd.mayContribute(se, daveNames) == elNo, "not named"
  doAssert newStubDriver().mayContribute(statement, names) == elUnknown, "a driver that does not say: unknown"
  echo "4. mayContribute answers from each driver's own signer set; the default is unknown OK"

echo "home_needs_test: all OK"
