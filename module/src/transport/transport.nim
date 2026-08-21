## The Transport seam (F-15, ADR-006).
##
## Muster codes against this interface, never against a concrete transport. The
## real network binds `logos-delivery-module` at runtime (content topics, publish,
## subscribe, store-node catchup); `LocalTransport` below is the in-process
## stand-in the integration tests run on — the working agreement is that tests use
## a real local transport, never a mock.
##
## The shape mirrors the delivery contract Muster consumes
## (`delivery_module.lidl`: `send(contentTopic, payload)`, `subscribe(contentTopic)`,
## the `messageReceived` event) plus `storeQuery` for the offline-catchup half of
## F-15. Ingest is idempotent over store duplicates (R-2/R-4): a message seen twice
## — live then from the store, or a store returning a duplicate — reduces once.
##
## The core never interprets payload bytes here; a payload is an opaque envelope
## (the epoch layer, F-16, encrypts what goes in it). Transport carries bytes on a
## topic and says when they arrived; it does not read them.

import std/[tables, sets]
import ../hashing/sha256

type
  IncomingMessage* = object
    contentTopic*: string
    payload*: seq[byte]
    messageHash*: string     ## content address; the ingest dedup key (R-2)
    timestamp*: int64

  MessageHandler* = proc (msg: IncomingMessage) {.gcsafe.}

  Transport* = ref object of RootObj
    ## The abstract seam. Concrete transports (LocalTransport here, a
    ## delivery-backed one next) override every method.

method publish*(t: Transport, contentTopic: string, payload: seq[byte]): string
    {.base, gcsafe.} =
  ## Publish a payload on a topic. Returns the message's content address (its
  ## delivery/propagation receipt in this v0 — a real fleet reports more).
  raise newException(CatchableError, "Transport.publish is abstract")

method subscribe*(t: Transport, contentTopic: string, handler: MessageHandler)
    {.base, gcsafe.} =
  ## Register a handler for live messages on a topic. Idempotent per topic.
  raise newException(CatchableError, "Transport.subscribe is abstract")

method unsubscribe*(t: Transport, contentTopic: string) {.base, gcsafe.} =
  raise newException(CatchableError, "Transport.unsubscribe is abstract")

method storeQuery*(t: Transport, contentTopic: string): seq[IncomingMessage]
    {.base, gcsafe.} =
  ## Offline catchup: the messages a store node retains for a topic, oldest first.
  ## F-15's catchup half; FS-9 names the metadata a store thereby observes.
  raise newException(CatchableError, "Transport.storeQuery is abstract")

# ── content address ───────────────────────────────────────────────────────────

proc messageHashOf*(contentTopic: string, payload: seq[byte]): string =
  ## Deterministic content address over (topic, payload) — the same message hashes
  ## the same everywhere, so ingest can dedup it (R-2). Domain-separated so a topic
  ## string and a payload prefix can't be confused for one another.
  var buf: seq[byte]
  for c in "muster.transport.msg.v1": buf.add byte(c)
  buf.add 0'u8
  for c in contentTopic: buf.add byte(c)
  buf.add 0'u8
  buf.add payload
  let h = sha256(buf)
  const d = "0123456789abcdef"
  result = "0x"
  for x in h: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# ── LocalTransport: the in-process fleet stand-in ─────────────────────────────

type
  LocalNetwork* = ref object
    ## A shared in-process bus + store that many LocalTransports attach to, so two
    ## instances in one test exchange real messages through it. Deliberately plain;
    ## the delivery-backed Transport replaces it for real networks.
    subscribers: Table[string, seq[MessageHandler]]   ## contentTopic -> live handlers
    store: Table[string, seq[IncomingMessage]]         ## contentTopic -> retained history
    seen: Table[string, HashSet[string]]               ## contentTopic -> hashes stored (dedup)
    clock: int64

  LocalTransport* = ref object of Transport
    net: LocalNetwork

proc newLocalNetwork*(): LocalNetwork =
  LocalNetwork(subscribers: initTable[string, seq[MessageHandler]](),
               store: initTable[string, seq[IncomingMessage]](),
               seen: initTable[string, HashSet[string]]())

proc newLocalTransport*(net: LocalNetwork): LocalTransport =
  ## Attach a new instance to the shared network.
  LocalTransport(net: net)

method publish*(t: LocalTransport, contentTopic: string, payload: seq[byte]): string =
  let hash = messageHashOf(contentTopic, payload)
  inc t.net.clock
  let msg = IncomingMessage(contentTopic: contentTopic, payload: payload,
                            messageHash: hash, timestamp: t.net.clock)
  # Retain in the store idempotently — a re-publish of identical bytes is one
  # stored message, so offline catchup never double-counts it (R-2/R-4).
  if not t.net.seen.hasKey(contentTopic):
    t.net.seen[contentTopic] = initHashSet[string]()
    t.net.store[contentTopic] = @[]
  if hash notin t.net.seen[contentTopic]:
    t.net.seen[contentTopic].incl hash
    t.net.store[contentTopic].add msg
  # Deliver live to every subscriber on the topic (this instance and others).
  if t.net.subscribers.hasKey(contentTopic):
    for h in t.net.subscribers[contentTopic]:
      if h != nil: h(msg)
  hash

method subscribe*(t: LocalTransport, contentTopic: string, handler: MessageHandler) =
  if not t.net.subscribers.hasKey(contentTopic):
    t.net.subscribers[contentTopic] = @[]
  t.net.subscribers[contentTopic].add handler

method unsubscribe*(t: LocalTransport, contentTopic: string) =
  t.net.subscribers.del contentTopic

method storeQuery*(t: LocalTransport, contentTopic: string): seq[IncomingMessage] =
  if t.net.store.hasKey(contentTopic): t.net.store[contentTopic] else: @[]
