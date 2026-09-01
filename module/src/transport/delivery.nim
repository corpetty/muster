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

import std/[json, tables, sets, strutils, os, times]
import ./transport
import ./lp_ffi
import ./inbound_queue

# Transport diagnostics — off unless MUSTER_LP_DEBUG is set. When the delivery
# node boot or cross-host relay misbehaves, this surfaces the lp createNode/start
# result, the topic subscribe, inbound frames, and send results on stderr. The
# foreign-thread callbacks read this bool (no GC) via c_fprintf (no Nim strings).
let gLpDebug* = getEnv("MUSTER_LP_DEBUG").len > 0

# Cross-host receive is store-polled (delivery's relay doesn't surface messages on
# our sparse shard, see docs/labbook/two-instance-live-wire-blockers.md), so these
# two knobs set the felt latency. The period is how often we re-query the store;
# the lookback is how far back each query reaches. A tight period makes messages
# arrive chat-fast, and the sliding lookback (below) keeps each query cheap so a
# tight period doesn't hammer the fleet store or re-parse the whole topic. Both
# are env-tunable for pushing snappier (or gentler on a shared store).
proc envMs(name: string, default, floor: int64): int64 =
  let e = getEnv(name)
  if e.len == 0: return default
  try: max(floor, parseInt(e).int64) except CatchableError: default

let gCatchupPeriodMs* = envMs("MUSTER_CATCHUP_MS", 1000, 200)
  ## re-query the store this often (ms). Default 1s ≈ chat cadence; floor 200ms.
let gCatchupLookbackMs* = max(gCatchupPeriodMs, envMs("MUSTER_CATCHUP_LOOKBACK_MS", 60_000, 1000))
  ## each steady-state query reaches back this far (ms). Wide enough to tolerate
  ## clock skew and a few missed polls (ingest dedups the overlap), small enough
  ## that a 1s cadence stays cheap. Never below the period.
const DeepCatchupTicks = 3
  ## the first few queries per topic fetch full recent history (no time bound) so a
  ## late joiner catches up on a room older than the lookback; then windowed.

type
  DeliveryTransport* = ref object of Transport
    client: ptr LpClient
    sub: ptr LpSubscription                       ## the single messageReceived subscription
    handlers: Table[string, seq[MessageHandler]]  ## contentTopic -> handlers (we route)
    queue: InboundQueue                           ## foreign-thread callbacks land here; poll() drains
    timeoutMs: cint
    nodeStarted: cint                             ## 1 once createNode+start returned; gates lifecycle
    storePeer: string                             ## a store service multiaddr (first entryNode); "" disables catchup
    storeQueue: InboundQueue                      ## async store-query responses land here; poll() parses them
    lastCatchupMs: int64                          ## throttle: only re-query the store every gCatchupPeriodMs
    catchupTicks: Table[string, int]              ## per-topic query count; first DeepCatchupTicks fetch full history, then windowed

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
  ## Fire-and-forget send result. Logs raw (no Nim GC on this thread) so a failed
  ## publish (no peers on the shard) is visible under MUSTER_LP_DEBUG — the tell for
  ## send-side vs receive-side when cross-host frames don't arrive.
  if gLpDebug: c_fprintf(cstderr, "MUSTER-LP send/sub-result ok=%d json=%s\n",
            ok, (if json != nil: json else: cstring"<nil>"))

proc onStoreResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## Async storeQuery response, on delivery's thread. Enqueue the raw JSON (malloc +
  ## copy, no Nim GC) — poll() parses it on the module thread and ingests the missed
  ## messages, exactly like a live messageReceived. This is the mesh-independent
  ## receive path: even when the relay never surfaces a message, the store has it.
  if gLpDebug: c_fprintf(cstderr, "MUSTER-LP store result ok=%d\n", ok)
  if userData == nil or json == nil: return
  cast[DeliveryTransport](userData).storeQueue.enqueue(json)

