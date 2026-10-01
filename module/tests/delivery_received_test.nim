## A delivery `messageReceived` event is read whichever module emits it (exo-eb6.1).
## Delivery v0.3.0 inserts `source` ("live" | "history") BEFORE `timestamp`:
##   v0.2.x  messageReceived(messageHash, contentTopic, payload, timestamp)
##   v0.3.0  messageReceived(messageHash, contentTopic, payload, source, timestamp)
## Read positionally the old way, v0.3's timestamp came out 0 and its source was lost.
## Held here: both shapes give the topic, the payload, the timestamp and the source;
## anything else is refused, never read as a message.

import std/json
import logos_sdk/bytes
import ../src/transport/received

let payload = @[byte 0x01, 0x02, 0xfe]
let wire = %*{"_bytes": b64urlEncode(payload)}

block v02:
  var ev: ReceivedEvent
  doAssert parseMessageReceived(%*["0xabc", "/muster/1/t/proto", wire, 1790000000123], ev)
  doAssert ev.contentTopic == "/muster/1/t/proto"
  doAssert ev.payload == payload
  doAssert ev.timestamp == 1790000000123, $ev.timestamp
  doAssert ev.source == ""
  echo "1. a v0.2 event (no source): topic, payload and timestamp OK"

block v03:
  for src in ["live", "history"]:
    var ev: ReceivedEvent
    doAssert parseMessageReceived(%*["0xabc", "/muster/1/t/proto", wire, src, 1790000000456], ev)
    doAssert ev.contentTopic == "/muster/1/t/proto"
    doAssert ev.payload == payload
    doAssert ev.timestamp == 1790000000456, src & ": timestamp " & $ev.timestamp
    doAssert ev.source == src, "source " & ev.source
  echo "2. a v0.3 event: source live and history, and the timestamp after it OK"

block refused:
  var ev: ReceivedEvent
  doAssert not parseMessageReceived(%*["0xabc", "/t", wire], ev)
  doAssert not parseMessageReceived(%*{"messageHash": "0xabc"}, ev)
  doAssert not parseMessageReceived(%*[1, "/t", wire, 5], ev)
  doAssert not parseMessageReceived(%*["0xabc", "/t", wire, "live", "soon"], ev)
  echo "3. too short, not an array, a non-string hash, a non-numeric timestamp: refused OK"
