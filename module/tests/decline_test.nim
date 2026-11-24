## Deny (exo-002.3): a decline event folds into the intent view and the activity feed,
## once per member, never touching the threshold, naming who declined. Pure Nim
## (stub driver).

import std/[strutils, algorithm]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents
import ../src/crypto/curve25519
import ./probes/attested

let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)

# The stub here is a room family (immediate finality), so an approval counts only with its
# signer's attestation over P (exo-af5): the approvers are real Ed25519 keys, attested
# the way the live path attests them.
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc edName(k: EncKeys): string =
  const d = "0123456789abcdef"
  result = "ed:"
  for x in k.identity().ed: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let carol = encFromSeed(seed(3))
let dave = encFromSeed(seed(4))
let yan = encFromSeed(seed(5))

proc viewOf(events: seq[Event], driverFor: DriverFor): IntentView =
  for v in reduceIntentViews(events, driverFor):
    if v.id == id: return v
  doAssert false, "intent not folded"

# ── named driver: decliners are listed, dedup'd, sorted; threshold untouched ─────
block:
  let named: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, verifyResult = true)
  var events = @[proposeEvent(id, effectJson), declineEvent(id, "bob"), declineEvent(id, "bob"),
                 declineEvent(id, "alice")]
  let v = viewOf(events, named)
  doAssert v.declines == 2 and v.decliners == @["alice", "bob"], $v.decliners
  doAssert v.state == "proposed" and v.approvals == 0, "a decline never moves the lifecycle"
  # approvals by others still complete: "bob" and "alice" here are no member's identity, so
  # the driver names neither as a signer (a real decliner's own approval is void:
  # decline_final_test)
  events.add contributeEvent(id, edName(carol), "aa")
  events.add contributeEvent(id, edName(dave), "bb")
  events = withAttestations(events, named, id, signers = [carol, dave])
  doAssert viewOf(events, named).state == "executable"
  var sawDecline = 0
  for a in reduceActivity(events, named):
    if a.kind == "decline":
      inc sawDecline
      doAssert a.account in ["alice", "bob"] and a.title.startsWith("Declined by")
  doAssert sawDecline == 2, "one activity line per decline event that folded (dedup by member)"
  echo "1. named driver: decliners listed once each, sorted; threshold and lifecycle untouched OK"

# ── convergence: order and duplication do not change the view (inv 4) ───────────
block:
  let named: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, verifyResult = true)
  let a = withAttestations(@[proposeEvent(id, effectJson), declineEvent(id, "x"),
                             contributeEvent(id, edName(yan), "s")], named, id, signers = [yan])
  var b = a.reversed()
  b.add declineEvent(id, "x")
  let va = viewOf(a, named)
  let vb = viewOf(b, named)
  doAssert va.declines == vb.declines and va.decliners == vb.decliners and va.state == vb.state
  echo "2. reorder + duplicate decline → identical view (inv 4) OK"

echo "decline_test: all OK"