proc newDeliveryTransport*(nodeConfigJson = "{}", timeoutMs = 5000): DeliveryTransport =
  ## Bind a client to delivery_module, boot its node, and open the single
  ## messageReceived subscription. `nodeConfigJson` is delivery's createNode config
  ## (the user-configurable endpoint set — invariant 8 lives in this string).
  result = DeliveryTransport(handlers: initTable[string, seq[MessageHandler]](),
                             catchupTicks: initTable[string, int](),
                             timeoutMs: cint(timeoutMs))
  initInboundQueue(result.queue)             # ready before any callback can fire
  initInboundQueue(result.storeQueue)
  # A store service peer for offline/mesh-independent catchup — the first entryNode
  # of the delivery config (the fleet's own nodes serve store). "" if none.
  try:
    let j = parseJson(nodeConfigJson)
    if j.kind == JObject and j.hasKey("entryNodes") and j["entryNodes"].kind == JArray and
       j["entryNodes"].len > 0:
      result.storePeer = j["entryNodes"][0].getStr()
  except CatchableError: discard
  if gLpDebug: stderr.writeLine("MUSTER-LP creating delivery client (mode=" & $lp_get_mode() & ")")
  result.client = lp_client_create("delivery_module", "muster_module", nil, nil)
  if result.client == nil:
    raise newException(CatchableError, "delivery_module: lp_client_create returned null")
  # Boot the node synchronously (createNode → start), THEN register the inbound
  # messageReceived handler — the order the working chat bridge uses. With the
  # module token now saved (logos_module_accept_token → lp_token_save), the
  # synchronous createNode reaches delivery and succeeds; the async variant booted
  # the node but the receive path never surfaced messages, so we match the proven
  # sync ordering (the event handler is registered against a started node).
  var args = newJArray(); args.add %nodeConfigJson
  let cn = result.invoke("createNode", $args)
  if gLpDebug: stderr.writeLine("MUSTER-LP createNode result=" & (if cn != nil: $cn else: "<nil>"))
  discard result.invoke("start", "[]")
  result.nodeStarted = 1
  GC_ref(result)                             # keep alive for the C-held user_data
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
    if gLpDebug: stderr.writeLine("MUSTER-LP subscribe " & contentTopic)
    discard t.invoke("subscribe", $args)     # tell delivery we want this topic (sync)
  t.handlers[contentTopic].add handler

method unsubscribe*(t: DeliveryTransport, contentTopic: string) =
  t.handlers.del contentTopic
  # delivery has no per-topic unsubscribe in the consumed contract; we stop routing.

method storeQuery*(t: DeliveryTransport, contentTopic: string): seq[IncomingMessage] =
  ## Superseded by the async, poll-driven store catchup (fireCatchup + poll). Kept as
  ## a no-op so the Transport seam stays satisfied; session.catchUp is a no-op on this
  ## transport (LocalTransport still implements the synchronous form for tests).
  @[]

proc fireCatchup(t: DeliveryTransport, contentTopic: string) =
  ## Ask a store service peer for the messages retained on `contentTopic` — the
  ## mesh-independent receive path. Async (like createNode/send) so it never blocks
  ## poll's dispatch; onStoreResult enqueues the response, poll parses it. The query
  ## follows delivery's storeQuery(jsonQuery, peerAddr, timeoutMs) contract.
  ##
  ## The first DeepCatchupTicks queries fetch full recent history (no time bound) so
  ## a late joiner catches up; after that each query is bounded to `timeStart = now -
  ## gCatchupLookbackMs`, a sliding window that stays cheap however long the room runs,
  ## so a 1s cadence doesn't re-parse the whole topic. Ingest dedups the window overlap
  ## (R-2/R-4), and the log reduces order-independently (inv 4), so paginationForward
  ## (kept `true`, the proven direction) and the window boundary are both harmless.
  if t.storePeer.len == 0: return
  let nowMs = int64(epochTime() * 1000)
  let tick = t.catchupTicks.getOrDefault(contentTopic, 0)
  t.catchupTicks[contentTopic] = tick + 1
  var req = %*{"requestId": "muster-" & $nowMs,
               "includeData": true, "paginationForward": true,
               "contentTopics": [contentTopic], "paginationLimit": 50}
  if tick >= DeepCatchupTicks:
    # Waku store filters on the message's own (nanosecond) timestamp. Second-precision
    # is plenty for a floor and avoids float64 losing ns digits at epoch scale.
    req["timeStart"] = %((nowMs - gCatchupLookbackMs) * 1_000_000)
  var args = newJArray()
  args.add %($req)                 # jsonQuery (tstr)
  args.add %t.storePeer            # peerAddr (tstr)
  args.add %(t.timeoutMs.int)      # timeoutMs (int)
  let argsStr = $args
  if gLpDebug: stderr.writeLine("MUSTER-LP storeQuery " & contentTopic &
                                (if tick >= DeepCatchupTicks: " windowed" else: " deep"))
  discard lp_invoke_async(t.client, cstring"storeQuery", argsStr.cstring,
                          t.timeoutMs, onStoreResult, cast[pointer](t))

