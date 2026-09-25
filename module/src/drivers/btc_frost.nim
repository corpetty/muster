## The aggregate-locus driver (Phase D, exo-a50.4.5): btc.frost-bip445, a t-of-n taproot
## account made by a ChillDKG ceremony and spent by BIP-445 FROST. To the chain it is
## single-sig: the output key is the threshold key, and the witness is one BIP-340
## signature (a key-path spend).
##
##   ACCOUNT       the ceremony itself. Its PUBLIC recovery data gives the threshold key,
##                 the public shares, the participants' host keys and t (coordinatorRecover),
##                 so a disclosure is checked by re-deriving the address from it, with no
##                 chain read. ChillDKG's key is already a taproot output key (it commits to
##                 an unspendable script path), so the address is OP_1 x(Q).
##   EFFECT        a btc-spend (drivers/btc_multisig.nim) from the account's coins.
##   MATERIAL.     every input's BIP-341 SigMsg on the key path (no leaf), SIGHASH_DEFAULT.
##   ROUND 1       {r: 1, signer: host key, nonces: [a public nonce per input]}.
##   ROUND 2       {r: 2, signer, set: [{signer, nonces} × t], psigs: [a partial per input]}.
##                 The signer SET is carried, because a partial signature is only valid
##                 under the set's aggregate nonce, and the core verifies each contribution
##                 alone. An honest member takes the first t round-1 contributions in the
##                 log's canonical order (coordination/aggregate.nim), so honest sets agree.
##                 Settlement aggregates only a set that has all t partials.
##   SETTLEMENT    the partials aggregate into one BIP-340 signature per input, verified
##                 under the account key before a transaction is built; the witness is that
##                 signature alone.
##
## Contributors are named by their 33-byte host key, so the attestation is a recoverable
## signature by that key (coordination/attest.nim). The shares and nonces never leave the
## keystore (seam S7).
## Demo-grade: the FROST code is not constant time (module/src/frost/CLAUDE.md).

import std/[json, strutils, sequtils, options]
import ../dcbor/dcbor
import ../intents/materialization
import ./driver
import ./manifest
import ./profile
import ./btc_multisig              # the btc-spend effect, its checks and its builder
import ../bitcoin/[tx, script, sighash, keys, bech32, network]
import ../frost/[secp, signing, chilldkg]

const FrostFamily* = "btc.frost-bip445"
const FrostDomain = "bip341.keypath.frost-bip445.v1"

type
  FrostAccount* = object
    network*: BtcNetwork
    params*: SessionParams        ## the participants' host keys (in ceremony order) and t
    threshPk*: seq[byte]          ## 33-byte compressed threshold key (the output key)
    pubshares*: seq[seq[byte]]    ## each participant's public share, by participant id
    recoveryData*: seq[byte]      ## the ceremony's public recovery data
    xonly*: seq[byte]
    scriptPubKey*: seq[byte]
    address*: string
    chain*: string                ## CAIP-2
    accountId*: string            ## CAIP-10

  BtcFrostDriver* = ref object of Driver
    account*: FrostAccount
    pending: seq[seq[byte]]       ## the sighashes contributions currently verify against

proc frostAccount*(networkName: string, recoveryData: seq[byte]): FrostAccount =
  ## The account a ceremony made, from its public recovery data alone. Raises on data
  ## that is not a ChillDKG recovery record.
  let (o, p) = coordinatorRecover(recoveryData)
  let net = networkByName(networkName)
  let xonly = pointFromCompressed(o.threshPk).toXonly()
  result = FrostAccount(network: net, params: p, threshPk: o.threshPk, pubshares: o.pubshares,
                        recoveryData: recoveryData, xonly: xonly, scriptPubKey: p2trScriptPubKey(xonly),
                        address: encodeSegwitAddress(net.hrp, 1, xonly), chain: net.caip2)
  result.accountId = result.chain & ":" & result.address

