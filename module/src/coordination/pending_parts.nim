## The payments this host has sent and not yet seen land (exo-a90.23). Pure: the hosted
## pump drives it and pending_parts_test holds it.
##
## Paying sends and returns; the "settled" report is published only once the payment lands
## (nothing reaches the log before the chain has it), so until then the log shows the part
## unpaid and this book alone knows a payment is on its way. Everything in it is in flight
## (liveSettlePartSend's inFlight, exo-a90.18): never paid twice. A payment is not dropped
## when its seam's pay deadline passes — a low-fee Bitcoin transaction or a stuck nonce can
## still land — it becomes UNRESOLVED: still in flight, checked less often. It leaves the book
## only when it lands (its report is published), fails on chain (it moved nothing), or the
## chain says it can never land (the seam's partGone). The book is saved after every change
## and read back on start, so a restart forgets nothing.

import std/[json, sequtils, strutils]
import ../intents/materialization   # PartTransfer
import ../crypto/keystore
import ./intent_events              # DriverFor
import ./session
import ./parts                      # PendingPart, liveSettlePartComplete

const UnresolvedCheckS* = 30.0
  ## how often an unresolved payment is asked about again (a fresh one: every tick)

type
  PendingEntry* = object
    topic*: string        ## the room it was paid in (its session)
    pp*: PendingPart
    startedS*: float
    deadlineS*: float     ## the seam's payDeadlineS when it was sent
    unresolved*: bool     ## its deadline passed without an answer from the chain
    nextCheckS*: float    ## an unresolved payment is asked about again from then on

  PendingBook* = object
    entries*: seq[PendingEntry]

  CheckResult* = enum
    crPending   ## not landed, not known to be gone
    crLanded    ## landed: its report was published
    crFailed    ## failed on chain: it moved nothing
    crGone      ## the chain says it can never land

proc add*(b: var PendingBook, topic: string, pp: PendingPart, nowS, deadlineS: float) =
  b.entries.add PendingEntry(topic: topic, pp: pp, startedS: nowS, deadlineS: deadlineS)

proc inFlight*(b: PendingBook, topic: string): seq[PendingPart] =
  ## Every payment of `topic`'s room still on its way — unresolved ones included.
  for e in b.entries:
    if e.topic == topic: result.add e.pp

proc paying*(b: PendingBook, topic, intentId, part: string): bool =
  for e in b.entries:
    if e.topic == topic and e.pp.intentId == intentId and e.pp.part == part: return true

proc due*(b: PendingBook, nowS: float): seq[int] =
  ## The entries to ask about now: a fresh payment every tick, an unresolved one when due.
  for i, e in b.entries:
    if not e.unresolved or nowS >= e.nextCheckS: result.add i

proc record*(b: var PendingBook, i: int, r: CheckResult, nowS: float): string =
  ## What the chain said about entry `i`. Returns the outcome to report ("" = still waiting):
  ## a payment that landed, failed or is gone leaves the book; one still pending past its
  ## deadline becomes unresolved — never dropped.
  let e = b.entries[i]
  case r
  of crLanded:
    b.entries.delete(i)
    "reported"
  of crFailed:
    b.entries.delete(i)
    "failed on chain: it moved nothing, so the part may be paid again"
  of crGone:
    b.entries.delete(i)
    "it will never land: the part may be paid again"
  of crPending:
    if not e.unresolved and nowS - e.startedS > e.deadlineS:
      b.entries[i].unresolved = true
      b.entries[i].nextCheckS = nowS + UnresolvedCheckS
      "unresolved: not landed by its deadline, still watched, never paid twice"
    else:
      if e.unresolved: b.entries[i].nextCheckS = nowS + UnresolvedCheckS
      ""

proc pumpBook*(b: var PendingBook, topic: string, s: CoordinationSession, ks: Keystore, driverFor: DriverFor,
               seamOf: proc (pp: PendingPart): PartSeam, nowS: float,
               note: proc (msg: string) = nil): seq[tuple[pp: PendingPart, outcome, said: string]] =
  ## One pass over the payments of `topic`'s room that are due (the hosted pump runs it on
  ## the intents tick): each is asked about through its seam — landed (its report is
  ## published), failed on chain, or, once past its deadline, gone by the chain's word — and
  ## the book records the answer. Returns what left the book or turned unresolved, with what
  ## the chain said. `seamOf` may raise (e.g. right after a restart, before the room's log
  ## names the intent's policy): that payment simply waits.
  let due = b.due(nowS)
  for k in countdown(due.high, 0):     # highest index first: a settled entry leaves the book
    let i = due[k]
    let e = b.entries[i]
    if e.topic != topic: continue      # a payment completes only in its own room
    var res = crPending
    var said = ""
    try:
      let seam = seamOf(e.pp)
      let r = liveSettlePartComplete(s, ks, driverFor, seam, e.pp)
      if not r.startsWith("unconfirmed"): (res = crLanded; said = r)
      elif "failed on" in r: (res = crFailed; said = r)
      else:
        if note != nil: note(e.pp.intentId & " " & e.pp.tx & ": " & r)
        if e.unresolved or nowS - e.startedS > e.deadlineS:
          # past its deadline it is not dropped: only the chain's word releases it
          let g = seam.partGone(e.pp.transfer, e.pp)
          if g.gone: (res = crGone; said = g.detail)
    except CatchableError as ex:       # an unreachable node or RPC: ask again later
      if note != nil: note(e.pp.intentId & " not checked: " & ex.msg)
    let outcome = b.record(i, res, nowS)
    if outcome.len > 0: result.add (e.pp, outcome, said)

# ── the saved form ───────────────────────────────────────────────────────────────
proc toJson*(b: PendingBook): JsonNode =
  result = newJArray()
  for e in b.entries:
    let t = e.pp.transfer
    result.add %*{"topic": e.topic, "startedS": e.startedS, "deadlineS": e.deadlineS,
                  "unresolved": e.unresolved, "nextCheckS": e.nextCheckS,
                  "intentId": e.pp.intentId, "part": e.pp.part, "tx": e.pp.tx, "spends": e.pp.spends,
                  "transfer": {"ok": t.ok, "chain": t.chain, "asset": t.asset, "to": t.to,
                               "amount": t.amount, "error": t.error}}

proc bookFromJson*(j: JsonNode): PendingBook =
  ## The book as saved; nothing saved (or not a list) is an empty book.
  if j == nil or j.kind != JArray: return
  for x in j:
    if x.kind != JObject: continue
    let t = x{"transfer"}
    result.entries.add PendingEntry(
      topic: x{"topic"}.getStr(), startedS: x{"startedS"}.getFloat(), deadlineS: x{"deadlineS"}.getFloat(),
      unresolved: x{"unresolved"}.getBool(), nextCheckS: x{"nextCheckS"}.getFloat(),
      pp: PendingPart(intentId: x{"intentId"}.getStr(), part: x{"part"}.getStr(), tx: x{"tx"}.getStr(),
                      spends: x{"spends"}.getElems().mapIt(it.getStr()),
                      transfer: PartTransfer(ok: t{"ok"}.getBool(), chain: t{"chain"}.getStr(),
                                             asset: t{"asset"}.getStr(), to: t{"to"}.getStr(),
                                             amount: t{"amount"}.getStr(), error: t{"error"}.getStr())))
