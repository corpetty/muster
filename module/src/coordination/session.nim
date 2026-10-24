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

import std/[json, sequtils, sets, strutils, tables, times]
import ../transport/transport
import ../crypto/conversation
import ../crypto/binding
import ../crypto/join_request
import ../crypto/sodium   # randomBytes: a beacon request's nonce
import ../log/log
import ./intents   # membershipEvent (the admit as a log entry)
export log, binding, join_request

type
  CoordinationSession* = ref object
    transport: Transport
    crypto: ConversationCrypto
    topic: string
    log*: Log
    pending: seq[JoinRequest]    ## join requests seen but not yet admitted (each names an encryption identity; no authority)
    invites: seq[seq[byte]]      ## invite frames seen on this (inbox) topic — opaque, sealed to the owner; the module opens them
    beacons: seq[seq[byte]]      ## join keys other rooms on this topic announced, most recent last (at most MaxBeacons)
    lastBeacon: seq[byte]        ## the join key we last announced
    lastBeaconAt: float          ## when (epoch seconds) — answers to beacon requests are rate-limited
    answered: HashSet[string]    ## beacon-request nonces already answered (a store catchup window re-delivers them)
    sealedIn*: Table[string, int] ## event id → the earliest epoch whose key opened (or sealed) it here; log + keys, never position (exo-dde)
    authorChecked*: Table[string, bool]  ## exo-f76: event id → its author signature verifies (authorship.nim). A pure function of (topic, event), so safe to cache
    afterChecked*: Table[string, bool]   ## C5: (event id, afterSig, after) → the author signed that `after` (authorship.afterVerified); pure, so safe to cache
    journal: proc(frame: seq[byte]) {.gcsafe.}  ## exo-dcc.14: every frame seen or sent, for the member's own copy (room_journal.nim)

# Every frame on the topic carries a 1-byte kind, so the membership handshake
# shares the topic with data without either misreading the other.
#
# What a store node — or anyone subscribed to the topic — reads (exo-661.7, FS-7/FS-9):
# the topic, when each frame was published, its size, and this kind byte. So it learns
# THAT someone asked to join, that an admit happened and how many members received the
# new key (one grant each), and when the room's join key changed. It never learns WHO:
# no frame carries a member identity, address, binding or epoch number in the clear.
const
  FrameData = 0x00'u8          ## body = epoch-sealed event envelope (no epoch number in the clear)
  FrameJoinRequest = 0x01'u8   ## body = a JoinRequest (the asker's encryption identity, self-signed for this room), sealed to a room's join key (a beacon) — no authority, no secp key (exo-a87)
  FrameControl = 0x02'u8       ## body = an opaque membership control frame (a grant, sealed whole to one member)
  FrameInvite = 0x03'u8        ## body = a sealed-box invite to THIS topic's owner (an inbox drop). Not epoch-sealed, so it needs no shared membership — anyone may drop, only the owner opens (sealed to their X25519).
  FrameBeacon = 0x04'u8        ## body = a room's current join key (32 bytes, derived from its epoch key; names no member)
  FrameBeaconRequest = 0x05'u8 ## body = a random 16-byte nonce: a would-be joiner has no join key to seal its request to yet
  MaxBeacons = 8               ## join keys a would-be joiner keeps (and seals each request to)
  BeaconMinInterval = 2.0      ## seconds between answers to beacon requests, per session, for an unchanged key
  VoiceFrameBytes* = 90_112    ## the padded plaintext of every `voice/` frame, so each is 1 + 24 + 16 +
                               ## 90,112 = 90,153 B on the wire whatever the note's length
                               ## (docs/design/voice-notes.md §3.4, §4, §5). A new value strands
                               ## notes already sent: it is a `v: 2`, never an edit

