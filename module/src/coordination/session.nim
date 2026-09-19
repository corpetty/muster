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

import std/[json, sequtils]
import ../transport/transport
import ../crypto/conversation
import ../crypto/binding
import ../log/log
import ./intents   # membershipEvent (the admit as a log entry)
export log, binding

type
  CoordinationSession* = ref object
    transport: Transport
    crypto: ConversationCrypto
    topic: string
    log*: Log
    pending: seq[LinkStatement]  ## join-requests seen but not yet admitted (each carries a binding; no authority)
    invites: seq[seq[byte]]      ## invite frames seen on this (inbox) topic — opaque, sealed to the owner; the module opens them

# Every frame on the topic carries a 1-byte kind, so the membership handshake
# shares the topic with data without either misreading the other.
const
  FrameData = 0x00'u8          ## body = epoch-sealed event envelope
  FrameJoinRequest = 0x01'u8   ## body = the requester's 33-byte member key (no authority)
  FrameControl = 0x02'u8       ## body = an opaque membership control frame (a grant)
  FrameInvite = 0x03'u8        ## body = a sealed-box invite to THIS topic's owner (an inbox drop). Not epoch-sealed, so it needs no shared membership — anyone may drop, only the owner opens (sealed to their X25519).

proc toBytes(s: string): seq[byte] = (for c in s: result.add byte(c))
proc toStr(b: openArray[byte]): string = (for x in b: result.add char(x))
proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)]

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
  ## Route a frame by its kind byte. A raise — we can't decrypt (not a member, or a
  ## later-epoch envelope we hold no key for, F-16), a control frame not addressed
  ## to us, or malformed bytes — is swallowed: the frame simply isn't ours to act on.
  if env.payload.len == 0: return
  let kind = env.payload[0]
  let body = env.payload[1 .. ^1]
  try:
    case kind
    of FrameData:
      s.log.ingest(decodeEvent(s.crypto.open(body)))
    of FrameJoinRequest:
      let st = decodeLink(body)                # a binding requesting admission
      let m = st.enc
      if m notin s.crypto.members() and not s.pending.anyIt(it.enc == m):
        s.pending.add st
    of FrameControl:
      discard s.crypto.ingestControl(body)     # a grant; ours to open or not
    of FrameInvite:
      s.invites.add body                       # opaque here; the module sealOpens it with its keystore
    else: discard
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
  discard s.transport.publish(s.topic, @[FrameData] & s.crypto.seal(encodeEvent(e)))

# ── membership handshake ───────────────────────────────────────────────────────

proc sendInvite*(s: CoordinationSession, sealed: seq[byte]) =
  ## Drop a sealed invite into this (inbox) topic. The bytes are already sealed to the
  ## inbox owner's X25519 by the caller, so no shared epoch is needed — this is a
  ## broadcast drop-box, not a room. The store retains it so an offline owner catches up.
  discard s.transport.publish(s.topic, @[FrameInvite] & sealed)

proc receivedInvites*(s: CoordinationSession): seq[seq[byte]] = s.invites
  ## The raw sealed invite frames seen on this topic — the module opens them with its
  ## keystore (only the owner can); malformed / not-for-us ones simply won't open.

proc requestJoin*(s: CoordinationSession, binding: LinkStatement) =
  ## Announce our binding on the topic, asking to be admitted. The binding lets a
  ## member VERIFY we are who we claim (our encryption identity is signed by our
  ## secp key) before admitting — but it carries no authority on its own: a member
  ## still has to decide. Discovery, not entry.
  discard s.transport.publish(s.topic, @[FrameJoinRequest] & encodeLink(binding))

proc members*(s: CoordinationSession): seq[Member] = s.crypto.members()
proc epoch*(s: CoordinationSession): int = s.crypto.epoch()
  ## The current membership epoch (monotonic; bumps on every admit/removal).
  ## The ADMITTED roster of the current epoch (recipients of the epoch key) —
  ## distinct from `pendingBindings` (join-requests not yet admitted).

proc nodeInfo*(s: CoordinationSession): string = s.transport.nodeInfo()
  ## The transport node's live view of itself (delivery: getNodeInfo) — for the
  ## connectivity indicators. "{}" for the in-process transport / a down node.

proc selfIdentity*(s: CoordinationSession): Member = s.crypto.identity()
  ## Our own member key, so the roster can flag which entry is us.

proc pendingBindings*(s: CoordinationSession): seq[LinkStatement] = s.pending
  ## Bindings awaiting an admission decision — the caller verifies each against its
  ## owner set (F-9, bindingBinds) before deciding, then calls admit.

proc pendingJoins*(s: CoordinationSession): seq[Member] = s.pending.mapIt(it.enc)

proc admit*(s: CoordinationSession, joiner: Member) =
  ## Admit a joiner (an existing member's decision): re-key forward and publish the
  ## grants so every member of the new epoch — the joiner included — gets its key.
  ## The joiner receives only this epoch's key, never earlier ones (F-16).
  for frame in s.crypto.admit(joiner):
    discard s.transport.publish(s.topic, @[FrameControl] & frame)
  s.pending = s.pending.filterIt(it.enc != joiner)
  # Record the transition IN the log (exo-275 / M4): sealed under the NEW epoch, so
  # the joiner reads its own admission and nothing before it (F-16), and every
  # member's history + provenance fold shows the re-key from the same log.
  s.publish(membershipEvent(s.crypto.epoch(), hexOf(toBytes(joiner))))

proc catchUp*(s: CoordinationSession) =
  ## Offline catchup (F-15): pull the store's retained envelopes for the topic and
  ## ingest the ones we can open. Idempotent — the log dedups (R-2/R-4), and
  ## envelopes from epochs we lack keys for are skipped (F-16).
  for m in s.transport.storeQuery(s.topic):
    s.ingestEnvelope(m)

proc poll*(s: CoordinationSession) =
  ## Drive inbound delivery. For a foreign-thread transport (delivery) this
  ## dispatches queued messages on this thread (GC-safe); for a synchronous one
  ## (LocalTransport) it is a no-op — messages already arrived via publish. The
  ## host calls this in its loop.
  s.transport.poll()

proc state*(s: CoordinationSession): State = s.log.state()
proc digest*(s: CoordinationSession): string = s.log.state().stateDigest
