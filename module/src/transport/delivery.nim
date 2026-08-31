## DeliveryTransport — the real-network Transport (ADR-006), consuming
## `logos-delivery-module` over the `lp_*` C ABI (see lp_ffi.nim). It is a
## Transport like LocalTransport, so everything above it (the epoch layer, F-16)
## is unchanged whether it runs on the in-process bus or a real Waku fleet.
##
## Wire contract matched to what delivery expects (from the chat module's own
## delivery bridge): `send(contentTopic: tstr, payload: bstr)`,
## `subscribe(contentTopic: tstr)`, and the `messageReceived(messageHash,
## contentTopic, payload, timestamp)` event; `bstr` rides the tagged
## {"_bytes":"<base64url>"} form.
##
## NOT compiled by pure-Nim `nim r` — it needs logos-protocol linked (the plugin
## build provides it). Live two-instance verification, and hardening the event
## callback's foreign-thread GC seam (the storage-nim `abandoned`-flag pattern),
## come with the P3 integration harness; this increment establishes the binding.

import std/[json, tables, os]
import ./transport
import ./lp_ffi
import ./inbound_queue

# Transport diagnostics — off unless MUSTER_LP_DEBUG is set. When the delivery
# node boot or cross-host relay misbehaves, this surfaces the lp createNode/start
# result, the topic subscribe, inbound frames, and send results on stderr. The
# foreign-thread callbacks read this bool (no GC) via c_fprintf (no Nim strings).
let gLpDebug* = getEnv("MUSTER_LP_DEBUG").len > 0

type
  DeliveryTransport* = ref object of Transport
    client: ptr LpClient
    sub: ptr LpSubscription                       ## the single messageReceived subscription
    handlers: Table[string, seq[MessageHandler]]  ## contentTopic -> handlers (we route)
    queue: InboundQueue                           ## foreign-thread callbacks land here; poll() drains
    timeoutMs: cint
    nodeStarted: cint                             ## set 1 by onStartResult (foreign thread); a plain int write
    pendingTopics: seq[string]                    ## topics to (re)subscribe once the node is started

