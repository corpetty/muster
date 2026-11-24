## A decline is final (exo-720, the operator's Part A review 2026-10-11): a member who
## declined does not approve, and a proposal too many of its possible signers declined is
## declined. Before, a decline was informational: the card showed "2 declined: Bob, you" and
## still offered Approve, and approvals after it counted.
##
##   1. a decliner's approval counts toward nothing, whichever arrived first, and the card's
##      approval count agrees with the fold;
##   2. a 2-of-3 is declined once two of its signers declined; one decline leaves it open;
##   3. a decline by someone the driver does not name as a signer closes nothing;
##   4. once the room has submitted, a decline that raced it changes nothing;
##   5. an approval by a secp key is the decliner's only through a binding that key signed:
##      nobody voids another's approval by binding that person's address to themselves.
## Order-free throughout (invariant 4): every check runs on the events and their reverse.

import std/[algorithm, tables]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/crypto/curve25519
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/log/log
import ../src/coordination/intents
import ./probes/attested

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let thr = newThresholdDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)
let thrFor: DriverFor = proc(kind: string): Driver = thr

const stmtJson = """{"effect":"statement","text":"we agree"}"""
let sid = intentIdFor(stmtJson, "threshold")
let sm = canonicalize(thr, effectFromJson(stmtJson))
proc approval(k: EncKeys): Event =
  let sig = hx(edSign(k, sm.bytes))
  contributeEvent(sid, contributorOf(thr, stmtJson, sig), sig)
proc decline(k: EncKeys): Event = declineEvent(sid, hx(k.identity().toBytes()))
let prop = @[policyDeclEvent(sid, "threshold"), proposeEvent(sid, stmtJson)]

# Folded as the live path leaves it: the threshold driver is room-bound, so every approval
# carries its signer's attestation over P (exo-af5).
proc att(ev: seq[Event]): seq[Event] = withAttestations(ev, thrFor, sid, signers = [a, b, c])
proc view(ev: seq[Event]): IntentView =
  for v in reduceIntentViews(att(ev), thrFor):
    if v.id == sid: return v
  doAssert false, "not folded"
proc both(ev: seq[Event], check: proc(v: IntentView)) =
  check(view(ev))
  check(view(ev.reversed()))

# ── 1. a decliner's approval counts toward nothing ──────────────────────────────
both(prop & @[approval(a), approval(b), decline(b)], proc(v: IntentView) =
  doAssert v.approvals == 1, "Bob declined: his approval is not counted (" & $v.approvals & ")"
  doAssert v.state == "collecting", "one approval of two: still collecting, not " & v.state)
both(prop & @[decline(b), approval(b), approval(a)], proc(v: IntentView) =
  doAssert v.approvals == 1 and v.state == "collecting", "approving after declining counts for nothing")
echo "1. a decliner's approval counts toward nothing, in either order OK"

# ── 2. declined once too many signers declined ──────────────────────────────────
both(prop & @[decline(b)], proc(v: IntentView) =
  doAssert v.state == "proposed", "one decline of three: two can still approve, not " & v.state)
both(prop & @[decline(b), decline(c)], proc(v: IntentView) =
  doAssert v.state == "declined", "two of three declined: 2 of 3 is out of reach, not " & v.state)
both(prop & @[approval(a), decline(b), decline(c)], proc(v: IntentView) =
  doAssert v.state == "declined", "one approval, two declines: declined, not " & v.state)
doAssert intentState(att(prop & @[decline(b), decline(c), approval(a), approval(b)]), thrFor, sid) == "declined",
  "a declined proposal stays declined: a decliner's later approval changes nothing"
echo "2. declined once two of three signers declined; one decline leaves it open OK"

# ── 3. a non-signer's decline closes nothing ────────────────────────────────────
let outsider = encFromSeed(seed(9))
both(prop & @[decline(outsider), decline(b)], proc(v: IntentView) =
  doAssert v.state == "proposed", "an outsider and one signer declined: still open, not " & v.state
  doAssert v.declines == 2, "both declines are still listed")
echo "3. a decline by someone who is not a signer closes nothing OK"

# ── 4. a decline that raced a submit changes nothing ────────────────────────────
both(prop & @[approval(a), approval(b), submitEvent(sid), decline(b), decline(c)], proc(v: IntentView) =
  doAssert v.approvals == 2, "after the room submitted, Bob's approval still counts"
  doAssert v.state != "declined", "a submitted intent is not declined by a late decline")
echo "4. once submitted, a decline changes nothing OK"

# ── 5. only a binding the key itself signed ties an address to a decliner ───────
block:
  let bobKs = newInMemoryKeystore(seed(0x22), seed(2))     # Bob's chat key is b
  let malKs = newInMemoryKeystore(seed(0x23), seed(4))
  let bobAddr = "0x" & hx(bobKs.address())
  let ctx = LinkContext(account: "intent", slot: "0", expiry: high(uint64))
  # Bob's own binding: his key, his identity → his address is his
  let genuine = keyBindingEvent(sid, bobAddr, hx(encodeLink(bobKs.bindingFor(ctx))))
  # Mallory publishes HER binding under Bob's address, hoping to void Bob's approval by declining
  let forged = keyBindingEvent(sid, bobAddr, hx(encodeLink(malKs.bindingFor(ctx))))
  let malDecline = declineEvent(sid, hx(malKs.encIdentity().toBytes()))
  let fold = declineFold(@[forged, malDecline])
  doAssert not voidedByDecline(fold, sid, bobAddr), "a binding Bob's key did not sign ties nothing to Mallory"
  let bobDecline = declineEvent(sid, hx(bobKs.encIdentity().toBytes()))
  doAssert voidedByDecline(declineFold(@[genuine, bobDecline]), sid, bobAddr),
    "Bob's own binding ties his address to his decline"
  doAssert voidedByDecline(declineFold(@[genuine, bobDecline].reversed()), sid, bobAddr), "in either order"
  doAssert not voidedByDecline(declineFold(@[genuine, bobDecline, submitEvent(sid)]), sid, bobAddr),
    "after a submit, nothing is voided"
echo "5. an address is a decliner's only through a binding its own key signed OK"

echo "decline_final_test: all OK"
