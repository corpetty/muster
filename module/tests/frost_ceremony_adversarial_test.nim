## exo-3b3.13 (audit P5-01, P5-02): a FROST key ceremony that a member with a modified client
## cannot bend. Three members in one room (Alice, Bob, Carol); Bob is the adversary.
##   1. one host per member: Bob's second join, with a second host key he holds, is not a
##      participant, whether it sorts after his first or before it, and so is one under
##      another spelling of his identity. Honest Carol still is, and the ceremony finishes
##      as a 2-of-3 over three distinct members, each named beside its host key;
##   2. a rival open: Bob's signed t=1 open, ground to sort first, is the open in force and
##      names Bob, but no join that committed to Alice's 2-of-3 counts under it, so no
##      honest share is ever made at t=1. An unsigned open naming Alice is no open, and a
##      rival that sorts after hers changes nothing: the ceremony finishes as Alice's 2-of-3;
##   3. t is bounded: t=0, t>n, a negative t, n=0 are refused at open and are no open in the
##      log;
##   4. junk step messages: an unsigned step-1 under Carol's name, an old-style step-1 keyed
##      by Carol's host, Bob's own step-1 naming Carol's host, and a junk step-2 under
##      Carol's name take nothing from her: the view holds her real messages, and the
##      ceremony finishes.
## Before the fix (aggregate.nim at muster-v0.4.0) all four failed: Bob held two of three
## slots, t read 1, t=0 opened, and Carol's step 1 was taken by junk.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, tables, algorithm]
import ../src/log/log
import ../src/bitcoin/tx
import ../src/crypto/curve25519
import ../src/coordination/[session, aggregate, authorship, accounts]
import ./probes/live_room

proc idOf(ks: Keystore): string = toHex(ks.encIdentity().toBytes())

var failures: seq[string]
template section(name: string, body: untyped) =
  try:
    body
    echo name, " OK"
  except AssertionDefect as e:
    failures.add name & ": " & e.msg
    echo name, " FAILED: ", e.msg

var r = newRoom3("/muster/1/frost-adversarial/proto")
let aKs = Keystore(aliceKs)
let bKs = Keystore(bobKs)
let cKs = Keystore(room3CarolKs)
let members = @[(r.alice, aKs), (r.bob, bKs), (r.carol, cKs)]
proc pollAll() = (for (s, _) in members: s.poll())
let (aliceId, bobId, carolId) = (idOf(aKs), idOf(bKs), idOf(cKs))
proc hostOf(ks: Keystore, cid: string): string = toHex(ks.frostHostPubkey(ceremonyLabel(cid)))

proc runSteps(cid: string, rounds = 6): seq[string] =
  for _ in 0 ..< rounds:
    pollAll()
    result = members.mapIt(frostCeremonyStep(it[0], it[1], cid))
  pollAll()

proc idIn(e: Event): EventId = eventId(signAuthored(bKs, r.topic, e))
  ## the id an event of Bob's has once he signs it (an Ed25519 signature is deterministic)

proc eventOf(s: CoordinationSession, key: string): Event =
  for e in s.roomEvents():
    if e.key == key: return e

proc secondJoin(cid: string, terms: CeremonyTerms, pad: int, member = bobId): Event =
  ## Bob's modified client: a join with a second host key he holds, its proof made by that key.
  let lab = "frost/" & cid & "/second"
  let h2 = toHex(bKs.frostHostPubkey(lab))
  let pop = bKs.frostHostSign(lab, frostJoinClaim(cid, bobId, h2, terms))
  Event(key: "frost/" & cid & "/join/" & member,
        value: $(%*{"host": h2, "opener": terms.opener, "network": terms.network,
                    "t": terms.t, "n": terms.n, "pop": toHex(pop), "pad": pad}))

proc groundAgainst(make: proc(i: int): Event, other: EventId, before: bool): Event =
  for i in 0 .. 100000:
    result = make(i)
    if (idIn(result) < other) == before: return
  doAssert false, "could not grind"

