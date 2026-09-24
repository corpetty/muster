## The LEZ multisig program's on-chain objects, as muster reads them (exo-a26, Phase C1).
##
## logos-co/lez-multisig (Squads-v4-style, on the Logos Execution Zone) keeps a multisig
## as a state PDA and each proposal as its own PDA; members vote with their own
## transactions and the program counts them. This module is the program's data, not its
## execution:
##   * MultisigState and Proposal in the program's BORSH layout (multisig_core/src/lib.rs
##     @ c45100b) — muster decodes what it reads from the chain and re-derives it against
##     what the room reviewed (S5); a partial or padded account is refused, never guessed;
##   * SPEL seeds (spel-framework-core v0.3.0 pda.rs): strings zero-padded to 32 bytes,
##     integers as their LE bytes zero-padded, one seed used as is, several combined as
##     SHA-256(seed1 || seed2 || …);
##   * the chain's public-PDA formula, SHA-256(prefix || program || seed), VERSIONED: the
##     published program targets nssa v0.2.0-rc3 ("/NSSA/v0.2/AccountId/PDA/" over the
##     program's image id as LE words) while lez_core v0.4.2 speaks LEE v0.2.5-rc2
##     ("/LEE/v0.2/AccountId/PDA/" over the program's ACCOUNT id). An account names its
##     scheme; the two never mix silently.
## The voting rules (auto-approve, one vote per member, flips, threshold, dead) mirror
## the program's Proposal impl so the in-process model (multisig_chain) behaves like it.
##
## The proposal layout is NAMED too (exo-3c9): the published program records only how many
## target accounts a call takes (`plCountOnly`, c45100b — lez-multisig#40: whoever executes
## chooses them); the rebuild for the live testnet line (SPEL v0.7.0 / LEZ v0.2.4) carries
## #41's fix and commits `target_account_ids` right after the count (`plAccountIds`), which
## execute then binds. An account's config names its layout; count-only is the default.

import std/[strutils, sequtils]
import ../hashing/sha256

type
  LezDecodeError* = object of CatchableError

  ProposalLayout* = enum
    plCountOnly = "count-only"    ## lez-multisig c45100b: target_account_count only (#40)
    plAccountIds = "account-ids"  ## the rebuild with #41: + target_account_ids, bound at execute

  PdaScheme* = enum
    psNssa02 = "nssa-v0.2"    ## nssa v0.2.0-rc3: the program the repo publishes today
    psLee02 = "lee-v0.2"      ## LEE v0.2.5: the chain lez_core v0.4.2 talks to

  ProposalStatus* = enum
    psActive = "active", psExecuted = "executed", psRejected = "rejected", psCancelled = "cancelled"

  ConfigKind* = enum caAddMember, caRemoveMember, caChangeThreshold
  ConfigAction* = object
    case kind*: ConfigKind
    of caAddMember, caRemoveMember: member*: seq[byte]   ## 32
    of caChangeThreshold: threshold*: int

  LezAction* = object
    ## What a proposal will call when executed (a ChainedCall to `target`), as the room
    ## reviews it. `accounts` are the target accounts the executor passes (the chain stores
    ## only their count); `accountCount` is used when `accounts` is empty (a chain read).
    target*: seq[byte]          ## the target program, 32 bytes ([u32; 8] as LE words)
    instruction*: seq[uint32]   ## the target instruction, as the program's u32 words
    accounts*: seq[seq[byte]]   ## execute-time target accounts, 32 bytes each
    accountCount*: int
    pdaSeeds*: seq[seq[byte]]   ## PDA seeds the multisig proves in the chained call
    authorized*: seq[uint8]     ## which target accounts are authorized in the call

  Proposal* = object
    index*: uint64
    proposer*: seq[byte]
    createKey*: seq[byte]
    action*: LezAction
    approved*: seq[seq[byte]]
    rejected*: seq[seq[byte]]
    status*: ProposalStatus
    hasConfig*: bool
    config*: ConfigAction

  MultisigState* = object
    createKey*: seq[byte]
    threshold*: int
    members*: seq[seq[byte]]
    transactionIndex*: uint64

proc `==`*(a, b: ConfigAction): bool =
  if a.kind != b.kind: return false
  case a.kind
  of caAddMember, caRemoveMember: a.member == b.member
  of caChangeThreshold: a.threshold == b.threshold

proc targetAccountCount*(a: LezAction): int =
  if a.accounts.len > 0: a.accounts.len else: a.accountCount

