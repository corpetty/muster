## A room creates a lez-msig together (epic exo-0d3, docs/design/lez-msig.md §8).
##
##   lmsig/<ck>/open          the opener's invitation: who is in it (room identities), the
##                            threshold, roles and weights, the time lock, the program and
##                            zone. <ck> is the multisig's create key, random.
##   lmsig/<ck>/key/<who>     a member's approval key for this multisig, author-signed by
##                            their room identity, with a BIP-340 proof by the approval key
##                            over (room, create key, their identity): the binding is mutual,
##                            and lives only in the room (Privacy-1).
##
## The ceremony is ready once every invited member has joined. The opener then sends Create
## from their own funded LEZ account and discloses the account once the chain holds it. That
## step is the host's, because it needs the chain. Every view here is a fold over the room's
## authentic events (invariant 4). An approval key that is not proved by its own signature is
## not counted, and neither is one from a member the opener did not invite.

import std/[json, strutils, tables, sequtils, options, sysrand]
import ../log/log
import ../crypto/keystore
import ../crypto/curve25519
import ./session
import ./authorship
import ../lez/msig
import ../drivers/lez_msig
import ../drivers/driver
import ../intents/materialization
import ../crypto/binding
import ./intent_events
import ./live
import ./member_accounts
import stint

const BindTag = "muster-msig/v1/bind"

type
  MsigCeremony* = object
    createKey*: string            ## hex
    opener*: string               ## the opener's room identity (hex)
    chain*: string                ## CAIP-2
    program*, zone*: string       ## hex
    members*: seq[string]         ## invited room identities, in order
    roles*: seq[uint8]
    weights*: seq[uint16]
    threshold*: uint32
    timelockMs*: uint64
    openExecution*: bool
    keys*: Table[string, string]  ## room identity → approval key hex (proved)
    fromAccount*: Table[string, string]  ## room identity → the disclosed account (hex) the opener picked for them
    ready*: bool
    private*: bool                ## a group-owned private PDA: its group secret is sealed to each member

proc hx(b: openArray[byte]): string = hexOf(b)
proc unhx(s: string): seq[byte] =
  var h = s.strip().toLowerAscii()
  if h.startsWith("0x"): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc bytesOf(s: string): seq[byte] =
  for c in s: result.add byte(c)

proc memberId*(ks: Keystore): string = hx(ks.encIdentity().toBytes())

