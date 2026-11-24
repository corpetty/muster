## FROST in the room (Phase D, exo-a50.4.5): the aggregate locus over the room's log.
##
## THE CEREMONY (ChillDKG). The room is the authenticated coordinator ChillDKG asks for,
## and the coordinator only relays, so every member computes its steps from the log. Every
## entry is author-signed (coordination/authorship.nim), so each is its named member's
## (exo-3b3.13):
##   frost/<cid>/open                 {network, t, n, author}: the opener's terms. The open
##                                    in force is the first in canonical order that names
##                                    its author and has 1 <= t <= n
##   frost/<cid>/join/<member>        {host, opener, network, t, n, pop}: the member's host
##                                    key for this ceremony, derived in its keystore under
##                                    "frost/<cid>", the terms it joins, and the host key's
##                                    BIP-340 signature over (ceremony, member, host, terms):
##                                    the key's holder offers it for this member. The first n
##                                    joins committed to the terms in force are the
##                                    participants, in log order, ONE per member — a member's
##                                    later join is ignored, and no host is held twice
##   frost/<cid>/pmsg1/<member>       {host, msg}: a participant's step-1 message
##   frost/<cid>/pmsg2/<member>       {host, msg}: its step-2 message (its CertEq signature)
## So a rival open changes nothing for the joins that committed to another, one member never
## holds two shares, t is bounded, and no member's step message can be taken by another.
## A participant finalizes (its keystore checks the certificate) and discloses the account,
## with {ceremony, recovery} as config. The recovery data is public by the draft's design,
## and it is what every member later recovers its share from (seam S7). No share and no
## nonce ever enters the log.
##
## THE ROUNDS. A spend from the account collects twice (the driver says rounds = 2):
##   round 1  each member's public nonces, from its keystore;
##   round 2  each member's partial signatures, under the signer SET the log fixes: the
##            first t round-1 contributions the fold accepts, in its order (canonical
##            order, the attestation gate, the driver's check). Honest members compute the
##            same set, so their partials aggregate. A member outside the set publishes
##            nothing.
## Every contribution is attested by the member's host key over P (invariants 2 + 10). A
## member whose keystore lost its nonce (a restart) is refused: the session aborts.

import std/[json, strutils, sequtils, tables]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ../drivers/kinds
import ../drivers/btc_frost
import ../drivers/frost_group      # the group + the two rounds, whatever a family signs
import ../drivers/lez_frost        # a ceremony on a lez: zone discloses a LEZ account
import ../frost/chilldkg
import ../crypto/keystore
import ../crypto/curve25519
import ../bitcoin/tx                 # toHex / hexToBytes
import ../bitcoin/keys as btckeys    # schnorrVerify: a join's proof of its host key
import ../dcbor/dcbor
import ../hashing/hash_input
import ./session
import ./authorship   # the room's authentic view + author-signed publishing (exo-f76)
import ./intent_events
import ./intents
import ./attest
import ./accounts

const FrostJoinDomain* = "muster.frost.join.v1"

proc ceremonyLabel*(cid: string): string = "frost/" & cid

type
  CeremonyTerms* = object
    ## What a ceremony is: who opened it, on which network, t of n. A join commits to it.
    opener*, network*: string
    t*, n*: int

  CeremonyView* = object
    open*: bool
    opener*: string                   ## the member whose open is in force (room identity, hex)
    network*: string
    t*, n*: int
    hosts*: seq[seq[byte]]            ## the participants' host keys, in join order
    members*: seq[string]             ## beside each host, the member whose it is
    pmsg1*: Table[string, seq[byte]]  ## host hex → that participant's step-1 message
    pmsg2*: Table[string, seq[byte]]

proc terms*(v: CeremonyView): CeremonyTerms =
  CeremonyTerms(opener: v.opener, network: v.network, t: v.t, n: v.n)

proc normMember(s: string): string =
  ## A room identity as the views compare it: lowercase hex, no 0x (an author's signature
  ## verifies under either spelling, so a view must not count two spellings as two members).
  result = s.strip().toLowerAscii()
  if result.startsWith("0x"): result = result[2 .. ^1]

proc validTerms(t: CeremonyTerms): bool =
  t.n >= 1 and t.t >= 1 and t.t <= t.n and t.network.len > 0 and t.opener.len == 128

proc frostJoinClaim*(cid, member, host: string, terms: CeremonyTerms): array[32, byte] =
  ## What a join's host key signs: that its holder offers it to ceremony `cid` for `member`,
  ## on these terms. The join itself is author-signed for the room, so this names no room.
  digest(hashInput(FrostJoinDomain, @[
    ("ceremony", cbText(cid)), ("member", cbText(normMember(member))),
    ("host", cbText(normMember(host))), ("opener", cbText(normMember(terms.opener))),
    ("network", cbText(terms.network)), ("t", cbInt(int64(terms.t))), ("n", cbInt(int64(terms.n)))]))

