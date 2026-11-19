## A lez-msig's members, as the room follows them across config changes (exo-0d3.13;
## docs/design/lez-msig.md §8 step 5; RFP-005 F.5, R.2, Coordination Architecture). No chain:
## a config change is final in the room once its settler reports it, and settlement's own
## chain re-read is covered by lez_msig_live_e2e. Alice, Bob and Carol share a room:
##   1. applyChanges is the program's: a refused change raises, naming why;
##   2. Alice and Bob make a 2-of-2; Carol shares an account; adding her (final) puts her key
##      in the room's copy of the config, at epoch 1: her approval counts, the card's k and
##      signers follow, and nobody re-discloses;
##   3. a threshold change applies at the epoch reached; a final the program would refuse
##      (removing a non-member) changes nothing;
##   4. removing Carol, proposed by Carol herself: the room re-keys her out once, by the
##      lowest remaining member's client, and her approval no longer counts;
##   5. a removal proposed by another member is done by the proposer's client; a removed
##      member who is still in another lez-msig of the room keeps the room;
##   6. the private posture: a member added later gets the group secret from the add's
##      proposer, and the newest note; a removed member's note no longer counts;
##   7. a proposal by a member since removed is found (lez_msig_state flags it in the queue,
##      where the room offers its cancel).
## Needs the secp closure + libsodium.

import std/[json, options, sequtils, strutils, tables]
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/lez_msig
import ../src/lez/msig
import ../src/intents/materialization
import ../src/coordination/session
import ../src/coordination/intent_events
import ../src/coordination/accounts
import ../src/coordination/authorship
import ../src/coordination/member_accounts
import ../src/coordination/msig_room
import ../src/coordination/msig_members
import ./probes/live_room

proc fill(x: byte): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 32: result[i] = x)
proc hx(b: openArray[byte]): string = hexOf(b)
proc unhexBytes(h: string): seq[byte] =
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

const Chain = "lez:local"
const Shared = "lez-account/0"
let program = fill(0x11)
let zone = fill(0x2e)
let kss = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ids = kss.mapIt(hx(it.encIdentity().toBytes()))

var r = newRoom3("/muster/1/msig-members/proto")
let sessions = @[r.alice, r.bob, r.carol]
proc pollAll() = (for s in sessions: s.poll())
proc evs(i = 0): seq[Event] = (pollAll(); sessions[i].roomEvents())
proc holders(i = 0): seq[string] = (pollAll(); sessions[i].members().mapIt(hx(it.toBytes())))

proc openPair(private = false): tuple[ck: string, acct: LezMsigAccount] =
  ## Alice and Bob make a 2-of-2 (every role, weight 1) and Alice discloses it.
  let ck = r.alice.msigOpen(aliceKs, Chain, program, zone,
                            @[(ids[0], RoleAll, 1'u16), (ids[1], RoleAll, 1'u16)], 2, 0, true, private)
  pollAll()
  r.alice.msigJoin(aliceKs, ck)
  r.bob.msigJoin(bobKs, ck)
  let c = ceremonyOf(evs(), r.topic, ck).get
  doAssert c.ready
  let address = (if private: fill(0x33) else: multisigPublic(program, unhexBytes(ck)))
  let acct = LezMsigAccount(chain: Chain, program: program, createKey: unhexBytes(ck), zone: zone, address: address,
                            accountId: Chain & ":" & hx(address), epoch: 0, config: configOf(c), private: private)
  r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMsigFamily, chain: Chain,
    address: hx(address), label: "pair", signers: acct.config.members.mapIt(hx(it.key)),
    threshold: 2, config: configJsonOf(acct)), ids[0]))
  pollAll()
  (ck, acct)

proc nowOf(a: LezMsigAccount, i = 0): LezMsigAccount = lezMsigNow(evs(i), a).account
proc roomAcct(a: LezMsigAccount, i = 0): RoomAccount =
  let all = reconcileLezMsig(evs(i), reduceAccounts(evs(i)))
  let (found, ra) = findAccount(all, a.accountId)
  doAssert found
  ra

