## Payments in flight are never forgotten while they might still land (exo-a90.23). Paying
## sends and returns; the "settled" report follows once the payment lands, so until then the
## log shows the part unpaid, and the host alone knows a payment is on its way (exo-a90.18).
## Before this, the host dropped a payment that had not landed by its seam's pay deadline —
## and forgot every one on a restart — so Pay sent the part again, and if the first still
## landed (a low-fee Bitcoin transaction, a stuck nonce) the share was paid twice. Held here:
##   * past its deadline a payment is UNRESOLVED, not dropped: still in flight, so paying
##     that part again answers "paying", and it is still watched (less often) — if it lands
##     late, its report is published as ever;
##   * it is released only when the chain says it can never land (the seam's partGone: a
##     transaction the node no longer knows whose coins went elsewhere, a nonce another
##     transaction used) or when it failed on chain — then the part may be paid again;
##   * the book survives a restart: it round-trips through its saved form, every field;
##   * a payment in one room never holds back another room's parts.

import std/[json, sequtils]
import ../src/intents/materialization
import ../src/coordination/parts
import ../src/coordination/pending_parts

proc pp(intent, part, tx: string): PendingPart =
  PendingPart(intentId: intent, part: part, tx: tx,
              transfer: PartTransfer(ok: true, chain: "eip155:31337", asset: "ETH", to: "0xabc", amount: "300"),
              spends: @["aa" & tx & ":0"])

var b: PendingBook
b.add("room-1", pp("0xsplit", "ed:bob", "0xt1"), nowS = 1000.0, deadlineS = 600.0)
doAssert b.inFlight("room-1").mapIt(it.tx) == @["0xt1"]
doAssert b.inFlight("room-2").len == 0, "another room's payment holds nothing back here"
echo "1. a payment sent is in flight, in its own room only OK"

# ── 2. past its deadline: unresolved, still in flight, still watched ──────────────────
block:
  doAssert b.due(1001.0) == @[0], "a fresh payment is checked every tick"
  discard b.record(0, crPending, 1001.0)
  discard b.record(0, crPending, 1000.0 + 601.0)
  doAssert b.entries.len == 1 and b.entries[0].unresolved, "past its deadline: unresolved, never dropped"
  doAssert b.inFlight("room-1").len == 1, "an unresolved payment is still in flight: never paid twice"
  doAssert b.due(1602.0).len == 0, "an unresolved payment is checked less often"
  doAssert b.due(1601.0 + UnresolvedCheckS + 1).len == 1, "but it is still checked"
  echo "2. past its deadline a payment is unresolved: still in flight, still watched OK"

# ── 3. it lands late: its report is published, and it leaves the book ─────────────────
block:
  var c = b
  let outcome = c.record(0, crLanded, 5000.0)
  doAssert outcome.len > 0 and c.entries.len == 0 and c.inFlight("room-1").len == 0
  echo "3. a payment that lands late is reported and leaves the book OK"

# ── 4. released only when the chain says it can never land, or it failed ─────────────
block:
  var c = b
  discard c.record(0, crPending, 6000.0)
  doAssert c.entries.len == 1, "not known to land and not known gone: kept"
  let gone = c.record(0, crGone, 7000.0)
  doAssert "never land" in gone and c.entries.len == 0 and c.inFlight("room-1").len == 0,
           "the chain says it can never land: the part may be paid again — " & gone
  var d = b
  let failed = d.record(0, crFailed, 7000.0)
  doAssert d.entries.len == 0 and failed.len > 0, "failed on chain: it moved nothing, so it may be paid again"
  echo "4. released only when the chain says it can never land, or it failed on chain OK"

# ── 5. the book survives a restart ─────────────────────────────────────────────────────
block:
  var c: PendingBook
  c.add("room-1", pp("0xsplit", "ed:bob", "0xt1"), 1000.0, 600.0)
  c.add("room-2", pp("0xother", "ed:carol", "0xt2"), 1100.0, 2100.0)
  discard c.record(0, crPending, 1700.0)          # the first is now unresolved
  let saved = $c.toJson()
  let back = bookFromJson(parseJson(saved))
  doAssert back.entries.len == 2
  doAssert back.entries[0] == c.entries[0] and back.entries[1] == c.entries[1], "every field, as it was"
  doAssert back.inFlight("room-1").len == 1 and back.inFlight("room-1")[0].spends == @["aa0xt1:0"]
  doAssert bookFromJson(parseJson("{}")).entries.len == 0 and bookFromJson(newJNull()).entries.len == 0,
           "nothing saved yet: an empty book"
  echo "5. the book round-trips through its saved form: a restart forgets nothing OK"

# ── 6. the fake ledger's word: a payment it dropped can never land ────────────────────
block:
  let l = newFakeLedger()
  let seam = newFakePartSeam(l, "bob")
  let t = PartTransfer(ok: true, chain: "eip155:31337", asset: "ETH", to: "0xabc", amount: "300")
  let sent = seam.sendPart(t)
  let p = PendingPart(intentId: "0xsplit", part: "ed:bob", tx: sent.tx, transfer: t)
  doAssert not seam.partGone(t, p).gone, "sent, not landed: it may still land"
  l.drop(sent.tx)
  doAssert seam.partGone(t, p).gone, "dropped: it can never land"
  let other = seam.sendPart(t)
  l.mine()
  doAssert not seam.partGone(t, PendingPart(tx: other.tx, transfer: t)).gone, "landed is never gone"
  doAssert not PartSeam().partGone(t, p).gone, "a seam that cannot tell never says gone"
  echo "6. partGone: only what the chain says can never land OK"

echo "pending_parts_test: all OK"