proc frostAccountOfDisclosure*(chain, address, recoveryHex: string): tuple[ok: bool, account: FrostAccount, detail: string] =
  ## Re-derive a disclosed FROST account from its recovery data and check the address.
  try:
    let acct = frostAccount(networkByCaip2(chain).name, hexToBytes(recoveryHex))
    if acct.address != address.toLowerAscii():
      return (false, acct, "the address " & address & " does not commit to this ceremony's key (it derives " &
                           acct.address & ")")
    (true, acct, "the address is the threshold key of a " & $acct.params.t & "-of-" &
                 $acct.params.hostpubkeys.len & " ceremony")
  except CatchableError as e:
    (false, FrostAccount(), "not a FROST account: " & e.msg)

proc newBtcFrostDriver*(acct: FrostAccount): BtcFrostDriver = BtcFrostDriver(account: acct)

# ── the spend ─────────────────────────────────────────────────────────────────
const KeyPathInputWeight = 4 * (32 + 4 + 1 + 4) + 1 + 1 + 64   ## one 64-byte signature in the witness

proc buildFrostSpend*(acct: FrostAccount, utxos: seq[BtcUtxo], payTo: string, amount: uint64,
                      feeRate = 1, sequence = 0xfffffffd'u32, locktime = 0'u32): string =
  ## A btc-spend from the account's coins, sized for key-path witnesses.
  buildSpendFrom(acct.scriptPubKey, acct.address, KeyPathInputWeight, utxos, payTo, amount,
                 feeRate, sequence, locktime)

proc sighashesOf*(d: BtcFrostDriver, e: Effect): seq[seq[byte]] =
  let (t, amounts, spks) = spendOf(e)
  for i in 0 ..< t.inputs.len:
    result.add @(bip341Sighash(t, i, amounts, spks, SighashDefault))

method describe*(d: BtcFrostDriver): DriverDescriptor =
  DriverDescriptor(rounds: 2, serializationDomain: FrostDomain, finality: finExternal,
                   threshold: d.account.params.t)

method environment*(d: BtcFrostDriver): string = d.account.chain

method canonicalize*(d: BtcFrostDriver, e: Effect): Materialization =
  var hs: seq[CborValue]
  try:
    for h in d.sighashesOf(e): hs.add cbBytes(h)
  except BtcError as err:
    return Materialization(bytes: encode(cbArray(@[cbText(FrostDomain), cbText("invalid: " & err.msg)])))
  d.pending = hs.mapIt(it.b)
  Materialization(bytes: encode(cbArray(@[cbText(FrostDomain), cbText(d.account.chain), cbArray(hs)])))

proc sighashesIn(m: Materialization): seq[seq[byte]] =
  try:
    let v = decode(m.bytes)
    if v.kind == ckArray and v.arr.len == 3 and v.arr[2].kind == ckArray:
      for h in v.arr[2].arr: result.add h.b
  except CatchableError: discard

method expectMaterialization*(d: BtcFrostDriver, m: Materialization) = d.pending = sighashesIn(m)

# ── the two rounds' contributions ─────────────────────────────────────────────
proc mapGet(m: CborValue, key: string): CborValue =
  if m.kind != ckMap: return cbNull()
  for (k, v) in m.pairs:
    if k.kind == ckText and k.t == key: return v
  cbNull()

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

proc bytesList(v: CborValue): seq[seq[byte]] =
  if v.kind != ckArray: return
  for x in v.arr:
    if x.kind != ckBytes: return @[]
    result.add x.b

proc validNonce(n: seq[byte]): bool =
  if n.len != 66: return false
  try:
    discard nonceAgg(@[n])
    true
  except CatchableError: false

type Round2* = object
  signer*: seq[byte]
  set*: seq[(seq[byte], seq[seq[byte]])]
  psigs*: seq[seq[byte]]

