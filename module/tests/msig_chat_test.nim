## A lez-msig's chat group follows its members (exo-7a5; RFP-005 S.2, roadmap M3). On a fake chat
## module that behaves as `chat_module` does (transport/chat_groups.nim), Alice, Bob and Carol:
##   1. a chat address is author-signed: one posted under another member's name is dropped;
##   2. each member shares a chat address; the opener's client is the steward: it creates the
##      group, announces it, and invites the others; no other client acts;
##   3. once applied, the plan is empty;
##   4. Carol relaunches (a new chat installation, a new address): the steward invites the new
##      address and removes the stale one;
##   5. Carol is removed from the multisig: the steward removes her address;
##   6. a member who has shared no address is reported, never guessed;
##   7. the opener removed: the lowest remaining member becomes steward, keeps the same group,
##      and removes the old opener's address.
## Needs the secp closure + libsodium.

import std/[json, options, sequtils, strutils, tables]
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/drivers/lez_msig
import ../src/lez/msig
import ../src/coordination/session
import ../src/coordination/intent_events
import ../src/coordination/accounts
import ../src/coordination/authorship
import ../src/coordination/msig_room
import ../src/coordination/msig_members
import ../src/coordination/msig_chat
import ../src/transport/chat_groups
import ./probes/live_room

proc fill(x: byte): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 32: result[i] = x)
proc hx(b: openArray[byte]): string = hexOf(b)
proc unhexBytes(h: string): seq[byte] =
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

const Chain = "lez:local"
let program = fill(0x11)
let zone = fill(0x2e)
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ids = kss.mapIt(hx(it.encIdentity().toBytes()))
var r = newRoom3("/muster/1/msig-chat/proto")
let ss = @[r.alice, r.bob, r.carol]
proc ev(i = 0): seq[Event] =
  for s in ss: s.poll()
  ss[i].roomEvents()

# a public 2-of-3 Alice opens; all three join; Alice discloses it
let ck = r.alice.msigOpen(aliceKs, Chain, program, zone,
                          @[(ids[0], RoleAll, 1'u16), (ids[1], RoleAll, 1'u16), (ids[2], RoleAll, 1'u16)], 2, 0, true)
for s in ss: s.poll()
for i in 0 .. 2: ss[i].msigJoin(kss[i], ck)
let cer = ceremonyOf(ev(), r.topic, ck).get
let address = multisigPublic(program, unhexBytes(ck))
let acct = LezMsigAccount(chain: Chain, program: program, createKey: unhexBytes(ck), zone: zone, address: address,
                          accountId: Chain & ":" & hx(address), epoch: 0, config: configOf(cer))
r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMsigFamily, chain: Chain,
  address: hx(address), label: "chat", signers: acct.config.members.mapIt(hx(it.key)), threshold: 2,
  config: configJsonOf(acct)), ids[0]))

let world = newFakeChatWorld()
var chats = @[newFakeChatGroups(world, "chat-alice-1"), newFakeChatGroups(world, "chat-bob-1"),
              newFakeChatGroups(world, "chat-carol-1")]

proc planFor(i: int): ChatPlan =
  let e = ev(i)
  let convo = chatGroupOf(e, r.topic, acct)
  chatPlan(e, r.topic, acct, ids[i], chats[i].address, (if convo.len > 0: chats[i].members(convo) else: @[]))

proc applyFor(i: int): seq[string] =
  let p = planFor(i)
  applyChatPlan(ss[i], kss[i], chats[i], acct, p, "chat").done

