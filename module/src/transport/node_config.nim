## The delivery node config muster hands to createNode, from the fleet config it holds
## (exo-eb6.1). Pure: tested without a node.
##
## muster's fleet configs (infra/fleets/*.json, the module's built-in presets) name a
## `preset` and list the fleet's `entryNodes` at the top level. muster needs those
## nodes itself: they are the store peers its catch-up queries. Delivery v0.3.0 reads
## the config two ways. A config of only layered keys (`preset`, `mode`,
## `messagingOverrides`, …) boots the preset's network with OS-assigned ports. One
## bare key beside them, `entryNodes` included, switches it to the legacy flat shape,
## whose TCP port defaults to 60000, so a second instance on the same machine cannot
## start. v0.3's presets carry their own entry nodes, so a config that names a preset
## goes to createNode without them.
##
## QUIC is off unless asked for. Delivery v0.3.0 dials QUIC first. From where muster
## was tested, every QUIC dial to the logos.dev fleet timed out after 3 s, and store
## queries failed with PEER_DIAL_FAILURE, while TCP to the same nodes connected. A
## config that sets `quic-support` itself, or MUSTER_DELIVERY_QUIC=1, keeps it on.
##
## The node is asked to log at INFO unless the config or the caller names a level
## (exo-9eed). Delivery's own fleet configs say DEBUG. Beside a preset the level goes inside
## `messagingOverrides` (`log-level`): a bare top-level key there is refused ("Unrecognized
## configuration option(s) found: logLevel"), and delivery treats `logLevel` and `log-level`
## as one option, refusing a config that sets both. Measured 2026-10-06 on logos.dev: at
## delivery v0.3.0 the node accepts the level and still logs DEBUG (~700-800 lines a
## minute either way), an upstream bug (exo-9eed notes); the level is sent so it takes
## effect once delivery applies it. A flat config takes `logLevel` at the top, as muster's
## local configs always have.

import std/[json, strutils]

type NodeConfig* = object
  createNode*: string        ## the JSON handed to delivery's createNode
  storePeers*: seq[string]   ## the fleet's nodes, for muster's own store catch-up

const LogLevels* = ["TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "ERROR", "FATAL"]

proc nodeConfigFor*(cfgJson: string, quic = false, logLevel = "INFO"): NodeConfig =
  var j: JsonNode
  try: j = parseJson(cfgJson)
  except CatchableError: return NodeConfig(createNode: cfgJson)
  if j.kind != JObject: return NodeConfig(createNode: cfgJson)
  if j.hasKey("entryNodes") and j["entryNodes"].kind == JArray:
    for n in j["entryNodes"]:
      if n.kind == JString and n.getStr().len > 0: result.storePeers.add n.getStr()
  let preset = j.hasKey("preset") and j["preset"].kind == JString and j["preset"].getStr().len > 0
  if preset:
    if j.hasKey("entryNodes"): j.delete("entryNodes")
    if not j.hasKey("messagingOverrides") or j["messagingOverrides"].kind != JObject:
      j["messagingOverrides"] = newJObject()
    if not quic and not j["messagingOverrides"].hasKey("quic-support"):
      j["messagingOverrides"]["quic-support"] = %false
  let level = (if logLevel.toUpperAscii() in LogLevels: logLevel.toUpperAscii() else: "INFO")
  if preset:
    let mo = j["messagingOverrides"]
    if not mo.hasKey("log-level") and not mo.hasKey("logLevel"): mo["log-level"] = %level
  elif j.len > 0 and not j.hasKey("logLevel"):
    j["logLevel"] = %level
  result.createNode = $j
