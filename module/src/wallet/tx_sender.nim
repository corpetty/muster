## A payment through the platform's tx_sender_module (exo-d4d.5, R4;
## docs/design/real-use-basecamp.md §5.4). Pure: what to ask the sender for, whether what it
## prepared is what the room agreed, what its replies mean, and the book of sends in flight.
## The lp_* half is a hook the plugin installs (wallet/tx_sender_lp.nim).
##
## Under Basecamp muster neither signs nor broadcasts a transaction. tx_sender_module is the
## device's one sender, with its one nonce ledger: prepare prices a bundle, send registers one
## keystore approval (a person types the vault password in the signer), and send_status IS
## the broadcast: the first poll after the approval sends each call and takes its hash. Its
## contract is logos-evm-tx-sender-module@7cd2fead README §The contract.
##
## Invariant 1 here: the call is derived from the agreed transfer (never supplied), and the
## legs prepare answers must be exactly that call, or nothing is sent.

import std/[json, strutils, tables]
import stint
import ../intents/materialization   # PartTransfer

type
  TxSenderError* = object of CatchableError
  TxCall* = object
    to*: string        ## 0x address, lowercase
    value*: string     ## wei, decimal
    data*: string      ## 0x calldata, "" for a plain transfer
  SendState* = enum
    ssAwaiting       ## a person has not approved yet (or the sender did not answer: ask again)
    ssBroadcasting   ## approved; the calls are leaving
    ssBroadcast      ## left, with a hash (final)
    ssStuck          ## a broadcast no poll can move (final; the hash may still be mined)
    ssEnded          ## rejected, cancelled or failed (final)
    ssUnknown        ## the sender holds no send with that id (final): a restart lost it
  SendStatus* = object
    state*: SendState
    status*: string    ## the sender's own word
    final*: bool
    blocked*: bool     ## held by the verified-proxy gate, not failed
    hash*: string      ## the last call's hash, "" until one left
    reason*: string
    neverSent*: bool   ## ended with nothing broadcast: it can never land
  Send = object
    requestId, handle, intentId, part, purpose: string
    st: SendStatus
    hash: string
  SendBook* = object
    sends: OrderedTable[string, Send]

const MarkerPrefix* = "txs:"   ## a part's tx until the sender answers with a hash

proc lowerHex(s: string): string = s.strip().toLowerAscii()

proc isEvmAddress(s: string): bool =
  let a = s.lowerHex()
  a.len == 42 and a.startsWith("0x") and a[2 .. ^1].allCharsInSet(HexDigits)

proc decimalOf(v: string): string =
  ## A wei amount, decimal or 0x-hex, as canonical decimal; raises when it is neither.
  let t = v.strip()
  try:
    if t.len == 0: return "0"
    if t.startsWith("0x") or t.startsWith("0X"):
      return (if t.len == 2: "0" else: $UInt256.fromHex(t))
    if not t.allCharsInSet(Digits): raise newException(ValueError, "not a number")
    $parse(t, UInt256)
  except CatchableError:
    raise newException(TxSenderError, "not an amount: " & v)

proc hexOfDecimal(v: string): string =
  let n = parse(decimalOf(v), UInt256)
  "0x" & (if n.isZero: "0" else: n.toHex().strip(leading = true, trailing = false, chars = {'0'}))

proc pad32(hexNoPrefix: string): string = repeat('0', 64 - hexNoPrefix.len) & hexNoPrefix

proc callFor*(t: PartTransfer): TxCall =
  ## The one call that pays `t`, from the agreed transfer alone: ETH to payTo, or a token
  ## share as transfer(payTo, share) on the token (selector a9059cbb).
  if not t.ok: raise newException(TxSenderError, "no transfer: " & t.error)
  if not isEvmAddress(t.to): raise newException(TxSenderError, "not an address to pay: " & t.to)
  let amount = decimalOf(t.amount)
  if t.asset == "ETH":
    return TxCall(to: t.to.lowerHex(), value: amount, data: "")
  if t.asset.startsWith("erc20:") and isEvmAddress(t.asset[6 .. ^1]):
    let amtHex = parse(amount, UInt256).toHex()
    return TxCall(to: t.asset[6 .. ^1].lowerHex(), value: "0",
                  data: "0xa9059cbb" & pad32(t.to.lowerHex()[2 .. ^1]) & pad32(amtHex))
  raise newException(TxSenderError, "an Ethereum payment is ETH or erc20:<token>, not " & t.asset)

proc requestJson*(chainId: int, frm: string, c: TxCall, purpose: string, meta: JsonNode): JsonNode =
  ## prepare's and send's request: one call, the room's purpose (≤ 256 bytes), and meta
  ## naming what it pays, so the sender's history joins back.
  var call = %*{"to": c.to, "value": hexOfDecimal(c.value)}
  if c.data.len > 0: call["data"] = %c.data
  if meta != nil and meta.kind == JObject and meta.len > 0: call["meta"] = meta
  var p = purpose
  if p.len > 256: p = p[0 ..< 253] & "..."
  %*{"chainId": chainId, "from": frm.lowerHex(), "calls": [call], "purpose": p}

