## A split: the room agrees who owes what, and each person pays their own share
## (exo-a90.3; docs/design/split-the-bill.md). The first family with NO shared account —
## the "each" locus: one member fronted a bill, the effect names every debtor and their
## share, and the address to pay; nothing on a chain counts or enforces any of it.
##
## Behind the one Driver seam:
##   * the EFFECT has one spelling (§4.1): canonical decimal amounts in the asset's
##     smallest unit (dCBOR has no bignum, and wei outgrows uint64), shares sorted by the
##     debtor's room identity with none repeated, the creditor never a debtor, the shares
##     never more than the total (the creditor's own share is the rest), the chain the
##     policy's. Anything else is refused with its reason and canonicalizes to a sentinel
##     no signature can name (invariants 1, 5);
##   * the THRESHOLD is how many debtors the effect names (describeFor, §4.2), and an
##     agreement is a debtor's Ed25519 room-key signature over the materialization — the
##     signer set is decoded from the materialization itself, never the room roster, so a
##     member the split does not name can never agree and a later joiner never moves it;
##   * each debtor is a PART (§4.3): settled by that debtor, confirmed by the creditor, and
##     the transfer that settles it is derived here from the reviewed effect (invariant 1);
##   * the PROFILE is the each locus; the manifest says what each rail discloses (§6).
## One driver, two families, as btc_multisig.nim: evm.split and lez.split — the private
## split (exo-a90.9): a shielded payTo, the private rail, and every share a distinct amount
## so the creditor's scan can attribute each note without the chain naming its payer.

import std/[json, strutils, sequtils, algorithm]
import stint
import ../dcbor/dcbor
import ../crypto/curve25519
import ../intents/materialization
import ./driver
import ./manifest
import ./profile

const
  EvmSplitFamily* = "evm.split"
  LezSplitFamily* = "lez.split"
  SplitDomain* = "muster.split.v1"
  SplitSchema* = "muster.effect.split.v1"
  MaxMemo* = 280            ## bytes of room-only text

type
  SplitShare* = object
    who*: string            ## the debtor's room identity: 64-byte encryption identity, lowercase hex
    amount*: string         ## canonical decimal, the asset's smallest unit

  Split* = object
    chain*, asset*, total*, creditor*, payTo*, memo*: string
    shares*: seq[SplitShare]

  SplitDriver* = ref object of Driver
    family*: string         ## evm.split | lez.split
    chain*: string          ## the CAIP-2 chain this instance settles on (the policy's qualifier)
    roster*: seq[string]    ## the room's members (room identities) — the propose/sign gate only, never the fold
    pending: seq[byte]      ## the materialization contributions currently verify against

proc newSplitDriver*(family, chain: string, roster: seq[string] = @[]): SplitDriver =
  SplitDriver(family: family, chain: chain, roster: roster.mapIt(it.toLowerAscii()))

# ── helpers ────────────────────────────────────────────────────────────────────
proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc isLowerHex(s: string): bool =
  s.len > 0 and s.allIt(it in {'0'..'9', 'a'..'f'})

proc isRoomIdentity*(s: string): bool = s.len == 128 and isLowerHex(s)

proc isCanonDec*(s: string): bool =
  ## Digits only, no sign, no leading zero, and it fits 256 bits: the ONE spelling of a
  ## non-negative integer (invariant 5 — "030" is refused, never normalized).
  if s.len == 0 or s.len > 78 or not s.allIt(it in {'0'..'9'}): return false
  if s.len > 1 and s[0] == '0': return false
  try: $u256(s) == s
  except CatchableError: false

proc edOf(identity: string): Ed25519Pub =
  var b: seq[byte]
  for i in 0 ..< identity.len div 2: b.add byte(parseHexInt(identity[2*i .. 2*i+1]))
  encIdentityFromBytes(b).ed

proc partName*(identity: string): string =
  ## How the driver names a debtor as a contributor and a part — the Ed25519 half of the
  ## room identity, "ed:<hex>" (the convention every room-key driver and the attestation
  ## layer already use).
  "ed:" & hx(edOf(identity))

proc isErc20Asset*(a: string): bool =
  ## A token an Ethereum split may be paid in, in its one spelling: "erc20:" + a lowercase
  ## 0x address, never the zero address (exo-5ab).
  if not a.startsWith("erc20:0x") or a.len != 48: return false
  let h = a[8 .. ^1]
  h.allCharsInSet({'0' .. '9', 'a' .. 'f'}) and h != repeat('0', 40)