type FrameTooLarge* = object of CatchableError
  ## An event whose JSON does not fit the pad its frame must have (voice-notes.md §4). Raised
  ## by `publish` before the event is ingested, journalled or sent, so nothing of it is left.

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
  var j = %*{"parents": ps, "key": e.key, "value": e.value}
  if e.after.len > 0:
    # only when present: a client from before causal order ignores the field, and the id
    # never covers it (docs/design/causal-parents.md §3.3)
    var af = newJArray()
    for a in e.after: af.add %a
    j["after"] = af
  if e.afterSig.len > 0: j["afterSig"] = %e.afterSig
  toBytes($j)

proc isVoiceKey*(key: string): bool =
  ## A voice note's part (voice-notes.md §3.3), by the key's first segment, as `authorOf`
  ## classifies a kind: so nothing a fold reads as a voice part leaves unpadded. Whether a
  ## room holds a note, which a log proof is refused for, is the fold's (voice_live.roomProof,
  ## §10).
  key.split('/', maxsplit = 1)[0] == "voice"

proc padFor(key: string, padTo: int): int =
  ## The pad a frame for `key` gets. The key decides for a voice part, never the caller:
  ## `publish` has two send paths for one event (a new one, and the stored copy re-sealed),
  ## and a pad each call site had to pass would leave a path that forgot it sending a frame
  ## whose size shows the note's length, with nothing failing (§4).
  if padTo < 0: raise newException(ValueError, "a negative pad: " & $padTo)
  if not isVoiceKey(key): return padTo
  if padTo != 0 and padTo != VoiceFrameBytes:
    raise newException(ValueError, "a voice/ frame is padded to " & $VoiceFrameBytes & " B, never " & $padTo)
  VoiceFrameBytes

proc padded(e: Event, pad: int): seq[byte] =
  ## The plaintext a frame seals: the event's JSON, then ASCII spaces up to exactly `pad`
  ## bytes (none for 0, today's frame byte for byte). The spaces are transport framing, as
  ## the JSON is: outside `value`, so the event id (parents, key, value) and every signature
  ## are unchanged, and `decodeEvent` reads the frame unchanged, an older client's included,
  ## since parseJson at the builder's Nim pin (2.2.4) accepts trailing whitespace
  ## (session_pad_test §2). Raises FrameTooLarge when the JSON alone is over `pad`.
  result = encodeEvent(e)
  let n = result.len
  if pad == 0: return
  if n > pad:
    raise newException(FrameTooLarge, "an event of " & $n & " B does not fit a " & $pad & " B frame")
  result.setLen(pad)
  for i in n ..< pad: result[i] = byte(' ')

proc decodeEvent(b: seq[byte]): Event =
  let j = parseJson(toStr(b))
  result.key = j["key"].getStr()
  result.value = j["value"].getStr()
  if j.hasKey("parents") and j["parents"].kind == JArray:
    for p in j["parents"]: result.parents.add p.getStr()
  if j.hasKey("after") and j["after"].kind == JArray:
    for a in j["after"]: result.after.add a.getStr()
  if j.hasKey("afterSig") and j["afterSig"].kind == JString: result.afterSig = j["afterSig"].getStr()

proc announceBeacon*(s: CoordinationSession) =
  ## Announce the room's current join key, so someone who knows only the topic can ask
  ## to join without saying who they are in the clear. A changed key is announced at
  ## once; the same key at most every BeaconMinInterval (it answers beacon requests,
  ## and a request flood must not become a reply flood). Nothing when we hold no key.
  let b = s.crypto.joinBeacon()
  if b.len == 0: return
  let now = epochTime()
  if b == s.lastBeacon and now - s.lastBeaconAt < BeaconMinInterval: return
  s.lastBeacon = b
  s.lastBeaconAt = now
  discard s.transport.publish(s.topic, @[FrameBeacon] & b)

