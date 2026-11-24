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

import std/[json, os, sequtils, strutils, sets, tables]
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
import ./covers      # a part another intent settles is paid through it, never directly (exo-3c6)

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

type PendingPart* = object
  ## A part's transfer sent and not yet landed: what completing it publishes.
  intentId*: string
  part*: string
  tx*: string
  transfer*: PartTransfer
  spends*: seq[string]      ## what the payment consumed that another can't — Bitcoin "txid:vout"
                            ## — so the chain can tell whether it may still land (exo-a90.23)

method lastSpends*(s: PartSeam): seq[string] {.base.} =
  ## What the last sendPart consumed that no other payment can (a Bitcoin payment's coins,
  ## "txid:vout"), kept with it so partGone can ask about them later — after a restart too.
  @[]

method partGone*(s: PartSeam, t: PartTransfer, pp: PendingPart): tuple[gone: bool, detail: string] {.base.} =
  ## Whether the chain says the payment `pp` can never land, so paying the part again cannot
  ## pay it twice (exo-a90.23). A seam that cannot tell never says gone: its payment stays
  ## in flight until it lands or fails.
  (false, "this rail cannot tell whether " & pp.tx & " may still land")

method notePayment*(s: PartSeam, intentId, part, memo: string) {.base.} =
  ## What the next sendPart pays for, before it is sent: a seam that asks someone else to
  ## send (tx_sender_module, exo-d4d.5) names it to the person approving. Default: nothing.
  discard

method confirmsUnreported*(s: PartSeam): bool {.base.} =
  ## Whether the counterparty's own read finds a payment with no reference from its payer:
  ## a rail where the payer pays outside muster and the counterparty's wallet history is
  ## what proves it (Monero, exo-dcc.5). The pump then reads for every unconfirmed part,
  ## reported or not, and a payer's report never decides anything. Default: no — a public
  ## rail looks up the transaction the payer reported.
  false

method observe*(s: PartSeam, events: seq[Event], driverFor: DriverFor) {.base.} =
  ## What the room's log says that this seam's reads depend on, given before a confirm reads.
  ## A seam that confirms from its own wallet history overrides it to learn which receive
  ## addresses more than one part is paid at (Monero, where a part alone at its subaddress
  ## may arrive in several transfers). Default: nothing.
  discard

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

proc isLowerHex64(h: string): bool = h.len == 64 and h.allCharsInSet({'0'..'9', 'a'..'f'})

proc canonicalRefRefusal*(chain, reference: string): string =
  ## Why `reference` is not the one spelling of a transaction reference on `chain`'s rail ("" =
  ## it is), exo-3b3.14: an EVM transaction hash is 0x + 64 lowercase hex; a Bitcoin or Monero
  ## txid is 64 lowercase hex — several comma-joined for a Monero part that arrived in more
  ## than one transfer. A reference is reported, confirmed and deduplicated only in its one
  ## spelling, so an RPC that reads other spellings of a hash as the same transaction cannot
  ## make one payment settle two parts. Other rails (LEZ: a zone transaction, a note hash)
  ## keep their own forms.
  if chain.startsWith("eip155:"):
    if not (reference.startsWith("0x") and isLowerHex64(reference[2 .. ^1])):
      return "an Ethereum transaction hash is 0x and 64 lowercase hex digits, not '" & reference & "'"
  elif chain.startsWith("bip122:"):
    if not isLowerHex64(reference):
      return "a Bitcoin txid is 64 lowercase hex digits, not '" & reference & "'"
  elif chain.startsWith("monero:"):
    for r in reference.split(','):
      if not isLowerHex64(r): return "a Monero txid is 64 lowercase hex digits, not '" & r & "'"
  ""

proc normRef(tx: string): string =
  ## The key one reference deduplicates under: lowercase, and a 32-byte hash without its 0x,
  ## so every spelling of one hash is one key, whichever rail wrote it.
  result = tx.strip().toLowerAscii()
  if result.startsWith("0x") and isLowerHex64(result[2 .. ^1]): result = result[2 .. ^1]

proc refsOf*(reference: string): seq[string] =
  ## The transfers one confirmation reference names: one, or several comma-joined, as a
  ## Monero part that arrived in more than one transfer is confirmed by all of them.
  for r in reference.split(','):
    let n = normRef(r)
    if n.len > 0: result.add n

proc viewOf(events: seq[Event], driverFor: DriverFor, intentId: string): tuple[found: bool, v: IntentView] =
  for v in reduceIntentViews(events, driverFor):
    if v.id == intentId: return (true, v)