proc payToOk(family, payTo: string): bool =
  case family
  of EvmSplitFamily: payTo.len == 42 and payTo.startsWith("0x") and isLowerHex(payTo[2 .. ^1])
  of LezSplitFamily:
    # a shielded key node: the private split pays only a shielded address (§4.6)
    let p = payTo.split(':')
    p.len == 3 and p[0] == "priv" and isLowerHex(p[1]) and isLowerHex(p[2])
  else: false

# ── the effect ─────────────────────────────────────────────────────────────────
proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc textOf(e: Effect, name: string): string =
  let v = e.fieldOf(name)
  if v.kind == ckText: v.t else: ""

proc splitOf*(e: Effect): Split =
  ## The split an effect carries, as carried — validation is `refusal`'s.
  if e.schemaId != SplitSchema: raise newException(ValueError, "not a split")
  result = Split(chain: e.textOf("chain"), asset: e.textOf("asset"), total: e.textOf("total"),
                 creditor: e.textOf("creditor"), payTo: e.textOf("payTo"), memo: e.textOf("memo"))
  let sh = e.fieldOf("shares")
  if sh.kind == ckArray:
    for x in sh.arr:
      if x.kind != ckArray or x.arr.len != 2 or x.arr[0].kind != ckText or x.arr[1].kind != ckText:
        raise newException(ValueError, "a share is [who, amount]")
      result.shares.add SplitShare(who: x.arr[0].t, amount: x.arr[1].t)

proc refusal(d: SplitDriver, sp: Split): string =
  ## Why `sp` is not a split this driver will propose, sign or pay ("" = it is one).
  if sp.chain != d.chain:
    return "this split settles on " & (if sp.chain.len > 0: sp.chain else: "no chain") &
           "; its policy settles on " & d.chain
  if d.family == EvmSplitFamily and sp.asset != "ETH" and not isErc20Asset(sp.asset):
    return "an Ethereum split is paid in ETH or in a token named erc20:<0x address, lowercase> (asked: " &
           sp.asset & ")"
  if d.family == LezSplitFamily and sp.asset != "LEZ":
    return "only LEZ is split privately on " & d.chain & " so far (asked: " & sp.asset & ")"
  if not isCanonDec(sp.total): return "the total is not a canonical decimal: " & sp.total
  if sp.total == "0": return "the total must be more than zero"
  if not isRoomIdentity(sp.creditor): return "the creditor is not a room identity (64 bytes, lowercase hex)"
  if not payToOk(d.family, sp.payTo): return "payTo is not a " & d.family & " address in its one spelling: " & sp.payTo
  if sp.memo.len > MaxMemo: return "the memo is longer than " & $MaxMemo & " bytes"
  if sp.shares.len == 0: return "no one owes anything"
  var sum = 0.u256
  for i, s in sp.shares:
    if not isRoomIdentity(s.who): return "a debtor is not a room identity (64 bytes, lowercase hex)"
    if s.who == sp.creditor: return "the creditor cannot also owe the creditor"
    if i > 0 and s.who <= sp.shares[i-1].who: return "shares must be sorted by who, each debtor once"
    if not isCanonDec(s.amount): return "a share is not a canonical decimal: " & s.amount
    if s.amount == "0": return "every share must be more than zero"
    let before = sum
    sum = sum + u256(s.amount)
    if sum < before: return "the shares overflow"
  if sum > u256(sp.total): return "the shares add up to more than the total"
  if d.family == LezSplitFamily:
    # the chain names no payer on the private rail, so the AMOUNT is what lets the
    # creditor's scan tell whose note arrived (§4.7): no two shares may be equal
    var seen: seq[string]
    for s in sp.shares:
      if s.amount in seen:
        return "every share of a private split must differ, so the creditor can tell whose payment arrived " &
               "without the chain naming anyone (" & s.amount & " twice)"
      seen.add s.amount
  ""

proc validSplit(d: SplitDriver, e: Effect): tuple[ok: bool, split: Split, why: string] =
  try:
    let sp = splitOf(e)
    let why = d.refusal(sp)
    (why.len == 0, sp, why)
  except ValueError as err:
    (false, Split(), err.msg)

proc debtorsOf(mat: seq[byte]): seq[string] =
  ## The debtors a materialization names — decoded from the bytes this driver produced.
  ## A sentinel (a malformed split) names none, so nothing can agree to it.
  try:
    let v = decode(mat)
    if v.kind != ckArray or v.arr.len != 9 or v.arr[0].kind != ckText or v.arr[0].t != SplitDomain: return
    if v.arr[7].kind != ckArray: return
    for s in v.arr[7].arr:
      if s.kind == ckArray and s.arr.len == 2 and s.arr[0].kind == ckText: result.add s.arr[0].t
  except CatchableError: discard

