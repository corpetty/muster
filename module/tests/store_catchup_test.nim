## Store catch-up follows the store's pagination (exo-aaf). Cross-host receive rides store
## queries (docs/labbook/two-instance-live-wire-blockers.md), and a member who joins or
## relaunches has nothing but those queries to rebuild the room from. Seen on a display:
## the first queries asked for the oldest 50 messages with no cursor, three times, then
## only the last minute — so a room past 50 messages came back missing its middle (a
## settle-up and its payments gone; a share offered for payment that had been paid).
## Held here, without a node (the pure state machine delivery.nim drives):
##   * a new topic is paged from the start, with no time bound, until the store returns a
##     page with no cursor — each next page asks for the cursor the last one gave, of the
##     SAME store peer (a cursor is that node's), and never two pages in flight at once;
##   * only then does the topic switch to the sliding window, round-robin over the peers;
##   * a lost or failed page is asked again from the same cursor once it times out — of
##     another peer while there is no cursor yet, and from the start on another peer once
##     the paging peer has failed MaxPageRetries times (a dead store node never stalls it);
##   * a store that keeps returning cursors is cut off after MaxDeepPages;
##   * each topic pages on its own.

import std/[json, sets, strutils]
import ../src/transport/store_catchup

const Peers = @["/dns4/a/tcp/30303/p2p/A", "/dns4/b/tcp/30303/p2p/B", "/dns4/c/tcp/30303/p2p/C"]
const Room = "/muster/1/room/proto"
const Other = "/muster/1/other/proto"
const Lookback = 60_000'i64

proc page(req: JsonNode, cursor: string): JsonNode =
  result = %*{"requestId": req["requestId"].getStr(), "statusCode": 200, "statusDesc": "OK", "messages": []}
  if cursor.len > 0: result["paginationCursor"] = %cursor

var c = newStoreCatchup(Peers)
var now = 1_790_000_000_000'i64

# ── 1. the first page: from the start, no time bound, no cursor ───────────────────
let q1 = c.nextQuery(Room, now, Lookback)
doAssert q1.fire and q1.deep, "a new topic is paged from the start"
doAssert not q1.req.hasKey("timeStart") and not q1.req.hasKey("paginationCursor")
doAssert q1.req["paginationForward"].getBool() and q1.req["contentTopics"][0].getStr() == Room
doAssert q1.req["requestId"].getStr().len > 0
echo "1. a new topic's first page: from the start, no time bound, no cursor OK"

# ── 2. no second page while the first is in flight ─────────────────────────────────
now += 1000
doAssert not c.nextQuery(Room, now, Lookback).fire, "one page in flight at a time"
echo "2. never two pages of one topic in flight OK"

# ── 3. the next page asks for the cursor, of the peer that gave it ─────────────────
c.onResponse(page(q1.req, "0xcursor1"))
now += 1000
let q2 = c.nextQuery(Room, now, Lookback)
doAssert q2.fire and q2.deep
doAssert q2.req["paginationCursor"].getStr() == "0xcursor1", $q2.req
doAssert q2.peer == q1.peer, "a cursor is asked of the node that issued it"
doAssert not q2.req.hasKey("timeStart")
c.onResponse(page(q2.req, "0xcursor2"))
now += 1000
let q3 = c.nextQuery(Room, now, Lookback)
doAssert q3.req["paginationCursor"].getStr() == "0xcursor2" and q3.peer == q1.peer
echo "3. each next page asks for the last cursor, of the same peer OK"

# ── 4. a lost page is asked again, from the same cursor, once it times out ─────────
now += 1000
doAssert not c.nextQuery(Room, now, Lookback).fire
now += PageTimeoutMs + 1
let q3b = c.nextQuery(Room, now, Lookback)
doAssert q3b.fire and q3b.deep and q3b.req["paginationCursor"].getStr() == "0xcursor2", $q3b.req
doAssert q3b.req["requestId"].getStr() != q3.req["requestId"].getStr()
# the late answer to the lost page is ignored; the retry's answer counts
c.onResponse(page(q3.req, "0xstale"))
echo "4. a lost page is asked again from the same cursor after a timeout OK"

# ── 5. a page with no cursor ends the history; then the sliding window ────────────
c.onResponse(page(q3b.req, ""))
now += 1000
let w1 = c.nextQuery(Room, now, Lookback)
doAssert w1.fire and not w1.deep, "caught up: windowed now"
doAssert w1.req["timeStart"].getBiggestInt() == (now - Lookback) * 1_000_000
doAssert not w1.req.hasKey("paginationCursor")
now += 1000
let w2 = c.nextQuery(Room, now, Lookback)
doAssert w2.fire and w2.peer != w1.peer, "the window round-robins the peers"
echo "5. a page without a cursor ends the history; then the window, round-robin OK"

# ── 6. each topic pages on its own ────────────────────────────────────────────────
let o1 = c.nextQuery(Other, now, Lookback)
doAssert o1.fire and o1.deep and not o1.req.hasKey("paginationCursor"), "a second topic starts its own history"
doAssert c.caughtUp(Room) and not c.caughtUp(Other)
echo "6. each topic pages on its own OK"

# ── 7. a store that never stops returning cursors is cut off ───────────────────────
block:
  var d = newStoreCatchup(Peers)
  var t = 0'i64
  var pages = 0
  while true:
    t += 1000
    let q = d.nextQuery(Room, t, Lookback)
    if not q.deep: break
    inc pages
    d.onResponse(page(q.req, "0xmore" & $pages))
    doAssert pages <= MaxDeepPages, "cut off"
  doAssert pages == MaxDeepPages and d.caughtUp(Room)
  echo "7. a store that never stops paging is cut off after ", MaxDeepPages, " pages OK"

# ── 8. a dead store node never stalls the history ───────────────────────────────────
block:
  var d = newStoreCatchup(Peers)
  var t = 0'i64
  let first = d.nextQuery(Room, t, Lookback)
  t += PageTimeoutMs + 1
  let again = d.nextQuery(Room, t, Lookback)
  doAssert again.deep and again.peer != first.peer, "no cursor yet: the first page is asked of another peer"
  d.onResponse(page(again.req, "0xc1"))
  t += 1000
  let paging = d.nextQuery(Room, t, Lookback)
  doAssert paging.req["paginationCursor"].getStr() == "0xc1" and paging.peer == again.peer
  var last = paging
  for i in 1 ..< MaxPageRetries:
    t += PageTimeoutMs + 1
    last = d.nextQuery(Room, t, Lookback)
    doAssert last.peer == again.peer and last.req["paginationCursor"].getStr() == "0xc1", "the cursor's node, retried"
  t += PageTimeoutMs + 1
  let restart = d.nextQuery(Room, t, Lookback)
  doAssert restart.deep and not restart.req.hasKey("paginationCursor") and restart.peer != again.peer,
           "after " & $MaxPageRetries & " failures: from the start, on another peer"
  # a failed answer (not 200) counts as a failure too, and is asked again
  d.onResponse(%*{"requestId": restart.req["requestId"].getStr(), "statusCode": 503, "statusDesc": "busy"})
  t += 1000
  let retry = d.nextQuery(Room, t, Lookback)
  doAssert retry.fire and retry.deep, "a failed page is asked again next tick"
  echo "8. a dead store node never stalls the history OK"

echo "store_catchup_test: all OK"
