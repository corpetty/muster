## The card's fixed rows — the phrasebook (exo-a50.1.6; docs/design/multisig-landscape.md
## §6.2–§6.3, seam S10).
##
## Every multisig family answers the SAME ten questions, in the same order, on every
## card — that is what makes a Safe, a Bitcoin vault, a vote-locus program and a FROST
## key feel like one product. The answers are a pure function of the driver's family
## PROFILE (drivers/profile.nim): no row reads a concrete driver type or a policy
## string, so a new family fills the card by declaring its profile, with no UI change.
## Each row carries its CREDIBILITY (action-manifest.md §2): imperative (the rule is
## enforced), motivational (someone could defect; the party is named), exposed (someone
## outside the room sees it; named) — classified, never scored. An undeclared family's
## rows say it does not know; nothing is guessed.
##
## The atlas (docs/design/multisig-atlas.html) carries a copy of this phrasebook for
## the landscape; THIS module is the one the running card reads.

import std/[json, strutils]
import ../drivers/profile

type
  CardRow* = object
    key*: string          ## where · sign · binding · ordering · expiry · collect · chain · cost · change · bypass
    label*: string        ## what the row asks, as the card shows it
    text*: string         ## this family's answer, filled from the instance
    credibility*: string  ## "imperative" | "motivational" | "exposed" | "" (not a trust claim)
    party*: string        ## who is relied on / who can see — set with motivational / exposed

const RowKeys* = ["where", "sign", "binding", "ordering", "expiry", "collect", "chain", "cost", "change", "bypass"]
const RowLabels = ["Where the rule lives", "What you sign", "Only valid on", "Ordering", "Expiry",
                   "Collecting", "What the chain learns", "Approving costs you", "Changing signers",
                   "Ways around the rule"]

proc row(i: int, text: string, cred = "", party = ""): CardRow =
  CardRow(key: RowKeys[i], label: RowLabels[i], text: text, credibility: cred, party: party)

proc kOfN(p: FamilyProfile): string =
  if p.n > 0: $p.k & " of " & $p.n else: $p.k & " signatures"

