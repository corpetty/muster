## What muster hands delivery's createNode, from the fleet config it holds (exo-eb6.1).
## Held: a config that names a preset goes without its top-level entryNodes (v0.3 reads
## a bare key as the legacy flat shape, whose fixed port stops a second instance on the
## same machine), and those nodes stay muster's store peers; QUIC is off unless the
## config or the caller asks for it; the node logs at INFO unless the config or the caller
## names a level (exo-9eed: delivery's own fleet configs say DEBUG, and a long-lived peer
## filled a disk), inside messagingOverrides beside a preset (delivery refuses a bare
## top-level key there), once (it refuses both spellings together), at the top level of a
## flat config; anything else passes through untouched.

import std/[json, strutils]
import ../src/transport/node_config

const Fleet = """{"mode":"Core","preset":"logos.dev","entryNodes":["/dns4/a/tcp/30303/p2p/A","/dns4/b/tcp/30303/p2p/B"]}"""

block preset:
  let c = nodeConfigFor(Fleet)
  let j = parseJson(c.createNode)
  doAssert not j.hasKey("entryNodes"), c.createNode
  doAssert j["preset"].getStr() == "logos.dev" and j["mode"].getStr() == "Core"
  doAssert j["messagingOverrides"]["quic-support"].getBool() == false
  doAssert c.storePeers == @["/dns4/a/tcp/30303/p2p/A", "/dns4/b/tcp/30303/p2p/B"]
  echo "1. a fleet config: entryNodes leave createNode and stay store peers; QUIC off OK"

block quicOn:
  let c = nodeConfigFor(Fleet, quic = true)
  doAssert not parseJson(c.createNode)["messagingOverrides"].hasKey("quic-support")
  let own = nodeConfigFor("""{"preset":"logos.dev","messagingOverrides":{"quic-support":true,"tcp-port":30303}}""")
  let o = parseJson(own.createNode)["messagingOverrides"]
  doAssert o["quic-support"].getBool() and o["tcp-port"].getInt() == 30303
  doAssert own.storePeers.len == 0
  echo "2. QUIC stays on when asked for, by the caller or the config's own setting OK"

block untouched:
  for raw in ["""{"clusterId":42,"entryNodes":["/dns4/x"]}""", "{}", "not json", "[1,2]"]:
    let c = nodeConfigFor(raw)
    if raw.startsWith("{\"clusterId"):
      var want = parseJson(raw)
      want["logLevel"] = %"INFO"
      doAssert parseJson(c.createNode) == want, "a config with no preset gains only its log level: " & c.createNode
      doAssert c.storePeers == @["/dns4/x"]
    else:
      doAssert c.createNode == raw
  echo "3. no preset, empty, not JSON, not an object: passed through as given (a flat config gains its log level) OK"

block logLevel:
  # beside a preset: inside messagingOverrides, never a bare top-level key
  let p = parseJson(nodeConfigFor(Fleet).createNode)
  doAssert not p.hasKey("logLevel"), "a bare key beside a preset switches delivery to the flat shape"
  # inside messagingOverrides, once: delivery reads log-level and logLevel as one option and
  # refuses a config that sets both
  doAssert p["messagingOverrides"]["log-level"].getStr() == "INFO"
  doAssert not p["messagingOverrides"].hasKey("logLevel")
  doAssert parseJson(nodeConfigFor(Fleet, logLevel = "DEBUG").createNode)["messagingOverrides"]["log-level"].getStr() == "DEBUG"
  # a level the config names itself, either spelling, wins over muster's default
  let own = parseJson(nodeConfigFor("""{"preset":"logos.dev","messagingOverrides":{"log-level":"TRACE"}}""").createNode)
  doAssert own["messagingOverrides"]["log-level"].getStr() == "TRACE"
  let own2 = parseJson(nodeConfigFor("""{"preset":"logos.dev","messagingOverrides":{"logLevel":"TRACE"}}""").createNode)
  doAssert not own2["messagingOverrides"].hasKey("log-level")
  # a flat config: at the top level, unless it names one
  doAssert parseJson(nodeConfigFor("""{"clusterId":198,"relay":true}""", logLevel = "WARN").createNode)["logLevel"].getStr() == "WARN"
  doAssert parseJson(nodeConfigFor("""{"clusterId":198,"logLevel":"DEBUG"}""").createNode)["logLevel"].getStr() == "DEBUG"
  # an unknown level is not passed on: the default stands
  doAssert parseJson(nodeConfigFor(Fleet, logLevel = "LOUD").createNode)["messagingOverrides"]["log-level"].getStr() == "INFO"
  echo "4. the node logs at INFO unless asked: inside messagingOverrides beside a preset, top level when flat OK"
