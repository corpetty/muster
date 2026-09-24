## The LEZ multisig program as a driver (exo-6cbe, Phase C3): family lez.multisig-program,
## the VOTE locus on Logos's own chain (logos-co/lez-multisig, Squads-v4-style).
##
## Unlike the Safe or Bitcoin, nobody signs shared bytes here. A proposal lives ON CHAIN
## at its own PDA; each member approves with their OWN transaction, which their LEZ
## wallet signs (never muster, invariant 3); the program counts the votes and executes
## at k. So, behind the same Driver seam:
##   * the ACCOUNT is disclosed with its config (program, create_key, PDA scheme); the
##     state address must be the PDA the config derives — checked, never trusted;
##   * the EFFECT is a POINTER — proposal #i — plus the content the room reviews there
##     (the target program, instruction, accounts, PDA seeds, authorized indices);
##     canonicalize commits to both, under the account (invariant 1);
##   * S5: before a member votes, the live path reads proposal #i from the chain and
##     `checkRead` refuses bytes that differ from what the room reviewed in any field, or
##     a proposal no longer active — the pointer is re-derived, never followed blind;
##   * a CONTRIBUTION is a vote receipt: which on-chain account voted, in which
##     transaction, FOR which materialization; it counts only for a member and only for
##     this pointer. The chain is the authority on the tally: settlement recounts there.
## The profile is the registry's: vote locus, own transaction, pointer, binding none — a
## LEZ public message commits to no zone or chain id, so the card marks the binding
## exposed (muster binds the environment in the room; the chain does not). And one way
## around the rule is known (logos-co/lez-multisig#40, open): a proposal records how MANY
## target accounts its call takes, not which, so whoever executes chooses them — an
## approved transfer can be executed to another recipient. Muster's own settlement
## passes the accounts the room reviewed; the chain does not hold anyone else to them.

import std/[json, strutils, sequtils]
import ../dcbor/dcbor
import ../hashing/sha256
import ../intents/materialization
import ./driver
import ./manifest
import ./profile
import ../lez/multisig

const LezMultisigFamily* = "lez.multisig-program"
const PointerDomain = "lez.multisig.pointer.v1"
const ReceiptDomain = "lez.multisig.vote.v1"

type
  LezMultisigAccount* = object
    chain*: string            ## CAIP-2 ("lez:testnet")
    scheme*: PdaScheme
    program*: seq[byte]       ## the program's identity in the scheme
    createKey*: seq[byte]
    statePda*: seq[byte]
    members*: seq[seq[byte]]  ## LEZ account ids, 32 bytes
    threshold*: int
    accountId*: string        ## CAIP-10: "<chain>:<state pda hex>"
    layout*: ProposalLayout   ## the program build: count-only (#40 open) or account-ids (#41)

  LezMultisigDriver* = ref object of Driver
    account*: LezMultisigAccount
    pending: seq[byte]        ## the materialization contributions currently verify against

proc hx(b: seq[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))
proc unhx(s: string): seq[byte] =
  var h = s.strip()
  if h.len >= 2 and h[0] == '0' and h[1] in {'x', 'X'}: h = h[2 .. ^1]
  if h.len mod 2 != 0: raise newException(ValueError, "odd-length hex")
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
proc b32(s: string): seq[byte] =
  result = unhx(s)
  if result.len != 32: raise newException(ValueError, "not 32 bytes: " & s)

proc lezMultisigAccountFromParts*(chain, address, config: string, members: seq[string],
                                  threshold: int): tuple[ok: bool, account: LezMultisigAccount, detail: string] =
  ## Re-derive the account a member disclosed: the state address must be the PDA its
  ## config derives, and k must fit n. Anything else is refused, with the reason.
  try:
    if config.len == 0: return (false, LezMultisigAccount(), "no config to derive the account from")
    let c = parseJson(config)
    let scheme = parsePdaScheme(c{"pda"}.getStr("lee-v0.2"))
    let program = b32(c{"program"}.getStr())
    let createKey = b32(c{"createKey"}.getStr())
    let layout = parseProposalLayout(c{"layout"}.getStr("count-only"))
    let state = statePda(scheme, program, createKey)
    var acct = LezMultisigAccount(chain: chain, scheme: scheme, program: program, createKey: createKey,
                                  statePda: state, members: members.mapIt(b32(it)), threshold: threshold,
                                  accountId: chain & ":" & hx(state), layout: layout)
    var given = address.toLowerAscii().strip()
    if given.startsWith("0x"): given = given[2 .. ^1]
    if hx(state) != given:
      return (false, acct, "the address " & address & " is not the state PDA this config derives (" & hx(state) & ")")
    if acct.members.len == 0 or threshold < 1 or threshold > acct.members.len:
      return (false, acct, "k=" & $threshold & " does not fit " & $acct.members.len & " members")
    (true, acct, "the address is the state PDA of program " & hx(program) & " / create_key " & hx(createKey))
  except CatchableError as e:
    (false, LezMultisigAccount(), "not a LEZ multisig account: " & e.msg)

