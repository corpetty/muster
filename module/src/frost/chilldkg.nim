## ChillDKG — distributed key generation for FROST (exo-fae, Phase D3).
##
## A port of the draft's reference (bip-chilldkg/python/chilldkg_ref: vss.py,
## simplpedpop.py, encpedpop.py, chilldkg.py @ mllwchrry/bips 2b9b0b1, bitcoin/bips#2227),
## held to every vector it ships (tests/frost_chilldkg_test.nim). Three layers:
##   * SimplPedPop — each participant commits to a random polynomial (a VSS commitment) and
##     proves possession of its constant term; shares sum to the threshold secret shares;
##   * EncPedPop — the shares travel encrypted to each participant's host key (ECDH pads);
##   * CertEq — every participant signs the transcript with its host key; the n signatures
##     are the certificate that all saw the same thing, so no one can be tricked into a
##     different key than the others.
## The threshold key carries an unspendable taproot tweak ("invalid taproot commit"), so a
## hidden script path is ruled out. The coordinator is untrusted and only relays: in a
## muster room every member can compute the coordinator's steps from the shared log.
##
## Errors are the reference's exceptions, carried as one DkgError: `kind` is the class name
## (FaultyParticipantError, FaultyCoordinatorError, HostSeckeyError, ValueError, …),
## `message` the reference's message when it gives one, and the blamed participant ids.
## NOT constant time — see secp.nim.

import std/[options, tables, sequtils]
import ./secp
import ./schnorr
import ../bitcoin/tx          # taggedHash

const BipTag = "BIP DKG/"

type
  DkgError* = object of CatchableError
    kind*: string                 ## the reference exception's class name
    message*: string              ## its message, "" when it has none
    participantId*: int           ## the blamed participant, −1 when none
    participantId1*, participantId2*: int
    inv*: InvestigationData       ## for UnknownFaultyParticipantOrCoordinatorError

  InvestigationData* = object
    n*, participantId*: int
    secshare*: Scalar
    pubshare*: GE
    encSecshare*: Scalar
    pads*: seq[Scalar]

  SessionParams* = object
    hostpubkeys*: seq[seq[byte]]
    t*: int

  DkgOutput* = object
    secshare*: Option[seq[byte]]  ## none for the coordinator
    threshPk*: seq[byte]
    pubshares*: seq[seq[byte]]

  SimplState = object
    t, n, participantId: int
    comToSecret: GE
  EncState = object
    simpl: SimplState
    pubnonce: seq[byte]
    enckeys: seq[seq[byte]]
    participantId: int

  ParticipantState1* = object
    params*: SessionParams
    participantId*: int
    enc: EncState

  ParticipantState2* = object
    params*: SessionParams
    eqInput*: seq[byte]
    dkgOutput*: DkgOutput

  CoordinatorState* = object
    params*: SessionParams
    eqInput*: seq[byte]
    dkgOutput*: DkgOutput

proc dkgError(kind: string, message = "", pid = -1): ref DkgError =
  result = newException(DkgError, if message.len > 0: kind & ": " & message else: kind)
  result.kind = kind
  result.message = message
  result.participantId = pid
  result.participantId1 = -1
  result.participantId2 = -1

type MsgParseError = object of ValueError    ## internal: converted to a blame at the boundary

proc parseErr(msg: string): ref MsgParseError = newException(MsgParseError, msg)

proc th(tag: string, data: openArray[byte]): seq[byte] = @(taggedHash(tag, data))
proc thDkg(tag: string, data: openArray[byte]): seq[byte] = th(BipTag & tag, data)
proc be4(x: int): seq[byte] = @[byte((x shr 24) and 0xff), byte((x shr 16) and 0xff), byte((x shr 8) and 0xff), byte(x and 0xff)]
proc concat(xs: seq[seq[byte]]): seq[byte] =
  for x in xs: result.add x
proc sumScalars(xs: seq[Scalar]): Scalar =
  result = scalar(0)
  for x in xs: result = result + x
proc sumPoints(xs: seq[GE]): GE =
  result = infinity()
  for x in xs: result = result + x

# ── VSS ─────────────────────────────────────────────────────────────────────────
type VssCommitment = object
  ges: seq[GE]

proc vssFromBytes(b: seq[byte], t: int): VssCommitment =
  ## ValueError on a wrong length or a bad point (the reference's VSSCommitment.from_bytes)
  if b.len != 33 * t: raise newException(ValueError, "wrong length")
  for i in 0 ..< t: result.ges.add pointFromCompressedWithInfinity(b[33*i ..< 33*i + 33])

