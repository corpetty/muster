## CoordinationSession — the multi-instance seam where the three P3 layers meet.
##
## Each coordination event is **sealed to the room** (ConversationCrypto) and
## **published on the conversation's content topic** (Transport); inbound
## envelopes are opened and **ingested into the local log**. State is always
## reduce(log), so two instances that see the same events converge to the same
## stateDigest (invariant 4) regardless of delivery order or duplication
## (R-2/R-3). The payload is opaque to the transport (it carries bytes) and to the
## core (it reduces a log); only members holding the epoch key can open it, and a
## member who joined a later epoch cannot open earlier envelopes (F-16).
##
## This is the join point: swap LocalTransport→delivery for a real network, or
## EpochCrypto→native chat, and this layer is unchanged (both are interfaces).

import std/json
import ../transport/transport
import ../crypto/conversation
import ../log/log
export log

type
  CoordinationSession* = ref object
    transport: Transport
    crypto: ConversationCrypto
    topic: string
    log*: Log

proc toBytes(s: string): seq[byte] = (for c in s: result.add byte(c))
proc toStr(b: openArray[byte]): string = (for x in b: result.add char(x))

proc encodeEvent(e: Event): seq[byte] =
  ## Wire form of an event, inside the sealed envelope. JSON is fine here — the
  ## bytes are encrypted, and the event's canonical identity (content address) is
  ## recomputed on ingest, so this is transport framing, not the signed form.
  var ps = newJArray()
  for p in e.parents: ps.add %p
  toBytes($(%*{"parents": ps, "key": e.key, "value": e.value}))

proc decodeEvent(b: seq[byte]): Event =
  let j = parseJson(toStr(b))
  result.key = j["key"].getStr()
  result.value = j["value"].getStr()
  if j.hasKey("parents") and j["parents"].kind == JArray:
    for p in j["parents"]: result.parents.add p.getStr()

proc ingestEnvelope(s: CoordinationSession, env: IncomingMessage) =
  ## Open + ingest. A raise — we can't decrypt (not a member, or a later-epoch
  ## envelope we hold no key for, F-16), or the bytes are malformed — is swallowed:
  ## the message simply isn't ours to reduce.
  try:
    s.log.ingest(decodeEvent(s.crypto.open(env.payload)))
  except CatchableError:
    discard

proc newCoordinationSession*(transport: Transport, crypto: ConversationCrypto,
                             topic: string): CoordinationSession =
  result = CoordinationSession(transport: transport, crypto: crypto, topic: topic)
  let self = result
  transport.subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    {.cast(gcsafe).}:                 # crypto.open uses secp's global context
      self.ingestEnvelope(m))

proc publish*(s: CoordinationSession, e: Event) =
  ## Record locally, then broadcast the sealed event to the room.
  s.log.ingest(e)
  discard s.transport.publish(s.topic, s.crypto.seal(encodeEvent(e)))

proc catchUp*(s: CoordinationSession) =
  ## Offline catchup (F-15): pull the store's retained envelopes for the topic and
  ## ingest the ones we can open. Idempotent — the log dedups (R-2/R-4), and
  ## envelopes from epochs we lack keys for are skipped (F-16).
  for m in s.transport.storeQuery(s.topic):
    s.ingestEnvelope(m)

proc state*(s: CoordinationSession): State = s.log.state()
proc digest*(s: CoordinationSession): string = s.log.state().stateDigest