proc contributionRound*(c: Contribution): int =
  ## 1 or 2 by the payload's own tag; 0 if it is not a FROST contribution.
  try:
    let r = decode(c.bytes).mapGet("r")
    if r.kind == ckUint and r.u in [1'u64, 2'u64]: int(r.u) else: 0
  except CatchableError: 0

proc decodeRound1Nonces*(c: Contribution): seq[seq[byte]] =
  ## A round-1 contribution's public nonces, one per input.
  bytesList(decode(c.bytes).mapGet("nonces"))

proc round2Of*(c: Contribution): Round2 =
  let v = decode(c.bytes)
  result.signer = v.mapGet("signer").b
  for e in v.mapGet("set").arr:
    result.set.add (e.mapGet("signer").b, bytesList(e.mapGet("nonces")))
  result.psigs = bytesList(v.mapGet("psigs"))

proc verifyAgainst(d: BtcFrostDriver, hashes: seq[seq[byte]], c: Contribution, wantRound = 0): string =
  ## The signer's host key hex if `c` is a valid contribution over `hashes`, else "".
  let a = d.account
  if hashes.len == 0: return ""
  var v: CborValue
  try: v = decode(c.bytes)
  except CatchableError: return ""
  let round = contributionRound(c)
  if round == 0 or (wantRound > 0 and round != wantRound): return ""
  let signer = v.mapGet("signer")
  if signer.kind != ckBytes or a.params.hostpubkeys.find(signer.b) < 0: return ""
  if round == 1:
    let ns = bytesList(v.mapGet("nonces"))
    if ns.len != hashes.len or not ns.allIt(validNonce(it)): return ""
    return toHex(signer.b)
  var r2: Round2
  try: r2 = round2Of(c)
  except CatchableError: return ""
  if r2.set.len != a.params.t or r2.psigs.len != hashes.len: return ""
  var ids: seq[int]
  for (h, ns) in r2.set:
    let id = a.params.hostpubkeys.find(h)
    if id < 0 or id in ids or ns.len != hashes.len or not ns.allIt(validNonce(it)): return ""
    ids.add id
  let me = r2.set.mapIt(it[0]).find(signer.b)
  if me < 0: return ""
  for j, h in hashes:
    var ok = false
    try:
      ok = partialSigVerify(r2.psigs[j], r2.set.mapIt(it[1][j]), a.params.hostpubkeys.len, a.params.t,
                            ids, ids.mapIt(a.pubshares[it]), a.threshPk, @[], @[], h, me)
    except CatchableError: ok = false
    if not ok: return ""
  toHex(signer.b)

method verifyContribution*(d: BtcFrostDriver, c: Contribution, round: int): bool =
  d.verifyAgainst(d.pending, c, round).len > 0

method identifyContributor*(d: BtcFrostDriver, m: Materialization, c: Contribution): string =
  d.verifyAgainst(sighashesIn(m), c)

# ── settlement: aggregate one set into one signature per input ────────────────
proc finalizeFrostSpend*(d: BtcFrostDriver, e: Effect, contributions: seq[Contribution]): BtcTx =
  ## The spend with every input's witness one aggregate BIP-340 signature, from a signer
  ## set every one of whose t members contributed a valid round-2 partial under it. The
  ## aggregate is verified under the account key before it is used. Raises BtcError when
  ## no set is complete.
  let a = d.account
  var (t, _, _) = spendOf(e)
  let hashes = d.sighashesOf(e)
  var groups: seq[(seq[(seq[byte], seq[seq[byte]])], seq[Round2])]
  for c in contributions:
    if contributionRound(c) != 2 or d.verifyAgainst(hashes, c, 2).len == 0: continue
    let r2 = round2Of(c)
    var placed = false
    for g in groups.mitems:
      if g[0] == r2.set:
        if not g[1].anyIt(it.signer == r2.signer): g[1].add r2
        placed = true
    if not placed: groups.add (r2.set, @[r2])
  for (set, parts) in groups:
    if parts.len < a.params.t: continue
    let ids = set.mapIt(a.params.hostpubkeys.find(it[0]))
    var sigs: seq[seq[byte]]
    for j, h in hashes:
      var psigs: seq[seq[byte]]
      for (host, _) in set:
        for p in parts:
          if p.signer == host: psigs.add p.psigs[j]
      let ctx = SessionContext(n: a.params.hostpubkeys.len, t: a.params.t, ids: ids,
                               pubshares: some(ids.mapIt(a.pubshares[it])), threshPk: a.threshPk,
                               aggnonce: nonceAgg(set.mapIt(it[1][j])), msg: h)
      let sig = partialSigAgg(psigs, ctx)
      if not schnorrVerify(sig, h, a.xonly): raise newException(BtcError, "the aggregate does not verify")
      sigs.add sig
    for i in 0 ..< t.inputs.len: t.inputs[i].witness = @[sigs[i]]
    return t
  raise newException(BtcError, "no signer set has all " & $a.params.t & " partial signatures")

