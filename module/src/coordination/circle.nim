## A savings circle's rounds from the pot (exo-267.3; docs/design/logos-world-plan.md Phase 1,
## The circle). The circle is a room whose charter in force names a LEZ multisig (the pot) and
## a round schedule: every member pays their share into the multisig's vault each round, and
## round r's payout — the whole pot of the round, n × share — goes to the r-th member of the
## schedule's order, as a vault transfer the members vote on like any other proposal.
##
## Nothing here moves money or decides anything; it reads, so that a member votes knowing:
##   * who has paid in this round — a pay-in counts only when the chain holds it: a
##     transaction the member reported (circle/<account>/<round>/paid/<who>, author-signed)
##     that is included, a native transfer of exactly the share into the vault, signed by an
##     account that member shared with the room (coordination/member_accounts, proved by its
##     own key). One transaction counts for one round. On LEZ v0.3 an included transfer may
##     still have been refused (docs/labbook/lez-v03-migration.md §8), so inclusion is not
##     effect: the vault's balance, read beside it, is what the payout spends.
##   * whether a payout is the schedule's: to the account the round's recipient shared, the
##     round's whole pot, the round next due — or off it, and why (out of order, an account
##     no circle member shared, the wrong amount, a round already paid). A missed pay-in
##     leaves its round open and names who has not paid; nothing is skipped.
## The chain enforces the multisig's members and threshold and the vault's balance; the room
## enforces the schedule. One cycle (each member receives once) for now.
##
## A pure function of the event set and the chain reads it is given (invariant 4).

import std/[json, sequtils, strutils, algorithm, tables]
import stint
import ../log/log
import ../drivers/driver
import ../drivers/kinds
import ../drivers/charter
import ../drivers/lez_multisig
import ../lez/multisig
import ../lez/multisig_chain
import ../lez/tx as leztx
import ./intents
import ./accounts
import ./member_accounts
import ./room_charter

type
  TxReader* = proc (hash: string): TxRead

  CircleSetup* = object
    ok*: bool
    why*: string               ## why the room runs no circle, when not ok
    account*: string           ## the multisig's CAIP-10 id
    chain*: string
    vault*: seq[byte]
    createKey*: seq[byte]
    order*: seq[string]        ## room identities: round r pays order[r-1]
    share*: uint64             ## each member's pay-in per round, native LEZ base units
    n*: int
    cadenceSec*: int64

  PayIn* = object
    member*: string
    round*: int
    tx*: string
    payer*: string             ## the LEZ account that signed it, hex ("" when unread)
    height*: uint64
    standing*: string          ## included | not on chain | not a pay-in | not theirs | counted for round k
    why*: string

  RoundView* = object
    round*: int
    recipient*: string
    payIns*: seq[PayIn]        ## every report for the round, counted or not
    missing*: seq[string]      ## members with no counted pay-in, in the schedule's order
    settled*: bool
    payout*: string            ## the on-schedule payout that settled it

  PayoutView* = object
    intent*: string
    state*: string
    to*: string                ## hex
    amount*: uint64
    round*: int                ## the round it pays, 0 when it matches none
    onSchedule*: bool
    why*: string               ## off schedule: why
    missing*: seq[string]      ## its round's members with no counted pay-in

  CircleView* = object
    setup*: CircleSetup
    rounds*: seq[RoundView]
    payouts*: seq[PayoutView]
    current*: int              ## the round next due (n + 1 once the cycle is complete)
    complete*: bool