proc toBytes(c: VssCommitment): seq[byte] =
  for g in c.ges: result.add g.toCompressedWithInfinity()

proc pubshare(c: VssCommitment, i: int): GE =
  ## Σ_j (i+1)^j · ges[j]
  result = infinity()
  var xj = scalar(1)
  let x = scalar(int64(i + 1))
  for g in c.ges:
    result = result + (xj * g)
    xj = xj * x

proc verifySecshare(secshare: Scalar, pubshare: GE): bool = mulG(secshare) == pubshare

proc `+`(a, b: VssCommitment): VssCommitment =
  doAssert a.ges.len == b.ges.len
  for i in 0 ..< a.ges.len: result.ges.add a.ges[i] + b.ges[i]

proc invalidTaprootCommit(c: VssCommitment): tuple[com: VssCommitment, tweak: Scalar, pubtweak: GE] =
  ## tweak the threshold key by TapTweak(x(pk)) with no script tree — an output key whose
  ## script path is provably unspendable (no hidden script path)
  let pk = c.ges[0]
  let tweak = scalarFromBytesChecked(th("TapTweak", pk.toXonly()))
  let pubtweak = mulG(tweak)
  var tw = VssCommitment(ges: @[pubtweak])
  for _ in 1 ..< c.ges.len: tw.ges.add infinity()
  (c + tw, tweak, pubtweak)

proc vssGenerate(seed: seq[byte], t: int): seq[Scalar] =
  for i in 0 ..< t: result.add scalarFromBytesChecked(thDkg("vss coeffs", seed & be4(i)))

proc polyEval(coeffs: seq[Scalar], x: Scalar): Scalar =
  result = scalar(0)
  for i in countdown(coeffs.len - 1, 0): result = result * x + coeffs[i]

# ── SimplPedPop ─────────────────────────────────────────────────────────────────
const PopMsgTag = BipTag & "pop message"

proc popProve(seckey: seq[byte], pid: int, auxRand: seq[byte]): seq[byte] =
  schnorrSign(be4(pid), seckey, auxRand, tagPrefix = PopMsgTag)
proc popVerify(pop, pubkey: seq[byte], pid: int): bool =
  schnorrVerify(be4(pid), pubkey, pop, tagPrefix = PopMsgTag)

type SimplPmsg = object
  com: VssCommitment
  pop: seq[byte]

proc simplPmsgFromBytes(b: seq[byte], t: int): SimplPmsg =
  if b.len != 33 * t + 64: raise newException(ValueError, "wrong length")
  try: result.com = vssFromBytes(b[0 ..< 33 * t], t)
  except ValueError: raise parseErr("invalid VSS commitment")
  result.pop = b[33 * t ..< b.len]

proc toBytes(m: SimplPmsg): seq[byte] = m.com.toBytes() & m.pop

type SimplCmsg = object
  comsToSecrets, sumComsToNonconstTerms: seq[GE]
  pops: seq[seq[byte]]

proc simplCmsgLen(t, n: int): int = 97 * n + 33 * (t - 1)

proc simplCmsgFromBytes(b: seq[byte], t, n: int): SimplCmsg =
  if b.len != simplCmsgLen(t, n): raise newException(ValueError, "wrong length")
  try:
    for i in 0 ..< n: result.comsToSecrets.add pointFromCompressedWithInfinity(b[33*i ..< 33*i + 33])
  except ValueError: raise parseErr("invalid commitment to secret")
  let rest = b[33 * n ..< b.len]
  try:
    for i in 0 ..< t - 1: result.sumComsToNonconstTerms.add pointFromCompressedWithInfinity(rest[33*i ..< 33*i + 33])
  except ValueError: raise parseErr("invalid sum commitment to non-constant term")
  let pops = rest[33 * (t - 1) ..< rest.len]
  for i in 0 ..< n: result.pops.add pops[64*i ..< 64*i + 64]

proc toBytes(m: SimplCmsg): seq[byte] =
  for p in m.comsToSecrets: result.add p.toCompressedWithInfinity()
  for p in m.sumComsToNonconstTerms: result.add p.toCompressedWithInfinity()
  result.add concat(m.pops)

proc assembleSumComs(comsToSecrets, sumNonconst: seq[GE]): VssCommitment =
  VssCommitment(ges: @[sumPoints(comsToSecrets)] & sumNonconst)

