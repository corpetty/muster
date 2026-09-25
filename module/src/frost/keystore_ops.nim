## FROST round secrets, held (seam S7 of docs/design/multisig-landscape.md; exo-a50.4.4).
## The keystore's side of a ChillDKG ceremony and of FROST signing, over the secret the
## keystore derives for a label (its host key). crypto/keystore.nim wraps these as
## operations; nothing here is reachable except through it.
##
##   - The ceremony's participant states live in memory between steps, and each step runs
##     once.
##   - The secret share is never stored and never returned. It is recovered, when needed,
##     from the ceremony's PUBLIC recovery data plus the host key (participantRecover).
##     So a member's share is "log + keys" (invariant 4): the recovery data rides in the
##     room.
##   - A nonce lives only in memory, one commit per session. It is removed BEFORE the
##     partial signature is computed, so it is consumed before it is used. A restart loses
##     it: the session aborts, and a nonce is never reused.

import std/[tables, options, sequtils, sysrand, strutils]
import ./[secp, signing, chilldkg]

type FrostSessions* = ref object
  state1: Table[string, ParticipantState1]
  state2: Table[string, ParticipantState2]
  nonces: Table[string, seq[seq[byte]]]      ## label/session → one secnonce per message

proc newFrostSessions*(): FrostSessions = FrostSessions()

proc rnd32(): seq[byte] =
  result = newSeq[byte](32)
  if not urandom(result): raise newException(ValueError, "no randomness for the ceremony")

proc hexOf(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc ceremonyKey(label: string, params: SessionParams): string = label & "/" & hexOf(paramsHash(params))

proc dkgStep1*(fs: FrostSessions, hostsec: seq[byte], label: string, params: SessionParams): seq[byte] =
  let k = ceremonyKey(label, params)
  if k in fs.state1 or k in fs.state2: raise newException(ValueError, "this ceremony already started")
  let (st, m) = participantStep1(hostsec, params, rnd32())
  fs.state1[k] = st
  m

proc dkgStep2*(fs: FrostSessions, hostsec: seq[byte], label: string, params: SessionParams,
               cmsg1: seq[byte]): seq[byte] =
  let k = ceremonyKey(label, params)
  if k notin fs.state1: raise newException(ValueError, "no step 1 held for this ceremony (each step runs once)")
  let st1 = fs.state1[k]
  fs.state1.del k
  let (st2, m) = participantStep2(hostsec, st1, cmsg1, rnd32())
  fs.state2[k] = st2
  m

proc dkgFinalize*(fs: FrostSessions, label: string, params: SessionParams,
                  cmsg2: seq[byte]): tuple[output: DkgOutput, recoveryData: seq[byte]] =
  let k = ceremonyKey(label, params)
  if k notin fs.state2: raise newException(ValueError, "no step 2 held for this ceremony (each step runs once)")
  let st2 = fs.state2[k]
  fs.state2.del k
  var (o, rec) = participantFinalize(st2, cmsg2)
  o.secshare = none(seq[byte])                  # the share stays in the keystore: recovered on use
  (o, rec)

proc recovered(hostsec, recoveryData: seq[byte]): tuple[output: DkgOutput, params: SessionParams, me: int] =
  let (o, p) = participantRecover(hostsec, recoveryData)
  let me = p.hostpubkeys.find(hostpubkeyGen(hostsec))
  if me < 0 or o.secshare.isNone: raise newException(ValueError, "this host key is not a participant of that ceremony")
  (o, p, me)

proc nonceCommit*(fs: FrostSessions, hostsec: seq[byte], label, session: string, recoveryData: seq[byte],
                  msgs: seq[seq[byte]]): seq[seq[byte]] =
  ## One public nonce per message; the secret nonces stay here.
  let k = label & "/" & session
  if k in fs.nonces: raise newException(ValueError, "a nonce is already committed for this session")
  let (o, _, me) = recovered(hostsec, recoveryData)
  let xonly = pointFromCompressed(o.threshPk).toXonly()
  var secs: seq[seq[byte]]
  for m in msgs:
    let (sn, pn) = nonceGen(o.secshare, some(o.pubshares[me]), some(xonly), some(m), none(seq[byte]))
    secs.add sn
    result.add pn
  fs.nonces[k] = secs

proc partialSign*(fs: FrostSessions, hostsec: seq[byte], label, session: string, recoveryData: seq[byte],
                  ids: seq[int], pubnonces: seq[seq[seq[byte]]], msgs: seq[seq[byte]]): seq[seq[byte]] =
  ## One partial signature per message, for the signer set `ids` whose public nonces are
  ## `pubnonces` [signer][message]. The secret nonces are consumed first.
  let k = label & "/" & session
  if k notin fs.nonces:
    raise newException(ValueError, "no nonce for this session: consumed, or lost in a restart — the session aborts")
  var secs = fs.nonces[k]
  fs.nonces.del k                                # consumed before it is used
  let (o, p, me) = recovered(hostsec, recoveryData)
  if me notin ids: raise newException(ValueError, "not a signer of this session")
  if pubnonces.len != ids.len or secs.len != msgs.len or pubnonces.anyIt(it.len != msgs.len):
    raise newException(ValueError, "one public nonce per signer per message")
  for j, m in msgs:
    let ctx = SessionContext(n: p.hostpubkeys.len, t: p.t, ids: ids,
                             pubshares: some(ids.mapIt(o.pubshares[it])), threshPk: o.threshPk,
                             aggnonce: nonceAgg(pubnonces.mapIt(it[j])), msg: m)
    var sn = secs[j]
    result.add sign(sn, o.secshare.get, me, ctx)
