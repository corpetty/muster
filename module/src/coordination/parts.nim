## Paying and confirming a part (exo-a90.4; docs/design/split-the-bill.md §4.4–§4.5) — the
## live path of a family that settles in parts, the split first.
##
## A debtor pays their own share from their own wallet, and the creditor's client confirms
## it from its own read. Like voting (vote.nim), each step is split in two so a hosted call
## never waits on a block (exo-3c9):
##
##   pay     liveSettlePartSend      the gates, the transfer DERIVED from the agreed effect,
##                                   sent through the payer's own wallet (the PartSeam)
##           liveSettlePartComplete  "unconfirmed: …" until the payer's own transfer landed;
##                                   then the author-signed "settled" report
##   confirm liveConfirmPart         the creditor's own read of one reported transfer — or,
##                                   with no reference, "received outside muster"
##           liveConfirmParts        the creditor's pump over every open part (the intents tick)
##
## Invariant 1 on the payment: the transfer comes from `Driver.partTransfer` over the
## effect in the LOG for this intent id — the materialization every debtor signed — and
## nothing a caller passes. Invariant 2: paying against an expired agreement is refused (a
## confirmation is not: money received late is still received). Invariant 9: a report is
## published only by its author (authorship.nim), and the fold counts only the author the
## driver allows. One transaction settles at most one part: the creditor's client refuses
## a reference it already confirmed for another part in this room.

import std/[json, strutils, sets, tables]
import ../log/log
import ../crypto/keystore
import ../crypto/curve25519
import ../drivers/driver
import ../drivers/kinds       # supported()
import ../intents/materialization
import ./session
import ./authorship
import ./intents
import ./attest

# ── the seam: a member's access to the chain their part settles on ────────────────
type PartSeam* = ref object of RootObj
  ## What paying and confirming a part needs from a chain: send from this member's own
  ## wallet, see that transfer land, and — for the counterparty — read whether a reported
  ## transfer pays a part exactly. The member's own keys and infrastructure (invariants 3, 8).

method sendPart*(s: PartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] {.base.} =
  (false, "", "this seam sends nothing")
method partLanded*(s: PartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] {.base.} =
  (false, "this seam reads nothing")
method checkReceived*(s: PartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] {.base.} =
  (false, "this seam reads nothing")

method matchReceived*(s: PartSeam, t: PartTransfer, reported: string,
                      claimed: HashSet[string]): tuple[ok: bool, reference, detail: string] {.base.} =
  ## The reference that proves the counterparty received `t` — what its "confirmed" report
  ## carries, and what one-reference-one-part dedups on (`claimed`: every reference already
  ## confirmed in this room, lowercased). Default: the transaction the party reported,
  ## checked by this member's own read (a public rail looks a payment up by its hash). A
  ## seam whose chain cannot — a private rail names no payer — overrides it to find an
  ## unclaimed receipt of exactly the part instead (parts_lez.nim).
  let got = s.checkReceived(t, reported)
  if got.ok: (true, reported, "") else: (false, "", got.detail)

method landedRef*(s: PartSeam, t: PartTransfer, tx: string): string {.base.} =
  ## The reference the payer's "settled" report carries once `tx` landed. Default: `tx`
  ## itself. A seam whose send returns a marker before the chain has answered (a proof
  ## running in the background) overrides it with the chain's own transaction reference.
  tx

method payDeadlineS*(s: PartSeam): float {.base.} =
  ## How long an in-flight payment may take to land before the host stops waiting for it.
  ## A seam that proves (minutes) overrides it with more than its proving budget.
  600.0

# ── helpers ────────────────────────────────────────────────────────────────────
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc myIdentity*(ks: Keystore): string = hx(ks.encIdentity().toBytes())
  ## This member's room identity, as a part report's author names it.
proc myPartName*(ks: Keystore): string = "ed:" & hx(ks.encIdentity().ed)
  ## This member's name as a party (the convention every room-key driver uses).

proc normRef(tx: string): string = tx.strip().toLowerAscii()

proc viewOf(events: seq[Event], driverFor: DriverFor, intentId: string): tuple[found: bool, v: IntentView] =
  for v in reduceIntentViews(events, driverFor):
    if v.id == intentId: return (true, v)

proc partViewOf(v: IntentView, part: string): tuple[found: bool, p: PartView] =
  for p in v.parts:
    if p.part == part: return (true, p)