proc hx(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

const Zero = newSeq[byte](32)

proc circleSetupOf*(charter: CharterView, accounts: seq[RoomAccount]): CircleSetup =
  ## The circle's terms, from the charter in force and the account it names; not ok, with
  ## the reason, when the room runs no circle from its pot.
  template no(msg: string) = return CircleSetup(ok: false, why: msg)
  if not charter.found: no("the room has no charter in force")
  let b = charter.body
  if not b.hasSchedule: no("the charter has no round schedule")
  if b.schedule.asset.toUpperAscii() != "LEZ": no("rounds from the pot are paid in native LEZ, not " & b.schedule.asset)
  if b.account.len == 0: no("the charter names no account to hold the pot")
  var share: uint64
  try: share = parseBiggestUInt(b.schedule.share)
  except ValueError: no("the schedule's share is not a whole amount")
  let want = b.account.toLowerAscii()
  for a in accounts:
    if a.id.toLowerAscii() != want: continue
    if a.family != LezMultisigFamily: no("the charter's account is not a LEZ multisig")
    let (ok, m, detail) = lezMultisigAccountFromParts(a.chain, a.address, a.config, a.signers, a.threshold)
    if not ok: no(detail)
    if m.layout != plV03: no("rounds from the pot run on the LEZ v0.3 multisig")
    return CircleSetup(ok: true, account: want, chain: a.chain, vault: vaultPda(m.scheme, m.program, m.createKey),
                       createKey: m.createKey, order: b.schedule.order, share: share, n: b.schedule.order.len,
                       cadenceSec: b.schedule.cadenceSec)
  no("the charter's account (" & b.account & ") has not been disclosed in this room")

proc payoutCall*(s: CircleSetup, to: seq[byte], amount: uint64): LezAction =
  ## A payout: a native transfer out of the vault, the vault authorized by its seed.
  lezCallV03(NativeTokenProgram, @[(s.vault, Zero), (to, Zero)], nativeTransfer(amount.stuint(128)),
             @[vaultSeed(s.createKey)])

proc payInCall*(s: CircleSetup, payer: seq[byte]): LezAction =
  ## A member's pay-in: a native transfer of the share from their own account into the vault.
  lezCallV03(NativeTokenProgram, @[(payer, Zero), (s.vault, Zero)], nativeTransfer(s.share.stuint(128)), @[])

proc payInEvent*(account: string, round: int, member, tx: string): Event =
  ## The report a member publishes (author-signed) once they have paid in.
  Event(key: "circle/" & account.toLowerAscii() & "/" & $round & "/paid/" & member.toLowerAscii(),
        value: $(%*{"tx": tx.toLowerAscii()}))

proc nativeTransferOf(a: LezAction): tuple[ok: bool, src, dst: seq[byte], amount: uint64] =
  ## A native transfer's sender, recipient and amount (an amount above u64 reads as none).
  if a.target != NativeTokenProgram or a.shards.len != 2 or a.shards.anyIt(it.program != Zero): return
  if a.data.len != 17 or a.data[0] != 0 or a.data[9 .. 16].anyIt(it != 0): return
  var x: uint64
  for i in 0 ..< 8: x = x or (uint64(a.data[1 + i]) shl uint64(8*i))
  (true, a.shards[0].account, a.shards[1].account, x)

proc sharedBy(events: seq[Event], room, who, chain: string): seq[string] =
  accountsOf(events, room, who, KindLezKey, chain).mapIt(hx(it.address))

proc circleView*(events: seq[Event], driverFor: DriverFor, room: string, s: CircleSetup, readTx: TxReader): CircleView =
  result.setup = s
  if not s.ok: return
  let shared = s.order.mapIt(sharedBy(events, room, it, s.chain))
  # every pay-in report, once each, in a canonical order: round, then the schedule's order
  let prefix = "circle/" & s.account & "/"
  var reports: seq[tuple[round, idx: int, member, tx: string]]
  for e in events:
    if not e.key.startsWith(prefix): continue
    let p = e.key[prefix.len .. ^1].split('/')
    if p.len != 3 or p[1] != "paid": continue
    var round: int
    try: round = parseInt(p[0])
    except ValueError: continue
    let idx = s.order.find(p[2])
    if round < 1 or round > s.n or idx < 0: continue
    var tx = ""
    try: tx = parseJson(e.value){"tx"}.getStr().toLowerAscii()
    except CatchableError: continue
    let r = (round, idx, p[2], tx)
    if r notin reports: reports.add r
  reports.sort(proc (a, b: tuple[round, idx: int, member, tx: string]): int =
    result = cmp(a.round, b.round)
    if result == 0: result = cmp(a.idx, b.idx)
    if result == 0: result = cmp(a.tx, b.tx))

  var countedIn = initTable[string, int]()   # tx → the round it counted for
  for i in 1 .. s.n:
    result.rounds.add RoundView(round: i, recipient: s.order[i - 1])
  var paid = initTable[(int, int), bool]()
  for (round, idx, member, tx) in reports:
    var pi = PayIn(member: member, round: round, tx: tx)
    let t = readTx(tx)
    if not t.known:
      (pi.standing, pi.why) = ("not on chain", "the chain holds no transaction " & tx)
    else:
      pi.payer = hx(t.signer)
      pi.height = t.height
      let (ok, src, dst, amount) = nativeTransferOf(t.call)
      if not ok or dst != s.vault or src != t.signer:
        (pi.standing, pi.why) = ("not a pay-in", "not a transfer from its signer into the circle's vault")
      elif amount != s.share:
        (pi.standing, pi.why) = ("not a pay-in", "pays " & $amount & "; a share is " & $s.share)
      elif pi.payer notin shared[idx]:
        (pi.standing, pi.why) = ("not theirs", "signed by an account this member has not shared with the room")
      elif tx in countedIn:
        (pi.standing, pi.why) = ("counted for round " & $countedIn[tx], "one transaction pays one round")
      else:
        pi.standing = "included"
        countedIn[tx] = round
        paid[(round, idx)] = true
    result.rounds[round - 1].payIns.add pi
  for rv in result.rounds.mitems:
    for i, m in s.order:
      if not paid.getOrDefault((rv.round, i)): rv.missing.add m

  # payouts: vault transfers the multisig was asked to make, matched to a round
  let policy = qualify("lez-multisig", s.account)
  let pot = s.share * uint64(s.n)
  var cands: seq[PayoutView]
  for v in reduceIntentViews(events, driverFor):
    if v.policy.toLowerAscii() != policy or v.effectJson.len == 0: continue
    try:
      let j = parseJson(v.effectJson)
      if j{"effect"}.getStr() != "lez-multisig-proposal" or j{"lez"}.getStr() != "v0.3": continue
      let (_, action) = lezActionOf(effectFromJson(v.effectJson))
      let (ok, src, dst, amount) = nativeTransferOf(action)
      if not ok or src != s.vault: continue
      var p = PayoutView(intent: v.id, state: v.state, to: hx(dst), amount: amount)
      for i in 0 ..< s.n:
        if p.to in shared[i]: p.round = i + 1
      cands.add p
    except CatchableError: discard
  cands.sort(proc (a, b: PayoutView): int = cmp(a.intent, b.intent))
  for p in cands.mitems:
    if p.round == 0: p.why = "pays an account no circle member shared with the room"
    elif p.amount != pot: p.why = "pays " & $p.amount & "; round " & $p.round & " pays the pot, " & $pot
  for rv in result.rounds.mitems:
    for p in cands.mitems:
      if p.round != rv.round or p.why.len > 0 or p.state != "final": continue
      if rv.settled: p.why = "round " & $rv.round & " was paid twice"
      else: (rv.settled, rv.payout, p.onSchedule) = (true, p.intent, true)
  result.current = s.n + 1
  for rv in result.rounds:
    if not rv.settled:
      result.current = rv.round
      break
  result.complete = result.current > s.n
  for p in cands.mitems:
    if p.round > 0: p.missing = result.rounds[p.round - 1].missing
    if p.why.len > 0 or p.onSchedule: continue
    if result.rounds[p.round - 1].settled: p.why = "round " & $p.round & " is already paid"
    elif p.round != result.current:
      p.why = "out of order: round " & $result.current & " comes first"
    else: p.onSchedule = true
  result.payouts = cands

proc toJson(p: PayIn): JsonNode =
  %*{"member": p.member, "round": p.round, "tx": p.tx, "payer": p.payer, "height": p.height,
     "standing": p.standing, "why": p.why}

proc toJson(p: PayoutView): JsonNode =
  %*{"intent": p.intent, "state": p.state, "to": p.to, "amount": $p.amount, "round": p.round,
     "onSchedule": p.onSchedule, "why": p.why, "missing": p.missing}

proc circleJson*(v: CircleView): JsonNode =
  ## The circle for its members: its terms, each round (who receives, who has paid in, whether
  ## it is settled), and every payout asked of the vault with whether it is the schedule's.
  let s = v.setup
  result = %*{"ok": s.ok, "why": s.why}
  if not s.ok: return
  result["account"] = %s.account
  result["chain"] = %s.chain
  result["vault"] = %hx(s.vault)
  result["share"] = %($s.share)
  result["pot"] = %($(s.share * uint64(s.n)))
  result["order"] = %s.order
  result["cadence"] = %s.cadenceSec
  result["current"] = %v.current
  result["complete"] = %v.complete
  result["rounds"] = %v.rounds.mapIt(%*{"round": it.round, "recipient": it.recipient, "settled": it.settled,
                                        "payout": it.payout, "missing": it.missing,
                                        "payIns": it.payIns.mapIt(it.toJson())})
  result["payouts"] = %v.payouts.mapIt(it.toJson())

proc circleReadingOf*(v: CircleView, intentId: string): tuple[ok: bool, reading: JsonNode] =
  ## A payout proposal as its card reads it: the round it pays and whether that is the
  ## schedule's, and who has not paid in.
  for p in v.payouts:
    if p.intent == intentId:
      var j = p.toJson()
      if p.round > 0: j["recipient"] = %v.rounds[p.round - 1].recipient
      j["n"] = %v.setup.n
      return (true, j)
  (false, newJNull())
