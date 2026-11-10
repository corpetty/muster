## Quests in the room (exo-267.8; docs/design/logos-world-plan.md Phase 1;
## docs/design/lez-quest-program.md).
##
## A circle's LEZ multisig issues a quest by an ordinary multisig proposal whose call opens a
## record in the quest program, its taker and its confirmer act with their own transactions,
## and the circle closes it by a second proposal that pays the bounty. This module is the
## room's half, and holds no key:
##   * QuestTerms — the task, the bounty, the confirmer, the named taker if any, a salt — and
##     their hash, a domain-separated hash-input record (invariant 5). The text stays in the
##     room (a `quest/<id>/terms` event); the chain holds only the hash, so the members
##     publish the text when they choose and anyone can check it against the record;
##   * the quest id, from the issuer and the terms hash;
##   * the calls: Open and Close and Cancel as a multisig proposal's call (every row the
##     program and its chained transfer need, the vault's seed), Accept and Confirm as a
##     person's own transaction, and Open from a person's own account;
##   * questCallOf — a call read back from its bytes, so the card can say "issue a quest"
##     and the fold can find quests among the room's intents;
##   * questsOf — the quests the room has proposed, with their terms when the room holds
##     text that hashes to the record's hash, never otherwise;
##   * verifyQuestAttestation — what anyone outside the room checks from chain reads alone:
##     the record closed, its issuer this multisig's vault, the closing proposal executed,
##     committing to this quest's Close, approved by at least the threshold.

import std/[json, strutils, sequtils]
import stint
import ../dcbor/dcbor
import ../hashing/hash_input
import ../log/log
import ../intents/materialization
import ../lez/multisig
import ../lez/multisig_chain
import ../lez/quest
import ../drivers/lez_multisig
import ./intent_events

type
  QuestTerms* = object
    task*: string
    bounty*: UInt128          ## native LEZ, base units
    confirmer*: string        ## the confirmer's LEZ account, 32 bytes hex
    taker*: string            ## the named taker's LEZ account, or "" (anyone but the confirmer)
    salt*: string             ## hex; makes the same task issued twice two quests

  QuestCallKind* = enum
    qkOpen = "open", qkAccept = "accept", qkConfirm = "confirm", qkClose = "close", qkCancel = "cancel"

  QuestCall* = object
    kind*: QuestCallKind
    questId*: seq[byte]
    issuer*: seq[byte]        ## the record's issuer, from the call's rows
    record*: seq[byte]
    termsHash*: seq[byte]
    bounty*: UInt128
    confirmer*: seq[byte]
    taker*: seq[byte]

  QuestView* = object
    questId*: seq[byte]
    issuer*: seq[byte]
    record*: seq[byte]
    termsHash*: seq[byte]
    bounty*: UInt128
    openIntent*: string       ## the room intent whose call opens it
    closeIntent*: string      ## the room intent whose call closes it ("" = none proposed)
    closeIndex*: uint64       ## that intent's on-chain proposal index (what a verifier names)
    termsFound*: bool
    terms*: QuestTerms

  QuestAttestation* = object
    ok*: bool
    why*: string
    issuer*, taker*, confirmer*, termsHash*: seq[byte]
    bounty*: UInt128
    approvals*: int           ## the closing proposal's approvals by current members
    threshold*: int

const
  TermsDomain = "muster.quest.terms.v1"
  QuestIdDomain = "muster.quest.id.v1"

