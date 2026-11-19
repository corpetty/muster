## The lez-msig driver (epic exo-0d3, docs/design/lez-msig.md), family `lez.msig`: an M-of-N
## multisig on LEZ whose program verifies its members' approvals itself, at execution (RFP R.1).
##
## Nobody votes on chain. Each member holds a per-multisig APPROVAL KEY (BIP-340), derived in
## their keystore under `msigLabel(createKey)` and never exported. A proposal is signed in the
## room; one transaction carries it with its approvals, and the program checks them. Behind the
## Driver seam:
##   * the ACCOUNT is the multisig's PDA, disclosed with its config. A public PDA is re-derived
##     from (program, create key) and refused if it differs. The config is the one the chain
##     held when it was disclosed: the program's own state is what counts, and settlement
##     re-reads it;
##   * the EFFECT is the proposal's exact borsh bytes (`muster.effect.lez-msig.v1`). The card
##     shows their decode, so what a member sees is what their approval signs (RFP U.6);
##   * the MATERIALIZATION commits to the proposal id under the chain (invariant 1). The
##     proposal itself commits to the zone tag, the account, the config epoch, the nonce and
##     the expiry (invariant 2);
##   * a CONTRIBUTION is {signer, sig}: a BIP-340 signature by a member's approval key over
##     the approve message. It counts only for a member holding APPROVE, or for the proposer;
##   * the contributor is named "msig:<x-only key>", and attests with that same key.
##   * a SPEND under a spending limit (`muster.effect.lez-msig-spend.v1`, exo-0d3.12) is the
##     one bypass of the quorum: its effect is the spend's exact bytes, only its limit's signers
##     count, and its threshold is the limit's.
## Settlement (settlement.nim, LezMsigSettlement) re-reads the state, chooses Execute, Queue
## or ExecuteQueued, and sends one public transaction from the settling member's own funded
## account. The private posture (a group-owned private PDA) is proved, not built here: it is
## its own family, and arrives with the prover seam.

import std/[json, options, strutils, sequtils, algorithm]
import stint
import ../dcbor/dcbor
import ../intents/materialization
import ../crypto/keystore
import ../crypto/account_labels
import ./driver
import ./manifest
import ./profile
import ./inapp
import ../lez/msig

const
  LezMsigFamily* = "lez.msig"
  LezMsigPrivateFamily* = "lez.msig-private"   ## the private posture: a group-owned private PDA (exo-efa)
  LezMsigSchema* = "muster.effect.lez-msig.v1"
  LezMsigSpendSchema* = "muster.effect.lez-msig-spend.v1"   ## a spend under a limit (exo-0d3.12)
  ApproveDomain = "lez.msig.approve.v1"
  SpendDomain = "lez.msig.spend.v1"
  ContributorPrefix* = "msig:"

type
  LezMsigAccount* = object
    chain*: string            ## CAIP-2 ("lez:local", "lez:testnet")
    program*: seq[byte]       ## the program's account id (its program_loader header)
    createKey*: seq[byte]
    zone*: seq[byte]          ## the zone tag the state holds (invariant 2)
    address*: seq[byte]       ## the multisig's PDA
    accountId*: string        ## CAIP-10: "<chain>:<address hex>"
    epoch*: uint64            ## the config epoch the disclosure read
    config*: MsigConfig
    private*: bool            ## a group-owned private PDA: its state is a note only members read

  LezMsigDriver* = ref object of Driver
    account*: LezMsigAccount
    pending: seq[byte]        ## the approve message contributions currently verify against
    pendingSigners: seq[Key32] ## for a spend: the limit's signers, the only keys that count

proc msigLabel*(createKey: openArray[byte]): string =
  ## The keystore label of THIS member's approval key for one multisig: one key per
  ## multisig, so two multisigs never share an approver key on chain.
  "lez-msig/" & hexOf(createKey)