proc simplStep1(seed: seq[byte], t, n, pid: int, auxRand: seq[byte]): tuple[state: SimplState, msg: seq[byte], shares: seq[Scalar]] =
  if t > n: raise dkgError("ValueError")
  let coeffs = vssGenerate(seed, t)
  for i in 0 ..< n: result.shares.add polyEval(coeffs, scalar(int64(i + 1)))
  let pop = popProve(coeffs[0].toBytes(), pid, auxRand)
  var com: VssCommitment
  for c in coeffs: com.ges.add mulG(c)
  result.msg = SimplPmsg(com: com, pop: pop).toBytes()
  result.state = SimplState(t: t, n: n, participantId: pid, comToSecret: com.ges[0])

proc simplStep2(state: SimplState, cmsg: seq[byte], secshare: Scalar): tuple[output: DkgOutput, eqInput: seq[byte]] =
  let (t, n, pid) = (state.t, state.n, state.participantId)
  var c: SimplCmsg
  try: c = simplCmsgFromBytes(cmsg, t, n)
  except MsgParseError as e: raise dkgError("FaultyCoordinatorError", e.msg)
  if c.comsToSecrets[pid] != state.comToSecret:
    raise dkgError("FaultyCoordinatorError", "Coordinator sent unexpected first group element for local participant id")
  for i in 0 ..< n:
    if i == pid: continue
    if c.comsToSecrets[i].isInfinity:
      raise dkgError("FaultyParticipantOrCoordinatorError", "Participant sent invalid commitment", i)
    if not popVerify(c.pops[i], c.comsToSecrets[i].toXonly(), i):
      raise dkgError("FaultyParticipantOrCoordinatorError", "Participant sent invalid proof-of-knowledge", i)
  let sumComs = assembleSumComs(c.comsToSecrets, c.sumComsToNonconstTerms)
  let (tweaked, tweak, pubtweak) = sumComs.invalidTaprootCommit()
  let pubshareTweaked = tweaked.pubshare(pid)
  let secshareTweaked = secshare + tweak
  if not verifySecshare(secshareTweaked, pubshareTweaked):
    let e = dkgError("UnknownFaultyParticipantOrCoordinatorError",
      "Received invalid secshare; consider using participant_investigate() to determine a faulty party")
    e.inv = InvestigationData(n: n, participantId: pid, secshare: secshare, pubshare: pubshareTweaked + -pubtweak)
    raise e
  var pubshares: seq[seq[byte]]
  for i in 0 ..< n:
    pubshares.add (if i == pid: pubshareTweaked else: tweaked.pubshare(i)).toCompressed()
  result.output = DkgOutput(secshare: some(secshareTweaked.toBytes()), threshPk: tweaked.ges[0].toCompressed(),
                            pubshares: pubshares)
  result.eqInput = be4(t) & sumComs.toBytes()

proc simplCoordinatorStep(pmsgs: seq[seq[byte]], t, n: int): tuple[cmsg: seq[byte], output: DkgOutput, eqInput: seq[byte]] =
  if pmsgs.len != n: raise dkgError("ValueError")
  var parsed: seq[SimplPmsg]
  for i, m in pmsgs:
    try: parsed.add simplPmsgFromBytes(m, t)
    except MsgParseError as e: raise dkgError("FaultyParticipantError", e.msg, i)
    except ValueError: raise dkgError("ValueError")
  var comsToSecrets, sumNonconst: seq[GE]
  var pops: seq[seq[byte]]
  for p in parsed:
    comsToSecrets.add p.com.ges[0]
    pops.add p.pop
  for j in 0 ..< t - 1:
    var s = infinity()
    for p in parsed: s = s + p.com.ges[j + 1]
    sumNonconst.add s
  result.cmsg = SimplCmsg(comsToSecrets: comsToSecrets, sumComsToNonconstTerms: sumNonconst, pops: pops).toBytes()
  let sumComs = assembleSumComs(comsToSecrets, sumNonconst)
  let (tweaked, _, _) = sumComs.invalidTaprootCommit()
  var pubshares: seq[seq[byte]]
  for i in 0 ..< n: pubshares.add tweaked.pubshare(i).toCompressed()
  result.output = DkgOutput(secshare: none(seq[byte]), threshPk: tweaked.ges[0].toCompressed(), pubshares: pubshares)
  result.eqInput = be4(t) & sumComs.toBytes()

