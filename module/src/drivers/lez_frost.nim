## lez.frost-public-account (exo-55e): a LEZ public account owned by a FROST group. The
## account id is SHA-256("/LEE/v0.3/AccountId/Public/" ‖ x(Q)) of the ceremony's
## threshold key Q, with no tweak: the chain checks exactly that and a BIP-340 signature
## under x(Q) (verified on a v0.2.4 chain, lez_frost_account_e2e). The ceremony and the two
## rounds are btc.frost-bip445's (drivers/frost_group.nim, coordination/aggregate.nim);
## what is signed here is the LEZ public message hash.
##
##   EFFECT        lez-call v1 (the v0.2.4 line): {program, accounts, instruction (u32
##                 words), signers: [the account], nonces: [its nonce]}.
##                 lez-call v2 (the v0.3.0 line, exo-eb6.4 L3): {programAccount, shards
##                 (each row's program shard), instruction (borsh bytes), signers, nonces,
##                 fee {payer: the account, gasLimit, tip, maxFee}}: the group pays its own
##                 fee. Either way the nonce is read from the chain when proposing, and
##                 recorded in the log (invariant 10).
##   MATERIAL.     the LEZ message hash (lez/tx.nim) of exactly that call and nonce.
##   SETTLEMENT    the nonce re-read (refused if the chain moved past it, since a signature
##                 for an old nonce can never land), one aggregate signature, sent through
##                 the user's sequencer.
##
## Binding: a LEZ public message commits to no zone or chain id, so what binds a signature
## to this zone is the account's nonce and the program. Muster binds the environment in
## the room (invariant 2); the chain does not (the registry's exposure).

import std/[json, strutils, sequtils, options]
import stint
import ../dcbor/dcbor
import ../intents/materialization
import ./driver
import ./manifest
import ./profile
import ./frost_group
import ../bitcoin/tx                 # toHex / hexToBytes
import ../lez/tx as leztx
export frost_group

const LezFrostFamily* = "lez.frost-public-account"
const LezFrostDomain = "lee.public.frost-bip340.v1"

type
  LezFrostAccount* = object
    group*: FrostGroup
    chain*: string                ## CAIP-2, e.g. "lez:testnet"
    accountId*: seq[byte]         ## 32 bytes: the threshold key's public account
    address*: string              ## accountId, hex
    caip10*: string

  LezFrostDriver* = ref object of Driver
    account*: LezFrostAccount
    pending: seq[seq[byte]]

proc lezFrostAccount*(chain: string, recoveryData: seq[byte]): LezFrostAccount =
  let g = frostGroup(recoveryData)
  let id = publicAccountId(g.xonly)
  LezFrostAccount(group: g, chain: chain, accountId: id, address: toHex(id), caip10: chain & ":" & toHex(id))

proc lezFrostAccountOfDisclosure*(chain, address, recoveryHex: string): tuple[ok: bool, account: LezFrostAccount, detail: string] =
  ## Re-derive a disclosed LEZ FROST account from its recovery data and check the id.
  try:
    if not chain.startsWith("lez:"): return (false, LezFrostAccount(), "not a LEZ zone: " & chain)
    let acct = lezFrostAccount(chain, hexToBytes(recoveryHex))
    var given = address.toLowerAscii().strip()
    if given.startsWith("0x"): given = given[2 .. ^1]
    if acct.address != given:
      return (false, acct, "the account " & address & " is not this ceremony's key (it derives " & acct.address & ")")
    (true, acct, "the account is the threshold key of a " & $acct.group.params.t & "-of-" &
                 $acct.group.params.hostpubkeys.len & " ceremony")
  except CatchableError as e:
    (false, LezFrostAccount(), "not a LEZ FROST account: " & e.msg)

proc newLezFrostDriver*(acct: LezFrostAccount): LezFrostDriver = LezFrostDriver(account: acct)

# ── the call ──────────────────────────────────────────────────────────────────
proc lezFrostCallEffect*(program: seq[byte], accounts: seq[seq[byte]], words: seq[uint32], signer: seq[byte],
                         nonce: UInt128): string =
  ## A lez-call effect signed by `signer` at `nonce` (read from the chain: a recorded read).
  $(%*{"effect": "lez-call", "program": toHex(program), "accounts": accounts.mapIt(toHex(it)),
       "instruction": words.mapIt(int64(it)), "signers": [toHex(signer)], "nonces": [$nonce],
       "sources": {"nonces": "read"}})