var seqNo = 0
proc changeFinal(s: CoordinationSession, ks: Keystore, a: LezMsigAccount, epoch: uint64,
                 changes: seq[MsigChange], proposerKey: seq[byte]): string =
  ## A config proposal from `ks`, reported final by its proposer's client (as settlement does).
  inc seqNo
  let p = MsigProposal(multisig: a.address, zone: a.zone, epoch: epoch, nonce: uint64(seqNo),
                       action: MsigAction(kind: akConfig, changes: changes), expiresMs: 9_000_000_000_000'u64,
                       proposer: proposerKey)
  let id = "0x" & hx(proposalId(p))
  s.publish(proposeEvent(id, lezMsigEffect(p)))
  s.publishAuthored(ks, proposerEvent(id, hx(ks.encIdentity().toBytes())))
  s.publish(finalEvent(id))
  pollAll()
  id

proc msigKey(ks: Keystore, ck: string): seq[byte] = ks.lezMemberKey(msigLabel(unhexBytes(ck)))
proc names(ks: Keystore, a: LezMsigAccount): seq[string] = @[ContributorPrefix & hx(ks.lezMemberKey(myMsigLabel(ks, a)))]

# ── 1. the program's config change ────────────────────────────────────────────
block:
  let base = MsigConfig(members: @[MsigMember(key: fill(1), roles: RoleAll, weight: 1),
                                   MsigMember(key: fill(2), roles: RoleAll, weight: 1)], threshold: 2,
                        openExecution: true, actions: ActAll)
  let c = applyChanges(base, @[MsigChange(kind: ccRemoveMember, removed: fill(2)),
                               MsigChange(kind: ccSetThreshold, threshold: 1)])
  doAssert c.members.len == 1 and c.threshold == 1
  for (bad, why) in [(@[MsigChange(kind: ccRemoveMember, removed: fill(9))], "not a member"),
                     (@[MsigChange(kind: ccRemoveMember, removed: fill(2))], "threshold"),
                     (@[MsigChange(kind: ccAddMember, member: base.members[0])], "distinct"),
                     (@[MsigChange(kind: ccRemoveLimit, limitId: 7)], "unknown spending limit")]:
    try:
      discard applyChanges(base, bad)
      doAssert false, "refused: " & why
    except ValueError as e: doAssert why in e.msg, e.msg
  echo "1. applyChanges applies a change as the program does, and refuses what it refuses OK"

# ── 2. adding a member who shared an account ──────────────────────────────────
let (ck, pair) = openPair()
let carolShared = discloseAccount(r.carol, room3CarolKs, Shared, Chain, name = "carol")
pollAll()
block:
  let policy = qualify("lez-msig", pair.accountId)
  let dfor = proc(i: int): DriverFor =
    let k = i
    result = proc(p: string): Driver =
      driverForPolicy(p, reconcileLezMsig(evs(k), reduceAccounts(evs(k))), proc(x: string): Driver = liveDriverFor(x))
  let before = LezMsigDriver(dfor(0)(policy))
  doAssert before.mayContribute(Effect(), names(room3CarolKs, before.account)) == elNo
  doAssert keyOwner(evs(), r.topic, carolShared.key) == ids[2]
  discard changeFinal(r.alice, aliceKs, pair, 0,
                      @[MsigChange(kind: ccAddMember, member: MsigMember(key: carolShared.key, roles: RoleAll, weight: 1))],
                      msigKey(aliceKs, ck))
  for i in 0 .. 2:
    let now = nowOf(pair, i)
    doAssert now.epoch == 1 and now.config.members.len == 3 and now.config.threshold == 2, $now.epoch
  let ra = roomAcct(pair)
  doAssert ra.signers.len == 3 and hx(carolShared.key) in ra.signers and ra.threshold == 2
  doAssert lezMsigDisclosureCheck(ra).status == acVerified, lezMsigDisclosureCheck(ra).detail
  let after = LezMsigDriver(dfor(2)(policy))
  doAssert after.account.epoch == 1
  doAssert after.mayContribute(Effect(), names(room3CarolKs, after.account)) == elYes,
    "carol's approval key is the account she shared, and it counts"
  doAssert memberIdsNow(evs(), r.topic, pair) == ids
  echo "2. adding Carol: the room's config is at epoch 1 with her key, her approval counts, and nobody re-disclosed OK"