proc invoke(t: DeliveryTransport, meth, argsJson: string): JsonNode =
  ## One synchronous inter-module call. Returns the result JSON (or nil on error).
  ## On failure, logs the rc + delivery's error object to stderr (prefix MUSTER-LP)
  ## so a silent createNode/start failure — no transport, no node — is diagnosable
  ## in the host console instead of vanishing behind `discard`.
  var res, err: cstring
  let rc = lp_invoke(t.client, meth.cstring, argsJson.cstring, t.timeoutMs,
                     addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc == LP_OK and res != nil:
    try: return parseJson($res)
    except CatchableError:
      stderr.writeLine("MUSTER-LP " & meth & " rc=OK unparsable-result=" & $res)
      return nil
  stderr.writeLine("MUSTER-LP " & meth & " FAILED rc=" & $rc &
                   " err=" & (if err != nil: $err else: "<none>") &
                   " res=" & (if res != nil: $res else: "<none>"))
  nil

# ── the messageReceived trampoline ────────────────────────────────────────────
# lp_subscribe is per-event-name, so one subscription carries every topic and we
# route to the topic's handlers. user_data is the DeliveryTransport (GC_ref'd on
# subscribe, cast back here). The message hash we hand up is OUR content address
# (deterministic over topic+payload), so ingest dedups identically to
# LocalTransport regardless of delivery's own hash.
proc onMessageReceived(eventName, dataJson: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## Runs on the delivery module's thread. Do the minimum the GC can't own — copy
  ## the raw event JSON into the queue (malloc + copy, no Nim GC) and return.
  ## poll() parses and dispatches it later, on the module's own thread.
  if userData == nil or dataJson == nil: return
  cast[DeliveryTransport](userData).queue.enqueue(dataJson)

proc bytesToStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

# C-level logging for the foreign-thread callbacks — no Nim string ops (the GC is
# not this thread's), so raw result/error objects surface safely.
var cstderr {.importc: "stderr", header: "<stdio.h>".}: pointer
proc c_fprintf(stream: pointer, fmt: cstring): cint
  {.importc: "fprintf", header: "<stdio.h>", varargs, discardable.}

proc onSendResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## Fire-and-forget send/subscribe result. Logs raw (no Nim GC on this thread) so a
  ## failed publish (no peers on the shard / lightpush needed) is visible — the tell
  ## for send-side vs relay-side when cross-host frames don't arrive.
  if gLpDebug: c_fprintf(cstderr, "MUSTER-LP send/sub-result ok=%d json=%s\n",
            ok, (if json != nil: json else: cstring"<nil>"))

proc onStartResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## start() completion. Mark the node started so poll() can issue the topic
  ## subscribes that were deferred (a plain int write — no Nim GC on this thread).
  if gLpDebug: c_fprintf(cstderr, "MUSTER-LP start async ok=%d json=%s\n",
            ok, (if json != nil: json else: cstring"<nil>"))
  if userData != nil: cast[DeliveryTransport](userData).nodeStarted = 1

proc onCreateNodeResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## createNode completed on delivery's thread → log its result/error, then fire
  ## start(), also async, so the boot sequence stays off the caller's dispatch stack.
  if gLpDebug: c_fprintf(cstderr, "MUSTER-LP createNode async ok=%d json=%s\n",
            ok, (if json != nil: json else: cstring"<nil>"))
  if userData == nil: return
  let t = cast[DeliveryTransport](userData)
  discard lp_invoke_async(t.client, cstring"start", cstring"[]", t.timeoutMs,
                          onStartResult, userData)

proc newDeliveryTransport*(nodeConfigJson = "{}", timeoutMs = 5000): DeliveryTransport =
  ## Bind a client to delivery_module, boot its node, and open the single
  ## messageReceived subscription. `nodeConfigJson` is delivery's createNode config
  ## (the user-configurable endpoint set — invariant 8 lives in this string).
  result = DeliveryTransport(handlers: initTable[string, seq[MessageHandler]](),
                             timeoutMs: cint(timeoutMs))
  initInboundQueue(result.queue)             # ready before any callback can fire
  if gLpDebug: stderr.writeLine("MUSTER-LP creating delivery client (mode=" & $lp_get_mode() & ")")
  result.client = lp_client_create("delivery_module", "muster_module", nil, nil)
  if result.client == nil:
    raise newException(CatchableError, "delivery_module: lp_client_create returned null")
  # Keep `result` alive for the C side that holds the user_data pointer — BEFORE the
  # async boot, whose callback dereferences it.
  GC_ref(result)
  # Register the inbound handler first (local, no round-trip), then boot the node
  # ASYNC. createNode/start were synchronous, but newDeliveryTransport runs inside
  # coordinate_join's QRO dispatch — a nested event loop — where a synchronous
  # lp_invoke can't complete its own QRO round-trip and returns null (the node never
  # boots). lp_invoke_async queues the call and returns; it runs once the dispatch
  # unwinds and the event loop pumps. start() is chained from createNode's callback
  # so it still follows createNode. publish() already sends this way for the same
  # reason.
  result.sub = lp_subscribe(result.client, "messageReceived",
                            onMessageReceived, cast[pointer](result))
  var args = newJArray(); args.add %nodeConfigJson
  let argsStr = $args
  if gLpDebug: stderr.writeLine("MUSTER-LP createNode dispatched async")
  discard lp_invoke_async(result.client, cstring"createNode", argsStr.cstring,
                          result.timeoutMs, onCreateNodeResult, cast[pointer](result))

method publish*(t: DeliveryTransport, contentTopic: string, payload: seq[byte]): string =
  var args = newJArray()
  args.add %contentTopic
  args.add parseJson(bytesTag(payload))     # {"_bytes":"<b64url>"}
  # Fire-and-forget: a synchronous send would block the module's dispatch thread on
  # delivery's accept handshake, so hand off async. `argsStr` is held until the
  # call returns; lp_invoke_async copies the args before it does.
  let argsStr = $args
  discard lp_invoke_async(t.client, "send".cstring, argsStr.cstring, t.timeoutMs,
                          onSendResult, nil)
  messageHashOf(contentTopic, payload)      # our content address (ingest dedup key)

proc issueSubscribe(t: DeliveryTransport, contentTopic: string) =
  var args = newJArray(); args.add %contentTopic
  let argsStr = $args
  if gLpDebug: stderr.writeLine("MUSTER-LP subscribe " & contentTopic)
  discard lp_invoke_async(t.client, cstring"subscribe", argsStr.cstring,
                          t.timeoutMs, onSendResult, nil)

method subscribe*(t: DeliveryTransport, contentTopic: string, handler: MessageHandler) =
  if not t.handlers.hasKey(contentTopic):
    t.handlers[contentTopic] = @[]
    # Local routing is set up synchronously. The lp `subscribe` to delivery must
    # wait for the node to be STARTED — subscribe runs inside coordinate_join, when
    # createNode/start are only just dispatched (async), so subscribing now targets
    # a node that does not exist yet and the relay never registers the topic (no
    # cross-host messages ever arrive). Defer to poll(), which issues it once
    # onStartResult has set nodeStarted.
    if t.nodeStarted == 1: t.issueSubscribe(contentTopic)
    else: t.pendingTopics.add contentTopic
  t.handlers[contentTopic].add handler

method unsubscribe*(t: DeliveryTransport, contentTopic: string) =
  t.handlers.del contentTopic
  # delivery has no per-topic unsubscribe in the consumed contract; we stop routing.

method storeQuery*(t: DeliveryTransport, contentTopic: string): seq[IncomingMessage] =
  ## Best-effort catchup: delivery's storeQuery is outside the minimal contract
  ## (delivery_module.lidl) but present on the full module. If unavailable this
  ## returns empty, and catchup falls back to live subscription only.
  var args = newJArray(); args.add %contentTopic
  let res = t.invoke("storeQuery", $args)
  if res == nil or res.kind != JArray: return
  for m in res:
    if m.kind != JArray or m.len < 4: continue
    let topic = m[1].getStr()
    var payload: seq[byte]
    if m[2].kind == JObject and m[2].hasKey("_bytes"):
      payload = b64urlDecode(m[2]["_bytes"].getStr())
    result.add IncomingMessage(contentTopic: topic, payload: payload,
                               messageHash: messageHashOf(topic, payload),
                               timestamp: m[3].getBiggestInt().int64)

method poll*(t: DeliveryTransport) =
  ## Drain the foreign-thread queue and dispatch each `messageReceived` event to
  ## the topic's handlers — parsing, base64-decode, and handler work all run here,
  ## on the module's own thread, so they are GC-safe. The module calls this from
  ## its loop. Our content address is recomputed so ingest dedups identically to
  ## LocalTransport (R-2/R-4), independent of delivery's own hash.
  # The node has started (onStartResult) — issue any topic subscribes that were
  # deferred while it was booting. Runs on the module thread (GC-safe).
  if t.nodeStarted == 1 and t.pendingTopics.len > 0:
    for topic in t.pendingTopics: t.issueSubscribe(topic)
    t.pendingTopics = @[]
  for raw in t.queue.drain():
    if gLpDebug: stderr.writeLine("MUSTER-LP inbound frame received")
    var arr: JsonNode
    try: arr = parseJson(bytesToStr(raw))
    except CatchableError: continue
    if arr.kind != JArray or arr.len < 4: continue
    let topic = arr[1].getStr()
    var payload: seq[byte]
    if arr[2].kind == JObject and arr[2].hasKey("_bytes"):
      payload = b64urlDecode(arr[2]["_bytes"].getStr())
    let msg = IncomingMessage(contentTopic: topic, payload: payload,
                              messageHash: messageHashOf(topic, payload),
                              timestamp: arr[3].getBiggestInt().int64)
    if t.handlers.hasKey(topic):
      for h in t.handlers[topic]:
        if h != nil: h(msg)

proc close*(t: DeliveryTransport) =
  ## Release the subscription + client and drop the GC anchor.
  if t.sub != nil: (lp_unsubscribe(t.sub); t.sub = nil)
  if t.client != nil: (lp_client_destroy(t.client); t.client = nil)
  t.queue.close()
  GC_unref(t)