proc lezFrostCallEffect3*(programAccount: seq[byte], shards: seq[LezShard], instruction: seq[byte],
                          signer: seq[byte], nonces: seq[UInt128], fee: Option[LezFee]): string =
  ## A lez-call effect on the LEZ v0.3.0 line, signed by `signer` at `nonces` (read from
  ## the chain: a recorded read), with its fee declaration.
  var j = %*{"effect": "lez-call", "lez": "v0.3", "programAccount": toHex(programAccount),
             "shards": shards.mapIt(%*{"account": toHex(it.account), "program": toHex(it.program)}),
             "instruction": toHex(instruction), "signers": [toHex(signer)], "nonces": nonces.mapIt($it),
             "sources": {"nonces": "read"}}
  if fee.isSome:
    let f = fee.get
    j["fee"] = %*{"payer": toHex(f.payer), "gasLimit": $f.gasLimit, "tip": $f.tip, "maxFee": $f.maxFee}
  $j

proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

type LezCall* = object
  v3*: bool                       ## the v0.3.0 line (lez-call v2)
  program*: seq[byte]             ## v1: the program id
  accounts*: seq[seq[byte]]       ## v1: the accounts
  signers*: seq[seq[byte]]
  nonces*: seq[UInt128]
  words*: seq[uint32]             ## v1: the instruction words
  programAccount*: seq[byte]      ## v2: the program, by account id
  shards*: seq[LezShard]          ## v2: each row's program shard
  instruction*: seq[byte]         ## v2: the instruction, borsh
  fee*: Option[LezFee]            ## v2: the fee declaration

proc mapGet(v: CborValue, key: string): CborValue =
  if v.kind == ckMap:
    for (k, x) in v.pairs:
      if k.kind == ckText and k.t == key: return x
  cbNull()

proc bytes32(v: CborValue, what: string): seq[byte] =
  if v.kind != ckBytes or v.b.len != 32: raise newException(ValueError, what & " is 32 bytes")
  v.b

proc callOf*(e: Effect): LezCall =
  ## The call a lez-call effect names; raises ValueError on anything malformed.
  if e.schemaId == "muster.effect.lez-call.v2":
    result.v3 = true
    result.programAccount = bytes32(e.fieldOf("programAccount"), "a program account")
    for s in e.fieldOf("shards").arr:
      result.shards.add LezShard(account: bytes32(s.mapGet("account"), "a shard's account"),
                                 program: bytes32(s.mapGet("program"), "a shard's program"))
    let ins = e.fieldOf("instruction")
    if ins.kind != ckBytes: raise newException(ValueError, "an instruction is bytes")
    result.instruction = ins.b
    for sgn in e.fieldOf("signers").arr: result.signers.add bytes32(sgn, "a signer")
    for n in e.fieldOf("nonces").arr:
      if n.kind != ckText: raise newException(ValueError, "a nonce is a decimal")
      result.nonces.add parse(n.t, UInt128)
    let f = e.fieldOf("fee")
    if f.kind == ckMap:
      let (g, t, m) = (f.mapGet("gasLimit"), f.mapGet("tip"), f.mapGet("maxFee"))
      if g.kind != ckText or t.kind != ckText or m.kind != ckText:
        raise newException(ValueError, "a fee's gas limit, tip and cap are decimals")
      result.fee = some LezFee(payer: bytes32(f.mapGet("payer"), "a fee payer"),
                               gasLimit: parseBiggestUInt(g.t).uint64, tip: parseBiggestUInt(t.t).uint64,
                               maxFee: parse(m.t, UInt128))
    return
  if e.schemaId != "muster.effect.lez-call.v1": raise newException(ValueError, "not a lez-call effect")
  let p = e.fieldOf("program")
  if p.kind != ckBytes or p.b.len != 32: raise newException(ValueError, "a program id is 32 bytes")
  result.program = p.b
  for a in e.fieldOf("accounts").arr:
    if a.kind != ckBytes or a.b.len != 32: raise newException(ValueError, "an account id is 32 bytes")
    result.accounts.add a.b
  for sgn in e.fieldOf("signers").arr:
    if sgn.kind != ckBytes or sgn.b.len != 32: raise newException(ValueError, "a signer is an account id")
    result.signers.add sgn.b
  for n in e.fieldOf("nonces").arr:
    if n.kind != ckText: raise newException(ValueError, "a nonce is a decimal")
    result.nonces.add parse(n.t, UInt128)
  for w in e.fieldOf("instruction").arr:
    if w.kind != ckUint or w.u > high(uint32).uint64: raise newException(ValueError, "an instruction word is a u32")
    result.words.add uint32(w.u)

proc messageOf*(c: LezCall): LezMessage =
  ## The v0.2.4 message of a v1 call.
  LezMessage(program: c.program, accounts: c.accounts, nonces: c.nonces, words: c.words)

proc message3Of*(c: LezCall): LezMessage3 =
  ## The v0.3.0 message of a v2 call.
  LezMessage3(programAccount: c.programAccount, shards: c.shards, nonces: c.nonces,
              instruction: c.instruction, fee: c.fee)

proc hashOf*(c: LezCall): array[32, byte] =
  ## What the group signs: the message hash of the call's own line.
  if c.v3: messageHash(message3Of(c)) else: messageHash(messageOf(c))

