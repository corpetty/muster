## lez.frost-public-account (exo-55e): a LEZ public account owned by a FROST group. The
## account id is SHA-256("/LEE/v0.3/AccountId/Public/" ‖ x(Q)) of the ceremony's
## threshold key Q, with no tweak: the chain checks exactly that and a BIP-340 signature
## under x(Q) (verified on a v0.2.4 chain, lez_frost_account_e2e). The ceremony and the two
## rounds are btc.frost-bip445's (drivers/frost_group.nim, coordination/aggregate.nim);
## what is signed here is the LEZ public message hash.
##
##   EFFECT        lez-call: {program, accounts, instruction (u32 words), signers: [the
##                 account], nonces: [its nonce]}. The nonce is read from the chain when
##                 proposing, and recorded in the log (invariant 10).
##   MATERIAL.     the LEZ message hash (lez/tx.nim) of exactly that call and nonce.
##   SETTLEMENT    the nonce re-read (refused if the chain moved past it, since a signature
##                 for an old nonce can never land), one aggregate signature, sent through
##                 the user's sequencer.
##
## Binding: a LEZ public message commits to no zone or chain id, so what binds a signature
## to this zone is the account's nonce and the program. Muster binds the environment in
## the room (invariant 2); the chain does not (the registry's exposure).

import std/[json, strutils, sequtils]
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

proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

type LezCall* = object
  program*: seq[byte]
  accounts*: seq[seq[byte]]
  signers*: seq[seq[byte]]
  nonces*: seq[UInt128]
  words*: seq[uint32]

proc callOf*(e: Effect): LezCall =
  ## The call a lez-call effect names; raises ValueError on anything malformed.
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
  LezMessage(program: c.program, accounts: c.accounts, nonces: c.nonces, words: c.words)

method frostGroupOf*(d: LezFrostDriver): tuple[ok: bool, group: FrostGroup] = (true, d.account.group)
method frostMessages*(d: LezFrostDriver, e: Effect): seq[seq[byte]] =
  try: @[@(messageHash(messageOf(callOf(e))))] except CatchableError: @[]

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
  if c.words.len == 0: return "the call has no instruction"
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
  ## Needs the zone reachable and a share of the ceremony; touches the account (its nonce)
  ## and every account the call names. At settle the zone sees one signature by the
  ## account: the call, never the policy or who signed.
  var touches = @[touch(d.account.chain, tmWrite), touch("lez:" & d.account.address, tmWrite)]
  try:
    for a in callOf(effect).accounts: touches.add touch("lez:" & toHex(a), tmWrite)
  except CatchableError: discard
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "lez-account"),
                    req(rqAuthority, "frost-share", rpContributor)],
    discloses: @[row("call", obChainObserver), row("signed-tx", obRpcProvider)],
    touches: touches)