proc ingestEnvelope(s: CoordinationSession, env: IncomingMessage) =
  ## Route a frame by its kind byte. A raise — we can't decrypt (not a member, or a
  ## later-epoch envelope we hold no key for, F-16), a control frame not addressed
  ## to us, or malformed bytes — is swallowed: the frame simply isn't ours to act on.
  if env.payload.len == 0: return
  if s.journal != nil: s.journal(env.payload)   # the member's own copy keeps what is room state
  let kind = env.payload[0]
  let body = env.payload[1 .. ^1]
  try:
    case kind
    of FrameData:
      let (ep, plain) = s.crypto.openedEpoch(body)
      let ev = decodeEvent(plain)
      s.log.ingest(ev)
      let id = eventId(ev)
      if ep >= 0 and (id notin s.sealedIn or ep < s.sealedIn[id]): s.sealedIn[id] = ep
    of FrameJoinRequest:
      # sealed to a join key; only a member opens it. A request for another room, expired,
      # or not signed by the identity it names is dropped here: nobody asks in another's name
      let r = decodeJoinRequest(s.crypto.openJoinRequest(body))
      if not joinRequestValid(r, s.topic, uint64(epochTime())): return
      let m = r.enc
      if m notin s.crypto.members() and not s.pending.anyIt(it.enc == m):
        s.pending.add r
    of FrameControl:
      discard s.crypto.ingestControl(body)     # a grant; ours to open or not
    of FrameInvite:
      s.invites.add body                       # opaque here; the module sealOpens it with its keystore
    of FrameBeacon:
      if body.len == 32 and not s.crypto.ownsBeacon(body):
        s.beacons = s.beacons.filterIt(it != body) & @[body]
        if s.beacons.len > MaxBeacons: s.beacons = s.beacons[^MaxBeacons .. ^1]
    of FrameBeaconRequest:
      let nonce = toStr(body)
      if nonce notin s.answered:
        s.answered.incl nonce
        s.announceBeacon()
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

proc setJournal*(s: CoordinationSession, journal: proc(frame: seq[byte]) {.gcsafe.}) =
  ## Keep a copy of every frame this session sees or sends (exo-dcc.14): the hosted module
  ## hands it to the room's journal, which keeps the data and grant frames.
  s.journal = journal

proc replay*(s: CoordinationSession, frames: seq[seq[byte]]) =
  ## Rebuild from the member's own copy (exo-dcc.14): each frame through the same ingest a
  ## frame from the network takes — grants first (room_journal.replayOrder), so every
  ## epoch's data opens. Idempotent: the log dedups.
  for f in frames: s.ingestEnvelope(IncomingMessage(contentTopic: s.topic, payload: f))

proc topic*(s: CoordinationSession): string = s.topic
  ## The room's content topic — what an author signature binds to (authorship.nim).

proc sealFrame(s: CoordinationSession, ev: Event, padTo: int, asGiven: bool): seq[byte] =
  ## Everything `publish` does but the send: the copy chosen, padded, recorded (the log,
  ## `sealedIn`, the journal) and sealed. The frame it returns is for the transport.
  var e = ev
  let id = eventId(e)
  if not asGiven:
    let held = s.log.find(id)
    if held.found: e = held.event
    elif e.after.len == 0: e.after = s.log.heads()
  let plain = padded(e, padFor(e.key, padTo))
  s.log.ingest(e)
  let ep = (try: s.crypto.epoch() except CatchableError: -1)
  if ep >= 0 and (id notin s.sealedIn or ep < s.sealedIn[id]): s.sealedIn[id] = ep
  result = @[FrameData] & s.crypto.seal(plain)
  if s.journal != nil: s.journal(result)

