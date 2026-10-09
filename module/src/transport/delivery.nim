## DeliveryTransport — the real-network Transport (ADR-006), consuming
## `logos-delivery-module` over the `lp_*` C ABI (see logos_sdk/ffi). It is a
## Transport like LocalTransport, so everything above it (the epoch layer, F-16)
## is unchanged whether it runs on the in-process bus or a real Waku fleet.
##
## Wire contract matched to what delivery expects (from the chat module's own
## delivery bridge): `send(contentTopic: tstr, payload: bstr)`,
## `subscribe(contentTopic: tstr)`, and the `messageReceived(messageHash,
## contentTopic, payload, [source,] timestamp)` event (v0.3.0 added `source`,
## received.nim); `bstr` rides the tagged {"_bytes":"<base64url>"} form.
##
## NOT compiled by pure-Nim `nim r` — it needs logos-protocol linked (the plugin
## build provides it). Live two-instance verification, and hardening the event
## callback's foreign-thread GC seam (the storage-nim `abandoned`-flag pattern),
## come with the P3 integration harness; this increment establishes the binding.

import std/[json, tables, sets, strutils, os, times]
import ./transport
import logos_sdk/ffi        # lp_* C-ABI bindings (was ./lp_ffi, now the shared SDK)
import logos_sdk/bytes      # {"_bytes":<b64url>} codec
import ./inbound_queue
import ./store_catchup    # which store query next: a topic's whole history, then the window (exo-aaf)
import ./received         # a messageReceived event, v0.2 or v0.3 (exo-eb6.1)
import ./node_config      # what createNode gets, and the store peers (exo-eb6.1)

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

var gStoreFailed, gStoreAnswered = 0   ## store responses seen, under MUSTER_LP_DEBUG

let gCatchupPeriodMs* = envMs("MUSTER_CATCHUP_MS", 1000, 200)
  ## re-query the store this often (ms). Default 1s ≈ chat cadence; floor 200ms.
let gCatchupWindowMs* = envMs("MUSTER_CATCHUP_WINDOW_MS", 15_000, 0)
  ## once a topic's history is read, its sliding window is asked only this often (ms).
  ## On delivery v0.3.0 live receive works and the module backfills on its own, so the
  ## window is a safety net; a query per topic per second held the module on dead store
  ## dials and stalled its sends (exo-eb6.1). 0 = every catch-up tick, as on v0.2.
let gStoreTimeoutMs* = envMs("MUSTER_STORE_TIMEOUT_MS", 3000, 500)
  ## how long delivery may spend on one store query; one to a dead peer holds it that long
let gCatchupLookbackMs* = max(max(gCatchupPeriodMs, gCatchupWindowMs) * 2,
                              envMs("MUSTER_CATCHUP_LOOKBACK_MS", 60_000, 1000))
  ## each steady-state query reaches back this far (ms). Wide enough to tolerate
  ## clock skew and a few missed polls (ingest dedups the overlap), small enough
  ## that a 1s cadence stays cheap. Never below the period.

type
  DeliveryTransport* = ref object of Transport
    client: ptr LpClient
    sub: ptr LpSubscription                       ## the single messageReceived subscription
    handlers: Table[string, seq[MessageHandler]]  ## contentTopic -> handlers (we route)
    queue: InboundQueue                           ## foreign-thread callbacks land here; poll() drains
    timeoutMs: cint
    nodeStarted: cint                             ## 1 once createNode+start returned; gates lifecycle
    catchup: StoreCatchup                         ## store peers (all entryNodes; none disables catchup) + each topic's paging
    storeQueue: InboundQueue                      ## async store-query responses land here; poll() parses them
    lastCatchupMs: int64                          ## throttle: only re-query the store every gCatchupPeriodMs
    asked: string                                 ## the anonymityLevel createNode was given (exo-dcc.4)

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

var gNodeBooted = false   ## this module instance booted delivery's node (exo-dcc.12)

