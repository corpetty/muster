## FROST signing for BIP-340 threshold signatures (exo-d7e, Phase D2).
##
## A port of the BIP-445 draft's reference implementation
## (bip-0445/python/frost_ref/signing.py, siv2r/bips @ 8e25d57, bitcoin/bips#2070), function
## for function, with the reference's error messages verbatim — held to every vector the
## draft ships (tests/frost_signing_test.nim). Two rounds: each signer publishes a public
## nonce pair (round 1); with the aggregate nonce fixed, each publishes a partial
## signature (round 2); the partial signatures sum to ONE BIP-340 signature under the
## threshold key — so a FROST spend looks single-sig to the chain.
##
## Identifiers are 0-based (participant id sits at polynomial x = id + 1). A secnonce is
## spent by signing: `sign` zeroes it, so a second use is refused. In muster the secnonce
## never leaves the keystore (S7, exo-24a); this module is the arithmetic.
## NOT constant time (see secp.nim) — demo-grade, behind the production gate.

import std/[options, algorithm, sequtils, sysrand]
import ./secp
import ../bitcoin/tx       # taggedHash

const
  FrostTagAux = "BIP0445/aux"
  FrostTagNonce = "BIP0445/nonce"
  FrostTagNonceCoef = "BIP0445/noncecoef"
  FrostTagDeterministicNonce = "BIP0445/deterministic/nonce"
  Bip340TagChallenge = "BIP0340/challenge"
  MaxParticipants* = 128

type
  InvalidContributionError* = object of CatchableError
    ## A signer (signerIndex ≥ 0) or the coordinator (signerIndex = −1) sent an invalid
    ## value; `contrib` names it: pubnonce | aggnonce | aggothernonce | psig.
    signerIndex*: int
    contrib*: string

  TweakContext* = object
    q*: GE
    gacc*, tacc*: Scalar

  ThresholdInfo* = object
    t*: int
    threshPk*: seq[byte]
    pubshares*: seq[Option[seq[byte]]]   ## length n; none = that participant's share is unknown

  SessionContext* = object
    n*, t*: int
    ids*: seq[int]                       ## the u signers
    pubshares*: Option[seq[seq[byte]]]   ## the u signers' public shares, or none if unknown
    threshPk*: seq[byte]
    aggnonce*: seq[byte]
    tweaks*: seq[seq[byte]]
    isXonly*: seq[bool]
    msg*: seq[byte]

proc invalidContribution(signerIndex: int, contrib: string): ref InvalidContributionError =
  result = newException(InvalidContributionError,
    (if signerIndex < 0: "the coordinator" else: "signer " & $signerIndex) & " sent an invalid " & contrib)
  result.signerIndex = signerIndex
  result.contrib = contrib

proc th(tag: string, data: openArray[byte]): seq[byte] = @(taggedHash(tag, data))
proc be(x: uint64, width: int): seq[byte] =
  result = newSeq[byte](width)
  for i in 0 ..< width: result[width - 1 - i] = byte((x shr uint64(8*i)) and 0xff)
proc xorBytes(a, b: openArray[byte]): seq[byte] =
  result = newSeq[byte](a.len)
  for i in 0 ..< a.len: result[i] = a[i] xor b[i]

proc hasDuplicates(xs: seq[int]): bool = deduplicate(xs).len != xs.len

# ── interpolation ──────────────────────────────────────────────────────────────
proc deriveInterpolatingValue*(ids: seq[int], myId: int): Scalar =
  doAssert myId in ids and myId >= 0 and myId < (1 shl 32) and not hasDuplicates(ids)
  var num = scalar(1)
  var deno = scalar(1)
  for cur in ids:
    if cur == myId: continue
    num = num * scalar(int64(cur + 1))
    deno = deno * scalar(int64(cur - myId))
  num / deno

proc derivePubshareAt*(ids: seq[int], pubshares: seq[GE], x: int): GE =
  doAssert ids.len == pubshares.len and not hasDuplicates(ids)
  result = infinity()
  for k, myId in ids:
    var num = scalar(1)
    var deno = scalar(1)
    for cur in ids:
      if cur == myId: continue
      num = num * scalar(int64(x - cur))
      deno = deno * scalar(int64(myId - cur))
    result = result + ((num / deno) * pubshares[k])

