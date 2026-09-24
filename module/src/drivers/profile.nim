## The family profile (exo-a50.1.1; docs/design/multisig-landscape.md §5, seams S3 + S9).
##
## A driver implements a multisig FAMILY — a way a group can hold an account and
## authorize from it (a Safe, a Bitcoin P2WSH vault, a FROST key, a room threshold).
## The profile says which family, in the closed vocabulary of
## contracts/families/registry.json, and fills the family's facts for THIS instance:
## the chain it settles on (CAIP-2), the account (CAIP-10), k of n, and the ways
## around the threshold as far as they are known. The card's fixed rows (§6) read the
## profile; no consumer branches on a concrete driver type to learn any of this (the
## null-ladder rule: a level or a fact is a typed attribute the seam declares).
##
## Two honesty rules, as for the manifest:
##   * the default is UNDECLARED — shown, never guessed; conformance fails it;
##   * an instance fact this driver has not read is UNKNOWN, never a reassuring
##     default: a Safe's modules can skip its threshold, so until they are read from
##     the chain its bypasses are `bypassesKnown = false`, not "none".
##
## The static half of every profile is held equal to its registry entry by
## tests/profile_test.nim (drift in either direction fails), so the atlas, the doc
## and the running driver cannot tell three different stories.

import std/[json, strutils]
import ./driver

type
  Locus* = enum
    loNative = "native", loContract = "contract", loVote = "vote",
    loAggregate = "aggregate", loRoom = "room"
  Scheme* = enum
    scSharedBytes = "shared-bytes", scPerSignerBytes = "per-signer-bytes",
    scOwnTransaction = "own-transaction", scAggregateNofN = "aggregate-n-of-n",
    scAggregateThreshold = "aggregate-threshold"
  Commits* = enum cmContent = "content", cmPointer = "pointer"
  Binding* = enum bdExplicit = "explicit", bdImplicit = "implicit", bdNone = "none", bdRoom = "room"
  Ordering* = enum
    orSequence = "sequence", orLanes = "lanes", orUtxo = "utxo", orObjects = "objects",
    orIndex = "index", orDedup = "dedup", orNone = "none"
  Expiry* = enum exNone = "none", exOptional = "optional", exForced = "forced"
  Setup* = enum suNone = "none", suDerive = "derive", suRegister = "register", suDeploy = "deploy", suDkg = "dkg"
  SignerChange* = enum chInPlace = "in-place", chNewAddress = "new-address", chReshare = "reshare", chFixed = "fixed"
  Reveal* = enum rvNever = "never", rvAtCreation = "at-creation", rvPerApproval = "per-approval", rvAtSettle = "at-settle"
  EffectVisibility* = enum
    evPublic = "public", evShielded = "shielded", evRoomOnly = "room-only",
    evTargetModule = "target-module"
  ApproverCost* = enum
    acNone = "none", acPerSignature = "per-signature", acPerVote = "per-vote",
    acPerVoteDeposit = "per-vote-deposit"
  Maturity* = enum
    maProduction = "production", maEarly = "early", maDraft = "draft",
    maExperimental = "experimental", maDemo = "demo", maDeprecated = "deprecated",
    maSunsetting = "sunsetting"

  FamilyProfile* = object
    declared*: bool           ## false = the driver has not said what family it is
    family*: string           ## registry id, e.g. "evm.safe", "room.threshold"
    settlement*: string       ## registry settlement key: "none" for a room family, else the chain side
    locus*: Locus
    scheme*: Scheme
    commits*: Commits
    binding*: Binding
    ordering*: Ordering
    expiry*: Expiry
    setup*: Setup
    signerChange*: SignerChange
    revealsPolicy*: Reveal
    revealsSigners*: Reveal
    revealsEffect*: EffectVisibility
    approverCost*: ApproverCost
    rounds*: int
    secretState*: bool
    maturity*: Maturity
    # ── the instance ──
    chain*: string            ## CAIP-2 ("eip155:31337"); "" for a room family
    account*: string          ## CAIP-10 ("eip155:31337:0x…"); "" for a room family
    k*: int                   ## approvals needed
    n*: int                   ## eligible signers; 0 = not known to this instance
    bypassesKnown*: bool      ## false = not read yet: shown as unknown, never as "none"
    bypasses*: seq[string]    ## the ways around the threshold actually present on this instance

method profile*(d: Driver): FamilyProfile {.base, gcsafe.} =
  ## Default: undeclared. Nothing about the family is derivable from describe(), so
  ## nothing is filled in (the rounds/k agreement is checked, not inferred).
  FamilyProfile(declared: false)

proc roomProfile*(family: string, desc: DriverDescriptor, n: int,
                  effect = evRoomOnly, maturity = maProduction): FamilyProfile =
  ## The shape every room family shares: agreement is final in the room, nothing goes
  ## to a chain, no outside observer learns the policy or the signers, and nothing can
  ## get around the threshold — the room's log and the driver's verify are the rule.
  FamilyProfile(declared: true, family: family, settlement: "none",
    locus: loRoom, scheme: scSharedBytes, commits: cmContent, binding: bdRoom,
    ordering: orNone, expiry: exOptional, setup: suNone, signerChange: chInPlace,
    revealsPolicy: rvNever, revealsSigners: rvNever, revealsEffect: effect,
    approverCost: acNone, rounds: desc.rounds, secretState: false, maturity: maturity,
    k: desc.threshold, n: n, bypassesKnown: true)

# ── CAIP-2 / CAIP-10 (S9): one spelling for a chain and an account ──────────────
proc isCaip2*(s: string): bool =
  ## namespace:reference — [-a-z0-9]{3,8} ":" [-_a-zA-Z0-9]{1,32}
  let i = s.find(':')
  if i < 3 or i > 8 or i == s.len - 1 or s.len - i - 1 > 32: return false
  for c in s[0 ..< i]:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  for c in s[i+1 .. ^1]:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: return false
  true