method frostGroupOf*(d: LezFrostDriver): tuple[ok: bool, group: FrostGroup] = (true, d.account.group)
method frostMessages*(d: LezFrostDriver, e: Effect): seq[seq[byte]] =
  try: @[@(hashOf(callOf(e)))] except CatchableError: @[]

method describe*(d: LezFrostDriver): DriverDescriptor =
  DriverDescriptor(rounds: 2, serializationDomain: LezFrostDomain, finality: finExternal,
                   threshold: d.account.group.params.t)

method environment*(d: LezFrostDriver): string = d.account.chain

method canonicalize*(d: LezFrostDriver, e: Effect): Materialization =
  let hs = d.frostMessages(e)
  if hs.len == 0:
    return Materialization(bytes: encode(cbArray(@[cbText(LezFrostDomain), cbText("invalid: not a lez-call")])))
  d.pending = hs
  Materialization(bytes: encode(cbArray(@[cbText(LezFrostDomain), cbText(d.account.chain),
                                          cbArray(hs.mapIt(cbBytes(it)))])))

proc hashesIn(m: Materialization): seq[seq[byte]] =
  try:
    let v = decode(m.bytes)
    if v.kind == ckArray and v.arr.len == 3 and v.arr[2].kind == ckArray:
      for h in v.arr[2].arr: result.add h.b
  except CatchableError: discard

method expectMaterialization*(d: LezFrostDriver, m: Materialization) = d.pending = hashesIn(m)

method verifyContribution*(d: LezFrostDriver, c: Contribution, round: int): bool =
  verifyFrost(d.account.group, d.pending, c, round).len > 0

method identifyContributor*(d: LezFrostDriver, m: Materialization, c: Contribution): string =
  verifyFrost(d.account.group, hashesIn(m), c)

method signRefusal*(d: LezFrostDriver, e: Effect): string =
  ## Before anyone signs: a well-formed call whose one signer is this account, at one nonce.
  var c: LezCall
  try: c = callOf(e)
  except CatchableError as err: return "not a LEZ call: " & err.msg
  if c.signers != @[d.account.accountId]: return "the call's signer is not this account"
  if c.nonces.len != 1: return "the call names one nonce, the account's"
  if c.v3:
    if c.instruction.len == 0: return "the call has no instruction"
    if c.fee.isNone: return "the call declares no fee: on LEZ v0.3 every transaction pays one"
    if c.fee.get.payer != d.account.accountId:
      return "the call's fee is paid by another account: the group pays its own fee here"
  elif c.words.len == 0: return "the call has no instruction"
  ""

method profile*(d: LezFrostDriver): FamilyProfile =
  ## The registry's lez.frost-public-account: an aggregate threshold scheme, two rounds,
  ## secret state, a key ceremony, reveals never; binding none (the exposure).
  FamilyProfile(declared: true, family: LezFrostFamily, settlement: "lez",
    locus: loAggregate, scheme: scAggregateThreshold, commits: cmContent, binding: bdNone,
    ordering: orSequence, expiry: exNone, setup: suDkg, signerChange: chNewAddress,
    revealsPolicy: rvNever, revealsSigners: rvNever, revealsEffect: evPublic,
    approverCost: acNone, rounds: 2, secretState: true, maturity: maDraft,
    chain: d.account.chain, account: d.account.caip10, k: d.account.group.params.t,
    n: d.account.group.params.hostpubkeys.len, bypassesKnown: true)

method manifest*(d: LezFrostDriver, effect: Effect): ActionManifest =
  ## Needs the user's LEZ sequencer (JSON-RPC, the `lez-rpc` setting: settlement sends the
  ## aggregate through it) and a share of the ceremony. On v0.2.4 no fee is charged; on
  ## v0.3 the group's account pays its own, so it must hold native LEZ (up to the declared
  ## cap; the unused part is refunded). Touches the group's account (its nonce), the
  ## program the call runs (read) and every account the call passes (each may be written)
  ## — each once, a chain in CAIP-2 and an account in CAIP-10 (exo-ec8). At settle the
  ## zone sees one signature by the account: the call, never the policy or who signed.
  let chain = d.account.chain
  var touches = @[touch(chain, tmWrite), touch(chain & ":" & d.account.address, tmWrite)]
  proc add(t: Touch) =
    if not touches.anyIt(it.target == t.target): touches.add t
  try:
    let c = callOf(effect)
    if c.v3:
      add touch(chain & ":" & toHex(c.programAccount), tmRead)   # the program it calls
      for s in c.shards: add touch(chain & ":" & toHex(s.account), tmWrite)
    else:
      add touch(chain & ":" & toHex(c.program), tmRead)       # the program it calls
      for a in c.accounts: add touch(chain & ":" & toHex(a), tmWrite)
  except CatchableError: discard
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, chain), req(rqInfra, "lez-rpc"),
                    req(rqAuthority, "frost-share", rpContributor)],
    discloses: @[row("call", obChainObserver), row("signed-tx", obRpcProvider)],
    touches: touches)
