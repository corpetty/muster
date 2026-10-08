## derived-exo-dcc.5 s3: only the creditor's own wallet read confirms a part — an incoming
## transfer in its history to payTo's subaddress, of exactly the share, with at least 10
## confirmations. A debtor's report, a txid alone, an amount off by one atomic unit, another
## subaddress, fewer confirmations, or a busy or unread wallet read never confirms it; an
## unread read is not yet known, never paid and never failed.
##
## STEPPER: the case space is direction {in, out} x subaddress {payTo's, another} x amount
## {share - 1, share, share + 1} x confirmations {0, 9, 10, 11} x failed {no, yes} x the
## wallet read {answered, busy, unreachable} x Bob's report {none, the matching txid, an
## unrelated txid}: 864 cases. Each runs against Alice's agreed request (Bob owes the share,
## Carol another amount) with Bob's report if any — a fresh room for each case after one
## that confirmed; one that confirms nothing leaves the room exactly as it found it, which
## is checked — ONE row in Alice's wallet history, and Alice's REAL confirm pump
## (xmr_request.xmrConfirmPump over her MoneroPartSeam), then her by-hand confirm from her
## wallet with the reported txid, the "txid alone" path.
## State = one (direction, failed, read, report) group of 24 cases (36 states, chained
## state -> state+1); each state checks its 24 — every case at 36 grader calls rather than
## 864 (each call is a separate `nim r`). The rule, stated alone:
##   * Bob's part is confirmed iff the row is in, on payTo's subaddress, exactly the share,
##     at least 10 deep, not failed, and the read answered; its reference is then the row's
##     txid;
##   * otherwise nothing is published: the log is unchanged, Bob's part unconfirmed, the
##     request not final — and a busy or unreachable read leaves it exactly as it was
##     (pending, never released, never failed); the by-hand confirm with the reported txid
##     confirms nothing either;
##   * Carol's part (whose amount the row never matches) is never confirmed.
## Run by hand (no argv), it checks all 864 with doAssert.

import std/[json, strutils]
import ./xmr_room
import ./oracle_emit

const Dirs = ["in", "out"]
const Fails = [false, true]
const Reads = [anAnswered, anBusy, anUnreachable]
const Reports = ["none", "matching", "unrelated"]
const Subs = ["payTo", "another"]
const Deltas = [-1, 0, 1]
const Confs = [0, 9, 10, 11]
const N = 36           # states
const PerState = 24    # cases a state checks
const Share = 2_000_000_000_000'u64

proc group(s: int): tuple[dir, failed, read, report: int] = (s div 18, (s mod 18) div 9, (s mod 9) div 3, s mod 3)
proc inGroup(c: int): tuple[sub, delta, conf: int] = (c div 12, (c mod 12) div 4, c mod 4)

type Fixture = object
  x: XmrRoom
  id, payTo: string
  other: Subaddress
  fresh: bool            ## no case has confirmed anything in it yet
  state: int

var fx: Fixture

proc fixture(s, c, rep: int): bool =
  ## Alice's agreed request and Bob's report (by the state's report kind, on the txid this
  ## case will use when it matches): reused while no case has confirmed in it.
  let txid = txidOf(s * 100)
  if fx.fresh and fx.state == s: return true
  fx = Fixture(x: newXmrRoom("/muster/1/xmr-confirm-" & $s & "-" & $c & "/proto", XmrStage), fresh: true, state: s)
  let (id, payTo) = fx.x.agreedRequest(@[(bob, $Share), (carol, "123456789")], "confirm")
  fx.id = id
  fx.payTo = payTo
  fx.other = fx.x.wallet("alice").mint("muster:other")
  let reported = (case Reports[rep]
                  of "matching": txid
                  of "unrelated": txidOf(99_999)
                  else: "")
  if Reports[rep] != "none":
    if fx.x.reportPaid("bob", id, reported) != "submitted": return false
  true

proc caseCorrect(s, c: int): bool =
  let (di, fi, ri, rep) = group(s)
  let (si, dl, ci) = inGroup(c)
  if not fixture(s, c, rep): return false
  let x = fx.x
  let (id, payTo, other) = (fx.id, fx.payTo, fx.other)
  let w = x.wallet("alice")
  w.status = anAnswered; w.info = anAnswered; w.hist = anAnswered
  let txid = txidOf(s * 100)          # one transfer per state: a room that confirmed it is replaced
  let reported = (case Reports[rep]
                  of "matching": txid
                  of "unrelated": txidOf(99_999)
                  else: "")
  let before = x.stateOf(id)
  let idx = (if Subs[si] == "payTo": x.subIndexOf(payTo) else: other.index)
  let amount = $(int64(Share) + int64(Deltas[dl]))
  w.rows = @[row(txid, Dirs[di], amount, Confs[ci], $idx, failed = Fails[fi])]
  case Reads[ri]
  of anAnswered: discard
  of anBusy: w.hist = anBusy                       # the wallet is held: history answers busy
  of anUnreachable:                                # the backend does not answer at all
    w.status = anUnreachable; w.info = anUnreachable; w.hist = anUnreachable
  let should = Dirs[di] == "in" and Subs[si] == "payTo" and Deltas[dl] == 0 and Confs[ci] >= 10 and
               not Fails[fi] and Reads[ri] == anAnswered
  x.r.sync()
  let logBefore = x.r.alice.roomEvents().len
  let got = x.pump()
  x.r.sync()
  let bobPart = x.partOf(id, "bob")
  if bobPart.confirmed != should: return false
  if got.len != (if should: 1 else: 0): return false
  if x.partOf(id, "carol").confirmed: return false
  if should:
    fx.fresh = false
    if bobPart.tx != txid: return false
    if x.stateOf(id) != "settling": return false
  else:
    # nothing published: the read was not a confirmation, and not a failure either
    if x.r.alice.roomEvents().len != logBefore: return false
    if x.stateOf(id) != before: return false
    if bobPart.settled != (Reports[rep] != "none"): return false
    if bobPart.confirmed: return false
    # the txid alone, by hand: still nothing
    if reported.len > 0:
      let (sa, ka) = x.r.sessionOf("alice")
      let r = liveConfirmPart(sa, ka, xmrFor, id, partName(bob), x.seamOf("alice", cmNow), reported)
      if r in ["submitted", "settling", "final"]: return false
      if x.partOf(id, "bob").confirmed: return false
  true

proc correct(s: int): bool =
  for c in 0 ..< PerState:
    if not caseCorrect(s, c): return false
  true

proc state(s: int): JsonNode = %*{"case": s, "decision_correct": correct(s)}

let arg = oracleStateArg()
if arg == nil:
  for s in 0 ..< N:
    for c in 0 ..< PerState:
      let (di, fi, ri, rep) = group(s)
      let (si, dl, ci) = inGroup(c)
      doAssert caseCorrect(s, c), "state " & $s & " case " & $c & ": " & Dirs[di] & ", failed " & $Fails[fi] &
        ", read " & $Reads[ri] & ", report " & Reports[rep] & ", sub " & Subs[si] & ", delta " & $Deltas[dl] &
        ", " & $Confs[ci] & " confirmations — judged wrongly"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