method poll*(t: DeliveryTransport) =
  ## Drain the foreign-thread queue and dispatch each `messageReceived` event to
  ## the topic's handlers — parsing, base64-decode, and handler work all run here,
  ## on the module's own thread, so they are GC-safe. The module calls this from
  ## its loop. Our content address is recomputed so ingest dedups identically to
  ## LocalTransport (R-2/R-4), independent of delivery's own hash.
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

  # Mesh-independent catchup: periodically ask the store for each subscribed topic,
  # so a message the relay never surfaced (sparse-shard mesh) still arrives. Fire on
  # the module thread (async invoke returns immediately); responses land on the store
  # queue, parsed below.
  if t.storePeer.len > 0 and t.nodeStarted == 1:
    let nowMs = int64(epochTime() * 1000)
    if nowMs - t.lastCatchupMs > gCatchupPeriodMs:
      t.lastCatchupMs = nowMs
      for topic in t.handlers.keys: t.fireCatchup(topic)

  for raw in t.storeQueue.drain():
    # Parse a store response and dispatch each retained message exactly like a live
    # one — ingest dedups our own (R-2/R-4), so only genuinely-missed messages take
    # effect. Shape (confirmed on the logos.test fleet):
    #   { "value": "<json string>" }                       # lp result envelope
    #   value -> { "messages": [ { "messageHash",
    #       "message": { "vResultPrivate": { "contentTopic", "payload": [byte,…] } } } ] }
    var env: JsonNode
    try: env = parseJson(bytesToStr(raw))
    except CatchableError: continue
    if env.kind != JObject or not env.hasKey("value"): continue
    var resp: JsonNode
    try: resp = parseJson(env["value"].getStr())
    except CatchableError: continue
    if resp.kind != JObject or not resp.hasKey("messages") or resp["messages"].kind != JArray:
      continue
    for m in resp["messages"]:
      if m.kind != JObject or not m.hasKey("message"): continue
      var wm = m["message"]
      if wm.kind == JObject and wm.hasKey("vResultPrivate"): wm = wm["vResultPrivate"]
      if wm.kind != JObject or not wm.hasKey("contentTopic") or not wm.hasKey("payload"):
        continue
      let topic = wm["contentTopic"].getStr()
      if wm["payload"].kind != JArray or not t.handlers.hasKey(topic): continue
      var payload = newSeqOfCap[byte](wm["payload"].len)
      for b in wm["payload"]: payload.add byte(b.getInt() and 0xFF)
      if payload.len == 0: continue
      let msg = IncomingMessage(contentTopic: topic, payload: payload,
                                messageHash: messageHashOf(topic, payload), timestamp: 0)
      if gLpDebug: stderr.writeLine("MUSTER-LP store message topic=" & topic &
                                    " bytes=" & $payload.len)
      for h in t.handlers[topic]:
        if h != nil: h(msg)

proc close*(t: DeliveryTransport) =
  ## Release the subscription + client and drop the GC anchor.
  if t.sub != nil: (lp_unsubscribe(t.sub); t.sub = nil)
  if t.client != nil: (lp_client_destroy(t.client); t.client = nil)
  t.queue.close()
  GC_unref(t)