proc termsOf(j: JsonNode, opener: string): CeremonyTerms =
  if j["t"].kind != JInt or j["n"].kind != JInt: raise newException(ValueError, "t and n are integers")
  CeremonyTerms(opener: normMember(opener), network: j["network"].getStr(),
                t: j["t"].getInt(), n: j["n"].getInt())

proc ceremonyView*(events: seq[Event], cid: string): CeremonyView =
  ## The ceremony as the log holds it: reduce(log), nothing else. Read it over the room's
  ## authentic view (`roomEvents`), where each open, join and step message is its named
  ## member's. Canonical order is not arrival order, so the open is read first, then the
  ## participants, then their step messages.
  let ordered = canonicalOrder(events)
  for e in ordered:
    if e.key != "frost/" & cid & "/open": continue
    try:
      let j = parseJson(e.value)
      let t = termsOf(j, j["author"].getStr())
      if not validTerms(t): continue              # t outside 1..n, or no author: no open
      result = CeremonyView(open: true, opener: t.opener, network: t.network, t: t.t, n: t.n)
      break
    except CatchableError: discard
  if not result.open: return
  let want = result.terms
  for e in ordered:
    if result.hosts.len >= result.n: break
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "frost" or p[1] != cid or p[2] != "join": continue
    try:
      let who = normMember(p[3])
      if who.len != 128 or who in result.members: continue   # one host per member
      let j = parseJson(e.value)
      if termsOf(j, j["opener"].getStr()) != want: continue  # it joined other terms
      let h = hexToBytes(j["host"].getStr())
      if h.len != 33 or h[0] notin [2'u8, 3'u8] or h in result.hosts: continue
      let pop = hexToBytes(j["pop"].getStr())
      if not btckeys.schnorrVerify(pop, frostJoinClaim(cid, who, toHex(h), want), h[1 .. 32]): continue
      result.hosts.add h
      result.members.add who
    except CatchableError: discard       # a malformed entry is not part of the ceremony
  for e in ordered:
    let p = e.key.split('/')
    if p.len != 4 or p[0] != "frost" or p[1] != cid or p[2] notin ["pmsg1", "pmsg2"]: continue
    try:
      let i = result.members.find(normMember(p[3]))
      if i < 0: continue                 # only a participant's own step messages count
      let hh = toHex(result.hosts[i])
      let j = parseJson(e.value)
      if normMember(j["host"].getStr()) != hh: continue
      let msg = hexToBytes(j["msg"].getStr())
      if p[2] == "pmsg1":
        if hh notin result.pmsg1: result.pmsg1[hh] = msg
      elif hh notin result.pmsg2: result.pmsg2[hh] = msg
    except CatchableError: discard

proc memberId(ks: Keystore): string = toHex(ks.encIdentity().toBytes())

proc frostCeremonyOpen*(s: CoordinationSession, ks: Keystore, cid, network: string,
                        t, n: int): CeremonyTerms =
  ## Open a ceremony as this member: an author-signed open naming its terms, which it
  ## returns for this member's own join to commit to. Refuses t outside 1..n.
  result = CeremonyTerms(opener: memberId(ks), network: network, t: t, n: n)
  if cid.len == 0 or '/' in cid: raise newException(ValueError, "a ceremony id is a name without /")
  if not validTerms(result): raise newException(ValueError, "a t-of-n ceremony needs 1 <= t <= n and a network")
  s.publishAuthored(ks, Event(key: "frost/" & cid & "/open",
    value: $(%*{"network": network, "t": t, "n": n, "author": result.opener})))

proc frostJoinEvent*(ks: Keystore, cid: string, terms: CeremonyTerms): Event =
  ## This member's join, committed to `terms`: its host key for the ceremony, and the host
  ## key's signature that its holder offers it for this member.
  let lab = ceremonyLabel(cid)
  let me = memberId(ks)
  let host = toHex(ks.frostHostPubkey(lab))
  let pop = ks.frostHostSign(lab, frostJoinClaim(cid, me, host, terms))
  Event(key: "frost/" & cid & "/join/" & me,
        value: $(%*{"host": host, "opener": normMember(terms.opener), "network": terms.network,
                    "t": terms.t, "n": terms.n, "pop": toHex(pop)}))

