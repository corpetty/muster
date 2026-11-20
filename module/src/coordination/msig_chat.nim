## A lez-msig's chat group follows its members (RFP-005 S.2; roadmap M3, exo-7a5). The
## multisig's deliberation runs in a `chat_module` group (transport/chat_groups.nim); this is
## the room's half, pure functions of the event set (invariant 4):
##
##   member/<who>/chat        a member's chat address for this session, author-signed by their
##                            room identity. The newest counts: a chat address lives for one
##                            session of one client, so a relaunch shares a new one.
##   lmsig/<ck>/chat          the multisig's group, announced by the member whose client created
##                            it (its steward, below), author-signed.
##
## chatPlan is what THIS member's client does to the group now. One client acts, so the group
## sees one commit at a time: the steward, who is the multisig's opener while they are a member,
## else the lowest remaining member. It creates the group if none is announced, invites each
## current member's newest address it does not hold, and removes every address that is no
## current member's newest: a removed member's, and a stale session of a current member's.
##
## The binding is a claim: a member says which chat address is theirs, and nothing proves it.
## A false claim can only get that address invited; who reads the group is still the members
## the program holds, through their own claims. Stated in docs/labbook/chat-module-binding.md.

import std/[json, strutils, sequtils, tables, algorithm, options, times]
import ../log/log
import ../crypto/keystore
import ../drivers/lez_msig
import ../lez/msig
import ./session
import ./authorship
import ./msig_room
import ./msig_members
import ../transport/chat_groups

proc nowMs(): int64 = int64(epochTime() * 1000)

proc chatAddressEvent*(me, address: string, atMs = nowMs()): Event =
  ## Stamped with the sharer's clock: a member's sessions are ordered by it, and only their
  ## own clock orders their own addresses.
  Event(key: "member/" & me.toLowerAscii() & "/chat",
        value: $(%*{"author": me.toLowerAscii(), "address": address, "at": atMs}))

proc chatAddresses*(events: seq[Event]): Table[string, string] =
  ## room identity → its newest chat address (the latest `at`; canonical order breaks a tie).
  var at = initTable[string, int64]()
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len != 3 or p[0] != "member" or p[2] != "chat": continue
    try:
      let j = parseJson(e.value)
      let who = p[1].toLowerAscii()
      if j{"author"}.getStr().toLowerAscii() != who: continue
      let a = j{"address"}.getStr()
      let t = j{"at"}.getBiggestInt(0)
      if a.len > 0 and t >= at.getOrDefault(who, -1):
        result[who] = a
        at[who] = t
    except CatchableError: discard

proc shareChatAddress*(s: CoordinationSession, ks: Keystore, address: string): bool =
  ## Share this session's chat address, unless the room already holds it as this member's newest.
  let me = memberId(ks)
  if chatAddresses(s.roomEvents()).getOrDefault(me, "") == address: return false
  s.publishAuthored(ks, chatAddressEvent(me, address))
  true

proc chatGroupEvent*(createKey, steward, convo: string, atMs = nowMs()): Event =
  Event(key: "lmsig/" & createKey.toLowerAscii() & "/chat",
        value: $(%*{"author": steward.toLowerAscii(), "convo": convo, "at": atMs}))

proc steward*(events: seq[Event], room: string, a: LezMsigAccount): string =
  ## The client that keeps the group: the opener while a member, else the lowest member now.
  let now = memberIdsNow(events, room, a)
  let c = ceremonyOf(events, room, hexOf(a.createKey))
  if c.isSome and c.get.opener in now: return c.get.opener
  let sorted = sorted(now)
  if sorted.len > 0: sorted[0] else: ""

proc chatGroupOf*(events: seq[Event], room: string, a: LezMsigAccount): string =
  ## The group's conversation id: the newest announced by a member the ceremony invited or a
  ## member now. A steward that changes keeps the group it finds.
  let ck = hexOf(a.createKey)
  var now = memberIdsNow(events, room, a)
  let c = ceremonyOf(events, room, ck)
  if c.isSome: now.add c.get.members        # an opener since removed keeps the group it made
  var best = -1'i64
  for e in canonicalOrder(events):
    if e.key != "lmsig/" & ck & "/chat": continue
    try:
      let j = parseJson(e.value)
      let t = j{"at"}.getBiggestInt(0)
      if j{"author"}.getStr().toLowerAscii() in now and j{"convo"}.getStr().len > 0 and t >= best:
        result = j{"convo"}.getStr()
        best = t
    except CatchableError: discard

type ChatPlan* = object
  steward*: bool                 ## this client keeps the group
  create*: bool                  ## no group yet: create it, then announce it
  convo*: string
  invite*: seq[string]           ## addresses to add
  remove*: seq[string]           ## addresses to remove
  missing*: seq[string]          ## current members who have shared no chat address

proc chatPlan*(events: seq[Event], room: string, a: LezMsigAccount, me, myAddress: string,
               roster: seq[ChatMember]): ChatPlan =
  ## What THIS client does to the multisig's chat group now. `roster` is the group as this
  ## client's chat module reads it (members and its own pending invites); `myAddress` its own.
  let mine = me.toLowerAscii()
  result.steward = steward(events, room, a) == mine
  result.convo = chatGroupOf(events, room, a)
  let now = memberIdsNow(events, room, a)
  let addrs = chatAddresses(events)
  var want: seq[string]
  for who in now:
    if who in addrs: want.add addrs[who] else: result.missing.add who
  if not result.steward: return
  if result.convo.len == 0:
    result.create = true
    result.invite = want.filterIt(it != myAddress)
    return
  let have = roster.mapIt(it.address)
  result.invite = want.filterIt(it != myAddress and it notin have)
  result.remove = have.filterIt(it != myAddress and it notin want)

proc applyChatPlan*(s: CoordinationSession, ks: Keystore, chat: ChatGroups, a: LezMsigAccount,
                    plan: ChatPlan, name: string): tuple[convo: string, done: seq[string], failed: seq[string]] =
  ## Carry out a steward's plan on the chat module: create and announce the group if needed,
  ## then invite and remove. Each step that the module refuses is reported, never retried here
  ## (the next tick plans again from what the module then holds).
  if not plan.steward: return
  result.convo = plan.convo
  if plan.create:
    result.convo = chat.createGroup(name, "lez-msig " & hexOf(a.createKey)[0 ..< 8] & " — members only")
    s.publishAuthored(ks, chatGroupEvent(hexOf(a.createKey), memberId(ks), result.convo))
  for x in plan.invite:
    try: (chat.addMember(result.convo, x); result.done.add "invite " & x)
    except CatchableError as e: result.failed.add "invite " & x & ": " & e.msg
  for x in plan.remove:
    try: (chat.removeMember(result.convo, x); result.done.add "remove " & x)
    except CatchableError as e: result.failed.add "remove " & x & ": " & e.msg