proc partViewOf(v: IntentView, part: string): tuple[found: bool, p: PartView] =
  for p in v.parts:
    if p.part == part: return (true, p)

proc confirmedRefs*(events: seq[Event], driverFor: DriverFor): HashSet[string] =
  ## Every transaction reference already confirmed for some part in this room.
  for v in reduceIntentViews(events, driverFor):
    for p in v.parts:
      if p.confirmed and p.tx.len > 0:
        for r in refsOf(p.tx): result.incl r

proc reportedRefs(events: seq[Event], driverFor: DriverFor): Table[string, seq[tuple[key, payer: string]]] =
  ## Every reference a part's counted report names — the payer's "settled" report, or the
  ## counterparty's confirmation — mapped to the parts ("<intent>/<part>") naming it, each
  ## with the party who pays that part (the driver's "settled" author).
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0: continue
    let drv = driverFor(v.policy)
    var effect: Effect
    try: effect = effectFromJson(v.effectJson)
    except CatchableError: continue
    for p in v.parts:
      if p.tx.len == 0: continue
      let payer = drv.partAuthor(effect, p.part, "settled").toLowerAscii()
      for r in refsOf(p.tx):
        let k = v.id & "/" & p.part
        if not result.mgetOrPut(r, @[]).anyIt(it.key == k): result[r].add (k, payer)

proc otherPayer(refs: Table[string, seq[tuple[key, payer: string]]], r, key, payer: string): string =
  ## A part (other than `key`) whose report names `r` and whose payer is not `payer`; "" = none.
  for x in refs.getOrDefault(r):
    if x.key != key and x.payer != payer: return x.key
  ""

proc contestedParts*(events: seq[Event], driverFor: DriverFor): Table[string, string] =
  ## The unconfirmed parts ("<intent>/<part>") whose reported reference a part paid by
  ## SOMEONE ELSE also reports, each with why (exo-3b3.14): one transaction settles one part,
  ## so when two parties report the same one, neither part is confirmed on it — the creditor
  ## may still mark either received by their own word. (One party naming their own payment
  ## for two of their own parts is not contested: it confirms at most one of them.)
  let refs = reportedRefs(events, driverFor)
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0: continue
    let drv = driverFor(v.policy)
    var effect: Effect
    try: effect = effectFromJson(v.effectJson)
    except CatchableError: continue
    for p in v.parts:
      if p.confirmed or p.tx.len == 0: continue
      let k = v.id & "/" & p.part
      let payer = drv.partAuthor(effect, p.part, "settled").toLowerAscii()
      for r in refsOf(p.tx):
        let other = otherPayer(refs, r, k, payer)
        if other.len > 0:
          result[k] = "the payment " & r & " is reported for two parts paid by different people (also " &
                      other & "): neither is confirmed on it"
          break

# ── the ledger of references this keystore confirmed, across rooms (exo-3b3.14) ──────
type RefLedger* = ref object
  ## Every chain reference this member's client confirmed a part on, in any room, each with
  ## where ("<room topic>|<intent>/<part>"). One payment settles one part across every room
  ## this keystore is in: a reference confirmed in another room is refused here. Kept in a
  ## small file beside the identity (the instance's persistence directory, as
  ## joined_rooms.json is). A file that exists but cannot be read is `broken`: every
  ## confirmation by reference is refused until it is fixed, never a silent fresh start.
  path*: string
  refs*: Table[string, string]
  broken*: string

proc openRefLedger*(path: string): RefLedger =
  result = RefLedger(path: path)
  if path.len == 0 or not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    if j.kind != JObject or j{"refs"} == nil or j["refs"].kind != JObject:
      result.broken = "it holds no refs object"
      return
    for k, v in j["refs"].pairs:
      if v.kind != JString:
        result.broken = "an entry is not text"
        return
      result.refs[k] = v.getStr()
  except CatchableError as e:
    result.broken = e.msg

proc save(l: RefLedger) =
  if l.path.len == 0: return
  var o = newJObject()
  for k, v in l.refs: o[k] = %v
  createDir(parentDir(l.path))
  let tmp = l.path & ".tmp"
  writeFile(tmp, $(%*{"v": 1, "refs": o}))
  moveFile(tmp, l.path)

var gRefLedger: RefLedger
proc setRefLedger*(l: RefLedger) = gRefLedger = l
  ## The ledger confirmations consult and record into (nil = none: one room's log alone).
proc refLedger*(): RefLedger = gRefLedger