proc deriveThreshPubkey*(ids: seq[int], pubshares: seq[GE]): seq[byte] =
  let q = derivePubshareAt(ids, pubshares, -1)
  if q.isInfinity: raise newException(ValueError, "The threshold public key must not be the point at infinity.")
  q.toCompressed()

proc validateThresholdInfo*(info: ThresholdInfo) =
  let n = info.pubshares.len
  if not (1 <= info.t and info.t <= n): raise newException(ValueError, "The threshold must be 1 <= t <= n.")
  if n > MaxParticipants:
    raise newException(ValueError, "The number of participants must be n <= " & $MaxParticipants & ".")
  try: discard pointFromCompressed(info.threshPk)
  except ValueError: raise newException(ValueError, "Invalid threshold public key.")
  var parsed: seq[(int, GE)]
  for i, ps in info.pubshares:
    if ps.isNone: continue
    try: parsed.add (i, pointFromCompressed(ps.get))
    except ValueError: raise newException(ValueError, "Invalid pubshare at index " & $i & ".")
  if parsed.len < info.t: raise newException(ValueError, "At least t pubshares must be present.")
  let baseIds = parsed[0 ..< info.t].mapIt(it[0])
  let basePoints = parsed[0 ..< info.t].mapIt(it[1])
  for (i, p) in parsed[info.t .. ^1]:
    if derivePubshareAt(baseIds, basePoints, i) != p:
      raise newException(ValueError,
        "The provided key material is incorrect: the public shares do not lie on a single polynomial.")
  if deriveThreshPubkey(baseIds, basePoints) != info.threshPk:
    raise newException(ValueError,
      "The provided key material is incorrect: the public shares do not match the threshold public key.")

# ── tweaks ─────────────────────────────────────────────────────────────────────
proc getXonlyPk*(c: TweakContext): seq[byte] = c.q.toXonly()
proc getPlainPk*(c: TweakContext): seq[byte] = c.q.toCompressed()

proc tweakCtxInit*(threshPk: seq[byte]): TweakContext =
  TweakContext(q: pointFromCompressed(threshPk), gacc: scalar(1), tacc: scalar(0))

proc applyTweak*(c: TweakContext, tweak: seq[byte], isXonly: bool): TweakContext =
  if tweak.len != 32: raise newException(ValueError, "The tweak must be a 32-byte array.")
  let g = (if isXonly and not c.q.hasEvenY(): scalar(-1) else: scalar(1))
  var twk: Scalar
  try: twk = scalarFromBytesChecked(tweak)
  except ValueError: raise newException(ValueError, "The tweak value is out of range.")
  let q2 = (g * c.q) + mulG(twk)
  if q2.isInfinity: raise newException(ValueError, "The result of tweaking cannot be infinity.")
  TweakContext(q: q2, gacc: g * c.gacc, tacc: twk + g * c.tacc)

proc threshPubkeyAndTweak*(threshPk: seq[byte], tweaks: seq[seq[byte]], isXonly: seq[bool]): TweakContext =
  if tweaks.len != isXonly.len:
    raise newException(ValueError, "The tweaks and is_xonly arrays must have the same length.")
  result = tweakCtxInit(threshPk)
  for i in 0 ..< tweaks.len: result = applyTweak(result, tweaks[i], isXonly[i])

# ── nonces ─────────────────────────────────────────────────────────────────────
proc nonceHash(rand, pubshare, threshPkXonly: seq[byte], i: int, msgPrefixed, extraIn: seq[byte]): seq[byte] =
  var buf = rand
  buf.add byte(pubshare.len); buf.add pubshare
  buf.add byte(threshPkXonly.len); buf.add threshPkXonly
  buf.add msgPrefixed
  buf.add be(uint64(extraIn.len), 4); buf.add extraIn
  buf.add byte(i)
  th(FrostTagNonce, buf)

