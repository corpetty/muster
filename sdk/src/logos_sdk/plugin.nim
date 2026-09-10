## PluginProxy — typed method calls and event subscriptions to another Logos
## module, over the `lp_*` C ABI. The Nim mirror of logos-rust-sdk `src/plugin.rs`
## (and the generalization of muster's `src/transport/delivery.nim`, which is one
## hand-written proxy to `delivery_module`).
##
## A generated consumer client (lidl-gen `--client`) wraps one of these per
## dependency and exposes each contract method as a typed Nim proc, so module code
## calls `deps.counter.increment(1)` rather than `proxy.callSync("increment", …)`.

import std/[json, tables]
import ./ffi
import ./bytes

export bytes.bytesTag, bytes.b64urlEncode, bytes.b64urlDecode

type
  CallResult* = object
    ## The outcome of one synchronous call. `ok` mirrors the ABI's rc; on success
    ## `value` is the parsed result JSON, on failure `error` is the parsed error
    ## object. `raw` keeps the exact returned string for diagnostics.
    ok*: bool
    value*: JsonNode
    error*: JsonNode
    raw*: string

  PluginProxy* = ref object
    ## A handle to one target module. Cheap to create; the underlying `lp_client`
    ## is shared per target (see the cache below), so many proxies to the same
    ## module coalesce onto one capability handshake — the reason a fan-out does
    ## not race N handshakes whose tokens overwrite each other.
    target*: string
    origin*: string

  EventSubscription* = ref object
    sub: ptr LpSubscription

# ── shared client cache (one lp_client per target module) ──────────────────────
# logos-rust-sdk holds a Weak per target and re-creates on demand; Nim has no Arc,
# so we keep a plain process-global map and a persistent client per target for the
# plugin's lifetime (a module process is long-lived; clients are cheap to hold and
# expensive to re-handshake). close()/destroyClient() drop one explicitly.
var gClients {.threadvar.}: TableRef[string, ptr LpClient]

proc clientFor(target, origin, targetTransportJson, capabilityTransportJson: string): ptr LpClient =
  if gClients == nil: gClients = newTable[string, ptr LpClient]()
  if target in gClients and gClients[target] != nil:
    return gClients[target]
  let tt = (if targetTransportJson.len > 0: targetTransportJson.cstring else: nil)
  let ct = (if capabilityTransportJson.len > 0: capabilityTransportJson.cstring else: nil)
  let c = lp_client_create(target.cstring, origin.cstring, tt, ct)
  if c != nil: gClients[target] = c
  c

proc newPluginProxy*(target: string, origin = "core"): PluginProxy =
  ## A proxy for calling `target`. `origin` is this module's own name (the
  ## identity the target authorizes). The client is created lazily on first call.
  PluginProxy(target: target, origin: origin)

proc client*(p: PluginProxy, targetTransportJson = "", capabilityTransportJson = ""): ptr LpClient =
  ## The shared lp_client for this proxy's target, created on first use. Nil means
  ## the create failed (e.g. the target module is not loaded) — callers surface it.
  clientFor(p.target, p.origin, targetTransportJson, capabilityTransportJson)

# ── argument helpers ───────────────────────────────────────────────────────────

proc bytesArg*(data: openArray[byte]): JsonNode =
  ## A `bstr` positional argument as its tagged JSON object `{"_bytes": …}`.
  parseJson(bytesTag(data))

proc args*(items: varargs[JsonNode]): JsonNode =
  ## Build the positional-args JSON array a call expects.
  result = newJArray()
  for it in items: result.add it

# ── calls ──────────────────────────────────────────────────────────────────────

proc callSync*(p: PluginProxy, meth: string, callArgs: JsonNode = newJArray(),
               timeoutMs: cint = 0): CallResult =
  ## One synchronous inter-module call. `timeoutMs <= 0` uses the ABI default
  ## (~20s). Never raises on a transport error — inspect `.ok`/`.error`.
  let c = p.client()
  if c == nil:
    return CallResult(ok: false, error: %*{"error": "lp_client_create returned null",
                                           "target": p.target})
  let argsStr = $callArgs
  var res, err: cstring
  let rc = lp_invoke(c, meth.cstring, argsStr.cstring, timeoutMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc == LP_OK and res != nil:
    let raw = $res
    var v: JsonNode = nil
    try: v = parseJson(raw)
    except CatchableError: v = %raw
    return CallResult(ok: true, value: v, raw: raw)
  var e: JsonNode = nil
  if err != nil:
    try: e = parseJson($err)
    except CatchableError: e = %($err)
  CallResult(ok: false, error: e, raw: (if err != nil: $err else: ""))

proc callAsync*(p: PluginProxy, meth: string, callArgs: JsonNode,
                cb: LpResultCb, userData: pointer = nil, timeoutMs: cint = 0): bool =
  ## Asynchronous call. The typed result lands on `cb` (running on the target's
  ## thread — do the minimum there; copy anything you keep). Returns false if the
  ## client could not be created. The ABI copies `callArgs` before returning.
  let c = p.client()
  if c == nil: return false
  let argsStr = $callArgs
  lp_invoke_async(c, meth.cstring, argsStr.cstring, timeoutMs, cb, userData) == LP_OK

proc subscribe*(p: PluginProxy, eventName: string, cb: LpEventCb,
                userData: pointer = nil): EventSubscription =
  ## Subscribe to `eventName` on the target. One subscription carries every
  ## payload for that event name; route inside `cb`. `cb` runs on the target's
  ## thread. Returns nil if the client could not be created.
  let c = p.client()
  if c == nil: return nil
  let s = lp_subscribe(c, eventName.cstring, cb, userData)
  if s == nil: return nil
  EventSubscription(sub: s)

proc unsubscribe*(s: EventSubscription) =
  if s != nil and s.sub != nil:
    lp_unsubscribe(s.sub)
    s.sub = nil

proc methodsOf*(p: PluginProxy): JsonNode =
  ## The target's method descriptors, parsed. Empty array if unavailable.
  let c = p.client()
  if c == nil: return newJArray()
  let m = lp_get_methods(c)
  if m == nil: return newJArray()
  defer: lp_string_free(m)
  try: parseJson($m)
  except CatchableError: newJArray()

proc destroyClient*(p: PluginProxy) =
  ## Drop the shared client for this proxy's target (next call re-creates). Rarely
  ## needed — a module process holds its clients for life.
  if gClients != nil and p.target in gClients and gClients[p.target] != nil:
    lp_client_destroy(gClients[p.target])
    gClients.del(p.target)

# ── result-envelope helper ──────────────────────────────────────────────────────

proc unwrap*(r: CallResult): JsonNode =
  ## Many module methods return a `{"success":bool,"value":…,"error":…}` envelope.
  ## This returns the inner `value` when the call and the envelope both succeeded,
  ## else raises with the error. A method that returns a bare value passes through.
  if not r.ok:
    raise newException(CatchableError, "call failed: " & $r.error)
  if r.value != nil and r.value.kind == JObject and r.value.hasKey("success"):
    if r.value["success"].getBool():
      return (if r.value.hasKey("value"): r.value["value"] else: newJNull())
    raise newException(CatchableError, "method error: " &
      (if r.value.hasKey("error"): $r.value["error"] else: "<unspecified>"))
  r.value
