## exo-a5a — a k-of-n decision needs k DISTINCT signers, whatever names their
## contributions are published under.
##
## A contribution event is keyed intent/<id>/sig/<who>/<round>, and <who> is whatever
## string its publisher wrote: any member holding the epoch key can publish raw events.
## The fold deduped by that name and counted every contribution the driver accepted, and
## the driver accepts a valid signature from ANY eligible signer — so one member's single
## signature, published under two names, completed a 2-of-3 room decision alone. For a
## room policy the fold IS the outcome: a threshold statement, an invoke action
## (coordinate_execute runs it when executable), an add-driver (roomDriverKinds admits it).
##
## The rule this holds the fold and every view to: when the driver can identify who signed
## (identifyContributor ≠ ""), a contribution counts only under THAT signer's name; one
## published under anyone else's name is not their approval and is dropped — before
## dedup, so a forgery that arrives first cannot block the named member's own approval.
## A driver that cannot identify a signer (the stub) is taken at the key's name, and its
## own verifyContribution decides, as before.
##
## Needs $SECP + libsodium (tests/README.md; run-suite.sh supplies them).

import std/[algorithm, sequtils, strutils]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/drivers/safe
import ../src/crypto/curve25519
import ../src/crypto/secp256k1
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/attest

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc approvers(events: seq[Event], dfor: DriverFor, id: string): int =
  for v in reduceIntentViews(events, dfor):
    if v.id == id: return v.approvals
proc graded(events: seq[Event], dfor: DriverFor, id: string): seq[string] =
  for g in approvalGrades(events, dfor, id):
    if g.grade != agRejected: result.add g.who
  result.sort()

# ── a 2-of-3 room threshold (Ed25519 roster) ─────────────────────────────────────
let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let thr = newThresholdDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)
let thrFor: DriverFor = proc(kind: string): Driver = thr

const stmtJson = """{"effect":"statement","text":"we agree"}"""
let sid = intentIdFor(stmtJson, "threshold")
let sm = canonicalize(thr, effectFromJson(stmtJson))
let sigA = hx(edSign(a, sm.bytes))
let sigB = hx(edSign(b, sm.bytes))
let nameA = contributorOf(thr, stmtJson, sigA)     # the name the hosted path publishes under
let nameB = contributorOf(thr, stmtJson, sigB)
doAssert nameA.len > 0 and nameB.len > 0 and nameA != nameB, "the threshold driver identifies its signers"
let prop = @[policyDeclEvent(sid, "threshold"), proposeEvent(sid, stmtJson)]

# 1. The honest path: two members, each under their own name → executable.
block:
  let ev = prop & @[contributeEvent(sid, nameA, sigA), contributeEvent(sid, nameB, sigB)]
  doAssert intentState(ev, thrFor, sid) == "executable"
  doAssert approvers(ev, thrFor, sid) == 2 and graded(ev, thrFor, sid) == @[nameA, nameB].sorted()
  echo "1. two distinct signers under their own names -> executable OK"

# 2. THE BUG: A's one signature under A's name AND B's name → still ONE signer.
block:
  let ev = prop & @[contributeEvent(sid, nameA, sigA), contributeEvent(sid, nameB, sigA)]
  doAssert intentState(ev, thrFor, sid) == "collecting",
           "one signer's signature under two names must not complete a 2-of-3 (got " & intentState(ev, thrFor, sid) & ")"
  doAssert approvers(ev, thrFor, sid) == 1, "the card counts one approver, not two"
  doAssert graded(ev, thrFor, sid) == @[nameA], "only A approved"
  echo "2. one signature published under two names counts once -> collecting OK"

# 3. A contribution under a made-up name (not an identity at all) is nobody's approval.
block:
  let ev = prop & @[contributeEvent(sid, "somebody", sigA), contributeEvent(sid, "somebody-else", sigA)]
  doAssert intentState(ev, thrFor, sid) == "proposed", "misnamed contributions count for no one"
  doAssert approvers(ev, thrFor, sid) == 0
  echo "3. a signature under a name that is not its signer's counts for no one OK"