proc completeSigners*(d: BtcFrostDriver, e: Effect, contributions: seq[Contribution]): int =
  ## How many signers the most complete round-2 set has (for "have k of t").
  let hashes = d.sighashesOf(e)
  var best = 0
  var sets: seq[(seq[(seq[byte], seq[seq[byte]])], seq[seq[byte]])]
  for c in contributions:
    if contributionRound(c) != 2 or d.verifyAgainst(hashes, c, 2).len == 0: continue
    let r2 = round2Of(c)
    var placed = false
    for s in sets.mitems:
      if s[0] == r2.set:
        if r2.signer notin s[1]: s[1].add r2.signer
        placed = true
    if not placed: sets.add (r2.set, @[r2.signer])
  for s in sets: best = max(best, s[1].len)
  best

# ── checks, profile, manifest ─────────────────────────────────────────────────
method signRefusal*(d: BtcFrostDriver, e: Effect): string =
  ## Before anyone signs: only this account's coins, the declared fee exactly inputs −
  ## outputs, no dust (the same rules as the script multisigs).
  spendRefusal(e, d.account.scriptPubKey)

method profile*(d: BtcFrostDriver): FamilyProfile =
  ## The registry's btc.frost-bip445: an aggregate threshold scheme, two rounds, secret
  ## state (shares, nonces), a key ceremony, and nothing about the policy or the signers
  ## ever on chain. Draft maturity: BIP-445 and ChillDKG are drafts, and this port is not
  ## constant time.
  FamilyProfile(declared: true, family: FrostFamily, settlement: "bitcoin",
    locus: loAggregate, scheme: scAggregateThreshold, commits: cmContent, binding: bdImplicit,
    ordering: orUtxo, expiry: exNone, setup: suDkg, signerChange: chNewAddress,
    revealsPolicy: rvNever, revealsSigners: rvNever, revealsEffect: evPublic,
    approverCost: acNone, rounds: 2, secretState: true, maturity: maDraft,
    chain: d.account.chain, account: d.account.accountId, k: d.account.params.t,
    n: d.account.params.hostpubkeys.len, bypassesKnown: true)

method manifest*(d: BtcFrostDriver, effect: Effect): ActionManifest =
  ## Needs the chain reachable and a share of the ceremony (a host key in the keystore);
  ## touches every input's coins. At spend the chain sees ONE signature: the outputs and
  ## the inputs, never the policy or who signed.
  var touches = @[touch(d.account.chain, tmWrite)]
  try:
    let (t, _, _) = spendOf(effect)
    for i in t.inputs:
      var r = i.prevout.txid
      for x in 0 ..< 16: swap(r[x], r[31 - x])
      touches.add touch("utxo:" & toHex(r) & ":" & $i.prevout.vout, tmWrite)
  except BtcError: discard
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "bitcoind-rpc"),
                    req(rqAuthority, "frost-share", rpContributor)],
    discloses: @[row("outputs", obChainObserver), row("inputs", obChainObserver),
                 row("signed-tx", obRpcProvider)],
    touches: touches)