proc memberCount*(s: MultisigState): int = s.members.len

# ── borsh ─────────────────────────────────────────────────────────────────────
proc bad(msg: string) {.noreturn.} = raise newException(LezDecodeError, msg)

proc putU32(b: var seq[byte], x: uint32) =
  for i in 0 ..< 4: b.add byte((x shr uint32(8*i)) and 0xff)
proc putU64(b: var seq[byte], x: uint64) =
  for i in 0 ..< 8: b.add byte((x shr uint64(8*i)) and 0xff)
proc put32(b: var seq[byte], x: seq[byte]) =
  if x.len != 32: raise newException(LezDecodeError, "a 32-byte field has " & $x.len & " bytes")
  b.add x
proc putVec32(b: var seq[byte], xs: seq[seq[byte]]) =
  b.putU32(uint32(xs.len))
  for x in xs: b.put32(x)

type Reader = object
  b: seq[byte]
  i: int

proc need(r: Reader, n: int) =
  if r.i + n > r.b.len: bad("the account ends early (" & $r.b.len & " bytes)")
proc u8(r: var Reader): uint8 =
  r.need(1)
  result = r.b[r.i]
  inc r.i
proc u32(r: var Reader): uint32 =
  r.need(4)
  for k in 0 ..< 4: result = result or (uint32(r.b[r.i + k]) shl uint32(8*k))
  r.i += 4
proc u64(r: var Reader): uint64 =
  r.need(8)
  for k in 0 ..< 8: result = result or (uint64(r.b[r.i + k]) shl uint64(8*k))
  r.i += 8
proc fixed(r: var Reader, n: int): seq[byte] =
  r.need(n)
  result = r.b[r.i ..< r.i + n]
  r.i += n
proc len32(r: var Reader, each: int): int =
  let n = int(r.u32())
  r.need(n * each)          # never allocate for a length the bytes cannot hold
  n
proc vec32(r: var Reader): seq[seq[byte]] =
  for _ in 0 ..< r.len32(32): result.add r.fixed(32)
proc done(r: Reader) =
  if r.i != r.b.len: bad("the account has " & $(r.b.len - r.i) & " bytes past its end")

proc encodeState*(s: MultisigState): seq[byte] =
  result.put32(s.createKey)
  result.add byte(s.threshold)
  result.add byte(s.members.len)
  result.putVec32(s.members)
  result.putU64(s.transactionIndex)

proc decodeState*(b: openArray[byte]): MultisigState =
  var r = Reader(b: @b)
  result.createKey = r.fixed(32)
  result.threshold = int(r.u8())
  let count = int(r.u8())
  result.members = r.vec32()
  if result.members.len != count: bad("member_count " & $count & " but " & $result.members.len & " members")
  result.transactionIndex = r.u64()
  r.done()

proc parseProposalLayout*(s: string): ProposalLayout =
  for x in ProposalLayout:
    if $x == s: return x
  raise newException(LezDecodeError, "unknown proposal layout: " & s)

proc encodeProposal*(p: Proposal, layout = plCountOnly): seq[byte] =
  result.putU64(p.index)
  result.put32(p.proposer)
  result.put32(p.createKey)
  result.put32(p.action.target)
  result.putU32(uint32(p.action.instruction.len))
  for w in p.action.instruction: result.putU32(w)
  result.add byte(p.action.targetAccountCount)
  if layout == plAccountIds: result.putVec32(p.action.accounts)
  result.putVec32(p.action.pdaSeeds)
  result.putU32(uint32(p.action.authorized.len))
  for x in p.action.authorized: result.add x
  result.putVec32(p.approved)
  result.putVec32(p.rejected)
  result.add byte(ord(p.status))
  if not p.hasConfig: result.add 0'u8
  else:
    result.add 1'u8
    result.add byte(ord(p.config.kind))
    case p.config.kind
    of caAddMember, caRemoveMember: result.put32(p.config.member)
    of caChangeThreshold: result.add byte(p.config.threshold)

