## What muster hands delivery's createNode, from the fleet config it holds (exo-eb6.1).
## Held: a config that names a preset goes without its top-level entryNodes (v0.3 reads
## a bare key as the legacy flat shape, whose fixed port stops a second instance on the
## same machine), and those nodes stay muster's store peers; QUIC is off unless the
## config or the caller asks for it; anything else passes through untouched.

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
      doAssert parseJson(c.createNode) == parseJson(raw), "a config with no preset is not rewritten"
      doAssert c.storePeers == @["/dns4/x"]
    else:
      doAssert c.createNode == raw
  echo "3. no preset, empty, not JSON, not an object: passed through as given OK"
