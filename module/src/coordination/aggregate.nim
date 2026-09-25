## FROST in the room (Phase D, exo-a50.4.5): the aggregate locus over the room's log.
##
## THE CEREMONY (ChillDKG). The room is the authenticated coordinator ChillDKG asks for,
## and the coordinator only relays, so every member computes its steps from the log:
##   frost/<cid>/open                 {network, t, n}, published by whoever opens it
##   frost/<cid>/join/<member>        {host}: the member's host key for this ceremony,
##                                    derived in its keystore under "frost/<cid>"; the first
##                                    n joins are the participants, in log order
##   frost/<cid>/pmsg1/<host>         a participant's step-1 message
##   frost/<cid>/pmsg2/<host>         a participant's step-2 message (its CertEq signature)
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
import ../frost/chilldkg
import ../crypto/keystore
import ../crypto/curve25519
import ../bitcoin/tx                 # toHex / hexToBytes
import ./session
import ./intent_events
import ./intents
import ./attest
import ./accounts

proc ceremonyLabel*(cid: string): string = "frost/" & cid

type CeremonyView* = object
  open*: bool
  network*: string
  t*, n*: int
  hosts*: seq[seq[byte]]            ## the participants' host keys, in join order
  pmsg1*: Table[string, seq[byte]]  ## host hex → step-1 message (first seen)
  pmsg2*: Table[string, seq[byte]]

proc ceremonyView*(events: seq[Event], cid: string): CeremonyView =
  ## The ceremony as the log holds it: reduce(log), nothing else. Canonical order is not
  ## arrival order, so the open is read first, then everything else in that order.
  let ordered = canonicalOrder(events)
  for e in ordered:
    if e.key == "frost/" & cid & "/open":
      try:
        let j = parseJson(e.value)
        result = CeremonyView(open: true, network: j["network"].getStr(), t: j["t"].getInt(), n: j["n"].getInt())
        break
      except CatchableError: discard
  if not result.open: return
  for e in ordered:
    let p = e.key.split('/')
    if p.len < 3 or p[0] != "frost" or p[1] != cid: continue
    try:
      case p[2]
      of "join":
        if result.open and result.hosts.len < result.n:
          let h = hexToBytes(parseJson(e.value)["host"].getStr())
          if h.len == 33 and h notin result.hosts: result.hosts.add h
      of "pmsg1":
        if p.len >= 4 and p[3] notin result.pmsg1: result.pmsg1[p[3]] = hexToBytes(e.value)
      of "pmsg2":
        if p.len >= 4 and p[3] notin result.pmsg2: result.pmsg2[p[3]] = hexToBytes(e.value)
      else: discard
    except CatchableError: discard       # a malformed entry is not part of the ceremony

proc frostCeremonyOpen*(s: CoordinationSession, cid, network: string, t, n: int): string =
  s.publish(Event(key: "frost/" & cid & "/open", value: $(%*{"network": network, "t": t, "n": n})))
  cid

proc memberId(ks: Keystore): string = toHex(ks.encIdentity().toBytes())

proc frostCeremonyJoin*(s: CoordinationSession, ks: Keystore, cid: string): string =
  ## Offer this member's host key for the ceremony; returns it (hex).
  let host = toHex(ks.frostHostPubkey(ceremonyLabel(cid)))
  s.publish(Event(key: "frost/" & cid & "/join/" & memberId(ks), value: $(%*{"host": host})))
  host

proc frostCeremonyStep*(s: CoordinationSession, ks: Keystore, cid: string): string =
  ## Advance this member's part of the ceremony by what the log allows: "step1",
  ## "step2", "done <address>" (finalized and disclosed), "waiting: …", or a refusal.
  ## Idempotent: call it on every tick.
  s.poll()
  let events = s.log.allEvents()
  let v = ceremonyView(events, cid)
  if not v.open: return "waiting: the ceremony is not open"
  if v.hosts.len < v.n: return "waiting: " & $v.hosts.len & " of " & $v.n & " participants joined"
  let lab = ceremonyLabel(cid)
  let host = ks.frostHostPubkey(lab)
  let hh = toHex(host)
  if host notin v.hosts: return "not-a-participant"
  let params = SessionParams(hostpubkeys: v.hosts, t: v.t)
  try:
    if hh notin v.pmsg1:
      s.publish(Event(key: "frost/" & cid & "/pmsg1/" & hh, value: toHex(ks.frostDkgStep1(lab, params))))
      return "step1"
    if v.pmsg1.len < v.n: return "waiting: step 1 from " & $(v.n - v.pmsg1.len) & " participants"
    let (cst, cmsg1) = coordinatorStep1(v.hosts.mapIt(v.pmsg1[toHex(it)]), params)
    if hh notin v.pmsg2:
      s.publish(Event(key: "frost/" & cid & "/pmsg2/" & hh, value: toHex(ks.frostDkgStep2(lab, params, cmsg1))))
      return "step2"
    if v.pmsg2.len < v.n: return "waiting: step 2 from " & $(v.n - v.pmsg2.len) & " participants"
    let (cmsg2, _, rec) = coordinatorFinalize(cst, v.hosts.mapIt(v.pmsg2[toHex(it)]))
    let acct = frostAccount(v.network, rec)
    let me = memberId(ks)
    let (found, ra) = findAccount(reduceAccounts(events), accountId(acct.chain, acct.address))
    if not (found and me in ra.disclosedBy):
      discard ks.frostDkgFinalize(lab, params, cmsg2)   # this member's check of the certificate
      s.publish(accountDiscloseEvent(RoomAccount(family: FrostFamily, chain: acct.chain, address: acct.address,
        label: "FROST " & $v.t & " of " & $v.n, signers: v.hosts.mapIt(toHex(it)), threshold: v.t,
        config: $(%*{"ceremony": cid, "recovery": toHex(rec)})), me))
    "done " & acct.address
  except CatchableError as e:
    "refused: " & e.msg