proc unhx(s: string): seq[byte] =
  var h = s.strip()
  if h.len >= 2 and h[0] == '0' and h[1] in {'x', 'X'}: h = h[2 .. ^1]
  if h.len mod 2 != 0: raise newException(ValueError, "odd-length hex")
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc configJsonOf*(a: LezMsigAccount): string =
  ## What a disclosure carries as its config: enough to re-derive the account and read its
  ## rules.
  $(%*{"program": hexOf(a.program), "createKey": hexOf(a.createKey), "zone": hexOf(a.zone),
       "placement": (if a.private: "private" else: "public"), "epoch": $a.epoch, "config": hexOf(borsh(a.config))})

proc lezMsigAccountOf*(chain, address, config: string): tuple[ok: bool, account: LezMsigAccount, detail: string] =
  ## Re-derive the account a member disclosed: the address must be the public PDA its config
  ## derives, and the config must be one the program would accept.
  try:
    let c = parseJson(config)
    let placement = c{"placement"}.getStr("public")
    if placement notin ["public", "private"]:
      return (false, LezMsigAccount(), "unknown placement " & placement)
    let program = unhx(c{"program"}.getStr())
    let createKey = unhx(c{"createKey"}.getStr())
    let zone = unhx(c{"zone"}.getStr())
    if program.len != 32 or createKey.len != 32 or zone.len != 32:
      return (false, LezMsigAccount(), "program, create key and zone are 32 bytes each")
    let cfg = decodeMsigConfig(unhx(c{"config"}.getStr()))
    if placement == "private":
      # a group-owned private PDA: its address takes the group's keys to derive, so only a member
      # holding the group secret checks it (through the prover's derive); here it is what was
      # disclosed, and the program's own derivation is what a private execution proves against
      let a = unhx(address)
      if a.len != 32: return (false, LezMsigAccount(), "a private multisig's address is 32 bytes")
      let acct = LezMsigAccount(chain: chain, program: program, createKey: createKey, zone: zone, address: a,
                                accountId: chain & ":" & hexOf(a), epoch: parseBiggestUInt(c{"epoch"}.getStr("0")),
                                config: cfg, private: true)
      if cfg.members.len == 0 or cfg.threshold == 0 or cfg.threshold > approvalWeight(cfg, cfg.members.mapIt(it.key)):
        return (false, acct, "the config's threshold does not fit its approvers")
      return (true, acct, "a private multisig of program " & hexOf(program) & ": " & $cfg.threshold & " of " &
                          $cfg.members.len & "; members holding the group secret check its address")
    let a = multisigPublic(program, createKey)
    let acct = LezMsigAccount(chain: chain, program: program, createKey: createKey, zone: zone, address: a,
                              accountId: chain & ":" & hexOf(a), epoch: parseBiggestUInt(c{"epoch"}.getStr("0")),
                              config: cfg)
    if hexOf(unhx(address)) != hexOf(a):
      return (false, acct, "the address " & address & " is not the PDA this program and create key derive (" & hexOf(a) & ")")
    if cfg.members.len == 0 or cfg.threshold == 0 or cfg.threshold > approvalWeight(cfg, cfg.members.mapIt(it.key)):
      return (false, acct, "the config's threshold does not fit its approvers")
    (true, acct, "the address is the PDA of program " & hexOf(program) & " / create key " & hexOf(createKey) &
                 ": " & $cfg.threshold & " of " & $cfg.members.len)
  except CatchableError as e:
    (false, LezMsigAccount(), "not a lez-msig account: " & e.msg)

proc newLezMsigDriver*(a: LezMsigAccount): LezMsigDriver = LezMsigDriver(account: a)

# ── the effect ────────────────────────────────────────────────────────────────
proc lezMsigEffect*(p: MsigProposal): string =
  ## The room's effect for a proposal: its exact bytes.
  $(%*{"effect": "lez-msig", "proposal": hexOf(borsh(p))})

proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc proposalOf*(e: Effect): MsigProposal =
  ## The proposal an effect carries; raises on anything but exact, canonical bytes.
  if e.schemaId != LezMsigSchema: raise newException(ValueError, "not a lez-msig effect")
  let b = e.fieldOf("proposal")
  if b.kind != ckBytes: raise newException(ValueError, "the effect carries no proposal")
  decodeProposal(b.b)

# ── a spend under a limit (exo-0d3.12, design §5): no quorum, no time lock ──────
## A limit lets k of its own signers move up to its amount per period. In the room a spend is
## an intent like a proposal, but its effect is the spend's exact bytes, its contributions are
## BIP-340 signatures over the spend message by the limit's signers, and its threshold is the
## limit's. It is the one bypass of the quorum, and the profile declares it (`bypasses`).
proc lezMsigSpendEffect*(s: MsigSpend): string =
  $(%*{"effect": "lez-msig-spend", "spend": hexOf(borsh(s))})

proc isSpend*(e: Effect): bool = e.schemaId == LezMsigSpendSchema

proc msigSpendOf*(e: Effect): MsigSpend =
  ## The spend an effect carries; raises on anything but exact, canonical bytes.
  if e.schemaId != LezMsigSpendSchema: raise newException(ValueError, "not a lez-msig spend")
  let b = e.fieldOf("spend")
  if b.kind != ckBytes: raise newException(ValueError, "the effect carries no spend")
  decodeSpend(b.b)

proc limitOf*(c: MsigConfig, id: uint32): Option[MsigLimit] =
  for l in c.limits:
    if l.id == id: return some(l)

proc spendRefusalOf(d: LezMsigDriver, s: MsigSpend): string =
  if s.multisig != d.account.address: return "the spend names another multisig (" & hexOf(s.multisig) & ")"
  if s.zone != d.account.zone: return "the spend names another zone"
  let l = d.account.config.limitOf(s.limit)
  if l.isNone: return "the multisig has no spending limit " & $s.limit
  if s.amount > l.get.amount: return "the spend is over the limit's " & $l.get.amount & " per period"
  if s.amount == 0.u128: return "the spend moves nothing"
  ""

proc refusalOf(d: LezMsigDriver, p: MsigProposal): string =
  if p.multisig != d.account.address: return "the proposal names another multisig (" & hexOf(p.multisig) & ")"
  if p.zone != d.account.zone: return "the proposal names another zone"
  if d.account.config.memberOf(p.proposer).isNone: return "the proposer is not a member"
  if (d.account.config.memberOf(p.proposer).get.roles and RolePropose) == 0: return "the proposer may not propose"
  ""

method describe*(d: LezMsigDriver): DriverDescriptor =
  ## The threshold as a count of approvals: exact when every weight is 1; with weights, the
  ## fewest members who could reach it (settlement sums the real weight).
  var ws = d.account.config.members.filterIt((it.roles and RoleApprove) != 0).mapIt(int(it.weight))
  ws.sort(SortOrder.Descending)
  var need, sum = 0
  for w in ws:
    if sum >= int(d.account.config.threshold): break
    sum += w
    inc need
  DriverDescriptor(rounds: 1, serializationDomain: ApproveDomain, finality: finExternal, threshold: max(need, 1))

method describeFor*(d: LezMsigDriver, e: Effect): DriverDescriptor =
  ## A proposer without APPROVE must still sign, and does not count: one more signature. A
  ## spend needs its limit's threshold of the limit's signers.
  if e.isSpend:
    try:
      let l = d.account.config.limitOf(msigSpendOf(e).limit)
      if l.isSome:
        return DriverDescriptor(rounds: 1, serializationDomain: SpendDomain, finality: finExternal,
                                threshold: max(int(l.get.threshold), 1))
    except CatchableError: discard
  result = d.describe()
  try:
    let m = d.account.config.memberOf(proposalOf(e).proposer)
    if m.isSome and (m.get.roles and RoleApprove) == 0: inc result.threshold
  except CatchableError: discard