proc cardRows*(p: FamilyProfile): seq[CardRow] =
  if not p.declared:
    for i in 0 ..< RowKeys.len:
      result.add row(i, "Not declared: this client has no driver for this kind, so nothing here is known.")
    return
  let room = p.locus == loRoom
  let chain = (if room: "this room" else: p.chain)
  let kn = kOfN(p)

  # 1. where the rule lives — enforced unless something gets around it
  let whereText = case p.locus
    of loNative: "The " & chain & " protocol itself checks that " & kn & " signed."
    of loContract: "A contract on " & chain & " checks that " & kn & " signed."
    of loVote: "Each approval is its own public transaction on " & chain & "; the chain counts " & kn & "."
    of loAggregate:
      (if p.scheme == scAggregateNofN: "All " & $p.n & " signers combine into one signature; "
       else: "Any " & $p.k & " of the " & $p.n & " signers combine into one signature; ") &
        chain & " sees a single signer and learns nothing about the group."
    of loRoom:
      if p.revealsEffect == evTargetModule:
        "The room agrees (" & kn & "); then this device hands the action to the module it names."
      else: "Agreement is final in this room (" & kn & "). Nothing goes to a chain."
  if room: result.add row(0, whereText, "imperative")
  elif not p.bypassesKnown:
    result.add row(0, whereText, "motivational",
                   "whatever can act without the owners here (modules, a guard) — not read yet")
  elif p.bypasses.len > 0:
    result.add row(0, whereText, "motivational", p.bypasses.join(", "))
  else: result.add row(0, whereText, "imperative")

  # 2. what you sign
  let signText = case p.scheme
    of scSharedBytes: "Everyone signs the same bytes: the full action. Muster rebuilds them and refuses on a mismatch."
    of scPerSignerBytes: "Each signer signs their own copy, with their account written into it. Muster rebuilds yours first."
    of scOwnTransaction:
      if p.commits == cmPointer:
        "Your approval is your own transaction that only points at a proposal stored on-chain; muster reads that proposal back and checks it before you approve."
      else: "Your approval is your own transaction, and it covers the full action."
    of scAggregateNofN, scAggregateThreshold:
      "A partial signature over the same bytes as everyone else's; they combine into one."
  if p.commits == cmPointer: result.add row(1, signText, "motivational", "your RPC provider, until the read is verified")
  else: result.add row(1, signText, "imperative")

  # 3. only valid on
  case p.binding
  of bdExplicit: result.add row(2, chain & ": the signed bytes name it.", "imperative")
  of bdImplicit: result.add row(2, "Only where the exact state it spends exists on " & chain & ".", "imperative")
  of bdNone: result.add row(2, "Another network of this chain would accept it; muster binds it to " & chain &
                                " in the room, the chain does not.", "exposed", "anyone holding your signature")
  of bdRoom: result.add row(2, "Nowhere outside this room.", "imperative")

  # 4. ordering
  result.add row(3, case p.ordering
    of orSequence: "One strict counter: this settles after the action before it, and anything else from the account first makes it stale."
    of orLanes: "Parallel lanes: unrelated actions don't block each other."
    of orUtxo: "Actions conflict only when they spend the same coins."
    of orObjects: "Actions conflict when they touch the same on-chain objects."
    of orIndex: "Proposals are numbered on-chain, in order."
    of orDedup: "No ordering between actions; a repeat is simply rejected."
    of orNone: "No ordering between proposals.")

  # 5. expiry
  result.add row(4, case p.expiry
    of exNone: "Collected signatures never expire; to cancel, spend or replace what they authorize."
    of exOptional: "No expiry unless the proposer sets one."
    of exForced: "The chain forces a short validity window; collect before it closes.")

  # 6. collecting
  result.add row(5, if p.rounds <= 1: "One signature from each signer."
    elif p.secretState: $p.rounds & " rounds: a commitment, then the signature. Your device keeps a one-time secret between them; reusing it would leak the key."
    else: $p.rounds & " rounds, each from the same signers.")

  # 7. what the chain learns
  if room:
    result.add row(6, (if p.revealsEffect == evTargetModule: "Nothing from the room; the module it calls sees the action."
                       else: "Nothing: it stays in the room."), "imperative")
  else:
    proc whenOf(r: Reveal): string =
      case r
      of rvNever: "never"
      of rvAtCreation: "from setup"
      of rvPerApproval: "with each vote"
      of rvAtSettle: "when it settles"
    let eff = case p.revealsEffect
      of evPublic: "public"
      of evShielded: "shielded"
      of evRoomOnly: "stays in the room"
      of evTargetModule: "seen by the module it calls"
    let t = "The policy: " & whenOf(p.revealsPolicy) & ". Who signed: " & whenOf(p.revealsSigners) &
            ". The action: " & eff & "."
    if p.revealsSigners == rvNever: result.add row(6, t, "imperative")
    else: result.add row(6, t, "exposed", "anyone reading the chain")

  # 8. approving costs you
  result.add row(7, case p.approverCost
    of acNone: "Nothing; whoever submits pays once."
    of acPerSignature: "Each signature adds a little to the one fee."
    of acPerVote: "A transaction you pay for."
    of acPerVoteDeposit: "A transaction you pay for, and the first approver locks a deposit.")

  # 9. changing signers
  result.add row(8, case p.signerChange
    of chInPlace: "A proposal on this account; the address stays."
    of chNewAddress: "A new account, and a second proposal to move the funds."
    of chReshare: "A key ceremony in the room; the address stays."
    of chFixed: "Not possible; create a new account.")

  # 10. ways around the rule
  if room: result.add row(9, "None: the room's log is the rule.")
  elif not p.bypassesKnown:
    result.add row(9, "Unknown until read from the chain (see Accounts).", "motivational",
                   "whatever the account allows beyond its owners")
  elif p.bypasses.len > 0:
    result.add row(9, p.bypasses.join("; "), "motivational", "whoever holds them")
  else: result.add row(9, "None (read from the chain).")

proc cardRowsJson*(rows: seq[CardRow]): JsonNode =
  result = newJArray()
  for r in rows:
    result.add %*{"key": r.key, "label": r.label, "text": r.text,
                  "credibility": r.credibility, "party": r.party}
