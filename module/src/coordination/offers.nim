## Offers — an action's requirements crossed with MY holdings (exo-45e K4,
## docs/design/material-and-disclosure.md §3.3).
##
## `offersFor(reqs, catalogue, manifest, parties)` answers, for each requirement that
## is a given participant's own to fill, WHICH of that participant's holdings satisfy
## it and, for each candidate, WHAT choosing it would disclose and to whom. It is a
## pure function of the caller's OWN catalogue and the manifest — it never takes, and
## can never reveal, another member's holdings (rule s3: graded about you only). The
## same function serves three surfaces (§3.3): the compose menu (proposer slots), the
## composer's account step (proposer slots), and the recipient's prompt (contributor +
## counterparty slots that are mine).
##
## Choosing material is choosing observers (rule s6): each candidate carries the
## disclosure rows binding it would add — the manifest's rows for the effect field this
## requirement lands in — so the promise shown before the choice is the record produced
## after it. Nothing here is scored or ranked (rule s7): candidates carry a class, a
## grade, and their rows, in catalogue order.

import std/strutils
import ./../drivers/manifest        # Requirement, ActionManifest, MaterialClass, RequirementParty
import ./../wallet/material         # Material, Disclosable, MaterialGrade, catalogue
import ./../intents/disclosure      # DisclosureRow

export material.Disclosable, material.MaterialGrade

type
  OfferStatus* = enum
    osSatisfiable   = "satisfiable"    ## at least one of my holdings fits
    osUnsatisfiable = "unsatisfiable"  ## none of my holdings fit
    osUnknown       = "unknown"        ## cannot be determined (e.g. a host capability, no broker)

  OfferCandidate* = object
    material*: Disclosable            ## the PUBLIC projection only — never the handle (rule s1)
    grade*: MaterialGrade
    discloses*: seq[DisclosureRow]    ## what choosing THIS candidate would add

  Offer* = object
    requirement*: Requirement
    candidates*: seq[OfferCandidate]
    status*: OfferStatus

proc trailing(s: string): string =
  ## The segment after the last ':' — so "chain:31337" and "evm:31337" both yield "31337".
  let i = s.rfind(':')
  if i < 0: s else: s[i+1 .. ^1]

proc targetMatches(r: Requirement, m: Material): bool =
  ## A requirement's target constraint against a holding. For AUTHORITY the target is a
  ## role label ("safe-owner", "signer", "roster-member"), not a constraint on the
  ## material's public face — any authority key is a candidate, and whether it is
  ## RECOGNIZED is graded by readiness / the chain (K3), never by the offer. For an
  ## address/asset the target names the chain (trailing id, format-insensitive across
  ## "chain:N" vs "evm:N") or the public face directly. Empty target = any.
  if r.needs.class == mcAuthority: return true
  let target = r.needs.target
  if target.len == 0: return true
  if m.chain.len > 0 and trailing(target) == trailing(m.chain): return true
  if target == m.public: return true
  false

proc rowsForField*(m: ActionManifest, field: string): seq[DisclosureRow] =
  ## The disclosure rows the manifest declares for one effect field — what leaves the
  ## room when material lands in that field (rule s6). Empty when the field discloses
  ## nothing beyond the baseline (which the card always shows separately).
  for r in m.discloses:
    if r.field == field: result.add r

proc offersFor*(reqs: seq[Requirement], cat: seq[Material], m: ActionManifest,
                parties: set[RequirementParty]): seq[Offer] =
  ## For each requirement whose party is in `parties` (the slots this surface is about),
  ## the candidates from MY catalogue that fit it, each with the rows it would disclose.
  ## `cat` is the caller's OWN catalogue; no other member's holdings are in scope (s3).
  for r in reqs:
    if r.party notin parties: continue
    # A host capability cannot be determined without the broker (exo-002.7) → unknown,
    # never a fabricated satisfiable/unsatisfiable (rule s5).
    if r.needs.class == mcCapability:
      result.add Offer(requirement: r, candidates: @[], status: osUnknown)
      continue
    var cands: seq[OfferCandidate]
    let rows = m.rowsForField(r.needs.field)
    for mat in cat:
      if mat.class == r.needs.class and targetMatches(r, mat):
        cands.add OfferCandidate(material: mat.disclosable(), grade: mat.grade, discloses: rows)
    result.add Offer(requirement: r, candidates: cands,
                     status: (if cands.len > 0: osSatisfiable else: osUnsatisfiable))

proc proposerOffers*(reqs: seq[Requirement], cat: seq[Material], m: ActionManifest): seq[Offer] =
  ## The composer's slots: what I can put into the effect (source account, amount,
  ## destination I supply directly).
  offersFor(reqs, cat, m, {rpProposer})

proc recipientOffers*(reqs: seq[Requirement], cat: seq[Material], m: ActionManifest): seq[Offer] =
  ## The recipient's slots: what a proposal asks ME to supply — a contribution key, or a
  ## counterparty address/asset the effect needs before it completes.
  offersFor(reqs, cat, m, {rpContributor, rpCounterparty})

proc satisfiable*(offers: seq[Offer]): bool =
  ## Every slot this surface is about has at least one of my holdings. An empty offer
  ## set is satisfiable (nothing is asked of me). Unknown is NOT satisfiable.
  for o in offers:
    if o.status != osSatisfiable: return false
  true