proc frostCeremonyJoin*(s: CoordinationSession, ks: Keystore, cid: string,
                        terms: CeremonyTerms): string =
  ## Offer this member's host key for the ceremony on `terms`; returns it (hex).
  let ev = frostJoinEvent(ks, cid, terms)
  s.publishAuthored(ks, ev)
  parseJson(ev.value)["host"].getStr()

proc frostCeremonyJoin*(s: CoordinationSession, ks: Keystore, cid: string): string =
  ## Join the ceremony in force, committing to its terms as this member reads them now.
  s.poll()
  let v = ceremonyView(s.roomEvents(), cid)
  if not v.open: raise newException(ValueError, "no ceremony " & cid & " is open in this room")
  frostCeremonyJoin(s, ks, cid, v.terms)

proc frostCeremonyStep*(s: CoordinationSession, ks: Keystore, cid: string): string =
  ## Advance this member's part of the ceremony by what the log allows: "step1",
  ## "step2", "done <address>" (finalized and disclosed), "waiting: …", or a refusal.
  ## Idempotent: call it on every tick.
  s.poll()
  let events = s.roomEvents()
  let v = ceremonyView(events, cid)
  if not v.open: return "waiting: the ceremony is not open"
  if v.hosts.len < v.n: return "waiting: " & $v.hosts.len & " of " & $v.n & " participants joined"
  if v.members.len != v.n or v.members.deduplicate().len != v.n or v.hosts.deduplicate().len != v.n:
    return "refused: the participants are not " & $v.n & " distinct members"
  let lab = ceremonyLabel(cid)
  let host = ks.frostHostPubkey(lab)
  let hh = toHex(host)
  let me = memberId(ks)
  let at = v.hosts.find(host)
  if at < 0 or v.members[at] != me: return "not-a-participant"
  let params = SessionParams(hostpubkeys: v.hosts, t: v.t)
  try:
    if hh notin v.pmsg1:
      s.publishAuthored(ks, Event(key: "frost/" & cid & "/pmsg1/" & me,
        value: $(%*{"host": hh, "msg": toHex(ks.frostDkgStep1(lab, params))})))
      return "step1"
    if v.pmsg1.len < v.n: return "waiting: step 1 from " & $(v.n - v.pmsg1.len) & " participants"
    let (cst, cmsg1) = coordinatorStep1(v.hosts.mapIt(v.pmsg1[toHex(it)]), params)
    if hh notin v.pmsg2:
      s.publishAuthored(ks, Event(key: "frost/" & cid & "/pmsg2/" & me,
        value: $(%*{"host": hh, "msg": toHex(ks.frostDkgStep2(lab, params, cmsg1))})))
      return "step2"
    if v.pmsg2.len < v.n: return "waiting: step 2 from " & $(v.n - v.pmsg2.len) & " participants"
    let (cmsg2, _, rec) = coordinatorFinalize(cst, v.hosts.mapIt(v.pmsg2[toHex(it)]))
    var (family, chain, address) = (FrostFamily, "", "")
    if v.network.startsWith("lez:"):
      let la = lezFrostAccount(v.network, rec)            # a LEZ public account, untweaked
      (family, chain, address) = (LezFrostFamily, la.chain, la.address)
    else:
      let ba = frostAccount(v.network, rec)
      (chain, address) = (ba.chain, ba.address)
    let (found, ra) = findAccount(reduceAccounts(events), accountId(chain, address))
    if not (found and me in ra.disclosedBy):
      discard ks.frostDkgFinalize(lab, params, cmsg2)   # this member's check of the certificate
      s.publishAuthored(ks, accountDiscloseEvent(RoomAccount(family: family, chain: chain, address: address,
        label: "FROST " & $v.t & " of " & $v.n, signers: v.hosts.mapIt(toHex(it)), threshold: v.t,
        config: $(%*{"ceremony": cid, "recovery": toHex(rec)})), me))
    "done " & address
  except CatchableError as e:
    "refused: " & e.msg

# ── the two signing rounds ────────────────────────────────────────────────────
proc contributed(events: seq[Event], fd: Driver, m: Materialization, intentId, who: string,
                 round: int): bool =
  ## Whether <who> already has a contribution to this round the fold can count. Junk someone
  ## else published under their name is not theirs, and must not stop them (exo-c00).
  let k = "intent/" & intentId & "/sig/" & who & "/" & $round
  events.anyIt(it.key == k and countable(fd, m, who, round, it.value))