proc newDeliveryTransport*(nodeConfigJson = "{}", timeoutMs = 5000, mix = mixOff): DeliveryTransport =
  ## Bind a client to delivery_module, boot its node, and open the single
  ## messageReceived subscription. `nodeConfigJson` is delivery's createNode config
  ## (the user-configurable endpoint set — invariant 8 lives in this string); `mix` is
  ## the mix setting, which asks delivery to send through the mixnet (exo-dcc.4).
  result = DeliveryTransport(handlers: initTable[string, seq[MessageHandler]](),
                             timeoutMs: cint(timeoutMs))
  initInboundQueue(result.queue)             # ready before any callback can fire
  initInboundQueue(result.storeQueue)
  # Store service peers for mesh-independent catchup — ALL entryNodes of the delivery
  # config (the fleet's own nodes serve store). fireCatchup round-robins across them,
  # so a peer that's down or throttling stalls one tick, not the whole catchup. Empty
  # if the config names none (catchup then disabled). What createNode itself gets is
  # node_config.nim's (exo-eb6.1): a preset's config without its entryNodes, QUIC off
  # unless MUSTER_DELIVERY_QUIC=1.
  # the node logs at INFO unless MUSTER_DELIVERY_LOG names a level (exo-9eed): DEBUG is
  # many lines a second, into the host's uncapped log
  let nc = nodeConfigFor(nodeConfigJson, quic = getEnv("MUSTER_DELIVERY_QUIC") == "1",
                         logLevel = getEnv("MUSTER_DELIVERY_LOG", "INFO"), mix = mix)
  result.asked = anonymityOf(nc.createNode)
  result.catchup = newStoreCatchup(nc.storePeers)
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
  # ONE node per module instance (exo-dcc.12): delivery refuses a second createNode
  # ("Context already…"), and a second start on a node still starting crashed delivery
  # 0.3.2 on relaunch, when the inbox and every restored room each booted in the same
  # call (an unhandled `len(a) == L` in its dial, every store query then null). So only
  # the first transport boots it; the rest bind to the running node.
  if not gNodeBooted:
    if gLpDebug: stderr.writeLine("MUSTER-LP createNode config=" & nc.createNode)
    var args = newJArray(); args.add %nc.createNode
    let cn = result.invoke("createNode", $args)
    if gLpDebug: stderr.writeLine("MUSTER-LP createNode result=" & (if cn != nil: $cn else: "<nil>"))
    discard result.invoke("start", "[]")
    gNodeBooted = true
  elif gLpDebug: stderr.writeLine("MUSTER-LP delivery node already booted; binding to it")
  result.nodeStarted = 1
  GC_ref(result)                             # keep alive for the C-held user_data
  result.sub = lp_subscribe(result.client, "messageReceived",
                            onMessageReceived, cast[pointer](result))

method securityLevel*(t: DeliveryTransport): SecurityLevel =
  ## The real network transport still provides no security level of its own (exo-1ec.5) — it
  ## carries the epoch-sealed payload opaquely. Its rung stays null; the override exists only
  ## to name honestly what the real path DOES expose: a store node on the fleet sees the
  ## topic and timing of every message (metadata, FS-9), even though it cannot read the
  ## payload. That is a reason to prefer the mixnet, not a security the transport adds.
  securityLevel(
    axisLevel(rungNull, "not authenticated here — the driver binds the speaker"),
    axisLevel(rungNull, "not attested here — the log attests provenance"),
    axisLevel(rungNull, "payload opaque (epoch-sealed); but topic + timing are visible to the store node (FS-9)"))

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
  ## Which query is store_catchup's (exo-aaf): a topic is first read WHOLE — paged from
  ## its start, following the store's cursor on the peer that issued it — so a member who
  ## joins or relaunches rebuilds the entire room, not its oldest page and its last
  ## minute. Then each query reaches back `gCatchupLookbackMs`, a sliding window that stays
  ## cheap however long the room runs. Ingest dedups every overlap (R-2/R-4), and the log
  ## reduces order-independently (inv 4).
  let q = t.catchup.nextQuery(contentTopic, int64(epochTime() * 1000), gCatchupLookbackMs,
                              windowEveryMs = gCatchupWindowMs)
  if not q.fire: return
  var args = newJArray()
  args.add %($q.req)               # jsonQuery (tstr)
  args.add %q.peer                 # peerAddr (tstr)
  args.add %(gStoreTimeoutMs.int)   # timeoutMs (int): bounded, a dead peer holds delivery this long
  let argsStr = $args
  if gLpDebug: stderr.writeLine("MUSTER-LP storeQuery " & contentTopic &
                                (if q.deep: " deep" & (if q.req.hasKey("paginationCursor"): " cursor" else: "")
                                 else: " windowed") & " peer=" & q.peer)
  discard lp_invoke_async(t.client, cstring"storeQuery", argsStr.cstring,
                          t.timeoutMs, onStoreResult, cast[pointer](t))

