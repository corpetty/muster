## Store catch-up: which store query to fire next for a topic (exo-aaf). Pure — no node,
## no lp — so delivery.nim drives it and store_catchup_test holds it.
##
## Cross-host receive rides the fleet's store (docs/labbook/two-instance-live-wire-blockers.md),
## and a member who joins or relaunches rebuilds the room from nothing else. So a topic is
## first read WHOLE: paged from its start with no time bound, each next page asking for the
## cursor the last one returned, of the store peer that returned it (a cursor is that node's
## position), one page in flight at a time. Only when a page comes back without a cursor is
## the topic caught up; from then on each query reaches back a sliding window, round-robin
## over the peers so a down node costs one tick. Ingest dedups every overlap (R-2/R-4), and
## the log reduces order-independently (inv 4), so re-asking a page is always harmless.

import std/[json, tables, sets]

const
  PageLimit* = 50            ## messages per page (the proven size on the logos.test fleet)
  MaxDeepPages* = 400        ## a store that never stops paging is cut off: 20,000 messages
  PageTimeoutMs* = 10_000'i64 ## a page with no answer by then is asked again (same cursor)
  MaxPageRetries* = 3        ## a paging peer that fails this often: start over on another

type
  Paging = object
    cursor: string           ## the last page's paginationCursor ("" = from the start)
    peer: string             ## the store peer paging this topic
    pages: int
    inFlight: string         ## the requestId awaited, "" = none
    sentMs: int64
    fails: int               ## pages lost or failed in a row on this peer

  StoreCatchup* = object
    peers*: seq[string]
    peerIdx: int
    seqNo: int
    paging: Table[string, Paging]       ## topic -> its history read, while it lasts
    caught: HashSet[string]             ## topics read whole: windowed from now on
    awaited: Table[string, string]      ## requestId -> topic, for the page in flight

proc newStoreCatchup*(peers: seq[string]): StoreCatchup =
  StoreCatchup(peers: peers)

proc caughtUp*(c: StoreCatchup, topic: string): bool = topic in c.caught

proc nextPeer(c: var StoreCatchup): string =
  result = c.peers[c.peerIdx mod c.peers.len]
  c.peerIdx = (c.peerIdx + 1) mod c.peers.len

proc nextQuery*(c: var StoreCatchup, topic: string, nowMs, lookbackMs: int64):
    tuple[fire: bool, deep: bool, req: JsonNode, peer: string] =
  ## The store query to fire now for `topic`, if any: the next page of its history until
  ## it is read whole, then the sliding window. fire=false while a page is in flight.
  if c.peers.len == 0: return (false, false, newJNull(), "")
  inc c.seqNo
  let rid = "muster-" & $nowMs & "-" & $c.seqNo
  var req = %*{"requestId": rid, "includeData": true, "paginationForward": true,
               "contentTopics": [topic], "paginationLimit": PageLimit}
  if topic notin c.caught:
    var p = c.paging.getOrDefault(topic)
    if p.inFlight.len > 0 and nowMs - p.sentMs < PageTimeoutMs:
      return (false, true, newJNull(), "")
    if p.inFlight.len > 0:                                      # lost: ask again
      c.awaited.del p.inFlight
      inc p.fails
    if p.pages >= MaxDeepPages:
      c.caught.incl topic
      c.paging.del topic
    else:
      # a cursor is its node's: keep asking that node — unless it keeps failing, then start
      # over on another (re-reading pages is harmless). With no cursor yet, any peer will do.
      if p.fails >= MaxPageRetries:
        p.cursor = ""
        p.fails = 0
        p.peer = ""
      if p.peer.len == 0 or (p.cursor.len == 0 and p.fails > 0): p.peer = c.nextPeer()
      if p.cursor.len > 0: req["paginationCursor"] = %p.cursor
      inc p.pages
      p.inFlight = rid
      p.sentMs = nowMs
      c.paging[topic] = p
      c.awaited[rid] = topic
      return (true, true, req, p.peer)
  # Waku store filters on the message's own (nanosecond) timestamp; second precision is a
  # plenty floor and avoids float64 losing ns digits at epoch scale.
  req["timeStart"] = %((nowMs - lookbackMs) * 1_000_000)
  (true, false, req, c.nextPeer())

proc onResponse*(c: var StoreCatchup, resp: JsonNode) =
  ## A store response (the delivery module's StoreQueryResponse JSON). For the page a topic
  ## awaits: keep its cursor for the next page, or — no cursor — the topic is read whole.
  ## Anything else (a windowed answer, a late answer to a page already re-asked) is ignored.
  if resp == nil or resp.kind != JObject: return
  let rid = resp{"requestId"}.getStr()
  if rid notin c.awaited: return
  let topic = c.awaited[rid]
  c.awaited.del rid
  var p = c.paging.getOrDefault(topic)
  if p.inFlight != rid: return
  p.inFlight = ""
  let status = resp{"statusCode"}.getInt(200)
  if status != 200:
    inc p.fails                         # a failed page: asked again next tick
    c.paging[topic] = p
    return
  p.fails = 0
  let cursor = resp{"paginationCursor"}.getStr()
  if cursor.len == 0 or cursor == p.cursor:
    c.caught.incl topic                 # the last page: read whole
    c.paging.del topic
  else:
    p.cursor = cursor
    c.paging[topic] = p
