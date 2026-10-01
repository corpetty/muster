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
##
## A peer that cannot be dialled is backed off (exo-eb6.1): skipped for 5 s, doubling to
## a minute while it keeps failing, cleared by its next answer. Delivery v0.3.0 reports a
## dial failure with no requestId, only the peer's id, so the caller passes that id here.

import std/[json, tables, sets, strutils]

const
  PageLimit* = 50            ## messages per page (the proven size on the logos.test fleet)
  MaxDeepPages* = 400        ## a store that never stops paging is cut off: 20,000 messages
  PageTimeoutMs* = 10_000'i64 ## a page with no answer by then is asked again (same cursor)
  MaxPageRetries* = 3        ## a paging peer that fails this often: start over on another
  StoreBackoffBaseMs* = 5_000'i64  ## a peer that failed to dial is skipped this long…
  StoreBackoffCapMs* = 60_000'i64  ## …doubling while it keeps failing, up to this
  MaxSentTracked = 512       ## requestIds remembered for whose answer clears a backoff

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
    sentTo: OrderedTable[string, string] ## requestId -> the peer it was asked of (recent)
    downUntil: Table[string, int64]     ## peer -> skip it until then (ms)
    downCount: Table[string, int]       ## peer -> dial failures in a row

proc newStoreCatchup*(peers: seq[string]): StoreCatchup =
  StoreCatchup(peers: peers)

proc caughtUp*(c: StoreCatchup, topic: string): bool = topic in c.caught

proc nextPeer(c: var StoreCatchup, nowMs: int64): string =
  ## The next peer round-robin that is not backed off; with every peer backed off, the
  ## one back soonest — a down fleet slows the catch-up, never stops it.
  var soonest = -1
  for k in 0 ..< c.peers.len:
    let i = (c.peerIdx + k) mod c.peers.len
    let until = c.downUntil.getOrDefault(c.peers[i], 0)
    if until <= nowMs:
      c.peerIdx = (i + 1) mod c.peers.len
      return c.peers[i]
    if soonest < 0 or until < c.downUntil.getOrDefault(c.peers[soonest], 0): soonest = i
  c.peerIdx = (soonest + 1) mod c.peers.len
  c.peers[soonest]

proc onPeerFailure*(c: var StoreCatchup, peerId: string, nowMs: int64) =
  ## A store query could not dial the peer whose multiaddr ends in /p2p/<peerId>: back it
  ## off, and ask again at once any page in flight on it (not after PageTimeoutMs).
  for peer in c.peers:
    if not peer.endsWith("/p2p/" & peerId): continue
    let n = c.downCount.getOrDefault(peer, 0) + 1
    c.downCount[peer] = n
    c.downUntil[peer] = nowMs + min(StoreBackoffCapMs, StoreBackoffBaseMs shl min(n - 1, 16))
    for topic, p in c.paging.mpairs:
      if p.peer == peer and p.inFlight.len > 0:
        p.sentMs = nowMs - PageTimeoutMs        # lost: the next tick asks again

proc dialFailurePeer*(resp: JsonNode): string =
  ## The peer id a failed store query names, "" when it is no dial failure. Delivery
  ## v0.3.0's envelope: {"error": "…storeQuery failed: PEER_DIAL_FAILURE: <peer id>",
  ## "success": false, "value": null}.
  const Tag = "PEER_DIAL_FAILURE: "
  if resp == nil or resp.kind != JObject or resp{"success"}.getBool(true): return ""
  let err = resp{"error"}.getStr()
  let at = err.find(Tag)
  if at < 0: return ""
  var id = ""
  for ch in err[at + Tag.len .. ^1]:
    if ch in {'0'..'9', 'a'..'z', 'A'..'Z'}: id.add ch else: break
  id

proc noteSent(c: var StoreCatchup, rid, peer: string) =
  c.sentTo[rid] = peer
  if c.sentTo.len > MaxSentTracked:
    var oldest = ""
    for k in c.sentTo.keys:
      oldest = k
      break
    c.sentTo.del oldest

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
      if p.peer.len == 0 or (p.cursor.len == 0 and p.fails > 0): p.peer = c.nextPeer(nowMs)
      if p.cursor.len > 0: req["paginationCursor"] = %p.cursor
      inc p.pages
      p.inFlight = rid
      p.sentMs = nowMs
      c.paging[topic] = p
      c.awaited[rid] = topic
      c.noteSent(rid, p.peer)
      return (true, true, req, p.peer)
  # Waku store filters on the message's own (nanosecond) timestamp; second precision is a
  # plenty floor and avoids float64 losing ns digits at epoch scale.
  req["timeStart"] = %((nowMs - lookbackMs) * 1_000_000)
  let peer = c.nextPeer(nowMs)
  c.noteSent(rid, peer)
  (true, false, req, peer)

proc cursorOf(resp: JsonNode): string =
  ## The response's paginationCursor, "" = none. liblogosdelivery serializes it (with `%*`)
  ## as a nim-results Opt[string] — {"oResultPrivate": true, "vResultPrivate": "0x…"}, or
  ## {"oResultPrivate": false} — the same wrapping its messages carry; a plain string is
  ## read too.
  let c = resp{"paginationCursor"}
  if c == nil: return ""
  case c.kind
  of JString: c.getStr()
  of JObject: (if c{"oResultPrivate"}.getBool(false): c{"vResultPrivate"}.getStr() else: "")
  else: ""

proc onResponse*(c: var StoreCatchup, resp: JsonNode) =
  ## A store response (the delivery module's StoreQueryResponse JSON). For the page a topic
  ## awaits: keep its cursor for the next page, or — no cursor — the topic is read whole.
  ## Anything else (a windowed answer, a late answer to a page already re-asked) is ignored.
  if resp == nil or resp.kind != JObject: return
  let rid = resp{"requestId"}.getStr()
  if rid in c.sentTo:                       # an answer clears its peer's backoff
    let peer = c.sentTo[rid]
    c.sentTo.del rid
    if resp{"statusCode"}.getInt(200) == 200:
      c.downCount.del peer
      c.downUntil.del peer
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
  let cursor = cursorOf(resp)
  if cursor.len == 0 or cursor == p.cursor:
    c.caught.incl topic                 # the last page: read whole
    c.paging.del topic
  else:
    p.cursor = cursor
    c.paging[topic] = p