proc ledgerRefusal(l: RefLedger, refs: seq[string], here: string): string =
  ## Why `refs` may not be confirmed for `here` ("" = they may).
  if l == nil or refs.len == 0: return ""
  if l.broken.len > 0:
    return "the ledger of payments this client confirmed (" & l.path & ") could not be read: " & l.broken
  let room = here.split('|')[0]
  for r in refs:
    let at = l.refs.getOrDefault(r, "")
    if at.len > 0 and at != here and at.split('|')[0] != room:
      return "that payment already settled a share in another room"
  ""

proc recordRefs(l: RefLedger, refs: seq[string], here: string) =
  if l == nil or l.broken.len > 0 or refs.len == 0: return
  var changed = false
  for r in refs:
    if r notin l.refs: (l.refs[r] = here; changed = true)
  if changed:
    try: l.save()
    except CatchableError as e: l.broken = "it could not be written: " & e.msg

proc recordRoom*(l: RefLedger, s: CoordinationSession, events: seq[Event], driverFor: DriverFor) =
  ## Bring the ledger up to date with every reference this room's log shows confirmed —
  ## confirmations made before the ledger existed, or on another of this member's devices.
  if l == nil or l.broken.len > 0: return
  for v in reduceIntentViews(events, driverFor):
    for p in v.parts:
      if p.confirmed and p.tx.len > 0:
        l.recordRefs(refsOf(p.tx), s.topic & "|" & v.id & "/" & p.part)

# ── paying my part ─────────────────────────────────────────────────────────────
proc effectMemo(effectJson: string): string =
  ## The memo a proposal carries ("dinner"), for naming a payment to the person approving it.
  try: parseJson(effectJson){"memo"}.getStr("") except CatchableError: ""

proc liveSettlePartSend*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                         seam: PartSeam, nowSec: uint64,
                         inFlight: seq[PendingPart] = @[]): tuple[outcome: string, pending: PendingPart] =
  ## Pay MY part of an agreed intent from my own wallet. outcome "" = sent (pending holds
  ## what completion needs), else a refusal with nothing sent or published: unknown-intent,
  ## unsupported-driver, not-in-parts, not-a-party, not-agreed, already-settled, paying,
  ## no-context, expired, "refused: …". `inFlight` is what this host has sent and not yet
  ## seen land: the log shows those parts unpaid until their report, so they are skipped —
  ## never paid twice — and when every part left is in flight the answer is "paying".
  s.poll()
  let events = s.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return ("unknown-intent", PendingPart())
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return ("unsupported-driver", PendingPart())
  let effect = effectFromJson(effectJson)
  let parts = drv.settlementParts(effect)
  if parts.len == 0: return ("not-in-parts", PendingPart())
  # MY parts: the ones the driver says I settle — one per split (named for me), and on a
  # settle-up one per person I pay (exo-3c6)
  let myId = myIdentity(ks)
  var minePts: seq[string]
  for p in parts:
    if drv.partAuthor(effect, p, "settled").toLowerAscii() == myId: minePts.add p
  if minePts.len == 0: return ("not-a-party", PendingPart())
  let (found, v) = viewOf(events, driverFor, intentId)
  if not found or v.state notin ["executable", "submitted", "settling"]:
    return ((if found and v.state == "final": "already-settled" else: "not-agreed"), PendingPart())
  var me = ""
  var busy = false
  for p in minePts:
    if partViewOf(v, p).p.settled: continue
    var flying = false
    for f in inFlight:
      if f.intentId == intentId and f.part == p: flying = true
    if flying:
      busy = true
      continue
    me = p
    break
  if me.len == 0: return ((if busy: "paying" else: "already-settled"), PendingPart())
  # a part another agreed intent settles (a settle-up) is paid through it, never twice
  if coveringIntent(events, driverFor, intentId, me, nowSec).len > 0: return ("covered-by-settle-up", PendingPart())
  let ctx = intentContext(events, intentId)
  if ctx.isPlaceholder: return ("no-context", PendingPart())
  # Paying against an expired agreement is refused (invariant 2) — except the rest of an
  # intent that settles OTHER intents' parts (a settle-up) once its payments have begun: what
  # it already moved replaced the parts it covers, so it is finished, never abandoned
  # (exo-a90.16, coordination/covers).
  if ctx.expired(nowSec) and not (beganSettling(v) and drv.covers(effect).len > 0):
    return ("expired", PendingPart())
  # invariant 1: the payment is the driver's reading of the AGREED effect — never supplied
  let t = drv.partTransfer(effect, me)
  if not t.ok: return ("refused: " & t.error, PendingPart())
  seam.notePayment(intentId, me, effectMemo(effectJson))
  let sent = seam.sendPart(t)
  # the wallet refused to send (a rail it will not take, no note that covers it, a scan
  # still catching up) or the chain did: either way nothing was sent, and the detail says why
  if not sent.ok: return ("refused: the payment was not sent: " & sent.detail, PendingPart())
  ("", PendingPart(intentId: intentId, part: me, tx: sent.tx, transfer: t, spends: seam.lastSpends()))