# ── the two signing rounds ────────────────────────────────────────────────────
proc contributed(events: seq[Event], intentId, who: string, round: int): bool =
  let k = "intent/" & intentId & "/sig/" & who & "/" & $round
  events.anyIt(it.key == k)

proc signingSet*(events: seq[Event], driverFor: DriverFor, intentId: string,
                 fd: BtcFrostDriver): seq[(seq[byte], seq[seq[byte]])] =
  ## The signer set the log fixes: the first t round-1 contributions the fold accepts, in
  ## its order (canonical order, the attestation gate, the driver's check).
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return
  let m = canonicalize(fd, effectFromJson(effectJson))
  let p = attestationPayload(events, driverFor, intentId)
  var attests = initTable[string, seq[string]]()
  for e in canonicalOrder(events):
    let q = e.key.split('/')
    if q.len >= 5 and q[0] == "intent" and q[1] == intentId and q[2] == "attest" and q[4] == "1":
      attests.mgetOrPut(q[3], @[]).add e.value
  var seen: seq[string]
  for e in canonicalOrder(events):
    let q = e.key.split('/')
    if q.len < 5 or q[0] != "intent" or q[1] != intentId or q[2] != "sig" or q[4] != "1": continue
    let who = q[3]
    if who in seen: continue
    seen.add who
    if who in attests and not attests[who].anyIt(verifyAttestation(who, p, it)): continue
    let c = Contribution(bytes: hexToBytes(e.value))
    if contributionRound(c) != 1 or identifyContributor(fd, m, c) != who: continue
    var nonces: seq[seq[byte]]
    try:
      let v = decodeRound1Nonces(c)
      nonces = v
    except CatchableError: continue
    result.add (hexToBytes(who), nonces)
    if result.len == fd.account.params.t: break

proc liveFrostContribute*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                          nowSec: uint64 = 0): string =
  ## This member's contribution to the round the intent is in: its public nonces (round 1)
  ## or, under the signer set the log fixes, its partial signatures (round 2), each from its
  ## keystore and attested by its host key over P. Returns the intent's state, or a refusal
  ## ("not-in-signing-set: …", "refused: …", "already-contributed", …) with nothing
  ## published.
  s.poll()
  let events = s.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return "unknown-intent"
  let policy = intentPolicyOf(events, intentId)
  let drv = driverFor(policy)
  if not (drv of BtcFrostDriver): return "not-an-aggregate-locus"
  let fd = BtcFrostDriver(drv)
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
  if host notin fd.account.params.hostpubkeys: return "not-a-participant"
  if contributed(events, intentId, hh, round): return "already-contributed"
  let hashes = fd.sighashesOf(effect)
  let rec = fd.account.recoveryData
  var c: Contribution
  try:
    if round == 1:
      c = round1Contribution(host, ks.frostNonceCommit(lab, intentId, rec, hashes))
    else:
      let set = signingSet(events, driverFor, intentId, fd)
      if set.len < fd.account.params.t: return "waiting: round 1 has not closed"
      if host notin set.mapIt(it[0]):
        return "not-in-signing-set: the log's first " & $fd.account.params.t & " round-1 contributions sign"
      let ids = set.mapIt(fd.account.params.hostpubkeys.find(it[0]))
      c = round2Contribution(host, set, ks.frostPartialSign(lab, intentId, rec, ids, set.mapIt(it[1]), hashes))
  except KeystoreError as e:
    return "refused: " & e.msg
  let att = toHex(ks.frostHostAttest(lab, attestationDigest(p)))
  if not verifyAttestation(hh, p, att): return "rejected"
  var parents: seq[EventId]
  for e in events:
    if e.key == "intent/" & intentId & "/propose" or e.key.startsWith("intent/" & intentId & "/sig/"):
      parents.add eventId(e)
  let sigEv = contributeEvent(intentId, hh, toHex(c.bytes), round = round, parents = parents)
  s.publish(sigEv)
  s.publish(attestEvent(intentId, hh, round, att, parents = @[eventId(sigEv)]))
  intentState(s.log.allEvents(), driverFor, intentId)