proc bindMsg*(room: string, createKey, member: seq[byte]): seq[byte] =
  ## What an approval key signs to say it is this member's, for this multisig, in this room.
  tagged(BindTag, bytesOf(room) & @[0'u8] & createKey & member)

proc configOf*(c: MsigCeremony): MsigConfig =
  ## The config Create writes: the invited members' approval keys, in invitation order.
  result = MsigConfig(threshold: c.threshold, timelockMs: c.timelockMs, openExecution: c.openExecution,
                      actions: ActAll)
  for i, m in c.members:
    result.members.add MsigMember(key: unhx(c.keys[m]), roles: c.roles[i], weight: c.weights[i])

proc ceremonies*(events: seq[Event], room: string): seq[MsigCeremony] =
  ## Every lez-msig ceremony in the room, with the keys proved so far.
  var byCk: OrderedTable[string, MsigCeremony]
  for e in events:
    let p = e.key.split('/')
    if p.len == 3 and p[0] == "lmsig" and p[2] == "open" and p[1] notin byCk:
      try:
        let j = parseJson(e.value)
        var c = MsigCeremony(createKey: p[1], opener: j{"opener"}.getStr(), chain: j{"chain"}.getStr(),
                             program: j{"program"}.getStr(), zone: j{"zone"}.getStr(),
                             threshold: uint32(j{"threshold"}.getInt()),
                             timelockMs: uint64(j{"timelockMs"}.getBiggestInt(0)),
                             openExecution: j{"openExecution"}.getBool(true),
                             private: j{"private"}.getBool(false))
        for m in j{"members"}.getElems():
          let id = m{"id"}.getStr().toLowerAscii()
          c.members.add id
          c.roles.add uint8(m{"roles"}.getInt(int(RoleAll)))
          c.weights.add uint16(m{"weight"}.getInt(1))
          # an account the member disclosed in this room (exo-1f9), picked by the opener as
          # their approval key: it counts as their join once the disclosure checks out
          let k = m{"key"}.getStr().toLowerAscii()
          if k.len == 64 and hasAccount(events, room, id, unhx(k)):
            c.keys[id] = k
            c.fromAccount[id] = hexOf(addressOf(KindLezKey, unhx(k)))
        if unhx(c.createKey).len == 32 and c.members.len > 0 and c.threshold >= 1:
          byCk[p[1]] = c
      except CatchableError: discard
  for e in events:
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "lmsig" or p[2] != "key" or p[1] notin byCk: continue
    let who = p[3].toLowerAscii()
    if who notin byCk[p[1]].members or who in byCk[p[1]].keys: continue
    try:
      let j = parseJson(e.value)
      let key = unhx(j{"key"}.getStr())
      if key.len == 32 and verifySig(key, bindMsg(room, unhx(p[1]), unhx(who)), unhx(j{"proof"}.getStr())):
        byCk[p[1]].keys[who] = hx(key)
    except CatchableError: discard
  for ck, c in byCk.mpairs:
    c.ready = c.members.allIt(it in c.keys)
    result.add c

proc ceremonyJson*(c: MsigCeremony, me: string): JsonNode =
  %*{"createKey": c.createKey, "chain": c.chain, "opener": c.opener, "openedByMe": c.opener == me,
     "members": c.members.mapIt(%*{"id": it, "joined": it in c.keys, "key": c.keys.getOrDefault(it, ""),
                                   "account": c.fromAccount.getOrDefault(it, "")}),
     "threshold": int(c.threshold), "timelockMs": $c.timelockMs, "openExecution": c.openExecution,
     "ready": c.ready, "invited": me in c.members, "joined": me in c.keys, "private": c.private}

proc msigOpen*(s: CoordinationSession, ks: Keystore, chain: string, program, zone: seq[byte],
               members: seq[tuple[id: string, roles: uint8, weight: uint16]], threshold: uint32,
               timelockMs: uint64, openExecution: bool, private = false,
               accounts = initTable[string, string]()): string =
  ## Open a ceremony; returns the create key. The opener joins at once. A private one
  ## (exo-efa) also seals a fresh group secret to every invited member, the opener included.
  ## `accounts` picks, for a member, an account they disclosed in the room (its key, hex) as
  ## their approval key instead of a fresh one (exo-1f9); it must be theirs and still stood
  ## by, or it is refused.
  var ck = newSeq[byte](32)
  if not urandom(ck): raise newException(OSError, "no randomness for a create key")
  let me = memberId(ks)
  let evs = s.roomEvents()
  var memberJson: seq[JsonNode]
  for m in members:
    let id = m.id.toLowerAscii()
    var mj = %*{"id": id, "roles": int(m.roles), "weight": int(m.weight)}
    if id in accounts:
      let k = accounts[id].toLowerAscii()
      if not hasAccount(evs, s.topic, id, unhx(k)):
        raise newException(ValueError, "the account picked for " & id[0 ..< 8] & " is not one they disclosed in this room")
      mj["key"] = %k
    memberJson.add mj
  s.publish(Event(key: "lmsig/" & hx(ck) & "/open", value: $(%*{
    "opener": me, "chain": chain, "program": hx(program), "zone": hx(zone), "threshold": int(threshold),
    "timelockMs": $timelockMs, "openExecution": openExecution, "private": private,
    "members": memberJson})))
  result = hx(ck)
  if private:
    var gms = newSeq[byte](32)
    if not urandom(gms): raise newException(OSError, "no randomness for a group secret")
    for m in members:
      let id = m.id.toLowerAscii()
      s.publishAuthored(ks, Event(key: "lmsig/" & result & "/gms/" & id, value: $(%*{
        "author": me, "sealed": hx(sealTo(encIdentityFromBytes(unhx(id)).x, gms))})))

proc msigJoin*(s: CoordinationSession, ks: Keystore, createKey: string) =
  ## This member's approval key for the multisig, proved by itself and author-signed.
  let ck = unhx(createKey)
  let label = msigLabel(ck)
  let me = memberId(ks)
  var h: array[32, byte]
  let m = bindMsg(s.topic, ck, unhx(me))
  for i in 0 ..< 32: h[i] = m[i]
  s.publishAuthored(ks, Event(key: "lmsig/" & createKey.toLowerAscii() & "/key/" & me,
                              value: $(%*{"key": hx(ks.lezMemberKey(label)), "proof": hx(ks.lezMemberSign(label, h))})))

proc joinInvited*(s: CoordinationSession, ks: Keystore): int =
  ## Join every ceremony that invites this member and has not had its key yet; returns how
  ## many. Run on the intents tick, so a member acts once (or never: an invitation is joined
  ## by the member's own client, which derives a fresh key for it).
  let me = memberId(ks)
  for c in ceremonies(s.roomEvents(), s.topic):
    if me in c.members and me notin c.keys:
      s.msigJoin(ks, c.createKey)
      inc result

# ── proposing ────────────────────────────────────────────────────────────────
proc takenNonces*(events: seq[Event], multisig: seq[byte]): seq[uint64] =
  ## The nonces proposals and spends in this room already use for this multisig (they share
  ## one window): a new one takes the lowest that neither the chain nor the room has used.
  for e in events:
    let p = e.key.split('/')
    if p.len == 3 and p[0] == "intent" and p[2] == "propose":
      try:
        let eff = effectFromJson(e.value)
        if eff.schemaId == LezMsigSchema:
          let pr = proposalOf(eff)
          if pr.multisig == multisig: result.add pr.nonce
        elif eff.schemaId == LezMsigSpendSchema:
          let sp = msigSpendOf(eff)
          if sp.multisig == multisig: result.add sp.nonce
      except CatchableError: discard

proc newMsigProposal*(events: seq[Event], ks: Keystore, d: LezMsigDriver, st: MsigState,
                      action: MsigAction, expiresMs: uint64): MsigProposal =
  ## A proposal from THIS member (their approval key is the proposer), at the chain's epoch
  ## and the next nonce free on chain and in the room. Its expiry is rounded down to the
  ## minute: the window it becomes is public (§5, exo-a99).
  MsigProposal(multisig: d.account.address, zone: st.zone, epoch: st.epoch,
               nonce: st.nextNonce(takenNonces(events, d.account.address)), action: action,
               expiresMs: floorMinute(expiresMs), proposer: ks.lezMemberKey(myMsigLabel(ks, d.account)))

proc liveMsigPropose*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, policy: string,
                      d: LezMsigDriver, p: MsigProposal, nowSec: int64, msgSeq: uint64,
                      bindingCtx: LinkContext, payee: seq[byte] = @[]): tuple[intentId, approval: string] =
  ## Propose into the room, then approve it in-app: the program refuses an action its
  ## proposer did not sign, so proposing IS the proposer's approval. `payee` is a private payee's
  ## recipient (LEZ v0.4, exo-ea3), carried in the effect beside the proposal.
  let ttl = max(60'i64, int64(p.expiresMs div 1000) - nowSec)
  let id = liveProposeIntent(s, ks, driverFor, policy, lezMsigEffect(p, payee), nowSec, msgSeq,
                             d.account.accountId, ttlSec = ttl)
  (id, liveContribute(s, ks, driverFor, id, "", "", bindingCtx, uint64(nowSec)))

proc newMsigSpend*(events: seq[Event], d: LezMsigDriver, st: MsigState, limit: uint32, to: seq[byte],
                   amount: UInt128, expiresMs: uint64): MsigSpend =
  ## A spend under a limit (exo-0d3.12), at the chain's epoch and the next nonce free on chain
  ## and in the room. Its expiry is rounded down to the minute, as a proposal's is.
  MsigSpend(multisig: d.account.address, zone: st.zone, epoch: st.epoch, limit: limit,
            nonce: st.nextNonce(takenNonces(events, d.account.address)), to: to, amount: amount,
            expiresMs: floorMinute(expiresMs))

proc liveMsigSpend*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, policy: string,
                    d: LezMsigDriver, sp: MsigSpend, nowSec: int64, msgSeq: uint64,
                    bindingCtx: LinkContext): tuple[intentId, approval: string] =
  ## Put a spend to the room, signed at once by this member (a signer of its limit): the
  ## limit's other signers add theirs on its card, and no quorum is asked.
  let ttl = max(60'i64, int64(sp.expiresMs div 1000) - nowSec)
  let id = liveProposeIntent(s, ks, driverFor, policy, lezMsigSpendEffect(sp), nowSec, msgSeq,
                             d.account.accountId, ttlSec = ttl)
  (id, liveContribute(s, ks, driverFor, id, "", "", bindingCtx, uint64(nowSec)))

# ── the private posture (exo-efa, docs/design/lez-msig.md §6) ──────────────────
## A private multisig's account takes its group's keys to derive and to spend from, so the
## group secret is shared with the members the opener invited, sealed to each one's room
## identity, never with the rest of the room. Its state lives in a note only those members
## read; after each transaction the chain includes, the member who sent it seals the new
## note to every member, so each can propose and execute next without scanning the chain.
##   lmsig/<ck>/gms/<who>        the group secret, sealed to <who>; only the opener's counts
##   lmsig/<ck>/note/<n>/<who>   the note after the n-th transaction (0 is Create), sealed to
##                               <who>, with the transaction's hash; only a member's counts
##   lmsig/<ck>/feenote/<n>/<who> on LEZ v0.4, the group fee account's n-th note (D17), sealed
##                               the same way: every transaction pays its fee from it, and a
##                               top-up changes it alone, so it is numbered on its own (exo-05f)

proc ceremonyOf*(events: seq[Event], room, createKey: string): Option[MsigCeremony] =
  for c in ceremonies(events, room):
    if c.createKey == createKey.toLowerAscii(): return some(c)

proc groupSecretOf*(events: seq[Event], ks: Keystore, room, createKey: string,
                    sealers: seq[string] = @[]): Option[seq[byte]] =
  ## This member's copy of a private multisig's group secret, sealed to them by its opener, or,
  ## for a member added later, by one of `sealers` (the members now, exo-0d3.13).
  let c = ceremonyOf(events, room, createKey)
  if c.isNone or not c.get.private: return
  let key = "lmsig/" & createKey.toLowerAscii() & "/gms/" & memberId(ks)
  for e in events:
    if e.key != key: continue
    try:
      let j = parseJson(e.value)
      let author = j{"author"}.getStr().toLowerAscii()
      if author != c.get.opener and author notin sealers: continue
      let g = ks.sealOpen(unhx(j{"sealed"}.getStr()))
      if g.len == 32: return some(g)
    except CatchableError: discard

proc sealGroupSecretTo*(s: CoordinationSession, ks: Keystore, createKey: string, gms: seq[byte], who: string) =
  ## Seal this member's copy of the group secret to a member added after creation (exo-0d3.13).
  s.publishAuthored(ks, Event(key: "lmsig/" & createKey.toLowerAscii() & "/gms/" & who.toLowerAscii(), value: $(%*{
    "author": memberId(ks), "sealed": hx(sealTo(encIdentityFromBytes(unhx(who)).x, gms))})))

proc sealNoteTo*(s: CoordinationSession, ks: Keystore, createKey: string, n: int, note: seq[byte], hash, who: string,
                 kind = "note", cursor = "") =
  var v = %*{"author": memberId(ks), "hash": hash, "sealed": hx(sealTo(encIdentityFromBytes(unhx(who)).x, note))}
  if cursor.len > 0: v["cursor"] = %cursor
  s.publishAuthored(ks, Event(key: "lmsig/" & createKey.toLowerAscii() & "/" & kind & "/" & $n & "/" & who.toLowerAscii(),
                              value: $v))

proc publishNote*(s: CoordinationSession, ks: Keystore, c: MsigCeremony, n: int, note: seq[byte], hash: string,
                  members: seq[string] = @[], kind = "note", cursor = "") =
  ## Seal the multisig's new note (`kind` "note"), or its fee account's ("feenote", LEZ v0.4), to
  ## every member after the chain included `hash`: to `members` (the members now, exo-0d3.13), or
  ## the ceremony's when none are given. `cursor` (v0.4) is where the next transaction collects
  ## deposits from outside the group: a position in the zone's public stream, so it rides in clear.
  for m in (if members.len > 0: members else: c.members):
    s.sealNoteTo(ks, c.createKey, n, note, hash, m, kind, cursor)

proc latestNote*(events: seq[Event], ks: Keystore, room, createKey: string,
                 authors: seq[string] = @[], kind = "note"): tuple[found: bool, n: int, note: seq[byte], hash, cursor: string] =
  ## The newest note (`kind` "note", or the fee account's, "feenote") sealed to this member by a
  ## member of the multisig: one of `authors` (the members now, exo-0d3.13; a removed member's note
  ## no longer counts), or, when none are given, one the ceremony invited. Only one transaction
  ## spending a note can land (its nullifier), so each number has one note; the first counts.
  let c = ceremonyOf(events, room, createKey)
  if c.isNone: return
  let me = memberId(ks)
  result.n = -1
  for e in events:
    let p = e.key.split('/')
    if p.len != 5 or p[0] != "lmsig" or p[1] != c.get.createKey or p[2] != kind or p[4] != me: continue
    try:
      let n = parseInt(p[3])
      if n <= result.n: continue
      let j = parseJson(e.value)
      let author = j{"author"}.getStr().toLowerAscii()
      if author notin (if authors.len > 0: authors else: c.get.members): continue
      let note = ks.sealOpen(unhx(j{"sealed"}.getStr()))
      result = (true, n, note, j{"hash"}.getStr(), j{"cursor"}.getStr())
    except CatchableError: discard