var removeSeq = 0
proc removeFinal(i: int, who: int, epoch: uint64, threshold = 0'u32) =
  inc removeSeq
  let k = kss[who].lezMemberKey(msigLabel(unhexBytes(ck)))
  var changes = @[MsigChange(kind: ccRemoveMember, removed: k)]
  if threshold > 0: changes.insert(MsigChange(kind: ccSetThreshold, threshold: threshold), 0)
  let p = MsigProposal(multisig: address, zone: zone, epoch: epoch, nonce: uint64(100 + removeSeq),
                       action: MsigAction(kind: akConfig, changes: changes),
                       expiresMs: 9_000_000_000_000'u64, proposer: kss[i].lezMemberKey(msigLabel(unhexBytes(ck))))
  let id = "0x" & hx(proposalId(p))
  ss[i].publish(proposeEvent(id, lezMsigEffect(p)))
  ss[i].publishAuthored(kss[i], proposerEvent(id, ids[i]))
  ss[i].publish(finalEvent(id))
  for s in ss: s.poll()

# ── 1. a chat address is author-signed ─────────────────────────────────────────
block:
  r.bob.publish(chatAddressEvent(ids[2], "chat-evil"))          # Bob posts as Carol, unsigned
  doAssert chatAddresses(ev()).getOrDefault(ids[2], "") == "", "an unsigned claim is dropped"
  echo "1. a chat address is author-signed: one posted under another member's name is dropped OK"

# ── 2. the steward creates, announces and invites ─────────────────────────────
block:
  for i in 0 .. 2: doAssert ss[i].shareChatAddress(kss[i], chats[i].address)
  doAssert not r.alice.shareChatAddress(aliceKs, chats[0].address), "shared once per session"
  doAssert not planFor(1).steward and not planFor(2).steward
  doAssert applyFor(1).len == 0, "a client that is not the steward does nothing"
  let p = planFor(0)
  doAssert p.steward and p.create and p.invite == @["chat-bob-1", "chat-carol-1"], $p
  discard applyFor(0)
  let convo = chatGroupOf(ev(1), r.topic, acct)
  doAssert convo.len > 0, "announced in the room, read by every member"
  doAssert world.groups[convo] == @["chat-alice-1", "chat-bob-1", "chat-carol-1"]
  echo "2. the opener's client creates the group, announces it, invites the others; no one else acts OK"

# ── 3. applied, the plan is empty ─────────────────────────────────────────────
block:
  let p = planFor(0)
  doAssert not p.create and p.invite.len == 0 and p.remove.len == 0 and p.missing.len == 0, $p
  echo "3. once applied, the plan is empty OK"

# ── 4. Carol relaunches: a new chat address ───────────────────────────────────
block:
  chats[2] = newFakeChatGroups(world, "chat-carol-2")
  doAssert r.carol.shareChatAddress(room3CarolKs, chats[2].address)
  let p = planFor(0)
  doAssert p.invite == @["chat-carol-2"] and p.remove == @["chat-carol-1"], $p
  discard applyFor(0)
  doAssert world.groups[chatGroupOf(ev(), r.topic, acct)] == @["chat-alice-1", "chat-bob-1", "chat-carol-2"]
  echo "4. Carol's new session is invited and her stale address removed OK"

# ── 5. Carol removed from the multisig ────────────────────────────────────────
block:
  removeFinal(0, 2, 0)
  let p = planFor(0)
  doAssert p.remove == @["chat-carol-2"] and p.invite.len == 0, $p
  discard applyFor(0)
  doAssert "chat-carol-2" notin world.groups[chatGroupOf(ev(), r.topic, acct)]
  echo "5. a member the program removed is removed from the group OK"

# ── 6. a member with no shared address is reported ─────────────────────────────
block:
  let e = ev()
  let addrs = chatAddresses(e)
  doAssert ids[0] in addrs and ids[1] in addrs
  # a fresh multisig member set where Bob never shared: simulated by a plan over a room view
  # without his address event
  let without = e.filterIt(it.key != "member/" & ids[1] & "/chat")
  let p = chatPlan(without, r.topic, acct, ids[0], chats[0].address, chats[0].members(chatGroupOf(e, r.topic, acct)))
  doAssert p.missing == @[ids[1]] and "chat-bob-1" in p.remove, $p
  echo "6. a member who shared no chat address is reported as missing, never guessed OK"

# ── 7. the opener removed: a new steward keeps the group ───────────────────────
block:
  let convo = chatGroupOf(ev(), r.topic, acct)
  removeFinal(1, 0, 1, threshold = 1)                       # Bob proposes Alice's removal, 1 of 1
  doAssert memberIdsNow(ev(1), r.topic, acct) == @[ids[1]]
  let p = planFor(1)
  doAssert p.steward and not p.create and p.convo == convo, "Bob keeps the group Alice made: " & $p
  doAssert p.remove == @["chat-alice-1"], $p
  discard applyFor(1)
  doAssert world.groups[convo] == @["chat-bob-1"]
  echo "7. the opener removed: the lowest remaining member keeps the group and removes her OK"
