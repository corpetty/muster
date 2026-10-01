## Pending keystore_module signing requests (exo-149.2 K2). Pure: the lp_* side sends
## request_approval / approval_status / fetch_result and hands the replies here; this
## says where each request stands and whether what came back may be used.
##
## A request returns {handle, receipt} at once and settles only when a human approves in
## an approver (evm_signer_ui, or evm_signer_cli headless). The receipt alone authorises
## collecting the result, and the keystore returns it exactly once, so it is held here,
## in memory, and never shown: not in view(), not in a log, not persisted. A restart
## drops it; the keystore expires an unclaimed request after 60 s and the member
## approves again. States and reasons are the keystore's own (approval.rs @2318c679):
## offered → rendered → settled {approved | rejected | expired_no_ack | cancelled}.
##
## Nothing fetched is trusted on the keystore's word: each signature must recover to the
## account muster chose over MUSTER's own hash for that leg (the safeTxHash it derived,
## the attestation digest it built), in leg order, or the request fails (invariant 1).

import std/[json, tables, strutils]
import ./keystore_legs

type
  SignRequestError* = object of CatchableError
  SignState* = enum
    ssWaiting = "waiting"       ## offered: no approver has it on screen yet
    ssShown = "shown"           ## rendered: an approver is showing it to a human
    ssApproved = "approved"
    ssRejected = "rejected"
    ssExpired = "expired"       ## expired_no_ack: nobody claimed it in time
    ssCancelled = "cancelled"   ## by the requester, or past muster's deadline
    ssFailed = "failed"         ## refused by the keystore, or a result that did not check
  SignLeg* = object
    kind*: string               ## what the leg is for, e.g. "contribution", "attestation"
    hash*: array[32, byte]      ## muster's own hash for it — the one the signature must cover
  PendingSign = object
    handle, intentId, account: string
    legs: seq[SignLeg]
    deadline, lastPoll: float
    state: SignState
    reason: string
  SignRequests* = object
    items: OrderedTable[string, PendingSign]
    receipts: Table[string, string]   ## kept apart from everything view() can reach
  Fetched* = object
    ok*: bool
    reason*: string
    sigs*: seq[string]          ## one per leg, in leg order; empty unless ok

const MaxPending* = 4           ## keystore_module: at most 4 pending per requester

proc isActive(s: SignState): bool = s in {ssWaiting, ssShown}

proc active*(r: SignRequests): int =
  for p in r.items.values:
    if p.state.isActive: inc result

proc canRequest*(r: SignRequests): bool = r.active() < MaxPending

proc add*(r: var SignRequests, handle, receipt, intentId, account: string,
          legs: seq[SignLeg], deadline: float) =
  if handle.len == 0 or receipt.len == 0: raise newException(SignRequestError, "no handle or receipt")
  if handle in r.items: raise newException(SignRequestError, "duplicate handle " & handle)
  if not r.canRequest(): raise newException(SignRequestError, "already " & $MaxPending & " pending")
  r.items[handle] = PendingSign(handle: handle, intentId: intentId, account: account.toLowerAscii(),
                                legs: legs, deadline: deadline, state: ssWaiting)
  r.receipts[handle] = receipt

proc handles*(r: SignRequests): seq[string] =
  for h in r.items.keys: result.add h

proc receiptOf*(r: SignRequests, handle: string): string = r.receipts.getOrDefault(handle)
proc stateOf*(r: SignRequests, handle: string): SignState = r.items[handle].state
proc reasonOf*(r: SignRequests, handle: string): string = r.items[handle].reason
proc intentOf*(r: SignRequests, handle: string): string = r.items[handle].intentId

proc remove*(r: var SignRequests, handle: string) =
  r.items.del handle
  r.receipts.del handle

proc fail(p: var PendingSign, why: string) =
  p.state = ssFailed
  p.reason = why

proc onStatus*(r: var SignRequests, handle: string, reply: JsonNode) =
  ## approval_status's {ok, state, reason?}. An unread reply (nil) changes nothing.
  if reply == nil or handle notin r.items: return
  var p = r.items[handle]
  if reply.kind != JObject or not reply{"ok"}.getBool(false):
    p.fail(if reply.kind == JObject: reply{"error"}.getStr("refused") else: "refused")
  else:
    case reply{"state"}.getStr()
    of "offered": p.state = ssWaiting
    of "rendered": p.state = ssShown
    of "settled":
      case reply{"reason"}.getStr()
      of "approved": p.state = ssApproved
      of "rejected": p.state = ssRejected
      of "expired_no_ack": p.state = ssExpired
      of "cancelled": p.state = ssCancelled
      else: p.fail("settled without a known reason: " & reply{"reason"}.getStr())
    else: p.fail("unexpected state: " & reply{"state"}.getStr())
  r.items[handle] = p

proc due*(r: SignRequests, now: float, every = 2.0): seq[string] =
  ## The active requests whose status is worth asking for again.
  for p in r.items.values:
    if p.state.isActive and now - p.lastPoll >= every: result.add p.handle

proc markPolled*(r: var SignRequests, handle: string, now: float) =
  if handle in r.items: r.items[handle].lastPoll = now

proc overdue*(r: var SignRequests, now: float): seq[string] =
  ## Active requests past muster's deadline: marked cancelled here; the caller tells the
  ## keystore (cancel_approval) so the human is not left approving something stale.
  for h, p in r.items.mpairs:
    if p.state.isActive and now > p.deadline:
      p.state = ssCancelled
      p.reason = "deadline"
      result.add h

proc onFetched*(r: var SignRequests, handle: string, reply: JsonNode): Fetched =
  ## fetch_result's {ok, signed:[…]}: usable only if every signature recovers to the
  ## chosen account over muster's own hash for its leg, in order.
  if handle notin r.items: return Fetched(reason: "unknown handle")
  var p = r.items[handle]
  defer: r.items[handle] = p
  if reply == nil or reply.kind != JObject or not reply{"ok"}.getBool(false):
    let why = (if reply != nil and reply.kind == JObject: reply{"error"}.getStr("refused") else: "unread")
    p.fail("fetch_result: " & why)
    return Fetched(reason: p.reason)
  let signed = reply{"signed"}
  if signed == nil or signed.kind != JArray or signed.len != p.legs.len:
    p.fail("fetch_result: " & $(if signed != nil and signed.kind == JArray: signed.len else: 0) &
           " signatures for " & $p.legs.len & " legs")
    return Fetched(reason: p.reason)
  var sigs: seq[string]
  for i, leg in p.legs:
    let s = signed[i].getStr()
    var who = ""
    try:
      let a = signerOf(leg.hash, s)
      who = "0x"
      for b in a: who.add toHex(b).toLowerAscii()
    except KeystoreLegError: discard
    if who != p.account:
      p.fail("the " & leg.kind & " signature does not recover to " & p.account & " over muster's hash")
      return Fetched(reason: p.reason)
    sigs.add s
  Fetched(ok: true, sigs: sigs)

proc view*(r: SignRequests): JsonNode =
  ## What the UI and logs may see: never a receipt.
  result = newJArray()
  for p in r.items.values:
    result.add %*{"handle": p.handle, "intentId": p.intentId, "account": p.account,
                  "state": $p.state, "reason": p.reason, "legs": p.legs.len}