# ── the Driver seam ────────────────────────────────────────────────────────────
method describe*(d: SplitDriver): DriverDescriptor =
  ## The family's one policy: a split needs at least one debtor. What a PROPOSAL needs is
  ## describeFor — every debtor it names.
  DriverDescriptor(rounds: 1, serializationDomain: SplitDomain, finality: finExternal, threshold: 1)

method describeFor*(d: SplitDriver, e: Effect): DriverDescriptor =
  result = d.describe()
  let (ok, sp, _) = d.validSplit(e)
  if ok: result.threshold = sp.shares.len

method environment*(d: SplitDriver): string = d.chain

method canonicalize*(d: SplitDriver, e: Effect): Materialization =
  ## dCBOR [domain, schema, chain, asset, total, creditor, payTo, [[who, amount]…], memo],
  ## the chain the driver's (the effect must name the same one). A malformed split is a
  ## sentinel no agreement can name.
  let (ok, sp, why) = d.validSplit(e)
  if not ok:
    return Materialization(bytes: encode(cbArray(@[cbText(SplitDomain), cbText("invalid: " & why)])))
  Materialization(bytes: encode(cbArray(@[
    cbText(SplitDomain), cbText(SplitSchema), cbText(d.chain), cbText(sp.asset), cbText(sp.total),
    cbText(sp.creditor), cbText(sp.payTo),
    cbArray(sp.shares.mapIt(cbArray(@[cbText(it.who), cbText(it.amount)]))),
    cbText(sp.memo)])))

method expectMaterialization*(d: SplitDriver, m: Materialization) = d.pending = m.bytes

proc agreerOf(mat: seq[byte], c: Contribution): string =
  ## "ed:<hex>" of the debtor whose room key signed `mat`, else "".
  if c.bytes.len != 64: return ""
  var sig: Ed25519Sig
  for i in 0 ..< 64: sig[i] = c.bytes[i]
  for who in debtorsOf(mat):
    try:
      let pk = edOf(who)
      if edVerify(pk, mat, sig): return "ed:" & hx(pk)
    except CatchableError: discard
  ""

method verifyContribution*(d: SplitDriver, c: Contribution, round: int): bool =
  agreerOf(d.pending, c).len > 0

method identifyContributor*(d: SplitDriver, m: Materialization, c: Contribution): string =
  agreerOf(m.bytes, c)

method signRefusal*(d: SplitDriver, e: Effect): string =
  ## The malformed-split refusal, and — on THIS client's propose / sign path only — a
  ## party who is not a member of the room: nobody could agree for them.
  let (ok, sp, why) = d.validSplit(e)
  if not ok: return why
  if d.roster.len > 0:
    if sp.creditor notin d.roster: return "the creditor is not a member of this room"
    for s in sp.shares:
      if s.who notin d.roster: return "a debtor (" & s.who[0 ..< 12] & "…) is not a member of this room"
  ""

# ── settlement in parts ────────────────────────────────────────────────────────
method settlementParts*(d: SplitDriver, e: Effect): seq[string] =
  let (ok, sp, _) = d.validSplit(e)
  if ok: sp.shares.mapIt(partName(it.who)) else: @[]

method partAuthor*(d: SplitDriver, e: Effect, part, step: string): string =
  ## "settled" by the debtor the part names; "confirmed" by the creditor, the one person
  ## the debt is owed to. Both named by room identity (invariant 9).
  let (ok, sp, _) = d.validSplit(e)
  if not ok: return ""
  for s in sp.shares:
    if partName(s.who) == part:
      return (case step
              of "settled": s.who
              of "confirmed": sp.creditor
              else: "")
  ""

method partTransfer*(d: SplitDriver, e: Effect, part: string): PartTransfer =
  ## The payment that settles `part`: its share, to payTo, in the split's asset, on the
  ## policy's chain — read from the reviewed effect, never supplied (invariant 1).
  let (ok, sp, why) = d.validSplit(e)
  if not ok: return PartTransfer(ok: false, error: why)
  for s in sp.shares:
    if partName(s.who) == part:
      return PartTransfer(ok: true, chain: d.chain, asset: sp.asset, to: sp.payTo, amount: s.amount)
  PartTransfer(ok: false, error: "not a part of this split")

