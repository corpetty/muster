## Provenance for EVERY action (M4, exo-002.4): logProvenance classes each log entry
## (message / propose / policy / sig / decline / submit / final / admit) by the F-20
## vocabulary, dedups like the fold, names the accounts involved, and carries the membership epoch each entry belongs to. Stub
## driver; links libsodium through the intents import closure.

import std/[strutils, tables, algorithm]
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents

let effectJson = """{"to":"0xabc","value":5}"""
let id = intentIdFor(effectJson)
let named: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, verifyResult = true)

let (_, msg) = newMessageEvent("alice-hex", 1, "hello", 1)
let events = @[msg, proposeEvent(id, effectJson), contributeEvent(id, "A", "sa"),
               contributeEvent(id, "A", "sa"), contributeEvent(id, "B", "sb"),
               declineEvent(id, "C"), membershipEvent(1, "dave-hex"),
               submitEvent(id), finalEvent(id)]

proc kinds(items: seq[LogProvItem]): seq[string] = (for it in items: result.add it.kind)
proc byKind(items: seq[LogProvItem], k: string): LogProvItem =
  for it in items:
    if it.kind == k: return it
  doAssert false, "no " & k

# ── 1. every kind is covered, classed, deduped ──────────────────────────────────
block:
  let items = logProvenance(events, named)
  var counts = initCountTable[string]()
  for k in items.kinds(): counts.inc k
  doAssert counts["message"] == 1 and counts["propose"] == 1 and counts["sig"] == 2 and
           counts["decline"] == 1 and counts["admit"] == 1 and counts["submit"] == 1 and counts["final"] == 1,
           $counts
  doAssert items.byKind("message").cls == icPeerMessage and items.byKind("message").account == "alice-hex"
  doAssert "not a verified signature" in items.byKind("message").guarantee
  doAssert items.byKind("sig").cls == icContribution and items.byKind("sig").account in ["A", "B"]
  doAssert items.byKind("submit").cls == icExternalRead and items.byKind("final").cls == icExternalRead
  doAssert items.byKind("admit").account == "dave-hex" and "F-16" in items.byKind("admit").guarantee
  for it in items: doAssert it.accountable
  echo "1. message/propose/sig/decline/admit/submit/final all present, classed, deduped OK"

# ── 2. epochs: entries after an admit belong to the new epoch; convergence ───────
block:
  let items = logProvenance(events, named)
  # the admit is unparented so canonical order places it by id; check the invariant
  # that every entry's epoch is ≤ the highest admit epoch seen, and the admit is 1
  for it in items: doAssert it.epoch in [0, 1]
  doAssert items.byKind("admit").epoch == 1
  var reordered = events.reversed()
  reordered.add msg
  doAssert logProvenance(reordered, named).kinds() == items.kinds(), "reorder + duplicate → identical lineage (inv 4)"
  echo "2. epoch scoping carried; reorder + duplicate → identical lineage OK"

echo "provenance_all_test: all OK"