# ── 1. a member's second join is not a participant; an honest member still is ──
section "1. one host per member":
  for (cid, before) in [("double", false), ("double-first", true)]:
    let terms = frostCeremonyOpen(r.alice, aKs, cid, "regtest", 2, 3)
    pollAll()
    discard frostCeremonyJoin(r.alice, aKs, cid, terms)
    discard frostCeremonyJoin(r.bob, bKs, cid)
    pollAll()
    let first = eventId(r.bob.eventOf("frost/" & cid & "/join/" & bobId))
    let j2 = groundAgainst(proc(i: int): Event = secondJoin(cid, terms, i), first, before)
    r.bob.publishAuthored(bKs, j2)
    # and under another spelling of his own identity, which his signature still verifies under
    r.bob.publishAuthored(bKs, groundAgainst(proc(i: int): Event =
      secondJoin(cid, terms, -1 - i, member = "0x" & bobId.toUpperAscii()), first, before = false))
    pollAll()
    discard frostCeremonyJoin(r.carol, cKs, cid)
    pollAll()
    let v = ceremonyView(r.alice.roomEvents(), cid)
    let hs = v.hosts.mapIt(toHex(it))
    doAssert hs.len == 3 and v.members.len == 3, $hs
    doAssert sorted(v.members) == sorted(@[aliceId, bobId, carolId]), "participants: " & $v.members
    doAssert hostOf(cKs, cid) in hs, "honest Carol was pushed out of " & cid
    doAssert v.members[hs.find(hostOf(cKs, cid))] == carolId and v.members[hs.find(hostOf(aKs, cid))] == aliceId
    let h2 = parseJson(j2.value)["host"].getStr()
    if before:
      doAssert h2 in hs and hostOf(bKs, cid) notin hs, "Bob holds one slot, his first join's"
      doAssert frostCeremonyStep(r.bob, bKs, cid) == "not-a-participant"
    else:
      doAssert h2 notin hs and hostOf(bKs, cid) in hs, "Bob's second host is a participant: " & $hs
      let outs = runSteps(cid)
      doAssert outs.allIt(it.startsWith("done")), $outs
      let accts = reduceAccounts(r.bob.roomEvents()).filterIt(it.label == "FROST 2 of 3" and
        parseJson(it.config)["ceremony"].getStr() == cid)
      doAssert accts.len == 1 and sorted(accts[0].signers) == sorted(hs)

# ── 2. a rival open does not change t for the joins that committed to the first ──
section "2. a rival open":
  block:
    const Cid = "rival"
    discard frostCeremonyOpen(r.alice, aKs, Cid, "regtest", 2, 3)
    pollAll()
    for (s, ks) in members: discard frostCeremonyJoin(s, ks, Cid)
    pollAll()
    let aliceOpen = eventId(r.alice.eventOf("frost/" & Cid & "/open"))
    let rival = groundAgainst(proc(i: int): Event =
      Event(key: "frost/" & Cid & "/open", value: $(%*{"network": "regtest", "t": 1, "n": 3, "author": bobId, "pad": i})),
      aliceOpen, before = true)
    r.bob.publishAuthored(bKs, rival)
    pollAll()
    let v = ceremonyView(r.carol.roomEvents(), Cid)
    doAssert v.opener == bobId and v.t == 1, "the open in force names who made it"
    doAssert v.hosts.len == 0, "joins committed to a 2-of-3 are counted under t=1: " & $v.members
    let outs = runSteps(Cid)
    doAssert outs.allIt(it.startsWith("waiting")), $outs
    doAssert reduceAccounts(r.alice.roomEvents()).allIt(it.label != "FROST 1 of 3")
  block:
    const Cid = "rival-late"
    discard frostCeremonyOpen(r.alice, aKs, Cid, "regtest", 2, 3)
    pollAll()
    let aliceOpen = eventId(r.alice.eventOf("frost/" & Cid & "/open"))
    # an unsigned open naming Alice, ground to sort first, and Bob's own, sorting after hers
    var forged: Event
    for i in 0 .. 100000:
      forged = Event(key: "frost/" & Cid & "/open", value: $(%*{"network": "regtest", "t": 1, "n": 3, "author": aliceId, "pad": i}))
      if eventId(forged) < aliceOpen: break
    doAssert eventId(forged) < aliceOpen
    r.bob.publish(forged)
    r.bob.publishAuthored(bKs, groundAgainst(proc(i: int): Event =
      Event(key: "frost/" & Cid & "/open", value: $(%*{"network": "regtest", "t": 1, "n": 3, "author": bobId, "pad": i})),
      aliceOpen, before = false))
    pollAll()
    for (s, ks) in members: discard frostCeremonyJoin(s, ks, Cid)
    let v = ceremonyView(r.carol.roomEvents(), Cid)
    doAssert v.opener == aliceId and v.t == 2 and v.n == 3, $v.t
    let outs = runSteps(Cid)
    doAssert outs.allIt(it.startsWith("done")), $outs
    doAssert reduceAccounts(r.alice.roomEvents()).anyIt(it.label == "FROST 2 of 3" and
      parseJson(it.config)["ceremony"].getStr() == Cid)