# The debug log names each inbound message once (exo-9eed): the store catch-up re-reads a
# room's last minute every second, so logging every delivery logged each message ~60 times.
var gLoggedInbound: HashSet[string]
var gLoggedOrder: seq[string]
const LoggedInboundCap = 4096

proc firstSighting(hash: string): bool {.gcsafe.} =
  ## poll runs on the module's own thread (inbound_queue's seam), the only one that logs
  {.cast(gcsafe).}:
    if hash in gLoggedInbound: return false
    gLoggedInbound.incl hash
    gLoggedOrder.add hash
    if gLoggedOrder.len > LoggedInboundCap:
      gLoggedInbound.excl gLoggedOrder[0]
      gLoggedOrder.delete(0)
    true

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
    var ev: ReceivedEvent                # delivery v0.2 or v0.3 (source before timestamp)
    if not parseMessageReceived(arr, ev): continue
    let topic = ev.contentTopic
    let payload = ev.payload
    let msg = IncomingMessage(contentTopic: topic, payload: payload,
                              messageHash: messageHashOf(topic, payload),
                              timestamp: ev.timestamp)
    if gLpDebug and firstSighting(msg.messageHash):
      stderr.writeLine("MUSTER-LP inbound source=" & ev.source & " topic=" & ev.contentTopic &
                       " bytes=" & $ev.payload.len)
    if t.handlers.hasKey(topic):
      for h in t.handlers[topic]:
        if h != nil: h(msg)

  # Mesh-independent catchup: periodically ask the store for each subscribed topic,
  # so a message the relay never surfaced (sparse-shard mesh) still arrives. Fire on
  # the module thread (async invoke returns immediately); responses land on the store
  # queue, parsed below.
  if t.catchup.peers.len > 0 and t.nodeStarted == 1:
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
    if gLpDebug:                         # the first few of each kind whole: their shape is checked live
      let r = bytesToStr(raw)
      let failed = r.contains("\"success\":false")
      if failed: inc gStoreFailed else: inc gStoreAnswered
      if (failed and gStoreFailed <= 3) or (not failed and gStoreAnswered <= 4):
        stderr.writeLine("MUSTER-LP store response (" & (if failed: "failed #" & $gStoreFailed
                         else: "answered #" & $gStoreAnswered) & "): " & r[0 ..< min(r.len, 900)])
    var env: JsonNode
    try: env = parseJson(bytesToStr(raw))
    except CatchableError: continue
    let down = dialFailurePeer(env)            # a peer we could not dial: back it off
    if down.len > 0:
      t.catchup.onPeerFailure(down, int64(epochTime() * 1000))
      continue
    if env.kind != JObject or not env.hasKey("value"): continue
    var resp: JsonNode
    try: resp = parseJson(env["value"].getStr())
    except CatchableError: continue
    t.catchup.onResponse(resp)       # the next page of a topic's history, or: read whole
    if resp.kind != JObject or not resp.hasKey("messages") or resp["messages"].kind != JArray:
      continue
    for m in resp["messages"]:
      if m.kind != JObject or not m.hasKey("message"): continue
      var wm = m["message"]
      if wm.kind == JObject and wm.hasKey("vResultPrivate"): wm = wm["vResultPrivate"]
      if wm.kind != JObject or not wm.hasKey("contentTopic") or not wm.hasKey("payload"):
        if gLpDebug: stderr.writeLine("MUSTER-LP store message unread: " & ($m)[0 ..< min(($m).len, 400)])
        continue
      let topic = wm["contentTopic"].getStr()
      var payload: seq[byte]
      if not storedPayload(wm["payload"], payload):
        if gLpDebug: stderr.writeLine("MUSTER-LP store payload unread (" & $wm["payload"].kind & "): " &
                                      ($wm["payload"])[0 ..< min(($wm["payload"]).len, 200)])
        continue
      if not t.handlers.hasKey(topic): continue
      if payload.len == 0: continue
      let msg = IncomingMessage(contentTopic: topic, payload: payload,
                                messageHash: messageHashOf(topic, payload), timestamp: 0)
      if gLpDebug and firstSighting(msg.messageHash):   # once per message, as inbound (exo-9eed)
        stderr.writeLine("MUSTER-LP store message topic=" & topic & " bytes=" & $payload.len)
      for h in t.handlers[topic]:
        if h != nil: h(msg)