method environment*(d: LezMsigDriver): string = d.account.chain

method canonicalize*(d: LezMsigDriver, e: Effect): Materialization =
  ## The bytes an approver commits to: the proposal id, under the domain and the chain. A
  ## proposal that does not decode, or names another multisig, canonicalizes to a sentinel
  ## no signature matches (signRefusal says why). A spend commits to its spend message and its
  ## limit: [spend domain, chain, the message, the limit id].
  if e.isSpend:
    var sp: MsigSpend
    try: sp = msigSpendOf(e)
    except CatchableError as err:
      return Materialization(bytes: encode(cbArray(@[cbText(SpendDomain), cbText("invalid: " & err.msg)])))
    let why = d.spendRefusalOf(sp)
    if why.len > 0:
      return Materialization(bytes: encode(cbArray(@[cbText(SpendDomain), cbText("invalid: " & why)])))
    d.pending = spendMsg(sp)
    d.pendingSigners = d.account.config.limitOf(sp.limit).get.signers
    return Materialization(bytes: encode(cbArray(@[cbText(SpendDomain), cbText(d.account.chain), cbBytes(d.pending),
                                                   cbUint(uint64(sp.limit))])))
  d.pendingSigners = @[]
  var p: MsigProposal
  try: p = proposalOf(e)
  except CatchableError as err:
    return Materialization(bytes: encode(cbArray(@[cbText(ApproveDomain), cbText("invalid: " & err.msg)])))
  let why = d.refusalOf(p)
  if why.len > 0:
    return Materialization(bytes: encode(cbArray(@[cbText(ApproveDomain), cbText("invalid: " & why)])))
  let id = proposalId(p)
  d.pending = approveMsg(id)
  Materialization(bytes: encode(cbArray(@[cbText(ApproveDomain), cbText(d.account.chain), cbBytes(id)])))

proc signedFor(d: LezMsigDriver, m: Materialization): tuple[msg: seq[byte], signers: seq[Key32]] =
  ## What a contribution to this materialization must sign, and, for a spend, the only keys
  ## that may sign it (its limit's signers).
  try:
    let v = decode(m.bytes)
    if v.kind != ckArray or v.arr.len < 3 or v.arr[0].kind != ckText or v.arr[2].kind != ckBytes or
       v.arr[2].b.len != 32: return
    if v.arr[0].t == ApproveDomain and v.arr.len == 3: return (approveMsg(v.arr[2].b), @[])
    if v.arr[0].t == SpendDomain and v.arr.len == 4 and v.arr[3].kind == ckUint:
      let l = d.account.config.limitOf(uint32(v.arr[3].u))
      if l.isSome: return (v.arr[2].b, l.get.signers)
  except CatchableError: discard

method expectMaterialization*(d: LezMsigDriver, m: Materialization) =
  let (msg, signers) = d.signedFor(m)
  d.pending = msg
  d.pendingSigners = signers

method signRefusal*(d: LezMsigDriver, e: Effect): string =
  if e.isSpend:
    try: return d.spendRefusalOf(msigSpendOf(e))
    except CatchableError as err: return "not a lez-msig spend: " & err.msg
  try: d.refusalOf(proposalOf(e))
  except CatchableError as err: "not a lez-msig proposal: " & err.msg

proc contributionOf*(signer, sig: seq[byte]): seq[byte] =
  encode(cbMap(@[(cbText("signer"), cbBytes(signer)), (cbText("sig"), cbBytes(sig))]))

proc signedOf*(c: Contribution): Option[MsigSigned] =
  try:
    let v = decode(c.bytes)
    var signer, sig: seq[byte]
    if v.kind != ckMap: return
    for (k, x) in v.pairs:
      if k.kind == ckText and k.t == "signer" and x.kind == ckBytes: signer = x.b
      if k.kind == ckText and k.t == "sig" and x.kind == ckBytes: sig = x.b
    if signer.len == 32 and sig.len == 64: return some(MsigSigned(key: signer, sig: sig))
  except CatchableError: discard

