## A delivery `messageReceived` event, parsed (exo-eb6.1). Pure: no lp_* calls, so it is
## tested without a node. delivery.nim's poll() feeds it each event's JSON args array.

import std/json
import logos_sdk/bytes      # {"_bytes":<b64url>} codec

type
  ReceivedEvent* = object
    contentTopic*: string
    payload*: seq[byte]
    source*: string         ## "live" | "history" (delivery ≥ 0.3.0); "" before it
    timestamp*: int64

proc parseMessageReceived*(arr: JsonNode, ev: var ReceivedEvent): bool =
  ## The event's args array → `ev`; false when it is not a messageReceived we can read.
  ##   delivery v0.2.x: [messageHash, contentTopic, payload, timestamp]
  ##   delivery v0.3.0: [messageHash, contentTopic, payload, source, timestamp]
  ## The two are told apart by the fourth field: a timestamp is a number, a source a
  ## string. Read by position alone, v0.3's timestamp was its source, read as 0.
  if arr.kind != JArray or arr.len < 4: return false
  if arr[0].kind != JString or arr[1].kind != JString: return false
  let withSource = arr[3].kind == JString
  let ts = (if withSource: (if arr.len >= 5: arr[4] else: newJNull()) else: arr[3])
  if ts.kind != JInt: return false
  ev.contentTopic = arr[1].getStr()
  ev.payload = @[]
  if arr[2].kind == JObject and arr[2].hasKey("_bytes"):
    ev.payload = b64urlDecode(arr[2]["_bytes"].getStr())
  ev.source = (if withSource: arr[3].getStr() else: "")
  ev.timestamp = ts.getBiggestInt().int64
  true
