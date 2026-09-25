## Voting in the room (exo-12a1, Phase C4; seams S5 + S6 of docs/design/multisig-landscape.md).
##
## For a VOTE-locus family nobody signs shared bytes: a member approves with their own
## on-chain transaction, which their chain wallet signs — never muster (invariant 3). So
## approving in the room is, in order, and all-or-nothing on the room's side:
##   1. the usual gates: a supported driver of the vote locus, its own signing refusal, a
##      real context not yet expired (invariant 2), accountable inputs (invariant 10);
##   2. S5 — read every value the driver declares (`reads`) from the chain and let the
##      driver re-derive it against what the room reviewed (`checkRead`): a pointer is
##      never followed blind. A mismatch, or a read that fails, refuses — nothing cast,
##      nothing published;
##   3. S6 — the member's vote transaction, through the vote seam; a chain refusal (not a
##      member, already voted) refuses, nothing published;
##   4. confirmation by reading the chain back — the vote must be there;
##   5. only then the receipt, the contribution the fold counts (the driver verifies it),
##      with an attestation over P by the member's ROOM key (Ed25519): the chain wallet
##      holds the vote's key, so the room identity is what commits to the context the room
##      reviewed. The S5 read is recorded as an external read — evidence of what was
##      checked, where, at what height — outside P, so earlier attestations stay valid.
## The chain is the authority on the tally: settlement recounts there (exo-0c9).
##
## Each step is also split in two, for a chain that sends without waiting (exo-3c9: a
## hosted call must not wait on a block): liveVoteCast runs 1-3 and returns what
## completion needs; liveVoteComplete runs 4-5, answering "unconfirmed: …" until the chain
## shows the vote. liveProposeOnChainStart sends the Propose; liveProposeOnChainComplete
## answers "pending" until proposal #i is on chain, then publishes the intent. liveVote and
## liveProposeOnChain are the two halves back to back.

import std/[json, strutils, tables]
import ../log/log
import ../intents/materialization
import ../drivers/driver
import ../drivers/kinds
import ../drivers/profile
import ../drivers/lez_multisig
import ../crypto/keystore
import ../crypto/curve25519
import ../lez/multisig
import ../lez/multisig_chain
import ./session
import ./intent_events
import ./intents
import ./attest
import ./live

type
  VoteSeam* = ref object of RootObj
    ## A member's access to a vote-locus chain: read what a pointer names, cast their vote
    ## (their wallet signs), confirm it landed, and describe it as a receipt.

method voterName*(v: VoteSeam): string {.base.} = ""
method readPointer*(v: VoteSeam, d: Driver, e: Effect, name: string): tuple[ok: bool, bytes: seq[byte], source, detail: string] {.base.} =
  (false, @[], "", "this seam reads nothing")
method castVote*(v: VoteSeam, d: Driver, e: Effect): tuple[ok: bool, tx, detail: string] {.base.} =
  (false, "", "this seam casts nothing")
method confirmVote*(v: VoteSeam, d: Driver, e: Effect): tuple[ok: bool, detail: string] {.base.} =
  (false, "this seam confirms nothing")
method receiptFor*(v: VoteSeam, d: Driver, e: Effect, tx: string): Contribution {.base.} =
  Contribution()

