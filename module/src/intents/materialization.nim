## Effect → materialization, and the unconditional re-derive-or-refuse check
## (spec: contracts/specs/derived-exo-8e7.spec.json, invariant 1, catastrophic).
##
## Participants review a semantic *effect*; what gets signed is its
## *materialization* — the concrete bytes a driver canonicalizes the effect into.
## A proposal carries a *claimed* materialization that may have been tampered in
## transit. Before signing, the core independently re-derives the materialization
## from the reviewed effect (local, deterministic code — never the transmitted
## copy) and refuses on any mismatch. This check is unconditional: no flag,
## plugin, or preference can turn it off (FS-6).

import std/strutils
import ../dcbor/dcbor
import ../drivers/driver

type
  Effect* = object
    schemaId*: string                    ## e.g. "muster.effect.transfer.v1"
    fields*: seq[(string, CborValue)]

  Materialization* = object
    bytes*: seq[byte]

method canonicalize*(driver: Driver, e: Effect): Materialization {.base.} =
  ## Effect → the concrete bytes owners sign — the ONE chain-specific step, now a
  ## driver method so a driver is a complete unit (its coordination AND its
  ## materialization live behind one interface). This base is the default: a
  ## deterministic dCBOR serialization under the driver's declared serialization
  ## domain (invariant 6: the domain is driver-described), which the stub uses. A
  ## real driver overrides it — the Safe driver computes its EIP-712 safeTxHash.
  ## Because it is pure local code, re-running it is the trustworthy derivation
  ## the re-derive-or-refuse check (invariant 1) depends on.
  let domain = driver.describe().serializationDomain
  var pairs: seq[(CborValue, CborValue)]
  for (k, v) in e.fields: pairs.add (cbText(k), v)
  Materialization(bytes: encode(cbArray(@[
    cbText(domain), cbText(e.schemaId), cbMap(pairs)])))

proc reviewAndCheck*(driver: Driver, e: Effect, claimed: Materialization): bool =
  ## Re-derive from the reviewed effect and compare to the claimed copy. True iff
  ## they are byte-identical. The one gate every signature passes through.
  canonicalize(driver, e).bytes == claimed.bytes

# ── the multi-party fold's two driver hooks (so the fold is driver-generic) ─────

method expectMaterialization*(d: Driver, m: Materialization) {.base.} =
  ## Tell the driver which materialization the contributions it is about to verify
  ## are over. The coordination fold sets this per intent before applying that
  ## intent's contributions. Default: no-op — a driver whose verifyContribution is
  ## stateless ignores it; the Safe driver records it as its pending hash.
  discard

method signRefusal*(d: Driver, e: Effect): string {.base, gcsafe.} =
  ## Why THIS client will not propose or sign `e` under this driver, or "" if it may.
  ## A driver-described gate on the signing path (exo-a50.1.4): the Safe refuses a
  ## delegatecall to a target this client has not allowlisted — the operation that
  ## runs foreign code AS the Safe. Default: nothing is refused.
  ""

method reads*(d: Driver, e: Effect): seq[string] {.base, gcsafe.} =
  ## S5: the external state `e`'s bytes depend on, by name, which the live path reads
  ## before anyone signs (a pointer approval's on-chain content, exo-6cbe). Default: none.
  @[]

method checkRead*(d: Driver, e: Effect, name: string, value: seq[byte]): string {.base, gcsafe.} =
  ## S5: why the value read for `name` refuses signing `e` ("" = it matches). The read is
  ## re-derived against what the room reviewed; a mismatch refuses (invariant 1 for
  ## pointers). Default: a read the driver never declared is refused, never waved through.
  "this driver declares no read named " & name

method identifyContributor*(d: Driver, m: Materialization, c: Contribution): string {.base.} =
  ## The stable id of whoever produced contribution `c` over materialization `m`,
  ## or "" if it is not a legitimate contribution. This is how the multi-party fold
  ## keys contributions (dedup) and rejects non-participants without the core ever
  ## reading the bytes. A driver that supports the fold overrides it; the base
  ## cannot identify one (returns "").
  ""

# ── parties named in the effect, and settlement in parts (exo-a90.2) ─────────────
# docs/design/split-the-bill.md §4.2–§4.3. Every family before the split had ONE policy
# for every proposal (describe()) and ONE submitter who settles the whole. A family whose
# parties are named in the effect (a split's debtors) derives its threshold from the
# effect, and each party settles its own part: still driver-described (invariant 6), so
# the core's rule is generic — it never knows what a split is.