proc liveSettlePartComplete*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: PartSeam,
                             pp: PendingPart): string =
  ## "unconfirmed: …" (nothing published) until my own transfer landed; then my
  ## author-signed "settled" report, and the intent's state.
  let landed = seam.partLanded(pp.transfer, pp.tx)
  if not landed.ok: return "unconfirmed: " & landed.detail
  let reference = seam.landedRef(pp.transfer, pp.tx)
  # the report carries the reference in its rail's one spelling, or is not made (exo-3b3.14)
  let bad = canonicalRefRefusal(pp.transfer.chain, reference)
  if bad.len > 0: return "unconfirmed: " & bad
  s.poll()
  s.publishAuthored(ks, partEvent(pp.intentId, pp.part, "settled", myIdentity(ks), reference))
  intentState(s.roomEvents(), driverFor, pp.intentId)

proc liveSettlePart*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                     seam: PartSeam, nowSec: uint64): string =
  ## Send, then complete, back to back (a seam whose transfers land at once).
  let (outcome, pp) = liveSettlePartSend(s, ks, driverFor, intentId, seam, nowSec)
  if outcome.len > 0: return outcome
  liveSettlePartComplete(s, ks, driverFor, seam, pp)

# ── confirming a part (the counterparty) ─────────────────────────────────────────
proc liveConfirmPart*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId, part: string,
                      seam: PartSeam, tx: string, fromRead = false): string =
  ## As the counterparty, confirm `part`. With a reported reference — or `fromRead`, my own
  ## read with no reference to look up (a Monero wallet's history, exo-dcc.5) — only after
  ## MY OWN read shows the part received exactly (the seam's matchReceived — the reported
  ## transaction on a public rail, an unclaimed note or transfer of exactly the share on a
  ## private one) — and never a reference already confirmed for another part. With neither,
  ## the part was received outside muster: my word, stated as such. Returns the intent's
  ## state, or a refusal with nothing published.
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
  if tx.len > 0 or fromRead:
    let t = drv.partTransfer(effect, part)
    if not t.ok: return "refused: " & t.error
    # a reference in its rail's one spelling, or none (exo-3b3.14)
    if tx.len > 0:
      let bad = canonicalRefRefusal(t.chain, tx)
      if bad.len > 0: return "refused: " & bad
    let claimed = confirmedRefs(events, driverFor)
    if tx.len > 0 and refsOf(tx).anyIt(it in claimed):
      return "refused: that payment already settled another share"
    # across rooms: never a reference this keystore confirmed in another room
    let here = s.topic & "|" & intentId & "/" & part
    gRefLedger.recordRoom(s, events, driverFor)
    if tx.len > 0:
      let other = ledgerRefusal(gRefLedger, refsOf(tx), here)
      if other.len > 0: return "refused: " & other
    # one reference identifies one part (exo-3b3.14): a reference another part's report also
    # names confirms neither of them
    let reported = reportedRefs(events, driverFor)
    let payer = drv.partAuthor(effect, part, "settled").toLowerAscii()
    proc elsewhere(refs: seq[string]): bool =
      refs.anyIt(otherPayer(reported, it, intentId & "/" & part, payer).len > 0)
    if tx.len > 0 and elsewhere(refsOf(tx)):
      return "refused: that payment is reported for two parts paid by different people; neither is confirmed on it"
    seam.observe(events, driverFor)
    let got = seam.matchReceived(t, tx, claimed)
    if not got.ok: return "unconfirmed: " & got.detail
    # one reference settles one part: whatever the seam found, never one already claimed
    if got.reference.len == 0 or refsOf(got.reference).anyIt(it in claimed):
      return "refused: that payment already settled another share"
    let badGot = canonicalRefRefusal(t.chain, got.reference)
    if badGot.len > 0: return "refused: " & badGot
    let otherGot = ledgerRefusal(gRefLedger, refsOf(got.reference), here)
    if otherGot.len > 0: return "refused: " & otherGot
    if elsewhere(refsOf(got.reference)):
      return "refused: that payment is reported for two parts paid by different people; neither is confirmed on it"
    reference = got.reference
  s.publishAuthored(ks, partEvent(intentId, part, "confirmed", myIdentity(ks), reference))
  gRefLedger.recordRefs(refsOf(reference), s.topic & "|" & intentId & "/" & part)
  intentState(s.roomEvents(), driverFor, intentId)