proc simplCinvFromBytes(b: seq[byte], n: int): seq[GE] =
  if b.len != 33 * n: raise newException(ValueError, "wrong length")
  try:
    for i in 0 ..< n: result.add pointFromCompressedWithInfinity(b[33*i ..< 33*i + 33])
  except ValueError: raise parseErr("invalid partial pubshare")

# ── EncPedPop ───────────────────────────────────────────────────────────────────
proc ecdhPad(seckey, myPubkey, theirPubkey, context: seq[byte], sending: bool): Scalar =
  var data = ecdhLibsecp(seckey, theirPubkey)
  if sending: data.add myPubkey & theirPubkey
  else: data.add theirPubkey & myPubkey
  doAssert data.len == 32 + 2 * 33
  data.add context
  scalarFromBytesWrapping(thDkg("encpedpop ecdh", data))

proc selfPad(symkey, nonce, context: seq[byte]): Scalar =
  scalarFromBytesWrapping(thDkg("encaps_multi self_pad", symkey & nonce & context))

proc encapsMulti(secnonce, pubnonce, deckey: seq[byte], enckeys: seq[seq[byte]], context: seq[byte], pid: int): seq[Scalar] =
  for i, enckey in enckeys:
    let ctx = be4(i) & context
    result.add (if i == pid: selfPad(deckey, pubnonce, ctx)
                else: ecdhPad(secnonce, pubnonce, enckey, ctx, sending = true))

proc decapsMulti(deckey, enckey: seq[byte], pubnonces: seq[seq[byte]], context: seq[byte], pid: int): seq[Scalar] =
  let ctx = be4(pid) & context
  for sender, pubnonce in pubnonces:
    if sender == pid: result.add selfPad(deckey, pubnonce, ctx)
    else:
      try: result.add ecdhPad(deckey, enckey, pubnonce, ctx, sending = false)
      except ValueError: raise dkgError("FaultyParticipantOrCoordinatorError", "invalid public nonce", sender)

proc serializeEncContext(t: int, enckeys: seq[seq[byte]]): seq[byte] = be4(t) & concat(enckeys)

type EncPmsg = object
  simpl: SimplPmsg
  pubnonce: seq[byte]
  encShares: seq[Scalar]

proc encPmsgLen(t, n: int): int = 33 * t + 64 + 33 + 32 * n

proc encPmsgFromBytes(b: seq[byte], t, n: int): EncPmsg =
  if b.len != encPmsgLen(t, n): raise newException(ValueError, "wrong length")
  let sl = 33 * t + 64
  result.simpl = simplPmsgFromBytes(b[0 ..< sl], t)
  result.pubnonce = b[sl ..< sl + 33]
  let rest = b[sl + 33 ..< b.len]
  try:
    for i in 0 ..< n: result.encShares.add scalarFromBytesChecked(rest[32*i ..< 32*i + 32])
  except ValueError: raise parseErr("invalid encrypted secret share")

proc toBytes(m: EncPmsg): seq[byte] =
  result = m.simpl.toBytes() & m.pubnonce
  for s in m.encShares: result.add s.toBytes()

proc encCmsgLen(t, n: int): int = simplCmsgLen(t, n) + 33 * n

proc encCmsgFromBytes(b: seq[byte], t, n: int): tuple[simpl: SimplCmsg, pubnonces: seq[seq[byte]]] =
  if b.len != encCmsgLen(t, n): raise newException(ValueError, "wrong length")
  let sl = simplCmsgLen(t, n)
  result.simpl = simplCmsgFromBytes(b[0 ..< sl], t, n)
  for i in 0 ..< n: result.pubnonces.add b[sl + 33*i ..< sl + 33*i + 33]

proc encStep1(seed, deckey: seq[byte], enckeys: seq[seq[byte]], t, pid: int, random: seq[byte]): tuple[state: EncState, msg: seq[byte]] =
  let n = enckeys.len
  let ctx = serializeEncContext(t, enckeys)
  let simplSeed = thDkg("encpedpop seed", seed & random & ctx)
  let simplAux = thDkg("simplpedpop aux", simplSeed)
  let secnonce = thDkg("encpedpop secnonce", simplSeed)
  let pubnonce = pubkeyGenPlain(secnonce)
  let (st, simplMsg, shares) = simplStep1(simplSeed, t, n, pid, simplAux)
  let pads = encapsMulti(secnonce, pubnonce, deckey, enckeys, ctx, pid)
  var enc: seq[Scalar]
  for i in 0 ..< shares.len: enc.add shares[i] + pads[i]
  result.msg = EncPmsg(simpl: simplPmsgFromBytes(simplMsg, t), pubnonce: pubnonce, encShares: enc).toBytes()
  result.state = EncState(simpl: st, pubnonce: pubnonce, enckeys: enckeys, participantId: pid)