proc publish*(s: CoordinationSession, ev: Event, padTo = 0, asGiven = false) =
  ## Record locally, then broadcast the sealed event to the room. A new event names the
  ## log's heads in `after` (what this member had seen; never part of the id, never read
  ## by a fold). An event the log already holds — a re-announce, a second submit — is
  ## re-sealed as the stored copy, so it carries its original order, not a fresh one
  ## (docs/design/causal-parents.md §3.2). `asGiven` seals `ev` as it is, its `after` and
  ## `afterSig` included, on either path: authorship.publishAuthored passes the copy this
  ## member signed, never one another member planted in the log (voice-notes.md §4).
  ##
  ## `padTo` > 0 pads the sealed plaintext to exactly that many bytes (`padded`); 0 is
  ## today's frame. A `voice/` key is padded to VoiceFrameBytes on either path with no pad
  ## passed, and any other non-zero pad for one raises ValueError, as a negative pad does
  ## (`padFor`; docs/design/voice-notes.md §4). An event whose JSON is over its pad
  ## raises FrameTooLarge before the log, the journal or the transport see it.
  discard s.transport.publish(s.topic, s.sealFrame(ev, padTo, asGiven))

proc publishTogether*(s: CoordinationSession, n: int, next: proc (i: int): Event) =
  ## Publish `n` events, each sealed as given (`publish`'s `asGiven`), as one burst: event
  ## `i` is made by `next(i)` once event `i - 1` is in the log (so the heads it names
  ## include it), padded, recorded and sealed, and only once all `n` are does any frame go
  ## out, then every frame back to back. So nothing whose cost depends on the events'
  ## contents runs between two sends: a voice note's two frames leave at a spacing its
  ## length does not set (voice-notes.md §10). FrameTooLarge from any event is raised
  ## before any frame of the burst is sent; the events before it stay recorded, as after a
  ## send that raised.
  var frames: seq[seq[byte]]
  for i in 0 ..< n: frames.add s.sealFrame(next(i), 0, true)
  for f in frames: discard s.transport.publish(s.topic, f)

# ── membership handshake ───────────────────────────────────────────────────────

proc sendInvite*(s: CoordinationSession, sealed: seq[byte]) =
  ## Drop a sealed invite into this (inbox) topic. The bytes are already sealed to the
  ## inbox owner's X25519 by the caller, so no shared epoch is needed — this is a
  ## broadcast drop-box, not a room. The store retains it so an offline owner catches up.
  discard s.transport.publish(s.topic, @[FrameInvite] & sealed)

proc receivedInvites*(s: CoordinationSession): seq[seq[byte]] = s.invites
  ## The raw sealed invite frames seen on this topic — the module opens them with its
  ## keystore (only the owner can); malformed / not-for-us ones simply won't open.

proc catchUp*(s: CoordinationSession)

proc requestJoin*(s: CoordinationSession, request: JoinRequest): bool {.discardable.} =
  ## Ask to be admitted: send our join request, sealed to each join key the room has
  ## announced, so only its members can read who is asking (FS-7) — the store node sees
  ## that someone asked, not who. The request names our encryption identity and is signed
  ## by it, so a member can tell we hold the key we name; it carries no secp key, so
  ## asking discloses nothing else (exo-a87), and no authority: a member still has to
  ## decide. Discovery, not entry.
  ##
  ## With no join key seen yet we pull the store's retained frames, and if there is
  ## still none, ask the room to announce one; a synchronous transport answers inside
  ## that publish, an asynchronous one by the next retry. False: nothing was sent yet.
  if s.beacons.len == 0:
    s.catchUp()
  if s.beacons.len == 0:
    discard s.transport.publish(s.topic, @[FrameBeaconRequest] & randomBytes(16))
  if s.beacons.len == 0: return false
  let bytes = encodeJoinRequest(request)
  for b in s.beacons:
    discard s.transport.publish(s.topic, @[FrameJoinRequest] & s.crypto.sealJoinRequest(b, bytes))
  true