proc confirmedRefs(events: seq[Event], driverFor: DriverFor): HashSet[string] =
  ## Every transaction reference already confirmed for some part in this room.
  for v in reduceIntentViews(events, driverFor):
    for p in v.parts:
      if p.confirmed and p.tx.len > 0: result.incl normRef(p.tx)

# ── paying my part ─────────────────────────────────────────────────────────────
type PendingPart* = object
  ## A part's transfer sent and not yet landed: what completing it publishes.
  intentId*: string
  part*: string
  tx*: string
  transfer*: PartTransfer

proc liveSettlePartSend*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                         seam: PartSeam, nowSec: uint64): tuple[outcome: string, pending: PendingPart] =
  ## Pay MY part of an agreed intent from my own wallet. outcome "" = sent (pending holds
  ## what completion needs), else a refusal with nothing sent or published: unknown-intent,
  ## unsupported-driver, not-in-parts, not-a-party, not-agreed, already-settled, no-context,
  ## expired, "refused: …".
  s.poll()
  let events = s.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return ("unknown-intent", PendingPart())
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return ("unsupported-driver", PendingPart())
  let effect = effectFromJson(effectJson)
  let parts = drv.settlementParts(effect)
  if parts.len == 0: return ("not-in-parts", PendingPart())
  let me = myPartName(ks)
  if me notin parts: return ("not-a-party", PendingPart())
  let (found, v) = viewOf(events, driverFor, intentId)
  if not found or v.state notin ["executable", "submitted", "settling"]:
    return ((if found and v.state == "final": "already-settled" else: "not-agreed"), PendingPart())
  let (_, mine) = partViewOf(v, me)
  if mine.settled: return ("already-settled", PendingPart())
  let ctx = intentContext(events, intentId)
  if ctx.isPlaceholder: return ("no-context", PendingPart())
  if ctx.expired(nowSec): return ("expired", PendingPart())
  # invariant 1: the payment is the driver's reading of the AGREED effect — never supplied
  let t = drv.partTransfer(effect, me)
  if not t.ok: return ("refused: " & t.error, PendingPart())
  let sent = seam.sendPart(t)
  # the wallet refused to send (a rail it will not take, no note that covers it, a scan
  # still catching up) or the chain did: either way nothing was sent, and the detail says why
  if not sent.ok: return ("refused: the payment was not sent: " & sent.detail, PendingPart())
  ("", PendingPart(intentId: intentId, part: me, tx: sent.tx, transfer: t))

proc liveSettlePartComplete*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: PartSeam,
                             pp: PendingPart): string =
  ## "unconfirmed: …" (nothing published) until my own transfer landed; then my
  ## author-signed "settled" report, and the intent's state.
  let landed = seam.partLanded(pp.transfer, pp.tx)
  if not landed.ok: return "unconfirmed: " & landed.detail
  s.poll()
  s.publishAuthored(ks, partEvent(pp.intentId, pp.part, "settled", myIdentity(ks),
                                  seam.landedRef(pp.transfer, pp.tx)))
  intentState(s.roomEvents(), driverFor, pp.intentId)

proc liveSettlePart*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                     seam: PartSeam, nowSec: uint64): string =
  ## Send, then complete, back to back (a seam whose transfers land at once).
  let (outcome, pp) = liveSettlePartSend(s, ks, driverFor, intentId, seam, nowSec)
  if outcome.len > 0: return outcome
  liveSettlePartComplete(s, ks, driverFor, seam, pp)

