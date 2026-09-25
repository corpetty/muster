## A FROST group, whatever it signs (Phase D): the ceremony's key and the two rounds'
## contributions, shared by every aggregate-locus family (btc.frost-bip445,
## lez.frost-public-account). A family says WHAT is signed (its messages); this module
## says how a round's contribution looks, when it is valid, and how t partials become one
## BIP-340 signature.
##
##   GROUP    from the ceremony's PUBLIC recovery data alone (coordinatorRecover): the
##            participants' host keys and t, the threshold key Q and each public share.
##   ROUND 1  {r: 1, signer: host key, nonces: [a public nonce per message]}.
##   ROUND 2  {r: 2, signer, set: [{signer, nonces} × t], psigs: [a partial per message]}.
##            A partial is only valid under its set's aggregate nonce, and the core checks
##            each contribution alone, so the set is carried and checked with it.
##
## The room path (coordination/aggregate.nim) reaches a family through two driver hooks:
## frostGroupOf (the group, if this driver is one) and frostMessages (what it signs).

import std/[sequtils, options]
import ../dcbor/dcbor
import ../intents/materialization
import ./driver
import ../bitcoin/[tx, keys]        # toHex; schnorrVerify
import ../frost/[secp, signing, chilldkg]

type
  FrostGroup* = object
    params*: SessionParams        ## the participants' host keys (ceremony order) and t
    threshPk*: seq[byte]          ## 33-byte compressed threshold key
    pubshares*: seq[seq[byte]]    ## each participant's public share, by participant id
    recoveryData*: seq[byte]      ## the ceremony's public recovery data
    xonly*: seq[byte]             ## x(Q): what a BIP-340 verifier checks against

  Round2* = object
    signer*: seq[byte]
    set*: seq[(seq[byte], seq[seq[byte]])]
    psigs*: seq[seq[byte]]

proc frostGroup*(recoveryData: seq[byte]): FrostGroup =
  ## The group a ceremony made. Raises on data that is not a ChillDKG recovery record.
  let (o, p) = coordinatorRecover(recoveryData)
  FrostGroup(params: p, threshPk: o.threshPk, pubshares: o.pubshares, recoveryData: recoveryData,
             xonly: pointFromCompressed(o.threshPk).toXonly())

# ── the driver hooks the room path dispatches on ──────────────────────────────
method frostGroupOf*(d: Driver): tuple[ok: bool, group: FrostGroup] {.base.} = (false, FrostGroup())
method frostMessages*(d: Driver, e: Effect): seq[seq[byte]] {.base.} = @[]

# ── contributions ─────────────────────────────────────────────────────────────
proc mapGet(m: CborValue, key: string): CborValue =
  if m.kind != ckMap: return cbNull()
  for (k, v) in m.pairs:
    if k.kind == ckText and k.t == key: return v
  cbNull()

proc bytesList(v: CborValue): seq[seq[byte]] =
  if v.kind != ckArray: return
  for x in v.arr:
    if x.kind != ckBytes: return @[]
    result.add x.b

proc round1Contribution*(host: seq[byte], nonces: seq[seq[byte]]): Contribution =
  Contribution(bytes: encode(cbMap(@[(cbText("r"), cbUint(1)), (cbText("signer"), cbBytes(host)),
                                     (cbText("nonces"), cbArray(nonces.mapIt(cbBytes(it))))])))

proc round2Contribution*(host: seq[byte], set: seq[(seq[byte], seq[seq[byte]])],
                         psigs: seq[seq[byte]]): Contribution =
  var entries: seq[CborValue]
  for (h, ns) in set:
    entries.add cbMap(@[(cbText("signer"), cbBytes(h)), (cbText("nonces"), cbArray(ns.mapIt(cbBytes(it))))])
  Contribution(bytes: encode(cbMap(@[(cbText("r"), cbUint(2)), (cbText("signer"), cbBytes(host)),
                                     (cbText("set"), cbArray(entries)),
                                     (cbText("psigs"), cbArray(psigs.mapIt(cbBytes(it))))])))

proc contributionRound*(c: Contribution): int =
  ## 1 or 2 by the payload's own tag; 0 if it is not a FROST contribution.
  try:
    let r = decode(c.bytes).mapGet("r")
    if r.kind == ckUint and r.u in [1'u64, 2'u64]: int(r.u) else: 0
  except CatchableError: 0

proc decodeRound1Nonces*(c: Contribution): seq[seq[byte]] =
  ## A round-1 contribution's public nonces, one per message.
  bytesList(decode(c.bytes).mapGet("nonces"))