proc encStep2(state: EncState, deckey, cmsg: seq[byte], encSecshare: Scalar): tuple[output: DkgOutput, eqInput: seq[byte]] =
  let (t, n, pid) = (state.simpl.t, state.enckeys.len, state.participantId)
  var c: tuple[simpl: SimplCmsg, pubnonces: seq[seq[byte]]]
  try: c = encCmsgFromBytes(cmsg, t, n)
  except MsgParseError as e: raise dkgError("FaultyCoordinatorError", e.msg)
  if c.pubnonces[pid] != state.pubnonce: raise dkgError("FaultyCoordinatorError", "Coordinator replied with wrong pubnonce")
  let ctx = serializeEncContext(t, state.enckeys)
  let pads = decapsMulti(deckey, state.enckeys[pid], c.pubnonces, ctx, pid)
  let secshare = encSecshare - sumScalars(pads)
  try: result = simplStep2(state.simpl, c.simpl.toBytes(), secshare)
  except DkgError as e:
    if e.kind == "UnknownFaultyParticipantOrCoordinatorError":
      e.inv.encSecshare = encSecshare
      e.inv.pads = pads
    raise
  result.eqInput.add concat(state.enckeys) & concat(c.pubnonces)

# ── CertEq ──────────────────────────────────────────────────────────────────────
proc prefixed33(label: string): seq[byte] =
  result = newSeq[byte](33)
  for i, ch in label: result[i] = byte(ch)

proc certeqMessage(x: seq[byte], pid: int): seq[byte] = prefixed33(BipTag & "certeq message") & be4(pid) & x

proc certeqVerify(hostpubkeys: seq[seq[byte]], x, cert: seq[byte]): int =
  ## −1 if every signature verifies, else the first participant whose does not;
  ## ValueError on a certificate of the wrong length
  let n = hostpubkeys.len
  if cert.len != 64 * n: raise newException(ValueError, "wrong length")
  for i in 0 ..< n:
    if not schnorrVerify(certeqMessage(x, i), hostpubkeys[i][1 .. 32], cert[64*i ..< 64*i + 64]): return i
  -1

proc recoveryAckMessage(x: seq[byte], pid: int): seq[byte] = prefixed33(BipTag & "recovery acknowledgment") & be4(pid) & x

# ── ChillDKG ────────────────────────────────────────────────────────────────────
proc hostpubkeyGen*(hostseckey: seq[byte]): seq[byte] =
  if hostseckey.len != 32: raise dkgError("ValueError")
  try: pubkeyGenPlain(hostseckey)
  except ValueError: raise dkgError("HostSeckeyError")

proc paramsValidate*(p: SessionParams) =
  if not (1 <= p.t and p.t <= p.hostpubkeys.len and p.hostpubkeys.len <= int(high(uint32))):
    raise dkgError("ThresholdOrCountError")
  for i, hpk in p.hostpubkeys:
    try: discard pointFromCompressed(hpk)
    except ValueError: raise dkgError("InvalidHostPubkeyError", "", i)
  var seen = initTable[seq[byte], int]()
  for i, hpk in p.hostpubkeys:
    if hpk in seen:
      let e = dkgError("DuplicateHostPubkeyError")
      e.participantId1 = seen[hpk]
      e.participantId2 = i
      raise e
    seen[hpk] = i

proc paramsHash*(p: SessionParams): seq[byte] =
  paramsValidate(p)
  thDkg("params_hash", be4(p.t) & concat(p.hostpubkeys))

proc indexOf(xs: seq[seq[byte]], x: seq[byte]): int =
  for i, y in xs:
    if y == x: return i
  -1

proc participantStep1*(hostseckey: seq[byte], params: SessionParams, random: seq[byte]): tuple[state: ParticipantState1, pmsg1: seq[byte]] =
  let hostpubkey = hostpubkeyGen(hostseckey)
  paramsValidate(params)
  let pid = params.hostpubkeys.indexOf(hostpubkey)
  if pid < 0: raise dkgError("HostSeckeyError", "Host secret key does not match any host public key")
  if random.len != 32: raise dkgError("ValueError")
  if random == newSeq[byte](32): raise dkgError("RandomnessError")
  let (enc, pmsg) = encStep1(hostseckey, hostseckey, params.hostpubkeys, params.t, pid, random)
  (ParticipantState1(params: params, participantId: pid, enc: enc), pmsg)