proc signingSet*(events: seq[Event], driverFor: DriverFor, intentId: string,
                 fd: Driver): seq[(seq[byte], seq[seq[byte]])] =
  ## The signer set the log fixes: the first t round-1 contributions the fold accepts, in
  ## its order (canonical order, the attestation gate, the driver's check).
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return
  let m = canonicalize(fd, effectFromJson(effectJson))
  let p = attestationPayload(events, driverFor, intentId)
  var attests = initTable[string, seq[string]]()
  for e in admittedAttestations(events, driverFor, intentId):   # the fold's gate reads only these (exo-093)
    let q = e.key.split('/')
    if q[4] == "1": attests.mgetOrPut(q[3], @[]).add e.value
  var seen: seq[string]
  for e in canonicalOrder(events):
    let q = e.key.split('/')
    if q.len < 5 or q[0] != "intent" or q[1] != intentId or q[2] != "sig" or q[4] != "1": continue
    let who = q[3]
    if who in seen: continue
    let c = Contribution(bytes: hexToBytes(e.value))
    # as the fold fills a slot: only with a contribution it can count, so junk published
    # under a member's name cannot take their place in the set (exo-c00)
    if not countable(fd, m, who, 1, e.value) or contributionRound(c) != 1 or
       identifyContributor(fd, m, c) != who: continue
    seen.add who
    if who in attests and not attests[who].anyIt(verifyAttestation(who, p, it)): continue
    var nonces: seq[seq[byte]]
    try:
      let v = decodeRound1Nonces(c)
      nonces = v
    except CatchableError: continue
    result.add (hexToBytes(who), nonces)
    if result.len == fd.frostGroupOf().group.params.t: break

proc liveFrostContribute*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                          nowSec: uint64 = 0): string =
  ## This member's contribution to the round the intent is in: its public nonces (round 1)
  ## or, under the signer set the log fixes, its partial signatures (round 2), each from its
  ## keystore and attested by its host key over P. Returns the intent's state, or a refusal
  ## ("not-in-signing-set: …", "refused: …", "already-contributed", …) with nothing
  ## published.
  s.poll()
  let events = s.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return "unknown-intent"
  let policy = intentPolicyOf(events, intentId)
  let drv = driverFor(policy)
  let (isFrost, g) = drv.frostGroupOf()
  if not isFrost: return "not-an-aggregate-locus"
  let fd = drv
  let effect = effectFromJson(effectJson)
  let refusal = fd.signRefusal(effect)
  if refusal.len > 0: return "refused: " & refusal
  let ctx = intentContext(events, intentId)
  if ctx.isPlaceholder: return "no-context"
  if ctx.expired(nowSec): return "expired"
  if not intentInputs(events, driverFor, intentId).allAccountable: return "unaccountable-input"
  let p = attestationPayload(events, driverFor, intentId)
  if p.len == 0: return "unaccountable-input"
  let folded = reduceIntents(events, driverFor)
  if intentId notin folded: return "unknown-intent"
  let col = folded[intentId].collection
  if col.complete: return intentState(events, driverFor, intentId)
  let round = col.round
  let (found, ra) = findAccount(reduceAccounts(events), splitPolicy(policy).account)
  if not found: return "unknown-account"
  var cid: string
  try: cid = parseJson(ra.config)["ceremony"].getStr()
  except CatchableError: return "refused: the account names no ceremony"
  let lab = ceremonyLabel(cid)
  let host = ks.frostHostPubkey(lab)
  let hh = toHex(host)
  if host notin g.params.hostpubkeys: return "not-a-participant"
  if contributed(events, fd, folded[intentId].materialization, intentId, hh, round): return "already-contributed"
  let hashes = fd.frostMessages(effect)
  if hashes.len == 0: return "refused: nothing to sign"
  let rec = g.recoveryData
  var c: Contribution
  try:
    if round == 1:
      c = round1Contribution(host, ks.frostNonceCommit(lab, intentId, rec, hashes))
    else:
      let set = signingSet(events, driverFor, intentId, fd)
      if set.len < g.params.t: return "waiting: round 1 has not closed"
      if host notin set.mapIt(it[0]):
        return "not-in-signing-set: the log's first " & $g.params.t & " round-1 contributions sign"
      let ids = set.mapIt(g.params.hostpubkeys.find(it[0]))
      c = round2Contribution(host, set, ks.frostPartialSign(lab, intentId, rec, ids, set.mapIt(it[1]), hashes))
  except KeystoreError as e:
    return "refused: " & e.msg
  let att = toHex(ks.frostHostAttest(lab, attestationDigest(p)))
  if not verifyAttestation(hh, p, att): return "rejected"
  let parents = approvalParents(events, driverFor, intentId)   # approvals only (exo-403, exo-96d)
  let sigEv = contributeEvent(intentId, hh, toHex(c.bytes), round = round, parents = parents)
  s.publish(sigEv)
  s.publish(attestEvent(intentId, hh, round, att, parents = @[eventId(sigEv)]))
  intentState(s.roomEvents(), driverFor, intentId)