proc verifyAgainst(d: LezMsigDriver, msg: seq[byte], c: Contribution, signers: seq[Key32] = @[]): string =
  ## "msig:<key>" if the contribution is a valid approval by a member who holds APPROVE
  ## (a proposer's own signature is checked in settlement), or, for a spend, by one of its
  ## limit's `signers`; else "".
  if msg.len != 32: return ""
  let s = signedOf(c)
  if s.isNone: return ""
  if signers.len > 0:
    if s.get.key notin signers: return ""
  elif d.account.config.memberOf(s.get.key).isNone: return ""
  if not verifySig(s.get.key, msg, s.get.sig): return ""
  ContributorPrefix & hexOf(s.get.key)

method verifyContribution*(d: LezMsigDriver, c: Contribution, round: int): bool =
  d.verifyAgainst(d.pending, c, d.pendingSigners).len > 0

method identifyContributor*(d: LezMsigDriver, m: Materialization, c: Contribution): string =
  let (msg, signers) = d.signedFor(m)
  if msg.len != 32: return ""
  d.verifyAgainst(msg, c, signers)

method mayContribute*(d: LezMsigDriver, e: Effect, names: seq[string]): Eligibility =
  ## A member of this multisig, named by its approval key; for a spend, a signer of its limit.
  let mine = names.mapIt(it.toLowerAscii())
  if e.isSpend:
    try:
      let l = d.account.config.limitOf(msigSpendOf(e).limit)
      if l.isSome:
        for k in l.get.signers:
          if ContributorPrefix & hexOf(k) in mine: return elYes
    except CatchableError: discard
    return elNo
  for m in d.account.config.members:
    if ContributorPrefix & hexOf(m.key) in mine: return elYes
  elNo

proc myMsigLabel*(ks: Keystore, a: LezMsigAccount): string =
  ## The label of THIS member's approval key for the multisig: the key derived for it at its
  ## ceremony, or an account of theirs the room set it up with (exo-1f9), whichever the
  ## multisig's config holds. The derived one when it holds neither (the member is not in it).
  let own = msigLabel(a.createKey)
  labelAmong(ks, a.config.members.mapIt(it.key), @[own]).get(own)

method signInApp*(d: LezMsigDriver, e: Effect, ks: Keystore, attestDigest: array[32, byte]): InAppSig =
  ## The member's approval key for THIS multisig signs the approve message, and attests the
  ## room's record (P) with the same key: an approval and its attestation come from one key.
  ## A spend is signed by the member's key among its limit's signers.
  if e.isSpend:
    let sp = msigSpendOf(e)
    let l = d.account.config.limitOf(sp.limit)
    if l.isNone: raise newException(ValueError, "the multisig has no spending limit " & $sp.limit)
    let own = msigLabel(d.account.createKey)
    let label = labelAmong(ks, l.get.signers, @[own]).get(own)
    let key = ks.lezMemberKey(label)
    var msg: array[32, byte]
    let sm = spendMsg(sp)
    for i in 0 ..< 32: msg[i] = sm[i]
    return InAppSig(handled: true, contribution: contributionOf(key, ks.lezMemberSign(label, msg)),
                    attestation: ks.lezMemberSign(label, attestDigest), keyRef: "")
  let label = myMsigLabel(ks, d.account)
  let key = ks.lezMemberKey(label)
  var msg: array[32, byte]
  let id = proposalId(proposalOf(e))
  let am = approveMsg(id)
  for i in 0 ..< 32: msg[i] = am[i]
  InAppSig(handled: true, contribution: contributionOf(key, ks.lezMemberSign(label, msg)),
           attestation: ks.lezMemberSign(label, attestDigest), keyRef: "")

