## The multi-party fold, run with a NON-Safe driver — the proof that the fold is
## driver-generic (not just typed that way). A threshold driver (Ed25519 k-of-n)
## folds the same intent lifecycle to `executable`: k distinct roster endorsements
## complete it, a non-member's endorsement never counts. Same reduceIntents, same
## reduce(log), no Safe, no secp. Needs libsodium (Ed25519). See tests/README.md.

import std/[strutils, tables]
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/threshold
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/intents

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(sig: Ed25519Sig): string =
  const d = "0123456789abcdef"
  for b in sig: (result.add d[int(b shr 4)]; result.add d[int(b and 0x0F)])

# A 3-member roster, threshold 2. Members A/B are in it; Mallory is not.
let a = encFromSeed(seed(1))
let b = encFromSeed(seed(2))
let c = encFromSeed(seed(3))
let mal = encFromSeed(seed(9))
let drv = newThresholdDriver(@[a.identity().ed, b.identity().ed, c.identity().ed], k = 2)

const effectJson = """{"to":"0x1111111111111111111111111111111111111111","value":1000,"nonce":0}"""
let id = intentIdFor(effectJson)
# What roster members sign: the intent's materialization (base dCBOR — this driver
# does not override canonicalize), exactly what reduceIntents will verify against.
let m = canonicalize(drv, effectFromJson(effectJson))
proc endorse(k: EncKeys): string = hex(edSign(k, m.bytes))

# Propose, then one endorsement → collecting (1 of 2).
var events = @[proposeEvent(id, effectJson), contributeEvent(id, "A", endorse(a))]
doAssert intentState(events, drv, id) == "collecting",
         "one roster endorsement -> collecting"
echo "1. propose + one endorsement -> collecting OK"

# A second distinct endorsement → executable (threshold met), through the SAME
# generic reduceIntents — no Safe, no secp.
events.add contributeEvent(id, "B", endorse(b))
doAssert intentState(events, drv, id) == "executable",
         "two distinct roster endorsements -> executable"
echo "2. two endorsements -> executable (generic fold, non-Safe driver) OK"

# 2b. The RENDER path is generic too — reduceIntentViews + intentProvenance (what
#     the UI draws) fold this non-Safe intent with NO Safe assumptions: the
#     threshold k comes from describe(), the materialization is re-derived
#     (base dCBOR, no EIP-712), the endorsers are named as `ed:` roster keys, and
#     the lineage is one peer-message propose + k driver-contributions.
block:
  # Key contributions the way the hosted contribute does — by the identified
  # endorser (contributorOf → "ed:<pubkey>"), not an arbitrary label — so the
  # render names the real member.
  let sigA = endorse(a)
  let sigB = endorse(b)
  let revents = @[proposeEvent(id, effectJson),
                  contributeEvent(id, contributorOf(drv, effectJson, sigA), sigA),
                  contributeEvent(id, contributorOf(drv, effectJson, sigB), sigB)]
  let views = reduceIntentViews(revents, drv)
  doAssert views.len == 1, "one intent"
  let v = views[0]
  doAssert v.state == "executable", "render view state matches the fold"
  doAssert v.approvals == 2, "two distinct roster endorsements counted"
  # The "bytes you'd sign" are driver-described: Safe's is the 32-byte safeTxHash,
  # this driver's is the base dCBOR materialization (variable length). Generic check
  # is well-formed, non-empty hex — the length is the driver's business, not ours.
  doAssert v.txhash.len > 2 and v.txhash.startsWith("0x"),
           "the materialization is re-derived generically (no Safe, no secp)"
  let prov = intentProvenance(revents, drv, id)
  var proposes = 0
  var endorsers: seq[string]
  for it in prov:
    doAssert it.accountable, "every input in a live fold is accountable"
    if it.cls == icPeerMessage: inc proposes
    elif it.cls == icContribution:
      doAssert it.account.startsWith("ed:"),
               "the threshold driver names the Ed25519 endorser (mmNamed)"
      endorsers.add it.account
  doAssert proposes == 1, "one propose (peer message)"
  doAssert endorsers.len == 2 and endorsers[0] != endorsers[1],
           "two distinct endorsers in the lineage"
echo "2b. render path generic (views + provenance) with the threshold driver OK"

# A non-roster endorsement never counts toward the threshold.
var ev2 = @[proposeEvent("2", effectJson),
            contributeEvent("2", "A", endorse(a)),
            contributeEvent("2", "mallory", endorse(mal))]
doAssert intentState(ev2, drv, "2") != "executable",
         "a non-member endorsement must not reach the threshold"
echo "3. non-member endorsement refused OK"

# 4. A SECOND effect type — a statement the room ratifies, not a payment — folds
#    through the SAME path. The ACTION is pluggable, not just the policy: the
#    statement selects its own schema, so its materialization differs from a
#    transfer's (a statement endorsement can never be reinterpreted as a payment,
#    F-5), and k endorsements still reach executable under the same threshold fold.
block:
  const stmtJson = """{"effect":"statement","text":"We ratify the treasury plan."}"""
  let te = effectFromJson(effectJson)
  let se = effectFromJson(stmtJson)
  doAssert te.schemaId == "muster.effect.transfer.v1", "default is a transfer"
  doAssert se.schemaId == "muster.effect.statement.v1", "the statement selects its own schema"
  let sm = canonicalize(drv, se)
  doAssert sm.bytes != canonicalize(drv, te).bytes,
           "a statement materialization differs from a transfer's (schema-bound)"
  let sid = intentIdFor(stmtJson)
  proc endorseS(k: EncKeys): string = hex(edSign(k, sm.bytes))
  let sa = endorseS(a)
  let sb = endorseS(b)
  let sevents = @[proposeEvent(sid, stmtJson),
                  contributeEvent(sid, contributorOf(drv, stmtJson, sa), sa),
                  contributeEvent(sid, contributorOf(drv, stmtJson, sb), sb)]
  doAssert intentState(sevents, drv, sid) == "executable",
           "a statement effect folds to executable under the same threshold path"
echo "4. a second effect type (statement) folds through the same path OK"

# 5. The room's policy is DECLARED IN THE LOG and converges: a policy event's kind
#    folds out, and a later event (greater ts) wins — so members agree on the driver
#    and a policy change is just a later event (the honest core of driver-as-proposal).
block:
  var pevents: seq[Event]
  doAssert activePolicyKind(pevents) == "safe", "no policy event -> default safe"
  pevents.add policyEvent("threshold", 100)
  doAssert activePolicyKind(pevents) == "threshold", "the policy event's kind folds out"
  pevents.add policyEvent("safe", 200)
  doAssert activePolicyKind(pevents) == "safe", "a later policy (greater ts) wins"
  pevents.add policyEvent("threshold", 150)   # earlier than the safe@200
  doAssert activePolicyKind(pevents) == "safe", "an earlier policy does not override a later one"
echo "5. log-declared policy folds, latest wins (convergent) OK"

echo "threshold_fold_test: all OK"
