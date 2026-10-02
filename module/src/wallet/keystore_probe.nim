## Reads keystore_module for its status row (exo-149.1 K1); keystore_status.nim says what
## the replies mean. Not pure: lp_* calls, so like rln_probe.nim it is compiled only into
## the plugin.
##
## Every read here is ungated and local to keystore_module (no chain, no human), but
## keystore_module dispatches one call at a time and runs scrypt inside approve(), so a
## read can wait behind a human's approval. A blocking cross-module call on the module
## thread is what stalled sends once already (exo-eb6.1), so each read goes out async,
## at most every 5 s, and lands in a queue the module thread drains. A reply older than
## 30 s, or a call that could not go out, reads as unread: never a stale green.

import std/[json, times, tables, strutils]
import logos_sdk/ffi
import ../transport/inbound_queue
import ./keystore_status

const
  AsyncMs = 15_000.cint     ## generous: a read may queue behind a human's approve (scrypt)
  EveryS = 5.0
  StaleS = 30.0

type
  AsyncRead = object
    q: InboundQueue
    inFlight: bool
    sentAt: float
    last: JsonNode          ## the last reply that parsed; nil until one does
    lastAt: float
  KeystoreProbe* = ref object
    client: ptr LpClient
    identity, accounts, labels, wallets: AsyncRead

proc onRead(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## On the callee's thread: copy the reply into the queue (no Nim GC), nothing more.
  let q = cast[ptr InboundQueue](userData)
  if ok != 0 and json != nil: q[].enqueue(json) else: q[].enqueue("")

proc newKeystoreProbe*(): KeystoreProbe =
  result = KeystoreProbe()
  for r in [addr result.identity, addr result.accounts, addr result.labels, addr result.wallets]:
    initInboundQueue(r[].q)
  GC_ref(result)            # the callbacks hold pointers into it

proc reached(p: KeystoreProbe): bool =
  ## Created on first use, origin muster_module: keystore_module must attribute our calls
  ## to us (it reads the runtime's caller, never an argument).
  if p.client == nil:
    p.client = lp_client_create(KeystoreModule.cstring, Ours.cstring, nil, nil)
  p.client != nil

proc drain(r: var AsyncRead, now: float) =
  for raw in r.q.drain():
    r.inFlight = false
    var s = newString(raw.len)
    if raw.len > 0: copyMem(addr s[0], unsafeAddr raw[0], raw.len)
    let j = ksReply(s)
    if j != nil: (r.last = j; r.lastAt = now)
  if r.inFlight and now - r.sentAt > AsyncMs.float / 1000 + 5: r.inFlight = false

proc fire(p: KeystoreProbe, r: var AsyncRead, meth: string, now: float) =
  if r.inFlight or now - r.sentAt < EveryS: return
  r.sentAt = now
  if lp_invoke_async(p.client, meth.cstring, "[]", AsyncMs, onRead, addr r.q) == LP_OK:
    r.inFlight = true
  else:
    r.last = nil            # it could not even be asked: unread, not the old answer

proc current(r: AsyncRead, now: float): JsonNode =
  if r.last != nil and now - r.lastAt <= StaleS: r.last else: nil

proc read*(p: KeystoreProbe): KeystoreInputs =
  ## Everything keystoreRow needs, now; the first call after load answers "did not
  ## answer" until the replies land (a few ms later, on the next read).
  if not p.reached(): return KeystoreInputs(reached: false)
  let now = epochTime()
  for (r, meth) in [(addr p.identity, "caller_identity"), (addr p.accounts, "list_accounts"),
                    (addr p.labels, "get_labels"), (addr p.wallets, "get_account_wallets")]:
    r[].drain(now)
    p.fire(r[], meth, now)
  KeystoreInputs(reached: true, identity: p.identity.current(now), accounts: p.accounts.current(now),
                 labels: p.labels.current(now), wallets: p.wallets.current(now))

# ── signing requests (exo-149.2 K2) ──────────────────────────────────────────────
# request_approval answers at once with {handle, receipt}, so it is asked directly with a
# short budget. approval_status / fetch_result can wait behind a human's approve (scrypt
# runs inside it), so they go out async: at most one call in flight per request, its reply
# queued for the module thread. ack_result and cancel_approval are fire-and-forget.

const
  RequestMs = 5_000.cint
  PollMs = 15_000.cint

type
  RequestIo = ref object
    q: InboundQueue
    op: string              ## "status" | "fetch" while a call is in flight, "" otherwise
    sentAt: float
  KeystoreReply* = object
    handle*, op*: string
    reply*: JsonNode        ## nil when the call failed or its reply did not parse

var ios: Table[string, RequestIo]

proc discardReply(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} = discard

proc requestApproval*(p: KeystoreProbe, intentJson: string): JsonNode =
  ## {ok, handle, receipt, state} or {ok:false, error}; nil when keystore_module did not answer.
  if not p.reached(): return nil
  var res, err: cstring
  let rc = lp_invoke(p.client, "request_approval", ($(%*[intentJson])).cstring, RequestMs,
                     addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return nil
  ksReply($res)

proc fireOp*(p: KeystoreProbe, op, handle, receipt: string) =
  ## Send approval_status ("status") or fetch_result ("fetch") for one request, unless a
  ## call for it is already in flight. The reply lands in that request's queue.
  if not p.reached(): return
  var io = ios.getOrDefault(handle)
  if io == nil:
    io = RequestIo()
    initInboundQueue(io.q)
    GC_ref(io)              # the callback holds a pointer into it until the request is dropped
    ios[handle] = io
  if io.op.len > 0: return
  let meth = (if op == "fetch": "fetch_result" else: "approval_status")
  if lp_invoke_async(p.client, meth.cstring, ($(%*[handle, receipt])).cstring, PollMs,
                     onRead, addr io.q) == LP_OK:
    io.op = op
    io.sentAt = epochTime()

proc drainOps*(p: KeystoreProbe): seq[KeystoreReply] =
  ## Every reply that has landed since the last drain, on the module thread. A call that
  ## never answered frees its slot after its budget, as an unread reply.
  let now = epochTime()
  for handle, io in ios:
    for raw in io.q.drain():
      var s = newString(raw.len)
      if raw.len > 0: copyMem(addr s[0], unsafeAddr raw[0], raw.len)
      let op = io.op
      io.op = ""
      result.add KeystoreReply(handle: handle, op: op, reply: ksReply(s))
    if io.op.len > 0 and now - io.sentAt > PollMs.float / 1000 + 5:
      result.add KeystoreReply(handle: handle, op: io.op, reply: nil)
      io.op = ""

proc fireAndForget*(p: KeystoreProbe, meth, handle, receipt: string) =
  ## ack_result / cancel_approval: nothing waits on the answer.
  if p.reached():
    discard lp_invoke_async(p.client, meth.cstring, ($(%*[handle, receipt])).cstring, PollMs,
                            discardReply, nil)

proc dropIo*(handle: string) =
  ## The request is finished: release its queue once no call for it is in flight.
  let io = ios.getOrDefault(handle)
  if io != nil and io.op.len == 0:
    ios.del handle
    GC_unref(io)

proc lastAccounts*(p: KeystoreProbe): seq[string] =
  ## The accounts keystore_module last reported (lowercase), for routing a key ref.
  let a = p.accounts.current(epochTime())
  if a != nil and a.kind == JObject:
    for e in a{"accounts"}.getElems():
      result.add e.getStr().toLowerAscii()