proc newLezMultisigDriver*(a: LezMultisigAccount): LezMultisigDriver = LezMultisigDriver(account: a)

# ── the pointer effect ─────────────────────────────────────────────────────────
proc lezProposalEffect*(index: uint64, a: LezAction): string =
  ## The room's effect for on-chain proposal #index with the content it reviews.
  $(%*{"effect": "lez-multisig-proposal", "index": index, "target": hx(a.target),
       "instruction": a.instruction.mapIt(int64(it)), "accounts": a.accounts.mapIt(hx(it)),
       "pdaSeeds": a.pdaSeeds.mapIt(hx(it)), "authorized": a.authorized.mapIt(int(it))})

proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc lezActionOf*(e: Effect): tuple[index: uint64, action: LezAction] =
  ## The pointer and content a lez-multisig-proposal effect carries; raises ValueError
  ## on anything malformed.
  if e.schemaId != "muster.effect.lez-multisig-proposal.v1": raise newException(ValueError, "not a LEZ multisig proposal")
  let idx = e.fieldOf("index")
  let target = e.fieldOf("target")
  if idx.kind != ckUint or idx.u == 0: raise newException(ValueError, "a proposal index is 1 or more")
  if target.kind != ckBytes or target.b.len != 32: raise newException(ValueError, "a target program is 32 bytes")
  result.index = idx.u
  result.action.target = target.b
  for (name, dest) in [("accounts", 0), ("pdaSeeds", 1)]:
    let v = e.fieldOf(name)
    if v.kind == ckArray:
      for x in v.arr:
        if x.kind != ckBytes or x.b.len != 32: raise newException(ValueError, name & " are 32 bytes each")
        if dest == 0: result.action.accounts.add x.b else: result.action.pdaSeeds.add x.b
  let ins = e.fieldOf("instruction")
  if ins.kind == ckArray:
    for x in ins.arr:
      if x.kind != ckUint or x.u > high(uint32).uint64: raise newException(ValueError, "an instruction is u32 words")
      result.action.instruction.add uint32(x.u)
  let au = e.fieldOf("authorized")
  if au.kind == ckArray:
    for x in au.arr:
      if x.kind != ckUint or x.u > 255: raise newException(ValueError, "authorized indices are bytes")
      result.action.authorized.add uint8(x.u)
  result.action.accountCount = result.action.accounts.len

method describe*(d: LezMultisigDriver): DriverDescriptor =
  DriverDescriptor(rounds: 1, serializationDomain: PointerDomain, finality: finExternal,
                   threshold: d.account.threshold)

method environment*(d: LezMultisigDriver): string = d.account.chain

method canonicalize*(d: LezMultisigDriver, e: Effect): Materialization =
  ## The pointer and the content the room reviews there, under this account. A malformed
  ## effect canonicalizes to a sentinel no receipt can name.
  var idx: uint64
  var a: LezAction
  try: (idx, a) = lezActionOf(e)
  except ValueError as err:
    return Materialization(bytes: encode(cbArray(@[cbText(PointerDomain), cbText("invalid: " & err.msg)])))
  Materialization(bytes: encode(cbArray(@[
    cbText(PointerDomain), cbText(d.account.chain), cbText($d.account.scheme),
    cbBytes(d.account.program), cbBytes(d.account.createKey), cbUint(idx),
    cbBytes(a.target), cbArray(a.instruction.mapIt(cbUint(uint64(it)))),
    cbArray(a.accounts.mapIt(cbBytes(it))), cbArray(a.pdaSeeds.mapIt(cbBytes(it))),
    cbArray(a.authorized.mapIt(cbUint(uint64(it))))])))

method expectMaterialization*(d: LezMultisigDriver, m: Materialization) = d.pending = m.bytes

# ── vote receipts ──────────────────────────────────────────────────────────────
proc mapGet(m: CborValue, key: string): CborValue =
  if m.kind != ckMap: return cbNull()
  for (k, v) in m.pairs:
    if k.kind == ckText and k.t == key: return v
  cbNull()

proc voteReceipt*(voter: seq[byte], index: uint64, tx: string, m: Materialization): Contribution =
  ## What a member's client publishes once their vote is on chain: which account voted, in
  ## which transaction, FOR which materialization (so it cannot count for another pointer).
  Contribution(bytes: encode(cbMap(@[
    (cbText("domain"), cbText(ReceiptDomain)), (cbText("for"), cbBytes(@(sha256(m.bytes)))),
    (cbText("index"), cbUint(index)), (cbText("tx"), cbText(tx)),
    (cbText("vote"), cbText("approve")), (cbText("voter"), cbBytes(voter))])))