# ── 3. the epoch, and a refused change ────────────────────────────────────────
block:
  discard changeFinal(r.bob, bobKs, pair, 1, @[MsigChange(kind: ccSetThreshold, threshold: 3)], msigKey(bobKs, ck))
  doAssert nowOf(pair).epoch == 2 and nowOf(pair).config.threshold == 3
  discard changeFinal(r.bob, bobKs, pair, 2, @[MsigChange(kind: ccRemoveMember, removed: fill(0x77))], msigKey(bobKs, ck))
  doAssert nowOf(pair).epoch == 2, "a change the program refuses moves nothing"
  discard changeFinal(r.bob, bobKs, pair, 5, @[MsigChange(kind: ccSetThreshold, threshold: 1)], msigKey(bobKs, ck))
  doAssert nowOf(pair).config.threshold == 3, "a proposal for a later epoch than any reached is not applied"
  discard changeFinal(r.bob, bobKs, pair, 2, @[MsigChange(kind: ccSetThreshold, threshold: 2)], msigKey(bobKs, ck))
  doAssert nowOf(pair).epoch == 3 and nowOf(pair).config.threshold == 2
  echo "3. each change applies at the epoch reached; a refused one, or one for an epoch never reached, does not OK"

# ── 4. Carol removes herself: the lowest remaining member re-keys her out ──────
block:
  doAssert msigRemovalsDue(evs(), r.topic, holders(), ids[0]).len == 0
  let id = changeFinal(r.carol, room3CarolKs, pair, 3, @[MsigChange(kind: ccRemoveMember, removed: carolShared.key)],
                       carolShared.key)
  doAssert nowOf(pair).config.members.len == 2 and memberIdsNow(evs(), r.topic, pair) == ids[0 .. 1]
  let lowest = min(ids[0], ids[1])
  let lowI = (if lowest == ids[0]: 0 else: 1)
  for i in 0 .. 2:
    let due = msigRemovalsDue(evs(i), r.topic, holders(i), ids[i])
    doAssert due == (if i == lowI: @[(ids[2], id)] else: @[]), $i & " " & $due
  sessions[lowI].expel(room3CarolKs.encIdentity())
  pollAll()
  doAssert ids[2] notin holders(0) and ids[2] notin holders(1)
  doAssert msigRemovalsDue(evs(lowI), r.topic, holders(lowI), ids[lowI]).len == 0, "once"
  let d = newLezMsigDriver(nowOf(pair))
  doAssert d.mayContribute(Effect(), @[ContributorPrefix & hx(carolShared.key)]) == elNo
  echo "4. Carol removes herself: the lowest remaining member's client re-keys her out, once; her approval no longer counts OK"

