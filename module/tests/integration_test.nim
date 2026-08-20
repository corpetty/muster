## Integration (invariant 4): two peers exchange coordination events over an
## unreliable LOCAL transport and MUST converge — state = reduce(log), independent
## of delivery order or duplication. Uses the real log + reduce and the real stub
## driver + collection; nothing is mocked (working agreement: integration tests
## use the stub driver and local transport, never mock Driver or Transport).
##
## The logoscore-hosted two-instance version (`nix run .#integration`, two isolated
## --user-dir hosts) is the DEPLOYMENT e2e and needs the platform host; this is its
## dependency-free core, runnable anywhere. Pure Nim.

import std/algorithm
import ../src/log/log
import ../src/drivers/driver
from ../src/transport/infra import localState

# ── a small coordination session as a causal event DAG ──
#   root ──▶ {alice, bob} ──▶ ready   (a diamond: ordering + id tiebreak matter)
let root = Event(parents: @[], key: "session", value: "open")
let rid  = eventId(root)
let a    = Event(parents: @[rid], key: "party", value: "alice")
let b    = Event(parents: @[rid], key: "party", value: "bob")   # same key → LWW by canonical order
let aid  = eventId(a)
let bid  = eventId(b)
let done = Event(parents: @[aid, bid], key: "session", value: "ready")
let events = @[root, a, b, done]

# The one convergent state every honest peer must reach, whatever the wire did.
let canonical = stateDigest(reduce(events))

# ── peer A: in-order delivery ──
var A: Log
for e in events: A.ingest(e)
doAssert stateDigest(A.state) == canonical, "in-order peer must match canonical state"

# ── peer B: an unreliable local transport — reversed order + at-least-once dupes ──
var B: Log
var scrambled = events
reverse(scrambled)
for e in scrambled:
  B.ingest(e)
  B.ingest(e)                       # duplicate every delivery
B.ingest(root); B.ingest(done)      # a couple of extra out-of-band dupes
doAssert stateDigest(B.state) == canonical,
  "peer B converges under reorder + duplication"

# ── peer C: fully OFFLINE cold start — same event SET, no transport at all ──
doAssert localState(events) == canonical, "offline cold start reconstructs the state"

# ── a second, disjoint delivery permutation still converges ──
var D: Log
for e in [done, root, b, a, a, root]:   # another arbitrary order + dupes
  D.ingest(e)
doAssert stateDigest(D.state) == canonical, "a third permutation converges too"

# ── driver-collection integration: a stub driver closes a round at threshold ──
let drv = newStubDriver(rounds = 1, threshold = 2, verifyResult = true)
var col = startCollection(drv)
doAssert not col.complete
col.submit(drv, Contribution(bytes: @[1'u8]))
doAssert not col.complete, "one contribution is below threshold 2"
col.submit(drv, Contribution(bytes: @[2'u8]))
doAssert col.complete, "threshold reached → the round closes"

echo "integration: two peers converge over an unreliable local transport; ",
     "offline cold-start matches; stub-driver collection closes at threshold"
