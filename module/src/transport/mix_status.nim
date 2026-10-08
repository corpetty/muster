## The node's mix path, as one status row (exo-dcc.4). Pure: it reads the replies
## muster_module gathers from delivery and says what a send does now. Never a false
## green: an unread reply is "unknown".
##
## Delivery v0.3 routes a send through the mixnet when the createNode config's
## `anonymityLevel` is above None (node_config.nim writes it from the `mix` setting).
## A send then goes as a Sphinx packet over three mix hops to a lightpush exit, which
## publishes it: the relay and store nodes get the message from the exit, not from this
## node. A path needs four mix nodes the node knows (three hops and the exit:
## logos_delivery MinMixPoolSize). Below that a Preferred send takes the plain path at
## once and a Required send waits, then fails. Mix carries sends only: every store
## query (muster's own catch-up, delivery's backfill) still leaves from this node's own
## address and names the room's topic, so the row says that too.
## Evidence and the live runs: docs/labbook/mixnet-on-delivery-03.md.

import std/[json, strutils]

const
  MinMixPool* = 4
    ## logos_delivery's MinMixPoolSize: three hops plus the exit
  SendsOnly* = "Mix carries this node's sends only. Its store queries, the room's " &
    "catch-up among them, still leave from its own address and name the room's topic, " &
    "so a store node still sees which rooms it reads and when."

type
  MixInputs* = object
    asked*: string        ## the level createNode asked for: None | Preferred | Required
    joined*: bool         ## a delivery node exists (a room was joined)
    pubKeyRead*: bool     ## getNodeInfo("MyMixPubKey") answered
    pubKey*: string       ## its reply, raw: the node's mix key, "" when mix is not mounted
    metrics*: string      ## getNodeInfo("Metrics") reply, raw ("" unread)
    connection*: string   ## getConnectionStatus reply, raw ("" unread)

proc nodeInfoValue*(raw: string): string =
  ## A getNodeInfo / getConnectionStatus reply's value, however it arrives: bare, a JSON
  ## string, or inside the lp result envelope {success, value}. "" when it carries none.
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return raw.strip()
  for _ in 0 .. 3:
    case j.kind
    of JString:
      let s = j.getStr()
      try: j = parseJson(s)
      except CatchableError: return s
    of JObject:
      if j.hasKey("value") and j{"success"}.getBool(true): j = j["value"]
      else: return ""
    of JInt, JFloat, JBool: return $j
    else: return ""
  ""

proc nodeInfoOk*(raw: string): bool =
  ## Whether a reply answered at all: false for nothing, or an lp envelope whose
  ## success is false (an error is not "mix is not mounted").
  if raw.strip().len == 0: return false
  try:
    let j = parseJson(raw)
    if j.kind == JObject and j.hasKey("success") and not j{"success"}.getBool(true): return false
  except CatchableError: discard
  true

proc mixPoolSize*(metrics: string): int =
  ## The `mix_pool_size` gauge from a Prometheus text reply; -1 when it is not there.
  let text = (if metrics.strip().startsWith("{") or metrics.strip().startsWith("\""):
                nodeInfoValue(metrics) else: metrics)
  for line in text.splitLines():
    let l = line.strip()
    if not l.startsWith("mix_pool_size"): continue
    let rest = l["mix_pool_size".len .. ^1]
    if rest.len == 0 or rest[0] notin {' ', '\t', '{'}: continue   # mix_pool_size_created …
    let parts = rest.splitWhitespace()
    if parts.len == 0: continue
    try: return int(parseFloat(parts[^1]))
    except ValueError: continue
  -1

proc row(level, detail: string, remedy = ""): JsonNode =
  result = %*{"key": "mix", "name": "Mixnet", "level": level, "detail": detail,
              "source": "room", "introducedBy": [], "covers": "sends", "note": SendsOnly}
  if remedy.len > 0: result["remedy"] = %remedy

proc mixRow*(i: MixInputs): JsonNode =
  ## The row. Levels: "off" (not asked), "ok", "warn", "down", "unknown".
  let asked = i.asked
  if asked notin ["Preferred", "Required"]:
    return row("off", "off: each message is published from this node's own address",
               "Settings → Mixnet: Preferred sends through the mixnet when it can.")
  let fallback = (if asked == "Preferred": "a send mix cannot carry goes over the plain path"
                  else: "a send mix cannot carry fails")
  if not i.joined:
    return row("unknown", asked & ": starts when you join a room")
  if not i.pubKeyRead:
    return row("unknown", asked & ": the node has not said whether mix is mounted")
  if nodeInfoValue(i.pubKey).len == 0:
    return row("down", "mix is not mounted: " &
               (if asked == "Preferred": "every send goes over the plain path"
                else: "every send will fail"),
               "Check the delivery config: it must not set mix to false.")
  let pool = mixPoolSize(i.metrics)
  if pool < 0:
    return row("unknown", asked & ": mix is mounted; the node has not said how many mix nodes it knows")
  if pool < MinMixPool:
    return row("warn", $pool & " of " & $MinMixPool & " mix nodes known: " &
               (if asked == "Preferred": "sends go over the plain path until there are " & $MinMixPool
                else: "sends wait for " & $MinMixPool & ", then fail"),
               "The node finds mix nodes through its fleet; this usually clears within a minute.")
  if asked == "Required" and nodeInfoValue(i.connection) == "Disconnected":
    return row("warn", "no mix exit is ready: sends wait, then fail (" & $pool & " mix nodes known)")
  row("ok", "sends go through the mixnet (" & $pool & " mix nodes known); " & fallback)