# ── 3. t outside 1..n is no ceremony ──
section "3. t bounds":
  for (t, n) in [(0, 3), (4, 3), (-1, 3), (0, 0)]:
    var raised = false
    try: discard frostCeremonyOpen(r.alice, aKs, "bad", "regtest", t, n)
    except ValueError: raised = true
    doAssert raised, "frostCeremonyOpen took " & $t & " of " & $n
    # a modified client publishes it anyway, signed
    let cid = "bad-" & $t & "-" & $n
    r.bob.publishAuthored(bKs, Event(key: "frost/" & cid & "/open",
      value: $(%*{"network": "regtest", "t": t, "n": n, "author": bobId})))
    pollAll()
    doAssert not ceremonyView(r.alice.roomEvents(), cid).open, $t & " of " & $n & " opened"

# ── 4. junk step messages under a victim's name do not block the victim ──
section "4. junk step messages":
  const Cid = "junk"
  discard frostCeremonyOpen(r.alice, aKs, Cid, "regtest", 2, 3)
  pollAll()
  for (s, ks) in members: discard frostCeremonyJoin(s, ks, Cid)
  pollAll()
  let ch = hostOf(cKs, Cid)
  let zeros = "00".repeat(96)
  r.bob.publish(Event(key: "frost/" & Cid & "/pmsg1/" & carolId, value: $(%*{"host": ch, "msg": zeros})))
  r.bob.publish(Event(key: "frost/" & Cid & "/pmsg1/" & ch, value: zeros))       # the old wire's key
  r.bob.publishAuthored(bKs, Event(key: "frost/" & Cid & "/pmsg1/" & bobId, value: $(%*{"host": ch, "msg": zeros})))
  r.bob.publish(Event(key: "frost/" & Cid & "/pmsg2/" & carolId, value: $(%*{"host": ch, "msg": zeros})))
  pollAll()
  let outs = runSteps(Cid)
  doAssert outs.allIt(it.startsWith("done")), $outs
  let v = ceremonyView(r.alice.roomEvents(), Cid)
  doAssert v.pmsg1.len == 3 and v.pmsg2.len == 3
  doAssert v.pmsg1[ch] != hexToBytes(zeros) and v.pmsg1[hostOf(bKs, Cid)] != hexToBytes(zeros)
  doAssert v.pmsg2[ch] != hexToBytes(zeros)

doAssert failures.len == 0, $failures.len & " failed: " & failures.join("; ")
echo "frost_ceremony_adversarial_test: one host per member, the open's terms, t bounded, no step taken — all OK"