proc cmsg1FromBytes(b: seq[byte], t, n: int): tuple[enc: seq[byte], encSecshares: seq[Scalar]] =
  if b.len != encCmsgLen(t, n) + 32 * n: raise newException(ValueError, "wrong length")
  let el = encCmsgLen(t, n)
  discard encCmsgFromBytes(b[0 ..< el], t, n)       # MsgParseError if invalid
  result.enc = b[0 ..< el]
  let rest = b[el ..< b.len]
  try:
    for i in 0 ..< n: result.encSecshares.add scalarFromBytesChecked(rest[32*i ..< 32*i + 32])
  except ValueError: raise parseErr("invalid encrypted secret shares")

proc participantStep2*(hostseckey: seq[byte], state1: ParticipantState1, cmsg1, auxRand: seq[byte]): tuple[state: ParticipantState2, pmsg2: seq[byte]] =
  let hostpubkey = hostpubkeyGen(hostseckey)
  if auxRand.len != 32: raise dkgError("ValueError")
  let (params, pid) = (state1.params, state1.participantId)
  if hostpubkey != params.hostpubkeys[pid]:
    raise dkgError("HostSeckeyError", "Host secret key does not match the one used in participant_step1")
  let t = state1.enc.simpl.t
  var c: tuple[enc: seq[byte], encSecshares: seq[Scalar]]
  try: c = cmsg1FromBytes(cmsg1, t, params.hostpubkeys.len)
  except MsgParseError as e: raise dkgError("FaultyCoordinatorError", e.msg)
  except ValueError: raise dkgError("ValueError")
  var (output, eqInput) = encStep2(state1.enc, hostseckey, c.enc, c.encSecshares[pid])
  for s in c.encSecshares: eqInput.add s.toBytes()
  let sig = schnorrSign(certeqMessage(eqInput, pid), hostseckey, auxRand)
  (ParticipantState2(params: params, eqInput: eqInput, dkgOutput: output), sig)

proc participantFinalize*(state2: ParticipantState2, cmsg2: seq[byte]): tuple[output: DkgOutput, recoveryData: seq[byte]] =
  if cmsg2.len != 64 * state2.params.hostpubkeys.len: raise dkgError("ValueError")
  if certeqVerify(state2.params.hostpubkeys, state2.eqInput, cmsg2) >= 0:
    raise dkgError("FaultyCoordinatorError", "Coordinator has provided a certificate with an invalid signature")
  (state2.dkgOutput, state2.eqInput & cmsg2)

proc participantInvestigate*(error: ref DkgError, cinv: seq[byte]) =
  ## After an invalid share: find who sent it, or show the coordinator lied. Always raises.
  let d = error.inv
  let n = d.n
  if cinv.len != 32 * n + 33 * n: raise dkgError("ValueError")
  var encPartial: seq[Scalar]
  var partialPubshares: seq[GE]
  try:
    for i in 0 ..< n: encPartial.add scalarFromBytesChecked(cinv[32*i ..< 32*i + 32])
  except ValueError: raise dkgError("FaultyCoordinatorError", "invalid encrypted partial secshare")
  try: partialPubshares = simplCinvFromBytes(cinv[32 * n ..< cinv.len], n)
  except MsgParseError as e: raise dkgError("FaultyCoordinatorError", e.msg)
  var partialSecshares: seq[Scalar]
  for i in 0 ..< n: partialSecshares.add encPartial[i] - d.pads[i]
  if sumPoints(partialPubshares) != d.pubshare:
    raise dkgError("FaultyCoordinatorError", "Sum of partial pubshares not equal to pubshare")
  if sumScalars(partialSecshares) != d.secshare:
    doAssert sumScalars(encPartial) != d.encSecshare
    raise dkgError("FaultyCoordinatorError", "Sum of encrypted partial secshares not equal to encrypted secshare")
  for i in 0 ..< n:
    if not verifySecshare(partialSecshares[i], partialPubshares[i]):
      if i != d.participantId:
        raise dkgError("FaultyParticipantOrCoordinatorError", "Participant sent invalid partial secshare", i)
      raise dkgError("FaultyCoordinatorError", "Coordinator fiddled with the share from me to myself")
  doAssert verifySecshare(d.secshare, d.pubshare)
  raise dkgError("RuntimeError", "participant_investigate() was called, but all inputs are consistent.")