method rlnState*(t: DeliveryTransport): string {.gcsafe.} =
  ## delivery v0.3.0's rlnState(): local to the module (no chain), so asked directly.
  ## "" when the call fails or the node predates it.
  try:
    let r = t.invoke("rlnState", "[]")
    if r == nil: "" else: $r
  except CatchableError: ""

method nodeInfo*(t: DeliveryTransport): string {.gcsafe.} =
  ## The delivery node's own view of itself (getNodeInfo) — proof the embedded lp
  ## node actually booted, for the connectivity indicator. "{}" if the call fails
  ## (node not up / unreachable), so a down node reads as down, never a false green.
  try: $t.invoke("getNodeInfo", "[]")
  except CatchableError: "{}"

method mixInputs*(t: DeliveryTransport): MixInputs {.gcsafe.} =
  ## The node's mix path (exo-dcc.4): the level createNode was given, the mix key the
  ## node mounted (getNodeInfo MyMixPubKey: "" when mix is not mounted), its metrics
  ## (the mix_pool_size gauge) and its connection status (Required reports Disconnected
  ## until a mix exit is ready). All local to the module, no network; asked only when a
  ## level above None was given.
  result = MixInputs(asked: t.asked, joined: t.nodeStarted == 1)
  if t.asked == "None" or t.nodeStarted != 1: return
  try:
    let k = t.invoke("getNodeInfo", $(%*["MyMixPubKey"]))
    if k != nil and nodeInfoOk($k): (result.pubKeyRead = true; result.pubKey = $k)
    let m = t.invoke("getNodeInfo", $(%*["Metrics"]))
    if m != nil and nodeInfoOk($m): result.metrics = $m
    let c = t.invoke("getConnectionStatus", "[]")
    if c != nil and nodeInfoOk($c): result.connection = $c
  except CatchableError: discard

method detach*(t: DeliveryTransport) =
  ## Stop taking traffic (exo-dcc.28): drop the messageReceived subscription, which
  ## queues every topic's messages, and every route. The client and the GC anchor stay,
  ## so a store answer already in flight lands on a live object rather than freed memory
  ## (the `abandoned` lesson); its one queued reply is never polled. The node is shared
  ## and keeps running for the rooms still joined.
  if t.sub != nil: (lp_unsubscribe(t.sub); t.sub = nil)
  t.handlers.clear()

proc close*(t: DeliveryTransport) =
  ## Release the subscription + client and drop the GC anchor.
  if t.sub != nil: (lp_unsubscribe(t.sub); t.sub = nil)
  if t.client != nil: (lp_client_destroy(t.client); t.client = nil)
  t.queue.close()
  GC_unref(t)