proc hx(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc publishVote(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId, effectJson: string,
                 receipt: Contribution, p: seq[byte]): string =
  ## Publish a confirmed vote's receipt + the room-key attestation over P. Returns the
  ## contributor, or "" if the driver does not accept the receipt (nothing published).
  let who = contributorOf(driverFor(intentPolicyOf(s.log.allEvents(), intentId)), effectJson, hx(receipt.bytes))
  if who.len == 0: return ""
  let edPub = ks.encIdentity().ed
  let attest = hx(@edPub & @(ks.edSign(p)))
  if not verifyAttestation(who, p, attest): return ""
  let events = s.log.allEvents()
  let folded = reduceIntents(events, driverFor)
  let round = (if intentId in folded: folded[intentId].collection.round else: 1)
  var parents: seq[EventId]
  for e in events:
    if e.key == "intent/" & intentId & "/propose" or e.key.startsWith("intent/" & intentId & "/sig/"):
      parents.add eventId(e)
  let sigEv = contributeEvent(intentId, who, hx(receipt.bytes), round = round, parents = parents)
  s.publish(sigEv)
  s.publish(attestEvent(intentId, who, round, attest, parents = @[eventId(sigEv)]))
  who

type PendingVote* = object
  ## A vote cast and not yet confirmed: what completing it publishes.
  intentId*: string
  effectJson*: string
  tx*: string
  recorded*: seq[Event]           ## the S5 reads, published with the receipt
  p*: seq[byte]                   ## the attestation payload P

proc liveVoteCast*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
                   seam: VoteSeam, bindingCtx: LinkContext, nowSec: uint64 = 0): tuple[outcome: string, pending: PendingVote] =
  ## Steps 1-3: the gates, the S5 re-read, the member's own vote transaction. outcome is
  ## "" when the vote was cast (pending holds what completion needs), else a refusal
  ## ("refused: …", "expired", "not-a-vote-locus", …) with nothing cast or published.
  s.poll()
  let events = s.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return ("unknown-intent", PendingVote())
  let drv = driverFor(intentPolicyOf(events, intentId))
  if not drv.supported(): return ("unsupported-driver", PendingVote())
  if drv.profile().locus != loVote: return ("not-a-vote-locus", PendingVote())
  let effect = effectFromJson(effectJson)
  let refusal = drv.signRefusal(effect)
  if refusal.len > 0: return ("refused: " & refusal, PendingVote())
  let ctx = intentContext(events, intentId)
  if ctx.isPlaceholder: return ("no-context", PendingVote())
  if ctx.expired(nowSec): return ("expired", PendingVote())
  if not intentInputs(events, driverFor, intentId).allAccountable: return ("unaccountable-input", PendingVote())
  let p = attestationPayload(events, driverFor, intentId)
  if p.len == 0: return ("unaccountable-input", PendingVote())
  # S5: the pointer's content, re-read and re-derived before anything is cast
  var recorded: seq[Event]
  for name in drv.reads(effect):
    let r = seam.readPointer(drv, effect, name)
    if not r.ok: return ("refused: could not read the " & name & " from the chain: " & r.detail, PendingVote())
    let why = drv.checkRead(effect, name, r.bytes)
    if why.len > 0: return ("refused: " & why, PendingVote())
    recorded.add readEvent(intentId, name & "-" & seam.voterName(), r.source, hx(r.bytes))
  # S6: the member's own vote transaction — their wallet signs it
  let voted = seam.castVote(drv, effect)
  if not voted.ok: return ("refused: the chain refused the vote: " & voted.detail, PendingVote())
  ("", PendingVote(intentId: intentId, effectJson: effectJson, tx: voted.tx, recorded: recorded, p: p))

proc liveVoteComplete*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: VoteSeam,
                       pv: PendingVote): string =
  ## Steps 4-5: the vote confirmed on chain, then the S5 reads and the receipt published.
  ## "unconfirmed: …" (nothing published) while the chain does not show the vote.
  s.poll()
  let drv = driverFor(intentPolicyOf(s.log.allEvents(), pv.intentId))
  let effect = effectFromJson(pv.effectJson)
  let conf = seam.confirmVote(drv, effect)
  if not conf.ok: return "unconfirmed: " & conf.detail
  for e in pv.recorded: s.publish(e)
  if publishVote(s, ks, driverFor, pv.intentId, pv.effectJson, seam.receiptFor(drv, effect, pv.tx), pv.p).len == 0:
    return "rejected"
  intentState(s.log.allEvents(), driverFor, pv.intentId)

proc liveVote*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
               seam: VoteSeam, bindingCtx: LinkContext, nowSec: uint64 = 0): string =
  ## Approve a vote-locus intent in the room: re-read (S5), cast the member's own vote
  ## (S6), confirm, then publish the receipt. Returns the intent's state, or a refusal
  ## ("refused: …", "expired", "not-a-vote-locus", …) with nothing cast or published.
  let (outcome, pv) = liveVoteCast(s, ks, driverFor, intentId, seam, bindingCtx, nowSec)
  if outcome.len > 0: return outcome
  liveVoteComplete(s, ks, driverFor, seam, pv)

# ── the LEZ multisig program's vote seam ──────────────────────────────────────
type LezVoteSeam* = ref object of VoteSeam
  chain*: LezMultisigChain
  voter*: seq[byte]      ## the member's LEZ account (in their LEZ wallet)
  payer*: seq[byte]      ## the funded account of theirs that pays the fee

proc newLezVoteSeam*(chain: LezMultisigChain, voter: seq[byte], payer: seq[byte] = @[]): LezVoteSeam =
  LezVoteSeam(chain: chain, voter: voter, payer: payer)

method voterName*(v: LezVoteSeam): string = "lez:" & hx(v.voter)

proc accountOf(d: Driver): LezMultisigAccount =
  if not (d of LezMultisigDriver): raise newException(ValueError, "not a LEZ multisig intent")
  LezMultisigDriver(d).account

method readPointer*(v: LezVoteSeam, d: Driver, e: Effect, name: string): tuple[ok: bool, bytes: seq[byte], source, detail: string] =
  try:
    let a = accountOf(d)
    let (idx, _) = lezActionOf(e)
    let pda = proposalPda(a.scheme, a.program, a.createKey, idx)
    let r = v.chain.readAccount(pda)
    if not r.found:
      return (false, @[], "", "no proposal #" & $idx & " on " & v.chain.chain & " (height " & $r.height & ")")
    (true, r.data, v.chain.chain & "@" & $r.height, "")
  except CatchableError as err:
    (false, @[], "", err.msg)