proc round2Of*(c: Contribution): Round2 =
  let v = decode(c.bytes)
  result.signer = v.mapGet("signer").b
  for e in v.mapGet("set").arr:
    result.set.add (e.mapGet("signer").b, bytesList(e.mapGet("nonces")))
  result.psigs = bytesList(v.mapGet("psigs"))

proc validNonce(n: seq[byte]): bool =
  if n.len != 66: return false
  try:
    discard nonceAgg(@[n])
    true
  except CatchableError: false

proc verifyFrost*(g: FrostGroup, msgs: seq[seq[byte]], c: Contribution, wantRound = 0): string =
  ## The signer's host key hex if `c` is a valid contribution over `msgs`, else "".
  if msgs.len == 0: return ""
  var v: CborValue
  try: v = decode(c.bytes)
  except CatchableError: return ""
  let round = contributionRound(c)
  if round == 0 or (wantRound > 0 and round != wantRound): return ""
  let signer = v.mapGet("signer")
  if signer.kind != ckBytes or g.params.hostpubkeys.find(signer.b) < 0: return ""
  if round == 1:
    let ns = bytesList(v.mapGet("nonces"))
    if ns.len != msgs.len or not ns.allIt(validNonce(it)): return ""
    return toHex(signer.b)
  var r2: Round2
  try: r2 = round2Of(c)
  except CatchableError: return ""
  if r2.set.len != g.params.t or r2.psigs.len != msgs.len: return ""
  var ids: seq[int]
  for (h, ns) in r2.set:
    let id = g.params.hostpubkeys.find(h)
    if id < 0 or id in ids or ns.len != msgs.len or not ns.allIt(validNonce(it)): return ""
    ids.add id
  let me = r2.set.mapIt(it[0]).find(signer.b)
  if me < 0: return ""
  for j, h in msgs:
    var ok = false
    try:
      ok = partialSigVerify(r2.psigs[j], r2.set.mapIt(it[1][j]), g.params.hostpubkeys.len, g.params.t,
                            ids, ids.mapIt(g.pubshares[it]), g.threshPk, @[], @[], h, me)
    except CatchableError: ok = false
    if not ok: return ""
  toHex(signer.b)

proc setsOf(g: FrostGroup, msgs: seq[seq[byte]], contributions: seq[Contribution]):
    seq[(seq[(seq[byte], seq[seq[byte]])], seq[Round2])] =
  ## The valid round-2 partials, grouped by the signer set they sign under, one per signer.
  for c in contributions:
    if contributionRound(c) != 2 or verifyFrost(g, msgs, c, 2).len == 0: continue
    let r2 = round2Of(c)
    var placed = false
    for s in result.mitems:
      if s[0] == r2.set:
        if not s[1].anyIt(it.signer == r2.signer): s[1].add r2
        placed = true
    if not placed: result.add (r2.set, @[r2])

proc completeSignersFrost*(g: FrostGroup, msgs: seq[seq[byte]], contributions: seq[Contribution]): int =
  ## How many signers the most complete round-2 set has (for "have k of t").
  for (_, parts) in setsOf(g, msgs, contributions): result = max(result, parts.len)

proc aggregateFrost*(g: FrostGroup, msgs: seq[seq[byte]], contributions: seq[Contribution]): seq[seq[byte]] =
  ## One BIP-340 signature per message, from a signer set every one of whose t members
  ## contributed a valid partial under it; each is verified under x(Q) before it is
  ## returned. Raises ValueError when no set is complete.
  for (set, parts) in setsOf(g, msgs, contributions):
    if parts.len < g.params.t: continue
    let ids = set.mapIt(g.params.hostpubkeys.find(it[0]))
    var sigs: seq[seq[byte]]
    for j, h in msgs:
      var psigs: seq[seq[byte]]
      for (host, _) in set:
        for p in parts:
          if p.signer == host: psigs.add p.psigs[j]
      let ctx = SessionContext(n: g.params.hostpubkeys.len, t: g.params.t, ids: ids,
                               pubshares: some(ids.mapIt(g.pubshares[it])), threshPk: g.threshPk,
                               aggnonce: nonceAgg(set.mapIt(it[1][j])), msg: h)
      let sig = partialSigAgg(psigs, ctx)
      if not schnorrVerify(sig, h, g.xonly): raise newException(ValueError, "the aggregate does not verify")
      sigs.add sig
    return sigs
  raise newException(ValueError, "no signer set has all " & $g.params.t & " partial signatures")