proc members*(s: CoordinationSession): seq[Member] = s.crypto.members()
proc epoch*(s: CoordinationSession): int = s.crypto.epoch()
proc securityLevel*(s: CoordinationSession): SecurityLevel = s.crypto.securityLevel()
  ## The CONFIDENTIALITY level the room's crypto seam provides (null ladder, exo-1ec.5) —
  ## the real epoch layer, or the null base. The other axes are the driver's (authentication)
  ## and the log's (provenance); the hosted `security_levels` combines all three.
  ## The current membership epoch (monotonic; bumps on every admit/removal).
  ## The ADMITTED roster of the current epoch (recipients of the epoch key) —
  ## distinct from `pendingRequests` (join requests not yet admitted).

proc nodeInfo*(s: CoordinationSession): string = s.transport.nodeInfo()
proc rlnState*(s: CoordinationSession): string = s.transport.rlnState()
proc mixInputs*(s: CoordinationSession): MixInputs = s.transport.mixInputs()
  ## The transport node's mix path (exo-dcc.4), for the mix status row.
  ## The transport node's live view of itself (delivery: getNodeInfo) — for the
  ## connectivity indicators. "{}" for the in-process transport / a down node.

proc selfIdentity*(s: CoordinationSession): Member = s.crypto.identity()
  ## Our own member key, so the roster can flag which entry is us.

proc pendingRequests*(s: CoordinationSession): seq[JoinRequest] =
  ## Join requests awaiting a member's decision, each already checked to be signed by the
  ## identity it names, for this room. A relaunch's catch-up replays the topic in order, so
  ## a request is read before the grant that answered it (exo-7b3): anyone the current
  ## epoch already holds is not waiting.
  let members = s.crypto.members()
  s.pending.filterIt(it.enc notin members)

proc pendingJoins*(s: CoordinationSession): seq[Member] = s.pendingRequests().mapIt(it.enc)

proc admit*(s: CoordinationSession, joiner: Member) =
  ## Admit a joiner (an existing member's decision): re-key forward and publish the
  ## grants so every member of the new epoch — the joiner included — gets its key.
  ## The joiner receives only this epoch's key, never earlier ones (F-16).
  for frame in s.crypto.admit(joiner):
    if s.journal != nil: s.journal(@[FrameControl] & frame)
    discard s.transport.publish(s.topic, @[FrameControl] & frame)
  s.pending = s.pending.filterIt(it.enc != joiner)
  # Record the transition IN the log (exo-275 / M4): sealed under the NEW epoch, so
  # the joiner reads its own admission and nothing before it (F-16), and every
  # member's history + provenance fold shows the re-key from the same log.
  s.publish(membershipEvent(s.crypto.epoch(), hexOf(toBytes(joiner))))
  # The new epoch has a new join key; announce it so the next asker seals to a key
  # every current member (the new one included) can open.
  s.announceBeacon()

proc admitInvited*(s: CoordinationSession, invitee: Member): bool =
  ## Admit someone this member invites by name (exo-dcc.29): the invite IS the member's
  ## decision, and the identity is the one the member holds for them, so there is no
  ## request to wait for and nothing to verify. The grant waits in the store, so the
  ## invitee is a member on arrival and reads the room from here on, never before (F-16).
  ## Only a member of the current epoch can admit; someone already in is left alone (no
  ## re-key). True when the invitee is a member afterwards.
  let members = s.crypto.members()
  if invitee in members: return true
  if s.crypto.identity() notin members: return false
  s.admit(invitee)
  true

proc leave*(s: CoordinationSession) =
  ## Stop following this room here (exo-dcc.28): no more of its traffic is taken. The log
  ## and keys stay what they were, so joining the topic again reads the room back from
  ## the store and the keystore. The others are not told; nothing re-keys.
  s.transport.unsubscribe(s.topic)
  s.transport.detach()

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

proc heads*(s: CoordinationSession): seq[EventId] = s.log.heads()
  ## what a new event published now would name in `after`

proc state*(s: CoordinationSession): State = s.log.state()
proc digest*(s: CoordinationSession): string = s.log.state().stateDigest
