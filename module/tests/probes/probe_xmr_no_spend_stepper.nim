## derived-exo-dcc.5 s6: muster never spends — on the request's paths it calls only the wallet
## backend's read and mint methods (wallet status, receive info, create subaddress, history,
## caller identity) and never a method that builds, signs or broadcasts a transfer or changes
## the wallet's roles.
##
## STEPPER: state = how far through a request the case drives (eleven states, chained
## case -> case+1), each through the REAL paths the module hosts (coordination/
## xmr_request.nim, the parts seam), every member with their own RECORDING fake
## monero_wallet_backend (fake_monero.nim records every method it is asked, whatever it is):
##   0 Alice mints a subaddress and proposes;  1 Bob and Carol agree;  2 each debtor's link
##   is shown;  3 Bob says he paid;  4 Alice's confirm pump ticks with nothing arrived;
##   5 Bob's transfer arrives and the pump confirms it;  6 Alice confirms Carol's part from
##   her wallet by hand;  7 a second request's part is marked received (her word);  8 a
##   relaunch — a fresh seam, pumped again;  9 Bob asks muster to pay his share of a third
##   request (the hosted settle path);  10 Alice shares a fresh subaddress and Bob proposes
##   a request on her behalf, which she agrees to.
## Each case runs every step up to its own and then checks. The rule, stated alone:
##   * every method any member's backend was asked is on {wallet_status, receive_info,
##     create_subaddress, history, caller_identity, list_networks, address_valid}, and none
##     is prepare_send, confirm_send, cancel_send, configure, set_*, reveal_*, open_wallet,
##     close_wallet or restore_*;
##   * asked to pay, muster refuses and sends nothing — the debtor pays from their own wallet;
##   * each step did what it says (so an empty record is never vacuous).
## Run by hand (no argv), it checks all 11 with doAssert.

import std/[json, strutils]
import ./xmr_room
import ./oracle_emit

const N = 11

proc run(k: int): bool =
  var x = newXmrRoom("/muster/1/xmr-nospend-" & $k & "/proto", XmrStage)
  let w = x.wallet("alice")
  # 0 propose
  let m = xmrMintPayTo(w, XmrStage, xmrRequestLabel(XmrStage, "500", "nospend", 1))
  if not m.ok: return false
  let id = x.propose("alice", x.requestJson(m.address, @[(bob, "300"), (carol, "200")], "nospend"))
  if not id.startsWith("0x"): return false
  if k >= 1:
    x.r.sync()
    if x.agree("bob", id) notin ["collecting", "executable"]: return false
    if x.agree("carol", id) != "executable": return false
  if k >= 2:
    for d in ["bob", "carol"]:
      if not x.linkOf(d, id, d).ok: return false
  if k >= 3:
    if x.reportPaid("bob", id, txidOf(1)) != "submitted": return false
  let idx = $x.subIndexOf(m.address)
  if k >= 4:
    for _ in 0 ..< 3:
      if x.pump().len != 0: return false
  if k >= 5:
    w.rows = @[row(txidOf(1), "in", "300", 10, idx)]
    if x.pump().len != 1 or not x.partOf(id, "bob").confirmed: return false
  if k >= 6:
    w.rows.add row(txidOf(2), "in", "200", 30, idx)
    let (s, ks) = x.r.sessionOf("alice")
    if xmrConfirmByHand(s, ks, xmrFor, x.seamOf("alice", cmNow), id, partName(carol), fromWallet = true) != "final":
      return false
  if k >= 7:
    let m2 = xmrMintPayTo(w, XmrStage, xmrRequestLabel(XmrStage, "40", "cash", 2))
    let id2 = x.propose("alice", x.requestJson(m2.address, @[(bob, "40")], "cash"))
    x.r.sync()
    if x.agree("bob", id2) != "executable": return false
    let (s, ks) = x.r.sessionOf("alice")
    if xmrConfirmByHand(s, ks, xmrFor, x.seamOf("alice", cmNow), id2, partName(bob), fromWallet = false) != "final":
      return false
  if k >= 8:
    # relaunch: no seam or backend view survives; a fresh one reads the same wallet
    let (s, ks) = x.r.sessionOf("alice")
    for _ in 0 ..< 2: discard xmrConfirmPump(s, ks, xmrFor, newMoneroPartSeam(XmrStage, w))
    if x.stateOf(id) != "final": return false
  if k >= 9:
    let m3 = xmrMintPayTo(w, XmrStage, xmrRequestLabel(XmrStage, "77", "pay", 3))
    let id3 = x.propose("alice", x.requestJson(m3.address, @[(bob, "77")], "pay"))
    x.r.sync()
    if x.agree("bob", id3) != "executable": return false
    let (sb, kb) = x.r.sessionOf("bob")
    let (outcome, _) = liveSettlePartSend(sb, kb, xmrFor, id3, x.seamOf("bob", cmNow), Now)
    if not outcome.startsWith("refused: the payment was not sent: muster never sends Monero"): return false
  if k >= 10:
    let shared = xmrMintPayTo(w, XmrStage, "muster:share")
    if not shared.ok: return false
    let (s, ks) = x.r.sessionOf("alice")
    let (_, ev) = newMessageEvent("0x" & alice, int64(Now), $xmrShareBody(XmrStage, shared.address), 9)
    s.publishAuthored(ks, ev)
    x.r.sync()
    let onBehalf = sharedMoneroAddressOf(x.r.bob.roomEvents(), alice, XmrStage)
    let id4 = x.propose("bob", x.requestJson(onBehalf, @[(bob, "61"), (carol, "60")], "behalf"))
    x.r.sync()
    if x.agree("alice", id4) != "collecting": return false
  # the record: read and mint only, on every member's backend
  for who in ["alice", "bob", "carol", "dave"]:
    if not x.wallet(who).onlyAllowed(): return false
  w.calls.len > 0

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": run(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert run(k), "case " & $k & ": a request path called a wallet method that is not read or mint"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