method describeFor*(d: Driver, e: Effect): DriverDescriptor {.base, gcsafe.} =
  ## The policy for ONE proposal. Default: describe() — the family's one policy. A
  ## family whose parties are named in the effect overrides it (the threshold is how
  ## many the effect names). The core reads this wherever it needs a proposal's policy:
  ## the collection, the card's "M of N", the activity feed, the audit file.
  d.describe()

method agreesByProposing*(d: Driver, e: Effect, proposer: string): bool {.base, gcsafe.} =
  ## Whether the member proposing `e` (their room identity, hex) is a party whose own
  ## agreement the proposal should carry — made then, by their key, as any other
  ## agreement is (exo-770). Default false: a Safe owner who proposes still signs like the
  ## rest. A split's creditor proposing their own split agrees to it, payTo included.
  false

type Eligibility* = enum
  ## Whether a member's contribution to an intent would count, as its driver says from its
  ## own signer set (exo-ed5). `elUnknown` is never read as yes.
  elUnknown = "unknown", elYes = "yes", elNo = "no"

proc bareNames*(names: openArray[string]): seq[string] =
  ## A member's contributor names (attest.myContributorNames: "0x"-addresses, "ed:" and
  ## "frost:" keys, a bare Bitcoin key) as lowercase bare hex, for a driver to look up in
  ## its signer set whatever spelling it names contributors by.
  for n in names:
    var h = n.toLowerAscii()
    for p in ["0x", "ed:", "frost:"]:
      if h.startsWith(p): h = h[p.len .. ^1]
    if h notin result: result.add h

method mayContribute*(d: Driver, e: Effect, names: seq[string]): Eligibility {.base, gcsafe.} =
  ## Whether a member known by `names` (their contributor names) is among those whose
  ## contribution to `e` would count — from the driver's own signer set, never a chain read
  ## (the home surface asks this for every intent on every tick, F-18). Default unknown:
  ## a driver that does not say is never taken to mean "you".
  elUnknown

method settlementParts*(d: Driver, e: Effect): seq[string] {.base, gcsafe.} =
  ## The parties who each settle their OWN part of `e`, named as the driver names a
  ## contributor ("ed:<hex>"), in the driver's order. Default: none — one member
  ## submits the whole, as every family before the each-locus does.
  @[]

method partAuthor*(d: Driver, e: Effect, part, step: string): string {.base, gcsafe.} =
  ## Who may record `step` for `part` — "settled" (the party's own report of its
  ## settlement) or "confirmed" (the counterparty's confirmation) — as a room identity
  ## (hex, the encryption identity a report's author signature names). "" = nobody: a
  ## report under this step for this part never counts.
  ""

type PartTransfer* = object
  ## What a party does to settle its part: send `amount` of `asset` on `chain` to `to`.
  ## Derived by the driver from the reviewed effect — never supplied by a caller — so a
  ## payment is always the one the party agreed to (invariant 1).
  ok*: bool
  error*: string        ## why there is no transfer ("" when ok)
  chain*: string        ## CAIP-2
  asset*: string        ## the asset symbol the effect names
  to*: string           ## the address to pay, as the effect carries it
  amount*: string       ## canonical decimal, in the asset's smallest unit

method partTransfer*(d: Driver, e: Effect, part: string): PartTransfer {.base, gcsafe.} =
  ## The transfer that settles `part` of `e`. Default: none — nothing settles in parts.
  PartTransfer(ok: false, error: "this family does not settle in parts")

# ── The signing entry point, and a config surface that cannot bypass the check ─
type
  Config* = object
    ## A representative configuration surface. NONE of these gate the
    ## materialization check — they exist so a probe can prove no reachable config
    ## value bypasses it.
    skipReviewRequested*: bool
    plugins*: seq[string]
    userPreference*: string

  SignOutcome* = enum
    soRefused, soSigned

proc signProposal*(cfg: Config, driver: Driver, e: Effect,
                   claimed: Materialization): SignOutcome =
  ## The materialization check runs unconditionally before signing, regardless of
  ## any config field. There is deliberately no branch consulting `cfg` to skip
  ## it — the check lives in the core and cannot be disabled.
  if not reviewAndCheck(driver, e, claimed):
    return soRefused
  soSigned
