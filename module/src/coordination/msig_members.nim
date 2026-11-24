## A lez-msig's members, as the room follows them across config changes (exo-0d3.13,
## docs/design/lez-msig.md §8 step 5; RFP-005 F.5, R.2, Coordination Architecture).
##
## The program holds the member set; the room holds its own (who reads it) and its own copy of
## the config (what the driver counts approvals against). Both must follow every config change
## the program executes:
##   * lezMsigNow — the account's config after the config changes the room saw execute: the
##     disclosed config, then each final config proposal for the multisig, applied as the
##     program applies it (applyChanges), one epoch each. So an added member's approval counts
##     in the room and a removed member's no longer does, without anyone re-disclosing;
##   * reconcileLezMsig — every lez-msig account in the room, rewritten to its config now;
##   * keyOwner — the room member an approval key belongs to: the one whose ceremony join
##     proved it, or who shared it as an account of their own (exo-1f9);
##   * msigRemovalsDue — the room-side removals THIS member's client owes: a member the
##     program no longer holds in any lez-msig of the room, who still holds the room's key.
##     One client does it, so the room re-keys once (CoordinationSession.expel): the removal's
##     proposer, or, when they removed themselves, the lowest remaining member;
##   * memberIdsNow — the room identities a private multisig's notes and group secret go to.
##
## A change is applied when its proposal names the epoch the fold has reached, or an earlier
## one no older than the disclosure (a queued change executes after its epoch: the R.2
## cutoff is the queue). The room's view is advisory: settlement re-reads the chain, and the
## program's check is the only one that counts. A change made outside this room leaves the
## room's copy behind until someone discloses the account again.
## Pure functions of the event set (invariant 4).

import std/[strutils, sequtils, tables, options, algorithm]
import ../log/log
import ../drivers/lez_msig
import ../lez/msig
import ./accounts
import ./msig_room
import ./member_accounts
import ./intent_events

type
  AppliedChange* = object
    intent*: string
    proposer*: string             ## room identity (hex), "" when unattributed
    changes*: seq[MsigChange]

proc finalConfigChanges(events: seq[Event], multisig: seq[byte]): seq[tuple[intent, proposer: string, p: MsigProposal]] =
  ## The final config proposals for this multisig, in canonical order of their final events.
  var proposal = initTable[string, MsigProposal]()
  var proposer = initTable[string, string]()
  for e in events:
    let k = e.key.split('/')
    if k.len == 3 and k[0] == "intent" and k[2] == "propose":
      try:
        let eff = effectFromJson(e.value)
        if eff.schemaId != LezMsigSchema: continue
        let p = proposalOf(eff)
        if p.multisig == multisig and p.action.kind == akConfig: proposal[k[1]] = p
      except CatchableError: discard
    elif k.len == 4 and k[0] == "intent" and k[2] == "proposer" and k[1] notin proposer:
      proposer[k[1]] = k[3].toLowerAscii()
  var seen: seq[string]
  for e in canonicalOrder(events):
    let k = e.key.split('/')
    if k.len == 3 and k[0] == "intent" and k[2] == "final" and k[1] in proposal and k[1] notin seen:
      seen.add k[1]
      result.add (k[1], proposer.getOrDefault(k[1], ""), proposal[k[1]])

proc lezMsigNow*(events: seq[Event], a: LezMsigAccount): tuple[account: LezMsigAccount, applied: seq[AppliedChange]] =
  ## The account with every config change the room saw execute applied, and those changes.
  result.account = a
  var pending = finalConfigChanges(events, a.address)
  while true:
    var hit = -1
    for i, x in pending:
      if x.p.epoch > result.account.epoch or x.p.epoch < a.epoch: continue
      try:
        result.account.config = applyChanges(result.account.config, x.p.action.changes)
        hit = i
        break
      except ValueError: discard
    if hit < 0: break
    let x = pending[hit]
    inc result.account.epoch
    result.applied.add AppliedChange(intent: x.intent, proposer: x.proposer, changes: x.p.action.changes)
    pending.delete(hit)

proc isLezMsig(a: RoomAccount): bool = a.family in [LezMsigFamily, LezMsigPrivateFamily]

proc reconcileLezMsig*(events: seq[Event], accounts: seq[RoomAccount]): seq[RoomAccount] =
  ## The room's accounts, each lez-msig one carrying its config now (signers, k, config).
  for ra in accounts:
    var r = ra
    if ra.isLezMsig:
      let (ok, acct, _) = lezMsigAccountOf(ra.chain, ra.address, ra.config)
      if ok:
        let now = lezMsigNow(events, acct).account
        if now.epoch != acct.epoch:
          r.config = configJsonOf(now)
          r.signers = now.config.members.mapIt(hexOf(it.key))
          r.threshold = int(now.config.threshold)
    result.add r

