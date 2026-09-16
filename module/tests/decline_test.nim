## Deny (exo-002.3): a decline event folds into the intent view and the activity feed,
## once per member, never touching the threshold; named under a named driver, a bare
## count under an anonymous one (invariant 9). Pure Nim (stub driver).

import std/[strutils, algorithm]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents

let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)

proc viewOf(events: seq[Event], driverFor: DriverFor): IntentView =
  for v in reduceIntentViews(events, driverFor):
    if v.id == id: return v
  doAssert false, "intent not folded"

# ── named driver: decliners are listed, dedup'd, sorted; threshold untouched ─────
block:
  let named: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, membership = mmNamed, verifyResult = true)
  var events = @[proposeEvent(id, effectJson), declineEvent(id, "bob"), declineEvent(id, "bob"),
                 declineEvent(id, "alice")]
  let v = viewOf(events, named)
  doAssert v.declines == 2 and v.decliners == @["alice", "bob"], $v.decliners
  doAssert v.state == "proposed" and v.approvals == 0, "a decline never moves the lifecycle"
  # approvals still complete regardless of declines (informational)
  events.add contributeEvent(id, "carol", "aa")
  events.add contributeEvent(id, "dave", "bb")
  doAssert viewOf(events, named).state == "executable"
  var sawDecline = 0
  for a in reduceActivity(events, named):
    if a.kind == "decline":
      inc sawDecline
      doAssert a.account in ["alice", "bob"] and a.title.startsWith("Declined by")
  doAssert sawDecline == 2, "one activity line per decline event that folded (dedup by member)"
  echo "1. named driver: decliners listed once each, sorted; threshold and lifecycle untouched OK"

# ── anonymous driver: a count only, no names anywhere ────────────────────────────
block:
  let anon: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, membership = mmAnonymous, verifyResult = true)
  let events = @[proposeEvent(id, effectJson), declineEvent(id, "nonce-1"), declineEvent(id, "nonce-2")]
  let v = viewOf(events, anon)
  doAssert v.declines == 2 and v.decliners.len == 0
  for a in reduceActivity(events, anon):
    if a.kind == "decline":
      doAssert a.account == "" and a.title == "A member declined"
  echo "2. anonymous driver: declines counted, nobody named (inv 9) OK"

# ── convergence: order and duplication do not change the view (inv 4) ───────────
block:
  let named: DriverFor = proc(kind: string): Driver =
    newStubDriver(rounds = 1, threshold = 2, membership = mmNamed, verifyResult = true)
  let a = @[proposeEvent(id, effectJson), declineEvent(id, "x"), contributeEvent(id, "y", "s")]
  var b = a.reversed()
  b.add declineEvent(id, "x")
  let va = viewOf(a, named)
  let vb = viewOf(b, named)
  doAssert va.declines == vb.declines and va.decliners == vb.decliners and va.state == vb.state
  echo "3. reorder + duplicate decline → identical view (inv 4) OK"

echo "decline_test: all OK"