proc coordinatorStep1*(pmsgs1: seq[seq[byte]], params: SessionParams): tuple[state: CoordinatorState, cmsg1: seq[byte]] =
  paramsValidate(params)
  let (t, n) = (params.t, params.hostpubkeys.len)
  if pmsgs1.len != n: raise dkgError("ValueError")
  var parsed: seq[EncPmsg]
  for i, m in pmsgs1:
    try: parsed.add encPmsgFromBytes(m, t, n)
    except MsgParseError as e: raise dkgError("FaultyParticipantError", e.msg, i)
    except ValueError: raise dkgError("ValueError")
  var (simplCmsg, output, eqInput) = simplCoordinatorStep(parsed.mapIt(it.simpl.toBytes()), t, n)
  var pubnonces: seq[seq[byte]]
  for p in parsed: pubnonces.add p.pubnonce
  var encSecshares: seq[Scalar]
  for i in 0 ..< n:
    var s = scalar(0)
    for p in parsed: s = s + p.encShares[i]
    encSecshares.add s
  eqInput.add concat(params.hostpubkeys) & concat(pubnonces)
  for s in encSecshares: eqInput.add s.toBytes()
  var cmsg1 = simplCmsg & concat(pubnonces)
  for s in encSecshares: cmsg1.add s.toBytes()
  (CoordinatorState(params: params, eqInput: eqInput, dkgOutput: output), cmsg1)

proc coordinatorFinalize*(state: CoordinatorState, pmsgs2: seq[seq[byte]]): tuple[cmsg2: seq[byte], output: DkgOutput, recoveryData: seq[byte]] =
  if pmsgs2.len != state.params.hostpubkeys.len: raise dkgError("ValueError")
  for m in pmsgs2:
    if m.len != 64: raise dkgError("ValueError")
  let cert = concat(pmsgs2)
  let bad = certeqVerify(state.params.hostpubkeys, state.eqInput, cert)
  if bad >= 0:
    raise dkgError("FaultyParticipantError", "Participant has provided an invalid signature for the certificate", bad)
  (cert, state.dkgOutput, state.eqInput & cert)

proc coordinatorInvestigate*(pmsgs: seq[seq[byte]], params: SessionParams): seq[seq[byte]] =
  let (t, n) = (params.t, pmsgs.len)
  var parsed: seq[EncPmsg]
  for i, m in pmsgs:
    try: parsed.add encPmsgFromBytes(m, t, n)
    except MsgParseError as e: raise dkgError("FaultyParticipantError", e.msg, i)
    except ValueError: raise dkgError("ValueError")
  for i in 0 ..< n:
    var b: seq[byte]
    for p in parsed: b.add p.encShares[i].toBytes()
    for p in parsed: b.add p.simpl.com.pubshare(i).toCompressedWithInfinity()
    result.add b

type Recovery = object
  t: int
  sumComs: VssCommitment
  hostpubkeys, pubnonces: seq[seq[byte]]
  encSecshares: seq[Scalar]
  cert: seq[byte]

proc deserializeRecoveryData(b: seq[byte]): Recovery =
  ## ValueError on anything malformed (the caller reports it as undeserializable)
  if b.len < 4: raise newException(ValueError, "short")
  let t64 = (uint64(b[0]) shl 24) or (uint64(b[1]) shl 16) or (uint64(b[2]) shl 8) or uint64(b[3])
  var rest = b[4 ..< b.len]
  if uint64(rest.len) < 33'u64 * t64: raise newException(ValueError, "short")
  result.t = int(t64)
  result.sumComs = vssFromBytes(rest[0 ..< 33 * result.t], result.t)
  rest = rest[33 * result.t ..< rest.len]
  if rest.len mod (33 + 33 + 32 + 64) != 0: raise newException(ValueError, "not whole records")
  let n = rest.len div (33 + 33 + 32 + 64)
  for i in 0 ..< n: result.hostpubkeys.add rest[33*i ..< 33*i + 33]
  rest = rest[33 * n ..< rest.len]
  for i in 0 ..< n: result.pubnonces.add rest[33*i ..< 33*i + 33]
  rest = rest[33 * n ..< rest.len]
  for i in 0 ..< n: result.encSecshares.add scalarFromBytesChecked(rest[32*i ..< 32*i + 32])
  rest = rest[32 * n ..< rest.len]
  result.cert = rest[0 ..< 64 * n]

