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
  if arr.kind != JArray or arr.len < 4: return false
  ev.contentTopic = arr[1].getStr()
  ev.payload = @[]
  if arr[2].kind == JObject and arr[2].hasKey("_bytes"):
    ev.payload = b64urlDecode(arr[2]["_bytes"].getStr())
  ev.timestamp = arr[3].getBiggestInt().int64
  true
