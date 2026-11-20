## Group conversations on the platform's chat module (RFP-005 S.2; roadmap M3, exo-7a5): the seam
## muster reaches `chat_module` through, and a fake that behaves as the module does, for tests.
##
## The limited integration: a lez-msig's DELIBERATION runs in a `chat_module` group whose members
## follow the program's, while proposals and approvals stay on muster's room until the full
## binding behind `ConversationCrypto` reaches parity. Members read and write the group in the
## platform's chat app; muster only provisions it and keeps its roster (coordination/msig_chat.nim).
##
## What the module does that the planner relies on (chat_module.lidl at logos-chat-module b53abd6,
## plus `remove_group_member`, which the module does not expose yet; see
## docs/labbook/chat-module-binding.md):
##   * a member is an ACCOUNT ADDRESS, and each `init` is a new installation with a new address, so
##     an address is good for one session of one member's client;
##   * a group is created with only its creator; members are invited (an MLS commit applied about
##     two minutes later) and removed the same way; a member cannot remove itself;
##   * the roster lists committed members, then invites this instance sent and has not applied.

import std/[tables, sequtils]

type
  ChatError* = object of CatchableError
  ChatMember* = object
    address*: string
    pending*: bool               ## invited by this instance, not applied yet

  ChatGroups* = ref object of RootObj

method ready*(c: ChatGroups): bool {.base.} = false
  ## The module is loaded and initialised (delivery may still be coming up).
method address*(c: ChatGroups): string {.base.} =
  ## This installation's account address: what other members invite.
  raise newException(ChatError, "ChatGroups.address is abstract")
method createGroup*(c: ChatGroups, name, desc: string): string {.base.} =
  ## A new group with this installation as its only member; its conversation id.
  raise newException(ChatError, "ChatGroups.createGroup is abstract")
method addMember*(c: ChatGroups, convo, address: string) {.base.} =
  raise newException(ChatError, "ChatGroups.addMember is abstract")
method removeMember*(c: ChatGroups, convo, address: string) {.base.} =
  raise newException(ChatError, "ChatGroups.removeMember is abstract")
method members*(c: ChatGroups, convo: string): seq[ChatMember] {.base.} =
  raise newException(ChatError, "ChatGroups.members is abstract")

# ── the fake: one shared world of groups, as several installations see it ─────────────────
type
  FakeChatWorld* = ref object
    groups*: Table[string, seq[string]]   ## convo id → member addresses
    seq: int
  FakeChatGroups* = ref object of ChatGroups
    world*: FakeChatWorld
    me*: string

proc newFakeChatWorld*(): FakeChatWorld = FakeChatWorld()
proc newFakeChatGroups*(world: FakeChatWorld, address: string): FakeChatGroups =
  FakeChatGroups(world: world, me: address)

method ready*(c: FakeChatGroups): bool = true
method address*(c: FakeChatGroups): string = c.me
method createGroup*(c: FakeChatGroups, name, desc: string): string =
  inc c.world.seq
  result = "convo-" & $c.world.seq
  c.world.groups[result] = @[c.me]
proc mustHold(c: FakeChatGroups, convo: string) =
  if convo notin c.world.groups or c.me notin c.world.groups[convo]:
    raise newException(ChatError, "unknown conversation " & convo)
method addMember*(c: FakeChatGroups, convo, address: string) =
  c.mustHold(convo)
  if address notin c.world.groups[convo]: c.world.groups[convo].add address
method removeMember*(c: FakeChatGroups, convo, address: string) =
  c.mustHold(convo)
  if address == c.me: raise newException(ChatError, "a member cannot remove itself")
  if address notin c.world.groups[convo]: raise newException(ChatError, "not a member: " & address)
  c.world.groups[convo] = c.world.groups[convo].filterIt(it != address)
method members*(c: FakeChatGroups, convo: string): seq[ChatMember] =
  if convo notin c.world.groups or c.me notin c.world.groups[convo]: return
  c.world.groups[convo].mapIt(ChatMember(address: it))