proc decryptSum(deckey, enckey: seq[byte], pubnonces: seq[seq[byte]], context: seq[byte], pid: int, sumCiphertexts: Scalar): Scalar =
  if pid >= pubnonces.len: raise dkgError("IndexError")
  sumCiphertexts - sumScalars(decapsMulti(deckey, enckey, pubnonces, context, pid))

proc recover(hostseckey: Option[seq[byte]], recoveryData: seq[byte]): tuple[output: DkgOutput, params: SessionParams] =
  var r: Recovery
  try: r = deserializeRecoveryData(recoveryData)
  except CatchableError: raise dkgError("RecoveryDataError", "Failed to deserialize recovery data")
  let n = r.hostpubkeys.len
  let params = SessionParams(hostpubkeys: r.hostpubkeys, t: r.t)
  try: paramsValidate(params)
  except DkgError as e:
    if e.kind in ["ThresholdOrCountError", "InvalidHostPubkeyError", "DuplicateHostPubkeyError"]:
      raise dkgError("RecoveryDataError", "Invalid session parameters in recovery data")
    raise
  let eqInput = recoveryData[0 ..< recoveryData.len - r.cert.len]
  if certeqVerify(r.hostpubkeys, eqInput, r.cert) >= 0:
    raise dkgError("RecoveryDataError", "Invalid certificate in recovery data")
  let (tweaked, tweak, _) = r.sumComs.invalidTaprootCommit()
  var pubshares: seq[seq[byte]]
  for i in 0 ..< n: pubshares.add tweaked.pubshare(i).toCompressed()
  var secshare = none(seq[byte])
  if hostseckey.isSome:
    let hpk = hostpubkeyGen(hostseckey.get)
    let pid = r.hostpubkeys.indexOf(hpk)
    if pid < 0: raise dkgError("HostSeckeyError", "Host secret key does not match any host public key in the recovery data")
    let ctx = serializeEncContext(r.t, r.hostpubkeys)
    let s = decryptSum(hostseckey.get, r.hostpubkeys[pid], r.pubnonces, ctx, pid, r.encSecshares[pid]) + tweak
    doAssert verifySecshare(s, tweaked.pubshare(pid))
    secshare = some(s.toBytes())
  (DkgOutput(secshare: secshare, threshPk: tweaked.ges[0].toCompressed(), pubshares: pubshares), params)

proc participantRecover*(hostseckey, recoveryData: seq[byte]): tuple[output: DkgOutput, params: SessionParams] =
  recover(some(hostseckey), recoveryData)

proc coordinatorRecover*(recoveryData: seq[byte]): tuple[output: DkgOutput, params: SessionParams] =
  recover(none(seq[byte]), recoveryData)

proc participantRecoveryAckSign*(hostseckey, recoveryData: seq[byte], params: SessionParams, auxRand: seq[byte]): seq[byte] =
  let hpk = hostpubkeyGen(hostseckey)
  paramsValidate(params)
  let pid = params.hostpubkeys.indexOf(hpk)
  if pid < 0: raise dkgError("HostSeckeyError", "Host secret key does not match any host public key")
  if auxRand.len != 32: raise dkgError("ValueError")
  var r: Recovery
  try: r = deserializeRecoveryData(recoveryData)
  except CatchableError: raise dkgError("RecoveryDataError", "Failed to deserialize recovery data")
  if r.t != params.t or r.hostpubkeys != params.hostpubkeys:
    raise dkgError("RecoveryDataError", "Recovery data does not match the provided session parameters")
  schnorrSign(recoveryAckMessage(recoveryData, pid), hostseckey, auxRand)

proc participantRecoveryAcksVerify*(recoveryData: seq[byte], params: SessionParams, ackSigs: seq[seq[byte]]) =
  paramsValidate(params)
  if ackSigs.len != params.hostpubkeys.len: raise dkgError("ValueError")
  var r: Recovery
  try: r = deserializeRecoveryData(recoveryData)
  except CatchableError: raise dkgError("RecoveryDataError", "Failed to deserialize recovery data")
  if r.t != params.t or r.hostpubkeys != params.hostpubkeys:
    raise dkgError("RecoveryDataError", "Recovery data does not match the provided session parameters")
  for i, sig in ackSigs:
    if sig.len != 64: raise dkgError("ValueError")
    if not schnorrVerify(recoveryAckMessage(recoveryData, i), params.hostpubkeys[i][1 .. 32], sig):
      raise dkgError("InvalidRecoveryAckError", "", i)