method profile*(d: LezMsigDriver): FamilyProfile =
  if d.account.private:
    # the private posture (exo-efa): the multisig is a group-owned private PDA. On chain an
    # execution is one privacy-preserving transaction: a nullifier, a commitment, a proof; no
    # member, no approval and no config appear. A public payee's credit shows its amount and
    # payee. The group secret is shared state the members hold.
    return FamilyProfile(declared: true, family: LezMsigPrivateFamily, settlement: "lez",
      locus: loContract, scheme: scSharedBytes, commits: cmContent, binding: bdExplicit,
      ordering: orDedup, expiry: exForced, setup: suRegister, signerChange: chInPlace,
      revealsPolicy: rvNever, revealsSigners: rvNever, revealsEffect: evPublic,
      approverCost: acNone, rounds: 1, secretState: false, maturity: maExperimental,
      chain: d.account.chain, account: d.account.accountId, k: d.describe().threshold,
      n: d.account.config.members.len, bypassesKnown: true,
      bypasses: (if d.account.config.limits.len > 0: @["spending-limit"] else: @[]))
  ## The public posture: a program checks k of n (contract locus) over one shared message;
  ## the approval commits to zone, account, epoch, nonce and expiry (explicit binding); a
  ## nonce is used once, in any order inside a window (dedup); every proposal expires;
  ## a create registers the config in the deployed program; members change in place (a
  ## config change, which voids older approvals). On chain, the config is public from
  ## creation, and the signers and the action at execution. Approving costs nothing: only
  ## the executor sends a transaction.
  FamilyProfile(declared: true, family: LezMsigFamily, settlement: "lez",
    locus: loContract, scheme: scSharedBytes, commits: cmContent, binding: bdExplicit,
    ordering: orDedup, expiry: exForced, setup: suRegister, signerChange: chInPlace,
    revealsPolicy: rvAtCreation, revealsSigners: rvAtSettle, revealsEffect: evPublic,
    approverCost: acNone, rounds: 1, secretState: false, maturity: maExperimental,
    chain: d.account.chain, account: d.account.accountId, k: d.describe().threshold,
    n: d.account.config.members.len, bypassesKnown: true,
    bypasses: (if d.account.config.limits.len > 0: @["spending-limit"] else: @[]))

method manifest*(d: LezMsigDriver, effect: Effect): ActionManifest =
  ## Needs the zone reachable and a member's approval key; touches the multisig's account,
  ## and the recipient of a transfer or a call's rows. At execution the chain sees the
  ## proposal, every approval and its key, and whoever sends it; the sequencer first.
  var touches = @[touch(d.account.chain, tmWrite), touch(d.account.accountId, tmWrite)]
  try:
    if effect.isSpend:
      touches.add touch(d.account.chain & ":" & hexOf(msigSpendOf(effect).to), tmWrite)
    else:
      let p = proposalOf(effect)
      case p.action.kind
      of akTransfer: touches.add touch(d.account.chain & ":" & hexOf(p.action.to), tmWrite)
      of akCall:
        for r in p.action.rows: touches.add touch(d.account.chain & ":" & hexOf(r.account), tmWrite)
      else: discard
  except CatchableError: discard
  if d.account.private:
    # proved by the lez_msig_module; the chain sees a nullifier, a commitment and a proof, and
    # only a public payee's credit (its amount and payee) in the clear
    return ActionManifest(declared: true, agreement: d.describeFor(effect),
      requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "lez-sequencer-rpc"),
                      req(rqModule, "lez_msig_module"), req(rqAuthority, "lez-msig-key", rpContributor)],
      discloses: @[row("payee-and-amount", obChainObserver), row("signed-tx", obRpcProvider)],
      touches: touches)
  ActionManifest(declared: true, agreement: d.describeFor(effect),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "lez-sequencer-rpc"),
                    req(rqAuthority, "lez-msig-key", rpContributor)],
    discloses: @[row("action", obChainObserver), row("approvals", obChainObserver),
                 row("signers", obChainObserver), row("executor", obChainObserver),
                 row("signed-tx", obRpcProvider)],
    touches: touches)