# ── confirming a part (the counterparty) ─────────────────────────────────────────
proc liveConfirmPart*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId, part: string,
                      seam: PartSeam, tx: string): string =
  ## As the counterparty, confirm `part`. With a reported reference, only after MY OWN read
  ## shows the part received exactly (the seam's matchReceived — the reported transaction on
  ## a public rail, an unclaimed note of exactly the share on a private one) — and never a
  ## reference already confirmed for another part. With none, the part was received outside
  ## muster: my word, stated as such. Returns the intent's state, or a refusal with nothing
  ## published.
  s.poll()
  let events = s.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return "unknown-intent"
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return "unsupported-driver"
  let effect = effectFromJson(effectJson)
  if part notin drv.settlementParts(effect): return "not-a-part"
  let confirmer = drv.partAuthor(effect, part, "confirmed")
  if confirmer.len == 0 or confirmer.toLowerAscii() != myIdentity(ks): return "not-the-counterparty"
  let (found, v) = viewOf(events, driverFor, intentId)
  if not found or v.state notin ["executable", "submitted", "settling"]:
    return (if found and v.state == "final": "already-confirmed" else: "not-agreed")
  if partViewOf(v, part).p.confirmed: return "already-confirmed"
  var reference = ""                   # "" = received outside muster: my word, shown as such
  if tx.len > 0:
    let claimed = confirmedRefs(events, driverFor)
    if normRef(tx) in claimed:
      return "refused: that payment already settled another share"
    let t = drv.partTransfer(effect, part)
    if not t.ok: return "refused: " & t.error
    let got = seam.matchReceived(t, tx, claimed)
    if not got.ok: return "unconfirmed: " & got.detail
    reference = got.reference
  s.publishAuthored(ks, partEvent(intentId, part, "confirmed", myIdentity(ks), reference))
  intentState(s.roomEvents(), driverFor, intentId)

proc liveConfirmParts*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: PartSeam): seq[string] =
  ## The counterparty's pump (the intents tick): every part reported settled with a
  ## reference, not yet confirmed, of an intent I am the counterparty of — confirmed when my
  ## own read shows it. Returns "<intent>/<part>" for each confirmed now.
  s.poll()
  let events = s.roomEvents()
  let me = myIdentity(ks)
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0 or v.state notin ["submitted", "settling"]: continue
    let drv = driverFor(v.policy)
    let effect = effectFromJson(v.effectJson)
    for p in v.parts:
      if not p.settled or p.confirmed or p.tx.len == 0: continue
      if drv.partAuthor(effect, p.part, "confirmed").toLowerAscii() != me: continue
      if liveConfirmPart(s, ks, driverFor, v.id, p.part, seam, p.tx) in
         ["submitted", "settling", "final"]:
        result.add v.id & "/" & p.part

# ── a ledger in memory: the no-chain seam tests and demos use ──────────────────────
type
  FakeTransfer* = object
    transfer*: PartTransfer
    payer*: string
    tx*: string
    landed*: bool

  FakeLedger* = ref object
    ## One pretend chain every member's seam shares: sends are recorded, and land when mined.
    sent*: seq[FakeTransfer]

  FakePartSeam* = ref object of PartSeam
    ledger*: FakeLedger
    payer*: string

proc newFakeLedger*(): FakeLedger = FakeLedger()
proc newFakePartSeam*(ledger: FakeLedger, payer: string): FakePartSeam =
  FakePartSeam(ledger: ledger, payer: payer)

proc mine*(l: FakeLedger) =
  ## Every sent transfer lands.
  for t in l.sent.mitems: t.landed = true

proc find(l: FakeLedger, tx: string): int =
  for i, t in l.sent:
    if t.tx == tx: return i
  -1

method sendPart*(s: FakePartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  let tx = "0xfake" & $(s.ledger.sent.len + 1)
  s.ledger.sent.add FakeTransfer(transfer: t, payer: s.payer, tx: tx)
  (true, tx, "")

method partLanded*(s: FakePartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  let i = s.ledger.find(tx)
  if i < 0: return (false, "no transfer " & tx)
  if not s.ledger.sent[i].landed: return (false, tx & " has not landed yet")
  (true, "")

method checkReceived*(s: FakePartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  ## The ledger's own record of `tx` against the part: landed, on the chain, the asset, the
  ## address and the amount — each mismatch named.
  let i = s.ledger.find(tx)
  if i < 0: return (false, "no transfer " & tx & " on the ledger")
  let got = s.ledger.sent[i]
  if not got.landed: return (false, tx & " has not landed yet")
  if got.transfer.chain != t.chain: return (false, tx & " is on " & got.transfer.chain & ", the part settles on " & t.chain)
  if got.transfer.asset != t.asset: return (false, tx & " pays " & got.transfer.asset & ", the part is in " & t.asset)
  if got.transfer.to.toLowerAscii() != t.to.toLowerAscii(): return (false, tx & " pays " & got.transfer.to & ", not " & t.to)
  if got.transfer.amount != t.amount:
    return (false, tx & " pays the amount " & got.transfer.amount & "; the share is " & t.amount)
  (true, "")