# ── profile + manifest ─────────────────────────────────────────────────────────
method profile*(d: SplitDriver): FamilyProfile =
  ## The each locus (docs/design/split-the-bill.md §3): no shared account, the room holds
  ## the agreement, each debtor's payment is their own transaction on the policy's chain.
  ## evm.split: every payment is an EIP-155 transfer — payer, payee and amount public at
  ## settle. lez.split: the private rail — nothing names a payer, payee or amount.
  let lez = d.family == LezSplitFamily
  FamilyProfile(declared: true, family: d.family, settlement: (if lez: "lez" else: "evm"),
    locus: loEach, scheme: scSharedBytes, commits: cmContent,
    binding: (if lez: bdNone else: bdExplicit),
    ordering: orNone, expiry: exOptional, setup: suNone, signerChange: chFixed,
    revealsPolicy: rvNever, revealsSigners: (if lez: rvNever else: rvAtSettle),
    revealsEffect: (if lez: evShielded else: evPublic),
    approverCost: acNone, rounds: 1, secretState: false, maturity: maDemo,
    chain: d.chain, account: "", k: 1, n: 0, bypassesKnown: true)

method manifest*(d: SplitDriver, effect: Effect): ActionManifest =
  ## Needs: the chain, an RPC to pay and to confirm through (the payer's and the
  ## creditor's own, invariant 8); from each debtor, the room key the split names and a
  ## balance that covers their share; from the proposer, the address to be paid (bound to
  ## payTo). Discloses per rail (§6): on EVM every payment's payer, payee and amount — and,
  ## because several payments reach one address close together, the group itself.
  let (ok, sp, _) = d.validSplit(effect)
  let lez = d.family == LezSplitFamily
  var touches = @[touch(d.chain, tmWrite)]
  if ok: touches.add touch(d.chain & ":" & sp.payTo, tmWrite)
  # a token share is a call on the token contract: its balances are what move
  if ok and isErc20Asset(sp.asset): touches.add touch(d.chain & ":" & sp.asset[6 .. ^1], tmWrite)
  let asset = (if ok: sp.asset elif lez: "LEZ" else: "ETH")
  ActionManifest(declared: true, agreement: d.describeFor(effect),
    requirements: @[
      req(rqEnvironment, d.chain),
      (if lez: req(rqModule, "lez_core") else: req(rqInfra, "rpc")),
      req(rqAuthority, "split-party", rpContributor),
      req(rqAsset, "share", rpContributor, need(mcAsset, d.chain & "/" & asset)),
      req(rqAddress, "pay-to", rpProposer, need(mcAddress, d.chain, "payTo"))],
    discloses: (if lez: @[row("a-private-transfer", obChainObserver), row("signed-tx", obRpcProvider)]
                else: @[row("payer", obChainObserver), row("payee", obChainObserver),
                        row("amount", obChainObserver), row("group-linkage", obChainObserver),
                        row("signed-tx", obRpcProvider)]),
    touches: touches)

# ── composing a split ──────────────────────────────────────────────────────────
proc evenShares*(total, creditor: string, parties: seq[string],
                 creditorShares = true, distinctAmounts = false): seq[SplitShare] =
  ## Split `total` evenly: among `parties` and the creditor (listed or not) — "I paid for
  ## dinner, split it" — or, with `creditorShares = false`, among `parties` alone — "chip
  ## in for the gift I bought". Every debtor owes total div n, rounded DOWN; the creditor
  ## absorbs the remainder — at most n−1 of the smallest unit, visible as total − sum
  ## (§10.3). Sorted by who, each once: the one spelling the driver accepts. With
  ## `distinctAmounts` (the private split, §4.7) the i-th debtor owes i smallest units less, so
  ## every share differs and a received note is attributable by its amount alone — the
  ## creditor absorbs those few units too.
  var who: seq[string]
  for p in parties:
    let w = p.toLowerAscii()
    if w != creditor.toLowerAscii() and w notin who: who.add w
  who.sort()
  if who.len == 0: return
  let each = u256(total) div u256(who.len + (if creditorShares: 1 else: 0))
  for i, w in who:
    let off = (if distinctAmounts: u256(i) else: 0.u256)
    if distinctAmounts and off >= each: return @[]   # too small to tell apart: no valid private split
    result.add SplitShare(who: w, amount: $(each - off))

proc splitEffectJson*(chain, asset, total, creditor, payTo: string, shares: seq[SplitShare],
                      memo: string): string =
  ## The effect JSON a composer proposes: shares sorted by who, so the same split has one
  ## intent id on every host.
  var sh = shares
  sh.sort(proc (a, b: SplitShare): int = cmp(a.who, b.who))
  var arr = newJArray()
  for s in sh: arr.add %*{"who": s.who, "amount": s.amount}
  $(%*{"effect": "split", "chain": chain, "asset": asset, "total": total, "creditor": creditor,
       "payTo": payTo, "shares": arr, "memo": memo})