proc isCaip10*(s, chain: string): bool =
  ## chain_id ":" account_address — the account must live on the profile's own chain.
  if not s.startsWith(chain & ":"): return false
  let a = s[chain.len + 1 .. ^1]
  if a.len == 0 or a.len > 128: return false
  for c in a:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '%'}: return false
  true

proc caip2Evm*(chainId: uint64): string = "eip155:" & $chainId
proc caip10*(chain, address: string): string = chain & ":" & address

# ── the rules a profile must satisfy to be believed ──────────────────────────
proc profileFailures*(p: FamilyProfile, desc: DriverDescriptor): seq[string] =
  ## Empty = consistent. The cross-field rules are the registry checker's
  ## (scripts/check-family-registry.py), so a profile cannot say what the registry
  ## would refuse; the rest hold the profile to the driver's own describe().
  if not p.declared: return @["undeclared: the driver does not say what family it is"]
  if p.family.len == 0: result.add "no family id"
  let room = p.locus == loRoom
  if room != (p.settlement == "none"): result.add "locus room iff settlement none"
  if room != (p.binding == bdRoom): result.add "locus room iff binding room"
  if (p.locus == loAggregate) != (p.scheme in {scAggregateNofN, scAggregateThreshold}):
    result.add "locus aggregate iff an aggregate scheme"
  if (p.locus == loVote) != (p.scheme == scOwnTransaction): result.add "locus vote iff own-transaction"
  if (p.locus == loVote) != (p.approverCost in {acPerVote, acPerVoteDeposit}):
    result.add "locus vote iff approving costs a transaction"
  if p.commits == cmPointer and p.locus != loVote: result.add "a pointer approval needs a vote locus"
  if p.locus == loAggregate and (p.revealsPolicy != rvNever or p.revealsSigners != rvNever):
    result.add "an aggregate signature reveals neither policy nor signers"
  if rvPerApproval in {p.revealsPolicy, p.revealsSigners} and p.locus != loVote:
    result.add "reveals per approval only when approvals are on-chain"
  if room and (p.revealsPolicy != rvNever or p.revealsSigners != rvNever or
               p.revealsEffect notin {evRoomOnly, evTargetModule}):
    result.add "a room family reveals nothing to a chain"
  if p.revealsEffect == evTargetModule and not room: result.add "target-module visibility is a room family's"
  if p.secretState and p.rounds < 2: result.add "secret round state implies at least 2 rounds"
  if p.setup == suDkg and p.scheme != scAggregateThreshold: result.add "a key ceremony is only for threshold aggregation"
  # agreement with the driver's own policy (invariant 6: describe() is the source)
  if p.rounds != desc.rounds: result.add "rounds " & $p.rounds & " contradict describe() " & $desc.rounds
  if p.k != desc.threshold: result.add "k " & $p.k & " contradicts describe() threshold " & $desc.threshold
  if (desc.finality == finExternal) != (p.settlement != "none"):
    result.add "external finality iff the family settles somewhere (settlement " & p.settlement & ")"
  # the instance (S9)
  if room:
    if p.chain.len > 0 or p.account.len > 0: result.add "a room family names no chain or account"
  else:
    if not isCaip2(p.chain): result.add "chain '" & p.chain & "' is not CAIP-2"
    if not isCaip10(p.account, p.chain): result.add "account '" & p.account & "' is not CAIP-10 on " & p.chain
  if p.k < 1: result.add "k must be at least 1"
  if p.n != 0 and p.n < p.k: result.add "n " & $p.n & " below k " & $p.k
  if p.bypassesKnown == false and p.bypasses.len > 0: result.add "bypasses listed but marked unknown"

# ── the stub (conformance probes randomize its descriptor) ───────────────────
method profile*(d: StubDriver): FamilyProfile =
  ## Follows its own descriptor, like the stub's manifest: an external-finality stub
  ## is a contract family on a stub chain; anything else is a room family.
  if d.descriptor.finality == finExternal:
    FamilyProfile(declared: true, family: "stub", settlement: "stub",
      locus: loContract, scheme: scSharedBytes, commits: cmContent, binding: bdExplicit,
      ordering: orNone, expiry: exNone, setup: suDeploy, signerChange: chInPlace,
      revealsPolicy: rvAtCreation, revealsSigners: rvAtSettle, revealsEffect: evPublic,
      approverCost: acNone, rounds: d.descriptor.rounds, secretState: false,
      maturity: maDemo, chain: "stub:0", account: "stub:0:stub",
      k: d.descriptor.threshold, n: 0, bypassesKnown: true)
  else:
    roomProfile("stub", d.descriptor, 0, maturity = maDemo)

# ── JSON, for the hosted surface and the card ─────────────────────────────────
proc toJson*(p: FamilyProfile): JsonNode =
  var byp = newJArray()
  for b in p.bypasses: byp.add %b
  %*{"declared": p.declared, "family": p.family, "settlement": p.settlement,
     "locus": $p.locus, "scheme": $p.scheme, "commits": $p.commits, "binding": $p.binding,
     "ordering": $p.ordering, "expiry": $p.expiry, "setup": $p.setup,
     "membershipChange": $p.signerChange, "approverCost": $p.approverCost,
     "reveals": {"policy": $p.revealsPolicy, "signers": $p.revealsSigners, "effect": $p.revealsEffect},
     "rounds": p.rounds, "secretState": p.secretState, "maturity": $p.maturity,
     "chain": p.chain, "account": p.account, "k": p.k, "n": p.n,
     "bypassesKnown": p.bypassesKnown, "bypasses": byp}