proc nonceGenInternal*(rand: seq[byte], secshare, pubshare, threshPkXonly, msg,
                       extraIn: Option[seq[byte]]): tuple[secnonce, pubnonce: seq[byte]] =
  let rand2 = (if secshare.isSome: xorBytes(secshare.get, th(FrostTagAux, rand)) else: rand)
  let ps = pubshare.get(@[])
  let tx = threshPkXonly.get(@[])
  var msgPrefixed: seq[byte]
  if msg.isNone: msgPrefixed = @[0'u8]
  else:
    msgPrefixed = @[1'u8] & be(uint64(msg.get.len), 8) & msg.get
  let ex = extraIn.get(@[])
  let k1 = scalarFromBytesWrapping(nonceHash(rand2, ps, tx, 0, msgPrefixed, ex))
  let k2 = scalarFromBytesWrapping(nonceHash(rand2, ps, tx, 1, msgPrefixed, ex))
  doAssert not k1.isZero and not k2.isZero
  (k1.toBytes() & k2.toBytes(), mulG(k1).toCompressed() & mulG(k2).toCompressed())

proc nonceGen*(secshare, pubshare, threshPkXonly, msg, extraIn: Option[seq[byte]]): tuple[secnonce, pubnonce: seq[byte]] =
  if secshare.isSome and secshare.get.len != 32:
    raise newException(ValueError, "The optional byte array secshare must have length 32.")
  if pubshare.isSome and pubshare.get.len != 33:
    raise newException(ValueError, "The optional byte array pubshare must have length 33.")
  if threshPkXonly.isSome and threshPkXonly.get.len != 32:
    raise newException(ValueError, "The optional byte array thresh_pk_xonly must have length 32.")
  var rand = newSeq[byte](32)
  if not urandom(rand): raise newException(ValueError, "no randomness available")
  nonceGenInternal(rand, secshare, pubshare, threshPkXonly, msg, extraIn)

proc nonceAgg*(pubnonces: seq[seq[byte]]): seq[byte] =
  for j in 1 .. 2:
    var r = infinity()
    for idx, pn in pubnonces:
      var rij: GE
      try:
        if pn.len != 66: raise newException(ValueError, "a pubnonce is 66 bytes")
        rij = pointFromCompressed(pn[(j - 1) * 33 ..< j * 33])
      except ValueError: raise invalidContribution(idx, "pubnonce")
      r = r + rij
    result.add r.toCompressedWithInfinity()

# ── the session ────────────────────────────────────────────────────────────────
proc serializeIds*(ids: seq[int]): seq[byte] =
  for i in sorted(ids): result.add be(uint64(i), 4)

proc validateSessionParams*(n, t: int, ids: seq[int], pubshares: Option[seq[seq[byte]]], threshPk: seq[byte]) =
  if not (1 <= t and t <= n): raise newException(ValueError, "The threshold must be 1 <= t <= n.")
  if n > MaxParticipants:
    raise newException(ValueError, "The number of participants must be n <= " & $MaxParticipants & ".")
  if not (t <= ids.len and ids.len <= n): raise newException(ValueError, "The number of signers must be between t and n.")
  if pubshares.isSome and pubshares.get.len != ids.len:
    raise newException(ValueError, "The pubshares and ids lists must have the same length.")
  var points: seq[GE]
  for idx, i in ids:
    if not (0 <= i and i <= n - 1): raise newException(ValueError, "Invalid id at index " & $idx)
    if pubshares.isSome:
      try: points.add pointFromCompressed(pubshares.get[idx])
      except ValueError: raise newException(ValueError, "Invalid pubshare at index " & $idx & ".")
  if hasDuplicates(ids): raise newException(ValueError, "The ids list contains duplicate elements.")
  if pubshares.isSome and deriveThreshPubkey(ids, points) != threshPk:
    raise newException(ValueError,
      "The provided key material is incorrect: the public shares do not match the threshold public key.")

type SessionValues = object
  q: GE
  gacc, tacc, b, e: Scalar
  r: GE

proc getSessionValues(c: SessionContext): SessionValues =
  validateSessionParams(c.n, c.t, c.ids, c.pubshares, c.threshPk)
  let tw = threshPubkeyAndTweak(c.threshPk, c.tweaks, c.isXonly)
  let b = scalarFromBytesWrapping(th(FrostTagNonceCoef,
    be(uint64(c.ids.len), 4) & serializeIds(c.ids) & c.aggnonce & tw.q.toXonly() & c.msg))
  doAssert not b.isZero
  var r1, r2: GE
  try:
    if c.aggnonce.len != 66: raise newException(ValueError, "an aggnonce is 66 bytes")
    r1 = pointFromCompressedWithInfinity(c.aggnonce[0 ..< 33])
    r2 = pointFromCompressedWithInfinity(c.aggnonce[33 ..< 66])
  except ValueError: raise invalidContribution(-1, "aggnonce")
  let r0 = r1 + (b * r2)
  let r = (if r0.isInfinity: generator() else: r0)
  let e = scalarFromBytesWrapping(th(Bip340TagChallenge, r.toXonly() & tw.q.toXonly() & c.msg))
  doAssert not e.isZero
  SessionValues(q: tw.q, gacc: tw.gacc, tacc: tw.tacc, b: b, r: r, e: e)

proc partialSigVerifyInternal*(psig: seq[byte], myId: int, pubnonce, pubshare: seq[byte], c: SessionContext): bool =
  let v = getSessionValues(c)
  var s: Scalar
  var r1, r2, p: GE
  try:
    s = scalarFromBytesChecked(psig)
    if pubnonce.len != 66: return false
    r1 = pointFromCompressed(pubnonce[0 ..< 33])
    r2 = pointFromCompressed(pubnonce[33 ..< 66])
    p = pointFromCompressed(pubshare)
  except ValueError: return false
  let re0 = r1 + (v.b * r2)
  let re = (if v.r.hasEvenY(): re0 else: -re0)
  let a = deriveInterpolatingValue(c.ids, myId)
  let g = (if v.q.hasEvenY(): scalar(1) else: scalar(-1))
  mulG(s) == re + ((v.e * a * (g * v.gacc)) * p)

proc sign*(secnonce: var seq[byte], secshare: seq[byte], myId: int, c: SessionContext): seq[byte] =
  ## A partial signature. Zeroes `secnonce` first — a secnonce signs once.
  let v = getSessionValues(c)
  var k1b, k2b: Scalar
  try: k1b = scalarFromBytesNonzeroChecked(secnonce[0 ..< 32])
  except ValueError, IndexDefect: raise newException(ValueError, "first secnonce value is out of range.")
  try: k2b = scalarFromBytesNonzeroChecked(secnonce[32 ..< 64])
  except ValueError, IndexDefect: raise newException(ValueError, "second secnonce value is out of range.")
  secnonce = newSeq[byte](64)
  let k1 = (if v.r.hasEvenY(): k1b else: -k1b)
  let k2 = (if v.r.hasEvenY(): k2b else: -k2b)
  var d0: Scalar
  try: d0 = scalarFromBytesNonzeroChecked(secshare)
  except ValueError: raise newException(ValueError, "The signer's secret share value is out of range.")
  let myPubshare = mulG(d0).toCompressed()
  if myId notin c.ids: raise newException(ValueError, "The signer's id is missing from the ids list.")
  if c.pubshares.isSome and c.pubshares.get[c.ids.find(myId)] != myPubshare:
    raise newException(ValueError, "The signer's pubshare is missing from the pubshares list.")
  let a = deriveInterpolatingValue(c.ids, myId)
  let g = (if v.q.hasEvenY(): scalar(1) else: scalar(-1))
  let d = g * v.gacc * d0
  let s = k1 + v.b * k2 + v.e * a * d
  result = s.toBytes()
  let pubnonce = mulG(k1b).toCompressed() & mulG(k2b).toCompressed()
  doAssert partialSigVerifyInternal(result, myId, pubnonce, myPubshare, c), "a partial signature must verify"

proc detNonceHash(secshare2: seq[byte], myId: int, ids: seq[int], aggothernonce, tweakedXonly, msg: seq[byte],
                  i: int): seq[byte] =
  var buf = secshare2
  buf.add be(uint64(myId), 4)
  buf.add be(uint64(ids.len), 4)
  buf.add serializeIds(ids)
  buf.add aggothernonce
  buf.add tweakedXonly
  buf.add be(uint64(msg.len), 8); buf.add msg
  buf.add byte(i)
  th(FrostTagDeterministicNonce, buf)

proc deterministicSign*(secshare: seq[byte], myId: int, aggothernonce: Option[seq[byte]], n, t: int,
                        ids: seq[int], pubshares: Option[seq[seq[byte]]], threshPk: seq[byte],
                        tweaks: seq[seq[byte]], isXonly: seq[bool], msg: seq[byte],
                        auxRand: Option[seq[byte]]): tuple[pubnonce, psig: seq[byte]] =
  validateSessionParams(n, t, ids, pubshares, threshPk)
  let ss2 = (if auxRand.isSome: xorBytes(secshare, th(FrostTagAux, auxRand.get)) else: secshare)
  let txo = getXonlyPk(threshPubkeyAndTweak(threshPk, tweaks, isXonly))
  let ago = aggothernonce.get(@[])
  let k1 = scalarFromBytesWrapping(detNonceHash(ss2, myId, ids, ago, txo, msg, 0))
  let k2 = scalarFromBytesWrapping(detNonceHash(ss2, myId, ids, ago, txo, msg, 1))
  doAssert not k1.isZero and not k2.isZero
  let pubnonce = mulG(k1).toCompressed() & mulG(k2).toCompressed()
  var secnonce = k1.toBytes() & k2.toBytes()
  var aggnonce: seq[byte]
  if aggothernonce.isNone: aggnonce = pubnonce
  else:
    try: aggnonce = nonceAgg(@[pubnonce, aggothernonce.get])
    except InvalidContributionError: raise invalidContribution(-1, "aggothernonce")
  let c = SessionContext(n: n, t: t, ids: ids, pubshares: pubshares, threshPk: threshPk, aggnonce: aggnonce,
                         tweaks: tweaks, isXonly: isXonly, msg: msg)
  (pubnonce, sign(secnonce, secshare, myId, c))

proc partialSigVerify*(psig: seq[byte], pubnonces: seq[seq[byte]], n, t: int, ids: seq[int],
                       pubshares: seq[seq[byte]], threshPk: seq[byte], tweaks: seq[seq[byte]],
                       isXonly: seq[bool], msg: seq[byte], i: int): bool =
  if pubnonces.len != ids.len or pubshares.len != ids.len:
    raise newException(ValueError, "The pubnonces, pubshares and ids lists must have the same length.")
  if not (0 <= i and i < ids.len): raise newException(ValueError, "The signer index must satisfy 0 <= i <= u - 1.")
  if tweaks.len != isXonly.len: raise newException(ValueError, "The tweaks and is_xonly lists must have the same length.")
  validateSessionParams(n, t, ids, some(pubshares), threshPk)
  let aggnonce = nonceAgg(pubnonces)
  let c = SessionContext(n: n, t: t, ids: ids, pubshares: some(pubshares), threshPk: threshPk, aggnonce: aggnonce,
                         tweaks: tweaks, isXonly: isXonly, msg: msg)
  partialSigVerifyInternal(psig, ids[i], pubnonces[i], pubshares[i], c)

proc partialSigAgg*(psigs: seq[seq[byte]], c: SessionContext): seq[byte] =
  ## The partial signatures of the session's signers, summed into one BIP-340 signature.
  let v = getSessionValues(c)
  if psigs.len != c.ids.len: raise newException(ValueError, "The psigs and ids lists must have the same length.")
  var s = scalar(0)
  for idx, ps in psigs:
    var si: Scalar
    try: si = scalarFromBytesChecked(ps)
    except ValueError: raise invalidContribution(idx, "psig")
    s = s + si
  let g = (if v.q.hasEvenY(): scalar(1) else: scalar(-1))
  s = s + v.e * g * v.tacc
  v.r.toXonly() & s.toBytes()