proc unhex(s: string): seq[byte] =
  var h = s
  if h.startsWith("0x") or h.startsWith("0X"): h = h[2 .. ^1]
  if h.len mod 2 != 0: raise newException(ValueError, "odd-length hex")
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc hx(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

# ── the terms ─────────────────────────────────────────────────────────────────
proc questTermsJson*(t: QuestTerms): string =
  $(%*{"task": t.task, "bounty": $t.bounty, "confirmer": t.confirmer.toLowerAscii(),
       "taker": t.taker.toLowerAscii(), "salt": t.salt.toLowerAscii()})

proc parseQuestTerms*(s: string): tuple[ok: bool, terms: QuestTerms, why: string] =
  try:
    let j = parseJson(s)
    var t = QuestTerms(task: j{"task"}.getStr(), confirmer: j{"confirmer"}.getStr().toLowerAscii(),
                       taker: j{"taker"}.getStr().toLowerAscii(), salt: j{"salt"}.getStr().toLowerAscii())
    t.bounty = parse(j{"bounty"}.getStr("0"), UInt128)
    if t.task.strip().len == 0: return (false, t, "a quest says what is to be done")
    if unhex(t.confirmer).len != 32: return (false, t, "the confirmer is a 32-byte LEZ account")
    if t.taker.len > 0 and unhex(t.taker).len != 32: return (false, t, "the taker is a 32-byte LEZ account")
    if t.taker.len > 0 and t.taker == t.confirmer: return (false, t, "the taker cannot be the confirmer")
    discard unhex(t.salt)
    (true, t, "")
  except CatchableError as e: (false, QuestTerms(), "not quest terms: " & e.msg)

proc questTermsHash*(t: QuestTerms): seq[byte] =
  ## What the record commits to: a hash-input record over the terms (invariant 5).
  @(digest(hashInput(TermsDomain, @[
    ("task", cbText(t.task)), ("bounty", cbText($t.bounty)),
    ("confirmer", cbBytes(unhex(t.confirmer))), ("taker", cbBytes(unhex(t.taker))),
    ("salt", cbBytes(unhex(t.salt)))])))

proc questIdFor*(issuer, termsHash: seq[byte]): seq[byte] =
  @(digest(hashInput(QuestIdDomain, @[("issuer", cbBytes(issuer)), ("terms", cbBytes(termsHash))])))

# ── the calls ─────────────────────────────────────────────────────────────────
proc zero32(): seq[byte] = newSeq[byte](32)

proc questOpenCall*(questProgram, msProgram: seq[byte], scheme: PdaScheme, createKey: seq[byte],
                    t: QuestTerms): LezAction =
  ## Issue from a multisig's vault: the call the multisig's Execute makes, with the vault's
  ## seed, whose grant carries into the quest program's transfer of the bounty.
  let vault = vaultPda(scheme, msProgram, createKey)
  let qid = questIdFor(vault, questTermsHash(t))
  let rec = questRecordPda(scheme, questProgram, vault, qid)
  var shards = @[(account: rec, program: questProgram), (account: vault, program: questProgram)]
  if t.bounty > 0.stuint(128): shards.add @[(account: vault, program: zero32()), (account: rec, program: zero32())]
  lezCallV03(questProgram, shards, questOpen(qid, questTermsHash(t), t.bounty, unhex(t.confirmer), unhex(t.taker)),
             @[vaultSeed(createKey)])

proc questPersonalOpenCall*(questProgram: seq[byte], scheme: PdaScheme, issuer, questId: seq[byte],
                            t: QuestTerms): LezAction =
  ## Issue from a person's own account, which signs it.
  let rec = questRecordPda(scheme, questProgram, issuer, questId)
  var shards = @[(account: rec, program: questProgram), (account: issuer, program: questProgram)]
  if t.bounty > 0.stuint(128): shards.add @[(account: issuer, program: zero32()), (account: rec, program: zero32())]
  lezCallV03(questProgram, shards, questOpen(questId, questTermsHash(t), t.bounty, unhex(t.confirmer), unhex(t.taker)), @[])

proc questAcceptCall*(questProgram: seq[byte], scheme: PdaScheme, issuer, questId, taker: seq[byte]): LezAction =
  ## The taker's own transaction.
  lezCallV03(questProgram, @[(account: questRecordPda(scheme, questProgram, issuer, questId), program: questProgram),
                             (account: taker, program: questProgram)], questAccept(issuer, questId), @[])

proc questConfirmCall*(questProgram: seq[byte], scheme: PdaScheme, issuer, questId, confirmer: seq[byte]): LezAction =
  ## The confirmer's own transaction.
  lezCallV03(questProgram, @[(account: questRecordPda(scheme, questProgram, issuer, questId), program: questProgram),
                             (account: confirmer, program: questProgram)], questConfirm(issuer, questId), @[])

proc questCloseCall*(questProgram, msProgram: seq[byte], scheme: PdaScheme, createKey, questId, taker: seq[byte],
                     bounty: UInt128): LezAction =
  ## Close from the multisig's vault, paying the taker from the record account.
  let vault = vaultPda(scheme, msProgram, createKey)
  let rec = questRecordPda(scheme, questProgram, vault, questId)
  var shards = @[(account: rec, program: questProgram), (account: vault, program: questProgram)]
  if bounty > 0.stuint(128): shards.add @[(account: rec, program: zero32()), (account: taker, program: zero32())]
  lezCallV03(questProgram, shards, questClose(questId, taker, bounty), @[vaultSeed(createKey)])

proc questCancelCall*(questProgram, msProgram: seq[byte], scheme: PdaScheme, createKey, questId: seq[byte],
                      bounty: UInt128): LezAction =
  let vault = vaultPda(scheme, msProgram, createKey)
  let rec = questRecordPda(scheme, questProgram, vault, questId)
  var shards = @[(account: rec, program: questProgram), (account: vault, program: questProgram)]
  if bounty > 0.stuint(128): shards.add @[(account: rec, program: zero32()), (account: vault, program: zero32())]
  lezCallV03(questProgram, shards, questCancel(questId, bounty), @[vaultSeed(createKey)])

proc questCallOf*(a: LezAction, questProgram: seq[byte]): tuple[ok: bool, call: QuestCall] =
  ## A call read back from its bytes: whether it is the quest program's, and what it does.
  if a.target != questProgram or a.shards.len < 2: return
  var ins: QuestInstruction
  try: ins = decodeQuestInstruction(a.data)
  except LezDecodeError: return
  var c = QuestCall(kind: QuestCallKind(ord(ins.kind)), questId: ins.questId, record: a.shards[0].account,
                    termsHash: ins.termsHash, bounty: ins.bounty, confirmer: ins.confirmer, taker: ins.taker)
  c.issuer = (if ins.kind in {qiAccept, qiConfirm}: ins.issuer else: a.shards[1].account)
  if ins.kind in {qiAccept, qiConfirm}: c.taker = a.shards[1].account
  (true, c)

# ── the room ──────────────────────────────────────────────────────────────────
proc questTermsEvent*(questId: seq[byte], termsJson: string): Event =
  ## The terms' text, into the room. Content-addressed by their hash: whatever is filed under
  ## an id counts only when it hashes to what the record holds.
  Event(key: "quest/" & hx(questId) & "/terms", value: termsJson)

proc questTermsFor*(events: seq[Event], questId, termsHash: seq[byte]): tuple[found: bool, terms: QuestTerms] =
  let k = "quest/" & hx(questId) & "/terms"
  for e in canonicalOrder(events):
    if e.key != k: continue
    let (ok, t, _) = parseQuestTerms(e.value)
    if ok and questTermsHash(t) == termsHash: return (true, t)

proc questIntents(events: seq[Event], questProgram: seq[byte]):
    seq[tuple[id: string, index: uint64, call: QuestCall]] =
  ## Every room intent whose LEZ multisig (v0.3) call is the quest program's, in canonical order.
  var seen: seq[string]
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len != 3 or p[0] != "intent" or p[2] != "propose" or p[1] in seen: continue
    let prop = proposalOf(events, p[1])
    if not prop.found: continue
    try:
      let j = parseJson(prop.effectJson)
      if j{"effect"}.getStr() != "lez-multisig-proposal" or j{"lez"}.getStr() != "v0.3": continue
      let (index, action) = lezActionOf(effectFromJson(prop.effectJson))
      let (ok, qc) = questCallOf(action, questProgram)
      if not ok: continue
      seen.add p[1]
      result.add (p[1], index, qc)
    except CatchableError: discard

proc questsOf*(events: seq[Event], questProgram: seq[byte]): seq[QuestView] =
  ## The quests the room has proposed to issue: every LEZ multisig intent whose call opens a
  ## quest in `questProgram`, once each, with the intent proposing its Close if there is one.
  let all = questIntents(events, questProgram)
  for (id, _, qc) in all:
    if qc.kind != qkOpen or result.anyIt(it.questId == qc.questId): continue
    var v = QuestView(questId: qc.questId, issuer: qc.issuer, record: qc.record, termsHash: qc.termsHash,
                      bounty: qc.bounty, openIntent: id)
    (v.termsFound, v.terms) = questTermsFor(events, qc.questId, qc.termsHash)
    for (cid, cidx, cc) in all:
      if cc.kind == qkClose and cc.questId == qc.questId and cc.record == qc.record:
        (v.closeIntent, v.closeIndex) = (cid, cidx)
        break
    result.add v

proc questReadingOf*(events: seq[Event], effectJson: string, questProgram: seq[byte]):
    tuple[ok: bool, text: string, quest: JsonNode] =
  ## A LEZ multisig proposal's call, read as the quest step it is — the card's line and its
  ## facts — when it is `questProgram`'s; not ok otherwise. The task is named only when the
  ## room holds text that hashes to what the call commits to.
  try:
    let j = parseJson(effectJson)
    if j{"effect"}.getStr() != "lez-multisig-proposal" or j{"lez"}.getStr() != "v0.3": return
    let (index, action) = lezActionOf(effectFromJson(effectJson))
    let (ok, qc) = questCallOf(action, questProgram)
    if not ok: return
    var th = qc.termsHash
    if qc.kind != qkOpen:
      for v in questsOf(events, questProgram):
        if v.questId == qc.questId and v.record == qc.record: th = v.termsHash
    let (found, t) = (if th.len > 0: questTermsFor(events, qc.questId, th) else: (false, QuestTerms()))
    let task = (if found: "“" & t.task & "”" else: "a quest whose terms this room does not hold")
    let short = proc (b: seq[byte]): string = (let h = hx(b); if h.len > 16: h[0 ..< 8] & "…" & h[^6 .. ^1] else: h)
    let text = case qc.kind
      of qkOpen: "on-chain proposal #" & $index & ": issue a quest — " & task & ", bounty " & $qc.bounty &
                 " set aside from the vault"
      of qkClose: "on-chain proposal #" & $index & ": close the quest " & task & " and pay its " & $qc.bounty &
                  " to " & short(qc.taker)
      of qkCancel: "on-chain proposal #" & $index & ": withdraw the quest " & task & ", its " & $qc.bounty &
                   " back to the vault"
      of qkAccept, qkConfirm: "on-chain proposal #" & $index & ": " & $qc.kind & " the quest " & task
    var q = %*{"step": $qc.kind, "questId": hx(qc.questId), "record": hx(qc.record), "bounty": $qc.bounty,
               "termsFound": found}
    if found: q["terms"] = parseJson(questTermsJson(t))
    if qc.taker.len > 0: q["taker"] = %hx(qc.taker)
    if qc.confirmer.len > 0: q["confirmer"] = %hx(qc.confirmer)
    (true, text, q)
  except CatchableError: (false, "", nil)

# ── outside the room ──────────────────────────────────────────────────────────
proc verifyQuestAttestation*(chain: LezMultisigChain, questProgram, record, createKey: seq[byte],
                             closeIndex: uint64): QuestAttestation =
  ## What anyone holding the record's id, the multisig's create key and the closing
  ## proposal's index can check from the chain alone, needing no room key: the record is the
  ## quest program's and closed; its issuer is this multisig's vault; proposal #closeIndex is
  ## executed and commits to this quest's Close; at least the threshold of current members
  ## approved it.
  template no(msg: string) =
    result.why = msg
    return
  let r = chain.readShard(record, questProgram)
  if not r.found or r.data.len == 0: no("no record at that account")
  var q: QuestRecord
  try: q = decodeQuestRecord(r.data)
  except LezDecodeError as e: no("not a quest record: " & e.msg)
  if questRecordPda(chain.scheme, questProgram, q.issuer, q.questId) != record:
    no("the account is not this quest program's record")
  (result.issuer, result.taker, result.confirmer, result.termsHash, result.bounty) =
    (q.issuer, q.statusTaker, q.confirmer, q.termsHash, q.bounty)
  if q.issuer != vaultPda(chain.scheme, chain.program, createKey): no("the quest's issuer is not this multisig's vault")
  if q.status != qsClosed: no("the quest is " & $q.status & ", not closed")
  let (pfound, prop, _) = chain.readProposal(createKey, closeIndex)
  if not pfound: no("no proposal #" & $closeIndex)
  if prop.hasConfig: no("proposal #" & $closeIndex & " is not a Close of this quest")
  let (cok, qc) = questCallOf(prop.action, questProgram)
  if not cok or qc.kind != qkClose or qc.questId != q.questId or qc.record != record or qc.taker != q.statusTaker:
    no("proposal #" & $closeIndex & " is not a Close of this quest")
  if prop.status != psExecuted: no("proposal #" & $closeIndex & " was not executed")
  let (sfound, st, _) = chain.readState(createKey)
  if not sfound: no("no multisig at that create key")
  result.threshold = st.threshold
  result.approvals = prop.approved.countIt(it in st.members)
  if result.approvals < result.threshold: no("fewer current members approved the close than the threshold")
  result.ok = true