proc keyOwner*(events: seq[Event], room: string, key: seq[byte]): string =
  ## The room member this approval key belongs to, "" when none: proved at a ceremony join,
  ## or shared by them as an account of their own.
  let k = hexOf(key)
  for c in ceremonies(events, room):
    for id, ck in c.keys:
      if ck == k: return id
  for m in memberAccounts(events, room):
    if hexOf(m.key) == k: return m.member
  ""

proc memberIdsNow*(events: seq[Event], room: string, a: LezMsigAccount): seq[string] =
  ## The room identities of the multisig's members now, in config order; a member whose key
  ## no one in the room owns is left out.
  for m in lezMsigNow(events, a).account.config.members:
    let who = keyOwner(events, room, m.key)
    if who.len > 0 and who notin result: result.add who

proc lezMsigAccounts(events: seq[Event]): seq[LezMsigAccount] =
  for ra in reduceAccounts(events):
    if ra.isLezMsig:
      let (ok, acct, _) = lezMsigAccountOf(ra.chain, ra.address, ra.config)
      if ok: result.add acct

proc msigRemovalsDue*(events: seq[Event], room: string, holders: seq[string], me: string): seq[(string, string)] =
  ## (member, intent) for each member a config change removed from a lez-msig of this room,
  ## who is a member of no lez-msig here now and still among `holders` (the room's current
  ## key holders, identity hex), when THIS member's client is the one to re-key them out.
  ## One entry per member, naming the first removal that made them due.
  let mine = me.toLowerAscii()
  let held = holders.mapIt(it.toLowerAscii())
  let accts = lezMsigAccounts(events)
  var stillIn: seq[string]
  for a in accts: stillIn.add memberIdsNow(events, room, a)
  for a in accts:
    let current = sorted(memberIdsNow(events, room, a).filterIt(it in held))
    for x in lezMsigNow(events, a).applied:
      for ch in x.changes:
        if ch.kind != ccRemoveMember: continue
        let who = keyOwner(events, room, ch.removed)
        if who.len == 0 or who notin held or who in stillIn: continue
        let actor = (if x.proposer.len > 0 and x.proposer != who: x.proposer
                     elif current.len > 0: current[0]
                     else: "")
        if actor == mine and not result.anyIt(it[0] == who): result.add (who, x.intent)

proc gmsAddsDue*(events: seq[Event], room: string, a: LezMsigAccount, me: string): seq[string] =
  ## The members of a private multisig, added since it was created, who hold no sealed group
  ## secret yet and whom THIS member's client seals it to: the add's proposer, or the lowest
  ## remaining member when the proposer is gone.
  let c = ceremonyOf(events, room, hexOf(a.createKey))
  if c.isNone or not c.get.private: return
  var sealed: seq[string]
  for e in events:
    let k = e.key.split('/')
    if k.len == 4 and k[0] == "lmsig" and k[1] == c.get.createKey and k[2] == "gms": sealed.add k[3].toLowerAscii()
  let now = memberIdsNow(events, room, a)
  let mine = me.toLowerAscii()
  for x in lezMsigNow(events, a).applied:
    for ch in x.changes:
      if ch.kind != ccAddMember: continue
      let who = keyOwner(events, room, ch.member.key)
      if who.len == 0 or who in sealed or who notin now or who in result: continue
      let others = sorted(now.filterIt(it != who))
      let actor = (if x.proposer in now and x.proposer != who: x.proposer
                   elif others.len > 0: others[0]
                   else: "")
      if actor == mine: result.add who

proc queuedProposers*(events: seq[Event], multisig: seq[byte]): Table[string, seq[byte]] =
  ## proposal id (hex) → the proposer's approval key, for every proposal in the room for this
  ## multisig. A queued action whose proposer the program no longer holds survives a removal
  ## (the R.2 cutoff is the queue); the room shows it so the current quorum can cancel it at
  ## once (cancels are never time-locked, design §5).
  for e in events:
    let k = e.key.split('/')
    if k.len != 3 or k[0] != "intent" or k[2] != "propose": continue
    try:
      let eff = effectFromJson(e.value)
      if eff.schemaId != LezMsigSchema: continue
      let p = proposalOf(eff)
      if p.multisig == multisig: result[hexOf(proposalId(p))] = p.proposer
    except CatchableError: discard

proc msigExecutedRemovals*(events: seq[Event], room: string): seq[string] =
  ## Every room member a lez-msig config change removed and no later one added back, who
  ## is a member of no lez-msig here now — whoever proposed it (exo-a16).
  var stillIn: seq[string]
  let accts = lezMsigAccounts(events)
  for a in accts: stillIn.add memberIdsNow(events, room, a)
  for a in accts:
    for x in lezMsigNow(events, a).applied:
      for ch in x.changes:
        if ch.kind == ccRemoveMember:
          let who = keyOwner(events, room, ch.removed)
          if who.len > 0 and who notin result: result.add who
        elif ch.kind == ccAddMember:
          let who = keyOwner(events, room, ch.member.key)
          result = result.filterIt(it != who)
  result = result.filterIt(it notin stillIn)