proc legsMismatch*(prepared: JsonNode, c: TxCall): string =
  ## "" when prepare's legs are exactly `c`; else what differs. A refusal from prepare is
  ## its own reason.
  if prepared == nil or prepared.kind != JObject: return "tx_sender_module did not answer prepare"
  if not prepared{"ok"}.getBool(false): return prepared{"error"}.getStr("tx_sender_module refused the payment")
  let legs = prepared{"legs"}
  if legs == nil or legs.kind != JArray or legs.len != 1:
    return "legs: the sender prepared " & (if legs == nil: "none" else: $legs.len) & " for one payment"
  let l = legs[0]
  if l{"to"}.getStr().lowerHex() != c.to: return "to: the sender would pay " & l{"to"}.getStr() & ", not " & c.to
  var v = ""
  try: v = decimalOf(l{"value"}.getStr("0")) except TxSenderError: v = "?"
  if v != c.value: return "value: the sender would move " & l{"value"}.getStr() & ", not " & c.value & " wei"
  var d = l{"data"}.getStr("").lowerHex()
  if d == "0x": d = ""
  if d != c.data.lowerHex(): return "data: the sender would send other calldata than the agreed payment"
  ""

proc parseSendStatus*(j: JsonNode): SendStatus =
  ## What a send_status reply means. No answer, or a refusal the sender says is not final,
  ## is "ask again": an approved send stops only when the sender says final.
  if j == nil or j.kind != JObject: return SendStatus(state: ssAwaiting)
  if not j{"ok"}.getBool(false):
    if j{"final"}.getBool(false):
      return SendStatus(state: ssUnknown, status: "unknown", final: true, neverSent: true,
                        reason: j{"error"}.getStr("the sender holds no such send"))
    return SendStatus(state: ssAwaiting, reason: j{"error"}.getStr(""))
  result.status = j{"status"}.getStr("")
  result.final = j{"final"}.getBool(false)
  result.blocked = j{"blocked"}.getBool(false)
  result.reason = j{"reason"}.getStr("")
  result.hash = j{"hash"}.getStr("")
  if result.hash.len == 0 and j{"hashes"} != nil and j["hashes"].kind == JArray and j["hashes"].len > 0:
    result.hash = j["hashes"][^1].getStr("")
  result.state = case result.status
    of "awaitingApproval": ssAwaiting
    of "broadcasting": ssBroadcasting
    of "broadcast": ssBroadcast
    of "stuck": ssStuck
    of "rejected", "cancelled", "failed": ssEnded
    else: ssAwaiting
  result.neverSent = result.state == ssEnded and result.hash.len == 0

proc markerOf*(requestId: string): string = MarkerPrefix & requestId
proc requestOfMarker*(tx: string): string =
  if tx.startsWith(MarkerPrefix): tx[MarkerPrefix.len .. ^1] else: ""

proc add*(b: var SendBook, requestId, handle, intentId, part, purpose: string) =
  b.sends[requestId] = Send(requestId: requestId, handle: handle, intentId: intentId, part: part,
                            purpose: purpose, st: SendStatus(state: ssAwaiting))

proc update*(b: var SendBook, requestId: string, st: SendStatus) =
  if requestId notin b.sends: return
  b.sends[requestId].st = st
  if st.hash.len > 0: b.sends[requestId].hash = st.hash   # a hash seen is never forgotten

proc has*(b: SendBook, requestId: string): bool = requestId in b.sends
proc handleOf*(b: SendBook, requestId: string): string =
  if requestId in b.sends: b.sends[requestId].handle else: ""
proc hashOf*(b: SendBook, requestId: string): string =
  if requestId in b.sends: b.sends[requestId].hash else: ""
proc statusOf*(b: SendBook, requestId: string): SendStatus =
  if requestId in b.sends: b.sends[requestId].st else: SendStatus(state: ssUnknown, final: true, neverSent: true)

proc view*(b: SendBook): JsonNode =
  ## The sends as the view's signer escort reads keystore requests: a handle and a state in
  ## the same words (waiting = a person has not approved). Never more than the sender said.
  result = newJArray()
  for s in b.sends.values:
    let state = case s.st.state
      of ssAwaiting: "waiting"
      of ssBroadcasting, ssBroadcast: "approved"
      of ssStuck: "stuck"
      of ssEnded: (if s.st.status.len > 0: s.st.status else: "failed")
      of ssUnknown: "expired"
    result.add %*{"kind": "send", "handle": s.handle, "requestId": s.requestId,
                  "intentId": s.intentId, "part": s.part, "state": state,
                  "reason": s.st.reason, "hash": s.hash}

# ── the platform hook and the book of this host's sends ─────────────────────────
type TxSenderCall* = proc(meth: string, args: JsonNode, timeoutMs: int): JsonNode {.nimcall, gcsafe.}
  ## One tx_sender_module call with its lp argument array → its reply, or nil when it did
  ## not answer. The plugin installs the lp_* call (wallet/tx_sender_lp.nim); tests a fake.

var txSender: TxSenderCall
var sendBook*: SendBook   ## the sends this host asked for, as far as the sender has answered

proc setTxSender*(f: TxSenderCall) = txSender = f
proc hasTxSender*(): bool = txSender != nil

proc senderCall*(meth: string, args: JsonNode, timeoutMs = 20_000): JsonNode =
  ## nil when there is no tx_sender_module on this host, or it did not answer.
  if txSender == nil: return nil
  txSender(meth, args, timeoutMs)

proc pollSend*(requestId: string): SendStatus =
  ## Advance one send (send_status IS the broadcast) and note what the sender said.
  result = parseSendStatus(senderCall("send_status", %*[requestId]))
  sendBook.update(requestId, result)
