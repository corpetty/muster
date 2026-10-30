## derived-exo-dcc.5 s3, extended (2026-10-30): a payer who sent too little tops it up. A
## part ALONE at its subaddress (every request and send) is confirmed by its creditor's own
## wallet when one incoming transfer there is exactly the share, or when every unclaimed
## incoming transfer there together comes to exactly the share, each at the agreed depth;
## the part's reference is then every one of those txids, sorted and comma-joined. A part
## that shares its subaddress with another (a split whose debtors pay one payTo, told apart
## by amount) is confirmed only by one transfer of exactly its share, as before — transfers
## never add up across debtors. Until it is confirmed, the creditor's own client shows how
## much has arrived at a part alone at its subaddress.
##
## STEPPER: layout {alone: Bob owes the share; shared: Bob owes it, Carol another amount, at
## the same subaddress} x depth {every row 10 deep; the last row 9 deep} x the rows at payTo
## {S/2 + S/2; S/4 + 3S/4; S/2 alone; S/2 + (S/2 + 1); S/2 + S; S/3 + S/3 + rest}: 24 cases.
## State = one (layout, depth) pair (4 states, chained state -> state+1); each checks its 6
## rows patterns, each in a fresh room, through Alice's REAL confirm pump
## (xmr_request.xmrConfirmPump over her MoneroPartSeam) and her REAL seen-parts read
## (xmrSeenParts). The rule, stated alone:
##   * Bob's part is confirmed iff some row is exactly the share at depth, or — alone only —
##     the rows (more than one) sum to exactly the share and every one is at depth;
##   * its reference is then that row's txid, or every row's txid sorted and comma-joined;
##   * Carol's part (whose amount no row matches) is never confirmed;
##   * unconfirmed and alone, Alice's seen-parts read names the rows' sum as received;
##     shared, it names no amount (it cannot tell whose a row is).
## Run by hand (no argv), it checks all 24 with doAssert.

import std/[algorithm, json, strutils, tables]
import ./xmr_room
import ./oracle_emit

const Share = 2_000_000_000_000'u64
const Layouts = ["alone", "shared"]
const Depths = ["all-deep", "last-shallow"]
const Patterns = 6
const N = 4            # states
const CarolOwes = "123456789"

proc rowsOf(p: int): seq[uint64] =
  const S = Share
  case p
  of 0: @[S div 2, S - S div 2]
  of 1: @[S div 4, S - S div 4]
  of 2: @[S div 2]
  of 3: @[S div 2, S - S div 2 + 1]
  of 4: @[S div 2, S]
  else: @[S div 3, S div 3, S - 2 * (S div 3)]

proc caseCorrect(s, p: int): bool =
  let (layout, depth) = (Layouts[s div 2], Depths[s mod 2])
  var x = newXmrRoom("/muster/1/xmr-topup-" & $s & "-" & $p & "/proto", XmrStage)
  let shares = (if layout == "alone": @[(bob, $Share)] else: @[(bob, $Share), (carol, CarolOwes)])
  let (id, payTo) = x.agreedRequest(shares, "topup")
  let w = x.wallet("alice")
  w.status = anAnswered; w.info = anAnswered; w.hist = anAnswered
  let idx = x.subIndexOf(payTo)
  let amounts = rowsOf(p)
  var txids: seq[string]
  var deep: seq[bool]
  w.rows = @[]
  for i, a in amounts:
    let t = txidOf(s * 1000 + p * 10 + i)
    let d = not (depth == "last-shallow" and i == amounts.high)
    txids.add t
    deep.add d
    w.rows.add row(t, "in", $a, (if d: 10 else: 9), $idx)
  # the rule
  var exact = ""
  for i, a in amounts:
    if a == Share and deep[i]: exact = txids[i]
  var total = 0'u64
  for a in amounts: total += a
  var allDeep = true
  for d in deep: allDeep = allDeep and d
  let sums = layout == "alone" and amounts.len > 1 and total == Share and allDeep
  let should = exact.len > 0 or sums
  var want = exact
  if want.len == 0 and sums:
    var ts = txids
    ts.sort()
    want = ts.join(",")
  # the confirm pump, then what Alice's own client reads
  x.r.sync()
  let (sa, ka) = x.r.sessionOf("alice")
  let seenBefore = xmrSeenParts(sa.roomEvents(), xmrFor, x.seamOf("alice"), myIdentity(ka))
  discard x.pump()
  x.r.sync()
  let bobPart = x.partOf(id, "bob")
  if bobPart.confirmed != should: return false
  if should and bobPart.tx.toLowerAscii() != want.toLowerAscii(): return false
  if layout == "shared" and x.partOf(id, "carol").confirmed: return false
  if not should:
    let key = id & "/" & bobPart.part
    let got = (if key in seenBefore: seenBefore[key].received else: "")
    if layout == "alone" and got != $total: return false
    if layout == "shared" and got.len > 0: return false
  true

proc correct(s: int): bool =
  for p in 0 ..< Patterns:
    if not caseCorrect(s, p): return false
  true

proc state(s: int): JsonNode = %*{"case": s, "decision_correct": correct(s)}

let arg = oracleStateArg()
if arg == nil:
  for s in 0 ..< N:
    for p in 0 ..< Patterns:
      doAssert caseCorrect(s, p), "layout " & Layouts[s div 2] & ", " & Depths[s mod 2] & ", rows " &
        $rowsOf(p) & " — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