# ── 5. the proposer's client re-keys; a member of another lez-msig keeps the room ─
block:
  # a fresh room: Alice, Bob, Carol; two multisigs, Carol in both
  r = newRoom3("/muster/1/msig-members-5/proto")
  let ss = @[r.alice, r.bob, r.carol]
  proc ev5(): seq[Event] =
    for s in ss: s.poll()
    r.alice.roomEvents()
  proc hold5(): seq[string] =
    for s in ss: s.poll()
    r.alice.members().mapIt(hx(it.toBytes()))
  proc open3(): LezMsigAccount =
    let ck = r.alice.msigOpen(aliceKs, Chain, program, zone,
                              @[(ids[0], RoleAll, 1'u16), (ids[1], RoleAll, 1'u16), (ids[2], RoleAll, 1'u16)], 2, 0, true)
    for s in ss: s.poll()
    r.alice.msigJoin(aliceKs, ck)
    r.bob.msigJoin(bobKs, ck)
    r.carol.msigJoin(room3CarolKs, ck)
    for s in ss: s.poll()
    let c = ceremonyOf(ev5(), r.topic, ck).get
    let address = multisigPublic(program, unhexBytes(ck))
    result = LezMsigAccount(chain: Chain, program: program, createKey: unhexBytes(ck), zone: zone, address: address,
                            accountId: Chain & ":" & hx(address), epoch: 0, config: configOf(c))
    r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMsigFamily, chain: Chain,
      address: hx(address), label: "three", signers: result.config.members.mapIt(hx(it.key)), threshold: 2,
      config: configJsonOf(result)), ids[0]))
    for s in ss: s.poll()
  let m1 = open3()
  let m2 = open3()
  proc final5(a: LezMsigAccount, removed: seq[byte]): string =
    inc seqNo
    let p = MsigProposal(multisig: a.address, zone: a.zone, epoch: 0, nonce: uint64(seqNo),
                         action: MsigAction(kind: akConfig, changes: @[MsigChange(kind: ccRemoveMember, removed: removed)]),
                         expiresMs: 9_000_000_000_000'u64, proposer: msigKey(bobKs, hx(a.createKey)))
    result = "0x" & hx(proposalId(p))
    r.bob.publish(proposeEvent(result, lezMsigEffect(p)))
    r.bob.publishAuthored(bobKs, proposerEvent(result, ids[1]))
    r.bob.publish(finalEvent(result))
    for s in ss: s.poll()
  let id = final5(m1, msigKey(room3CarolKs, hx(m1.createKey)))
  doAssert msigRemovalsDue(ev5(), r.topic, hold5(), ids[1]).len == 0,
    "Carol is still a member of the other lez-msig here: she keeps the room"
  let id2 = final5(m2, msigKey(room3CarolKs, hx(m2.createKey)))
  let due = msigRemovalsDue(ev5(), r.topic, hold5(), ids[1])
  doAssert due.len == 1 and due[0][0] == ids[2] and due[0][1] in [id, id2],
    "Bob proposed both: his client re-keys her out, once"
  doAssert msigRemovalsDue(ev5(), r.topic, hold5(), ids[0]).len == 0
  echo "5. the proposer's client re-keys a removed member out; one still in another lez-msig of the room keeps it OK"

# ── 6. the private posture: the group secret and notes follow the members ──────
block:
  r = newRoom3("/muster/1/msig-members-6/proto")
  let ss = @[r.alice, r.bob, r.carol]
  proc ev6(i = 0): seq[Event] =
    for s in ss: s.poll()
    ss[i].roomEvents()
  let ck = r.alice.msigOpen(aliceKs, Chain, program, zone,
                            @[(ids[0], RoleAll, 1'u16), (ids[1], RoleAll, 1'u16)], 2, 0, true, private = true)
  for s in ss: s.poll()
  r.alice.msigJoin(aliceKs, ck)
  r.bob.msigJoin(bobKs, ck)
  for s in ss: s.poll()
  let c = ceremonyOf(ev6(), r.topic, ck).get
  let address = fill(0x33)
  let a = LezMsigAccount(chain: Chain, program: program, createKey: unhexBytes(ck), zone: zone, address: address,
                         accountId: Chain & ":" & hx(address), epoch: 0, config: configOf(c), private: true)
  r.alice.publishAuthored(aliceKs, accountDiscloseEvent(RoomAccount(family: LezMsigFamily, chain: Chain,
    address: hx(address), label: "private", signers: a.config.members.mapIt(hx(it.key)), threshold: 2,
    config: configJsonOf(a)), ids[0]))
  let shared = discloseAccount(r.carol, room3CarolKs, Shared, Chain)
  for s in ss: s.poll()
  let gms = groupSecretOf(ev6(), aliceKs, r.topic, ck).get
  r.alice.publishNote(aliceKs, c, 0, @[byte 1, 2, 3], "0xcreate")
  # Bob proposes adding Carol
  inc seqNo
  let p = MsigProposal(multisig: address, zone: zone, epoch: 0, nonce: uint64(seqNo),
                       action: MsigAction(kind: akConfig, changes: @[MsigChange(kind: ccAddMember,
                         member: MsigMember(key: shared.key, roles: RoleAll, weight: 1))]),
                       expiresMs: 9_000_000_000_000'u64, proposer: msigKey(bobKs, ck))
  let id = "0x" & hx(proposalId(p))
  r.bob.publish(proposeEvent(id, lezMsigEffect(p)))
  r.bob.publishAuthored(bobKs, proposerEvent(id, ids[1]))
  r.bob.publish(finalEvent(id))
  for s in ss: s.poll()
  doAssert gmsAddsDue(ev6(), r.topic, a, ids[1]) == @[ids[2]], "the add's proposer seals the secret"
  doAssert gmsAddsDue(ev6(), r.topic, a, ids[0]).len == 0
  let now = memberIdsNow(ev6(), r.topic, a)
  doAssert groupSecretOf(ev6(2), room3CarolKs, r.topic, ck, now).isNone
  r.bob.sealGroupSecretTo(bobKs, ck, groupSecretOf(ev6(1), bobKs, r.topic, ck).get, ids[2])
  let ln = latestNote(ev6(1), bobKs, r.topic, ck, now)
  r.bob.sealNoteTo(bobKs, ck, ln.n, ln.note, ln.hash, ids[2])
  for s in ss: s.poll()
  doAssert groupSecretOf(ev6(2), room3CarolKs, r.topic, ck).isNone, "only the opener counts without the members now"
  doAssert groupSecretOf(ev6(2), room3CarolKs, r.topic, ck, now).get == gms
  doAssert gmsAddsDue(ev6(), r.topic, a, ids[1]).len == 0, "once"
  let cl = latestNote(ev6(2), room3CarolKs, r.topic, ck, now)
  doAssert cl.found and cl.n == 0 and cl.note == @[byte 1, 2, 3]
  # a later note sealed by Carol counts while she is a member, and not once she is removed
  r.carol.publishNote(room3CarolKs, c, 1, @[byte 4], "0xpay", now)
  for s in ss: s.poll()
  doAssert latestNote(ev6(), aliceKs, r.topic, ck, memberIdsNow(ev6(), r.topic, a)).n == 1
  inc seqNo
  let q = MsigProposal(multisig: address, zone: zone, epoch: 1, nonce: uint64(seqNo),
                       action: MsigAction(kind: akConfig, changes: @[MsigChange(kind: ccRemoveMember, removed: shared.key)]),
                       expiresMs: 9_000_000_000_000'u64, proposer: msigKey(aliceKs, ck))
  let rid = "0x" & hx(proposalId(q))
  r.alice.publish(proposeEvent(rid, lezMsigEffect(q)))
  r.alice.publishAuthored(aliceKs, proposerEvent(rid, ids[0]))
  r.alice.publish(finalEvent(rid))
  for s in ss: s.poll()
  let after = memberIdsNow(ev6(), r.topic, a)
  doAssert after == ids[0 .. 1]
  doAssert latestNote(ev6(), aliceKs, r.topic, ck, after).n == 0, "a removed member's note no longer counts"
  echo "6. private: an added member gets the group secret and the newest note from the add's proposer; a removed member's notes stop counting OK"

# ── 7. a queued action whose proposer was removed is pointed out ──────────────
block:
  # back in the first room: Carol's own proposal (her removal) names her key, which the
  # multisig no longer holds; Bob's still-member proposals do not
  let props = queuedProposers(evs(), pair.address)
  let now = nowOf(pair).config
  var removed, held = 0
  for pid, key in props:
    if now.memberOf(key).isNone: inc removed else: inc held
  doAssert removed == 1 and held >= 4, $removed & " " & $held
  doAssert queuedProposers(evs(), fill(0x99)).len == 0
  echo "7. a proposal by a member since removed is found, so the room can offer its cancel OK"
