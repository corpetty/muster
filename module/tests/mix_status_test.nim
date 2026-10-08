## The node's mix path as one status row (exo-dcc.4). Held: the row reads what delivery
## itself reports (the level the createNode config asked for, the mix key the node
## mounted, the mix pool size in its metrics, its connection status) and never a false
## green: with mix off it says sends leave from this node's own address; with no node,
## or a reply it could not read, it is unknown; a mounted mix with a pool below the four
## nodes a path needs is a warning that says what happens to a send at that level; and
## every row, even a green one, says that mix carries sends only, never the store reads.

import std/[json, strutils]
import ../src/transport/mix_status

const Key = "c288a425a6209c74ec07e2e8b6816e9b6995d1cd59b1ab482317c3dfb3ba200f"
const Metrics = """# HELP mix_pool_size number of nodes in the pool
# TYPE mix_pool_size gauge
mix_pool_size 6.0
mix_pool_size_created 1791480000.0
# HELP mix_messages_forwarded_total number of mix messages forwarded
mix_messages_forwarded_total{type="Entry"} 3.0
"""

block parsing:
  # getNodeInfo's reply, however it arrives: bare, a JSON string, or the lp envelope
  doAssert nodeInfoValue(Key) == Key
  doAssert nodeInfoValue("\"" & Key & "\"") == Key
  doAssert nodeInfoValue("""{"success":true,"value":"""" & Key & """"}""") == Key
  doAssert nodeInfoValue("""{"success":true,"value":""}""") == ""
  doAssert nodeInfoValue("""{"success":false,"error":"Context not initialized"}""") == ""
  doAssert nodeInfoValue("") == ""
  # an error is not an empty answer: "not mounted" is read only from a reply that answered
  doAssert nodeInfoOk("\"\"") and nodeInfoOk("""{"success":true,"value":""}""") and nodeInfoOk(Key)
  doAssert not nodeInfoOk("""{"success":false,"error":"Context not initialized"}""")
  doAssert not nodeInfoOk("") and not nodeInfoOk("  ")
  # the pool gauge from the metrics text; -1 when it is not there
  doAssert mixPoolSize(Metrics) == 6
  doAssert mixPoolSize("mix_pool_size 3") == 3
  doAssert mixPoolSize("""{"success":true,"value":"mix_pool_size 2.0\n"}""") == 2
  doAssert mixPoolSize("nothing here") == -1 and mixPoolSize("") == -1
  doAssert mixPoolSize("mix_pool_size_created 1.0") == -1
  echo "1. node info and the pool gauge are read through any envelope; absent is -1 OK"

block off:
  let r = mixRow(MixInputs(asked: "None", joined: true, pubKey: "", metrics: Metrics))
  doAssert r["key"].getStr() == "mix" and r["level"].getStr() == "off", $r
  doAssert "own address" in r["detail"].getStr(), $r
  echo "2. mix off: off, sends leave from this node's own address OK"

block noNode:
  for asked in ["Preferred", "Required"]:
    let r = mixRow(MixInputs(asked: asked, joined: false))
    doAssert r["level"].getStr() == "unknown" and "join a room" in r["detail"].getStr(), $r
  echo "3. asked, with no node yet: unknown until a room is joined OK"

block unread:
  # the node is up but did not answer: never green
  let r = mixRow(MixInputs(asked: "Preferred", joined: true, pubKeyRead: false, metrics: ""))
  doAssert r["level"].getStr() == "unknown", $r
  echo "4. an unread reply is unknown OK"

block notMounted:
  let p = mixRow(MixInputs(asked: "Preferred", joined: true, pubKeyRead: true, pubKey: ""))
  doAssert p["level"].getStr() == "down" and "plain path" in p["detail"].getStr(), $p
  let q = mixRow(MixInputs(asked: "Required", joined: true, pubKeyRead: true, pubKey: ""))
  doAssert q["level"].getStr() == "down" and "fail" in q["detail"].getStr(), $q
  doAssert q.hasKey("remedy")
  echo "5. asked but not mounted: down, saying what happens to a send OK"

block poolShort:
  let short = Metrics.replace("mix_pool_size 6.0", "mix_pool_size 2.0")
  let p = mixRow(MixInputs(asked: "Preferred", joined: true, pubKeyRead: true, pubKey: Key, metrics: short))
  doAssert p["level"].getStr() == "warn" and "2 of 4" in p["detail"].getStr() and "plain path" in p["detail"].getStr(), $p
  let q = mixRow(MixInputs(asked: "Required", joined: true, pubKeyRead: true, pubKey: Key, metrics: short))
  doAssert q["level"].getStr() == "warn" and "wait" in q["detail"].getStr(), $q
  # a pool it could not read is not a pool it has
  let u = mixRow(MixInputs(asked: "Preferred", joined: true, pubKeyRead: true, pubKey: Key, metrics: ""))
  doAssert u["level"].getStr() == "unknown", $u
  echo "6. mounted, pool below four: warn, saying what a send does meanwhile OK"

block ready:
  let p = mixRow(MixInputs(asked: "Preferred", joined: true, pubKeyRead: true, pubKey: Key, metrics: Metrics,
                           connection: "Connected"))
  doAssert p["level"].getStr() == "ok" and "6 mix nodes" in p["detail"].getStr(), $p
  doAssert "plain path" in p["detail"].getStr(), "Preferred still falls back, and the row says so: " & $p
  let q = mixRow(MixInputs(asked: "Required", joined: true, pubKeyRead: true, pubKey: Key, metrics: Metrics,
                           connection: "PartiallyConnected"))
  doAssert q["level"].getStr() == "ok", $q
  # Required: delivery reports Disconnected until a mix exit is ready
  let d = mixRow(MixInputs(asked: "Required", joined: true, pubKeyRead: true, pubKey: Key, metrics: Metrics,
                           connection: """{"success":true,"value":"Disconnected"}"""))
  doAssert d["level"].getStr() == "warn" and "exit" in d["detail"].getStr(), $d
  echo "7. mounted with a pool of four or more: ok; Required waits on an exit OK"

block sendsOnly:
  # every row says what mix does not cover: the store reads leave from this node
  for i in [MixInputs(asked: "None", joined: true),
            MixInputs(asked: "Preferred", joined: true, pubKeyRead: true, pubKey: Key, metrics: Metrics),
            MixInputs(asked: "Required", joined: true, pubKeyRead: true, pubKey: Key, metrics: Metrics)]:
    let r = mixRow(i)
    doAssert r["covers"].getStr() == "sends", $r
    doAssert "store" in r["note"].getStr(), $r
  echo "8. every row says mix carries sends only, and that store reads are not hidden OK"