proc decodeProposal*(b: openArray[byte], layout = plCountOnly): Proposal =
  var r = Reader(b: @b)
  result.index = r.u64()
  result.proposer = r.fixed(32)
  result.createKey = r.fixed(32)
  result.action.target = r.fixed(32)
  for _ in 0 ..< r.len32(4): result.action.instruction.add r.u32()
  result.action.accountCount = int(r.u8())
  if layout == plAccountIds: result.action.accounts = r.vec32()
  result.action.pdaSeeds = r.vec32()
  for _ in 0 ..< r.len32(1): result.action.authorized.add r.u8()
  result.approved = r.vec32()
  result.rejected = r.vec32()
  let st = r.u8()
  if st > 3: bad("unknown proposal status " & $st)
  result.status = ProposalStatus(st)
  case r.u8()
  of 0: result.hasConfig = false
  of 1:
    result.hasConfig = true
    case r.u8()
    of 0: result.config = ConfigAction(kind: caAddMember, member: r.fixed(32))
    of 1: result.config = ConfigAction(kind: caRemoveMember, member: r.fixed(32))
    of 2: result.config = ConfigAction(kind: caChangeThreshold, threshold: int(r.u8()))
    else: bad("unknown config action")
  else: bad("bad option tag for config_action")
  r.done()

# ── the voting model (multisig_core Proposal impl) ────────────────────────────
proc newProposal*(index: uint64, proposer, createKey: seq[byte], action: LezAction): Proposal =
  Proposal(index: index, proposer: proposer, createKey: createKey, action: action,
           approved: @[proposer], status: psActive)

proc newConfigProposal*(index: uint64, proposer, createKey: seq[byte], cfg: ConfigAction): Proposal =
  Proposal(index: index, proposer: proposer, createKey: createKey,
           action: LezAction(target: newSeq[byte](32)), approved: @[proposer], status: psActive,
           hasConfig: true, config: cfg)

proc approve*(p: var Proposal, member: seq[byte]): bool =
  if member in p.approved: return false
  p.rejected.keepItIf(it != member)
  p.approved.add member
  true

proc reject*(p: var Proposal, member: seq[byte]): bool =
  if member in p.rejected: return false
  p.approved.keepItIf(it != member)
  p.rejected.add member
  true

proc hasThreshold*(p: Proposal, k: int): bool = p.approved.len >= k
proc isDead*(p: Proposal, k, n: int): bool = n - p.rejected.len < k

# ── SPEL seeds and the chain's PDA formula ─────────────────────────────────────
proc seedFromStr*(s: string): seq[byte] =
  if s.len > 32: bad("seed string '" & s & "' exceeds 32 bytes")
  result = newSeq[byte](32)
  for i, c in s: result[i] = byte(c)

proc seedU64*(x: uint64): seq[byte] =
  result = newSeq[byte](32)
  for i in 0 ..< 8: result[i] = byte((x shr uint64(8*i)) and 0xff)

proc combineSeeds*(seeds: seq[seq[byte]]): seq[byte] =
  if seeds.len == 0: bad("a PDA needs at least one seed")
  for s in seeds:
    if s.len != 32: bad("a seed is 32 bytes")
  if seeds.len == 1: return seeds[0]
  var all: seq[byte]
  for s in seeds: all.add s
  @(sha256(all))

proc prefixOf(s: PdaScheme): seq[byte] =
  let text = (case s
              of psNssa02: "/NSSA/v0.2/AccountId/PDA/"
              of psLee02: "/LEE/v0.2/AccountId/PDA/")
  result = newSeq[byte](32)
  for i, c in text: result[i] = byte(c)

proc parsePdaScheme*(s: string): PdaScheme =
  for x in PdaScheme:
    if $x == s: return x
  bad("unknown PDA scheme: " & s)

proc publicPda*(scheme: PdaScheme, program, seed: seq[byte]): seq[byte] =
  ## SHA-256(prefix || program || seed). `program` is the program's 32-byte identity in
  ## the scheme: its image id as LE words (nssa v0.2) or its account id (LEE v0.2).
  if program.len != 32 or seed.len != 32: bad("a PDA takes a 32-byte program and seed")
  @(sha256(prefixOf(scheme) & program & seed))

proc statePda*(scheme: PdaScheme, program, createKey: seq[byte]): seq[byte] =
  publicPda(scheme, program, combineSeeds(@[createKey]))

proc proposalPda*(scheme: PdaScheme, program, createKey: seq[byte], index: uint64): seq[byte] =
  publicPda(scheme, program, combineSeeds(@[seedFromStr("multisig_prop___"), createKey, seedU64(index)]))

proc vaultSeed*(createKey: seq[byte]): seq[byte] =
  ## the vault's seed, as a Propose instruction's pda_seeds carries it
  combineSeeds(@[seedFromStr("multisig_vault__"), createKey])

proc vaultPda*(scheme: PdaScheme, program, createKey: seq[byte]): seq[byte] =
  publicPda(scheme, program, vaultSeed(createKey))