proc liveConfirmParts*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: PartSeam): seq[string] =
  ## The counterparty's pump (the intents tick): every part reported settled with a
  ## reference, not yet confirmed, of an intent I am the counterparty of — confirmed when my
  ## own read shows it. On a seam that confirmsUnreported (Monero), every unconfirmed part
  ## of an agreed intent, reported or not: the read decides, a report never does. Returns
  ## "<intent>/<part>" for each confirmed now.
  s.poll()
  let me = myIdentity(ks)
  let unreported = seam.confirmsUnreported()
  for v in reduceIntentViews(s.roomEvents(), driverFor):
    if v.parts.len == 0: continue
    if v.state notin ["submitted", "settling"] and not (unreported and v.state == "executable"): continue
    let drv = driverFor(v.policy)
    let effect = effectFromJson(v.effectJson)
    for p in v.parts:
      if p.confirmed: continue
      if not unreported and (not p.settled or p.tx.len == 0): continue
      if drv.partAuthor(effect, p.part, "confirmed").toLowerAscii() != me: continue
      if liveConfirmPart(s, ks, driverFor, v.id, p.part, seam, (if unreported: "" else: p.tx),
                         fromRead = unreported) in ["submitted", "settling", "final"]:
        result.add v.id & "/" & p.part

proc partsAwaiting*(events: seq[Event], driverFor: DriverFor, me: string): seq[IntentView] =
  ## The live intents settling in parts where a part still waits on `me`: mine to pay (not
  ## yet settled) or mine to confirm (not yet confirmed). What a seam that needs time to
  ## get ready keys on — a LEZ wallet's scan, which is slow and must be at the tip before
  ## a private payment can be sent or found (exo-270a). A final intent waits on no one.
  let me = me.toLowerAscii()
  for v in reduceIntentViews(events, driverFor):
    if v.parts.len == 0 or v.state notin ["proposed", "collecting", "executable", "submitted", "settling"]: continue
    let drv = driverFor(v.policy)
    let effect = effectFromJson(v.effectJson)
    for p in v.parts:
      let payer = drv.partAuthor(effect, p.part, "settled").toLowerAscii() == me
      let confirmer = drv.partAuthor(effect, p.part, "confirmed").toLowerAscii() == me
      if (payer and not p.settled) or (confirmer and not p.confirmed):
        result.add v
        break

# ── a ledger in memory: the no-chain seam tests and demos use ──────────────────────
type
  FakeTransfer* = object
    transfer*: PartTransfer
    payer*: string
    tx*: string
    landed*: bool
    dropped*: bool           ## left the pretend mempool without landing: it never will

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
  ## Every sent transfer still waiting lands.
  for t in l.sent.mitems:
    if not t.dropped: t.landed = true

proc drop*(l: FakeLedger, tx: string) =
  ## `tx` leaves the pretend mempool unlanded: it can never land now.
  for t in l.sent.mitems:
    if t.tx == tx and not t.landed: t.dropped = true

proc find(l: FakeLedger, tx: string): int =
  for i, t in l.sent:
    if t.tx == tx: return i
  -1

method sendPart*(s: FakePartSeam, t: PartTransfer): tuple[ok: bool, tx, detail: string] =
  # a hash in the one spelling an EVM chain's has (canonicalRefRefusal): 0x + 64 lowercase hex
  let tx = "0x" & align(toHex(s.ledger.sent.len + 1).toLowerAscii().strip(chars = {'0'}, trailing = false), 64, '0')
  s.ledger.sent.add FakeTransfer(transfer: t, payer: s.payer, tx: tx)
  (true, tx, "")

method partLanded*(s: FakePartSeam, t: PartTransfer, tx: string): tuple[ok: bool, detail: string] =
  let i = s.ledger.find(tx)
  if i < 0: return (false, "no transfer " & tx)
  if s.ledger.sent[i].dropped: return (false, tx & " was dropped: it will never land")
  if not s.ledger.sent[i].landed: return (false, tx & " has not landed yet")
  (true, "")

method partGone*(s: FakePartSeam, t: PartTransfer, pp: PendingPart): tuple[gone: bool, detail: string] =
  let i = s.ledger.find(pp.tx)
  if i >= 0 and s.ledger.sent[i].dropped: (true, pp.tx & " was dropped")
  else: (false, pp.tx & " may still land")

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