# 4. A forgery that arrives FIRST cannot block the named member's own approval.
block:
  let forged = contributeEvent(sid, nameB, sigA)   # A's signature, published as "B"
  for order in [prop & @[forged, contributeEvent(sid, nameA, sigA), contributeEvent(sid, nameB, sigB)],
                prop & @[contributeEvent(sid, nameB, sigB), forged, contributeEvent(sid, nameA, sigA)]]:
    doAssert intentState(order, thrFor, sid) == "executable", "B's genuine approval still counts"
    doAssert approvers(order, thrFor, sid) == 2 and graded(order, thrFor, sid) == @[nameA, nameB].sorted()
  echo "4. a forged contribution under B's name never blocks B's own OK"

# 5. Governance: one member cannot admit a driver kind alone.
block:
  const addJson = """{"effect":"add-driver","kind":"unanimous"}"""
  let gid = intentIdFor(addJson, "threshold")
  let gm = canonicalize(thr, effectFromJson(addJson))
  let ga = hx(edSign(a, gm.bytes))
  let ev = @[policyDeclEvent(gid, "threshold"), proposeEvent(gid, addJson),
             contributeEvent(gid, contributorOf(thr, addJson, ga), ga),
             contributeEvent(gid, contributorOf(thr, addJson, hx(edSign(b, gm.bytes))), ga)]
  doAssert "unanimous" notin roomDriverKinds(ev, thrFor), "one signer cannot grow the room's capabilities"
  echo "5. add-driver: one signer under two names admits nothing OK"

# 6. A chain driver (Safe, secp256k1 owners): the same rule holds.
block:
  var keys: seq[array[32, byte]]
  var owners: seq[Address]
  for k in 1 .. 3:
    var sk: array[32, byte]; sk[31] = byte(k)
    keys.add sk; owners.add addressOf(sk)
  var safeAddr: Address
  for i in 0 ..< 20: safeAddr[i] = byte(0x10 + i)
  let safe = newSafeDriver(chainId = 31337, safe = safeAddr, owners = owners, threshold = 2)
  let safeFor: DriverFor = proc(kind: string): Driver = safe
  const payJson = """{"to":"0x00112233445566778899aabbccddeeff00112233","value":1000,"nonce":0}"""
  let pid = intentIdFor(payJson)
  let pm = canonicalize(safe, effectFromJson(payJson))
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = pm.bytes[i]
  let s0 = hx(signRecoverable(h, keys[0]))
  let s1 = hx(signRecoverable(h, keys[1]))
  let n0 = contributorOf(safe, payJson, s0)
  let n1 = contributorOf(safe, payJson, s1)
  let base = @[proposeEvent(pid, payJson)]
  doAssert intentState(base & @[contributeEvent(pid, n0, s0), contributeEvent(pid, n1, s0)], safeFor, pid) == "collecting",
           "one owner's signature under two owners' names is one approval"
  doAssert intentState(base & @[contributeEvent(pid, n0, s0), contributeEvent(pid, n1, s1)], safeFor, pid) == "executable"
  echo "6. Safe: one owner under two owner names counts once; two owners -> executable OK"

# 7. Convergence (inv 4): the verdict is a function of the event SET.
block:
  let ev = prop & @[contributeEvent(sid, nameB, sigA), contributeEvent(sid, nameA, sigA),
                    contributeEvent(sid, nameB, sigB)]
  var shuffled = ev.reversed()
  shuffled.add ev[3]
  doAssert intentState(ev, thrFor, sid) == intentState(shuffled, thrFor, sid)
  doAssert approvers(ev, thrFor, sid) == approvers(shuffled, thrFor, sid)
  echo "7. reorder + duplicate -> identical verdict (inv 4) OK"

# 8. A driver that cannot identify a signer (the stub) is taken at the key's name, as before.
block:
  let stub = newStubDriver(rounds = 1, threshold = 2, verifyResult = true)
  let stubFor: DriverFor = proc(kind: string): Driver = stub
  let ev = prop & @[contributeEvent(sid, "alice", "aa"), contributeEvent(sid, "bob", "bb")]
  doAssert intentState(ev, stubFor, sid) == "executable", "an identity-blind driver keeps name-keyed counting"
  echo "8. an identity-blind driver keeps its name-keyed behaviour OK"

echo "distinct_signer_test: all OK"