method castVote*(v: LezVoteSeam, d: Driver, e: Effect): tuple[ok: bool, tx, detail: string] =
  try:
    let a = accountOf(d)
    let (idx, _) = lezActionOf(e)
    let t = v.chain.submit(v.voter, approveOp(a.createKey, idx), v.payer)
    if not t.ok: return (false, "", t.error)
    (true, t.hash, "")
  except CatchableError as err:
    (false, "", err.msg)

proc confirmOnChain(v: LezVoteSeam, d: Driver, index: uint64): tuple[ok: bool, detail: string] =
  try:
    let a = accountOf(d)
    let r = v.chain.readAccount(proposalPda(a.scheme, a.program, a.createKey, index))
    if not r.found: return (false, "proposal #" & $index & " is not on chain")
    if v.voter in decodeProposal(r.data, a.layout).approved: (true, "")
    else: (false, "the chain does not show the vote on #" & $index)
  except CatchableError as err:
    (false, err.msg)

method confirmVote*(v: LezVoteSeam, d: Driver, e: Effect): tuple[ok: bool, detail: string] =
  try: v.confirmOnChain(d, lezActionOf(e).index)
  except CatchableError as err: (false, err.msg)

method receiptFor*(v: LezVoteSeam, d: Driver, e: Effect, tx: string): Contribution =
  voteReceipt(v.voter, lezActionOf(e).index, tx, canonicalize(d, e))

type PendingPropose* = object
  ## A Propose sent and not yet on chain: what completing it publishes.
  policy*: string
  action*: LezAction
  index*: uint64
  tx*: string
  nowSec*: int64
  msgSeq*: uint64
  ttlSec*: int64

proc liveProposeOnChainStart*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, policy: string,
                              action: LezAction, seam: LezVoteSeam, nowSec: int64, msgSeq: uint64,
                              ttlSec = DefaultIntentTtl): tuple[outcome: string, pending: PendingPropose] =
  ## The proposer's own Propose transaction, as the next proposal. outcome "" = sent
  ## (pending holds what completion needs), else a refusal; nothing is published here.
  let drv = driverFor(policy)
  if not drv.supported() or not (drv of LezMultisigDriver): return ("unsupported-driver", PendingPropose())
  let a = LezMultisigDriver(drv).account
  var index: uint64
  try:
    let st = seam.chain.readAccount(a.statePda)
    if not st.found: return ("refused: no multisig state on " & seam.chain.chain & " for this account", PendingPropose())
    index = decodeState(st.data).transactionIndex + 1
  except CatchableError as err: return ("refused: could not read the multisig state: " & err.msg, PendingPropose())
  let t = seam.chain.submit(seam.voter, proposeOp(a.createKey, index, action), seam.payer)
  if not t.ok: return ("refused: the chain refused the proposal: " & t.error, PendingPropose())
  ("", PendingPropose(policy: policy, action: action, index: index, tx: t.hash, nowSec: nowSec,
                     msgSeq: msgSeq, ttlSec: ttlSec))

proc liveProposeOnChainComplete*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, seam: LezVoteSeam,
                                 pp: PendingPropose): string =
  ## "pending" until proposal #index is on chain with the proposer's vote; then the room
  ## intent pointing at it, and the proposer's vote reported. Returns the intent id, a
  ## refusal, or "pending".
  let drv = driverFor(pp.policy)
  if not drv.supported() or not (drv of LezMultisigDriver): return "unsupported-driver"
  let a = LezMultisigDriver(drv).account
  if not seam.confirmOnChain(drv, pp.index).ok: return "pending"
  let effectJson = lezProposalEffect(pp.index, pp.action)
  let id = liveProposeIntent(s, ks, driverFor, pp.policy, effectJson, pp.nowSec, pp.msgSeq,
                             account = hx(a.statePda), ttlSec = pp.ttlSec)
  if not id.startsWith("0x"): return id   # a refusal, not an intent id
  # the proposer's Propose was their vote: report it like any other
  let p = attestationPayload(s.log.allEvents(), driverFor, id)
  if p.len > 0:
    discard publishVote(s, ks, driverFor, id, effectJson, voteReceipt(seam.voter, pp.index, pp.tx,
                        canonicalize(drv, effectFromJson(effectJson))), p)
  id

proc liveProposeOnChain*(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, policy: string,
                         action: LezAction, seam: LezVoteSeam, nowSec: int64, msgSeq: uint64,
                         ttlSec = DefaultIntentTtl): string =
  ## Propose a LEZ multisig action: the proposer's own Propose transaction puts it ON
  ## CHAIN as the next proposal (which auto-approves), the room intent points at it with
  ## the content the room reviews, and the proposer's vote is reported like any other.
  ## Returns the intent id, or a refusal.
  let (outcome, pp) = liveProposeOnChainStart(s, ks, driverFor, policy, action, seam, nowSec, msgSeq, ttlSec)
  if outcome.len > 0: return outcome
  let id = liveProposeOnChainComplete(s, ks, driverFor, seam, pp)
  if id == "pending": "refused: the chain does not show proposal #" & $pp.index & " after it was accepted" else: id