proc receiptVoter(d: LezMultisigDriver, mat: seq[byte], c: Contribution): string =
  ## "lez:<voter>" if `c` is a member's approve receipt for `mat`, else ""
  var v: CborValue
  try: v = decode(c.bytes)
  except CatchableError: return ""
  if v.mapGet("domain").kind != ckText or v.mapGet("domain").t != ReceiptDomain: return ""
  let voter = v.mapGet("voter")
  let forH = v.mapGet("for")
  let vote = v.mapGet("vote")
  if voter.kind != ckBytes or voter.b notin d.account.members: return ""
  if forH.kind != ckBytes or mat.len == 0 or forH.b != @(sha256(mat)): return ""
  if vote.kind != ckText or vote.t != "approve": return ""
  "lez:" & hx(voter.b)

method verifyContribution*(d: LezMultisigDriver, c: Contribution, round: int): bool =
  d.receiptVoter(d.pending, c).len > 0

method identifyContributor*(d: LezMultisigDriver, m: Materialization, c: Contribution): string =
  d.receiptVoter(m.bytes, c)

method signRefusal*(d: LezMultisigDriver, e: Effect): string =
  try:
    discard lezActionOf(e)
    ""
  except ValueError as err: "not a LEZ multisig proposal: " & err.msg

# ── S5: the pointer's content, re-read ────────────────────────────────────────
method reads*(d: LezMultisigDriver, e: Effect): seq[string] = @["proposal"]

method checkRead*(d: LezMultisigDriver, e: Effect, name: string, value: seq[byte]): string =
  if name != "proposal": return "this driver declares no read named " & name
  var idx: uint64
  var a: LezAction
  try: (idx, a) = lezActionOf(e)
  except ValueError as err: return "not a LEZ multisig proposal: " & err.msg
  var p: Proposal
  try: p = decodeProposal(value, d.account.layout)
  except LezDecodeError as err: return "the on-chain proposal does not decode: " & err.msg
  if p.index != idx: return "the on-chain proposal is #" & $p.index & "; the room reviewed #" & $idx & " (index)"
  if p.createKey != d.account.createKey: return "the on-chain proposal belongs to another multisig"
  if p.hasConfig: return "the on-chain proposal is a config change, not the call the room reviewed"
  if p.action.target != a.target: return "the on-chain proposal calls another target program"
  if p.action.instruction != a.instruction: return "the on-chain proposal carries a different instruction"
  if p.action.accountCount != a.targetAccountCount:
    return "the on-chain proposal expects " & $p.action.accountCount & " target accounts; the room reviewed " &
           $a.targetAccountCount
  if d.account.layout == plAccountIds and p.action.accounts != a.accounts:
    return "the on-chain proposal names different target accounts"
  if p.action.pdaSeeds != a.pdaSeeds: return "the on-chain proposal proves different PDA seeds"
  if p.action.authorized != a.authorized: return "the on-chain proposal has different authorized target accounts"
  if p.status != psActive: return "the on-chain proposal is " & $p.status & " — no longer open to votes"
  ""

# ── profile + manifest ─────────────────────────────────────────────────────────
method profile*(d: LezMultisigDriver): FamilyProfile =
  ## The program keeps the rule (a vote locus): each member submits their own public
  ## transaction pointing at an on-chain proposal; the program counts and executes.
  FamilyProfile(declared: true, family: LezMultisigFamily, settlement: "lez",
    locus: loVote, scheme: scOwnTransaction, commits: cmPointer, binding: bdNone,
    ordering: orIndex, expiry: exNone, setup: suDeploy, signerChange: chInPlace,
    revealsPolicy: rvAtCreation, revealsSigners: rvPerApproval, revealsEffect: evPublic,
    approverCost: acPerVote, rounds: 1, secretState: false, maturity: maDemo,
    chain: d.account.chain, account: d.account.accountId, k: d.account.threshold,
    n: d.account.members.len, bypassesKnown: true,
    bypasses: (if d.account.layout == plAccountIds: @[]      # #41: the accounts are committed and bound
               else: @["the executor chooses the target accounts at execute — a proposal records only how many " &
                       "(logos-co/lez-multisig#40)"]))

method manifest*(d: LezMultisigDriver, effect: Effect): ActionManifest =
  ## Needs the zone reachable through lez_core, a funded account to pay each vote, and a
  ## member account of the multisig; every approval is a public transaction the chain
  ## (and the sequencer first) sees — who voted, on what, when.
  var touches = @[touch(d.account.chain, tmWrite)]
  try:
    let (idx, _) = lezActionOf(effect)
    touches.add touch("lez-proposal:" & hx(proposalPda(d.account.scheme, d.account.program,
                                                       d.account.createKey, idx)), tmWrite)
  except ValueError: discard
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqModule, "lez_core"),
                    req(rqInfra, "lez-account"),
                    req(rqAuthority, "lez-multisig-member", rpContributor)],
    discloses: @[row("approvals", obChainObserver), row("effect", obChainObserver),
                 row("policy", obChainObserver), row("signed-tx", obRpcProvider)],
    touches: touches)
