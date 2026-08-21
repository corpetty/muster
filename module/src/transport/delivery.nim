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

import std/[json, tables]
import ./transport
import ./lp_ffi
import ./inbound_queue

type
  DeliveryTransport* = ref object of Transport
    client: ptr LpClient
    sub: ptr LpSubscription                       ## the single messageReceived subscription
    handlers: Table[string, seq[MessageHandler]]  ## contentTopic -> handlers (we route)
    queue: InboundQueue                           ## foreign-thread callbacks land here; poll() drains
    timeoutMs: cint

proc invoke(t: DeliveryTransport, meth, argsJson: string): JsonNode =
  ## One synchronous inter-module call. Returns the result JSON (or nil on error).
  var res, err: cstring
  let rc = lp_invoke(t.client, meth.cstring, argsJson.cstring, t.timeoutMs,
                     addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc == LP_OK and res != nil:
    try: return parseJson($res)
    except CatchableError: return nil
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

proc onSendResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## Fire-and-forget send result. Runs on delivery's thread — a no-op, so it never
  ## touches the GC. A failed send is not surfaced (a "sent" confirmation is future
  ## work), matching the chat module's own delivery bridge.
  discard

proc newDeliveryTransport*(nodeConfigJson = "{}", timeoutMs = 5000): DeliveryTransport =
  ## Bind a client to delivery_module, boot its node, and open the single
  ## messageReceived subscription. `nodeConfigJson` is delivery's createNode config
  ## (the user-configurable endpoint set — invariant 8 lives in this string).
  result = DeliveryTransport(handlers: initTable[string, seq[MessageHandler]](),
                             timeoutMs: cint(timeoutMs))
  initInboundQueue(result.queue)             # ready before any callback can fire
  result.client = lp_client_create("delivery_module", "muster_module", nil, nil)
  if result.client == nil:
    raise newException(CatchableError, "delivery_module: lp_client_create returned null")
  var args = newJArray(); args.add %nodeConfigJson
  discard result.invoke("createNode", $args)
  discard result.invoke("start", "[]")
  # Keep `result` alive for the C side that holds the user_data pointer.
  GC_ref(result)
  result.sub = lp_subscribe(result.client, "messageReceived",
                            onMessageReceived, cast[pointer](result))

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

method subscribe*(t: DeliveryTransport, contentTopic: string, handler: MessageHandler) =
  if not t.handlers.hasKey(contentTopic):
    t.handlers[contentTopic] = @[]
    var args = newJArray(); args.add %contentTopic
    discard t.invoke("subscribe", $args)    # tell delivery we want this topic
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
  for raw in t.queue.drain():
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
