## The XMR payment request (exo-dcc.5, ADR-018): monero.split, the creditor's wallet seam
## over monero_wallet_backend, and the request's live path — over a recording fake backend
## (tests/probes/fake_monero.nim) that answers the backend's own double-encoded replies.
##
##   1. the driver: monero-split on monero:<ref>, XMR in atomic units; payTo a standard
##      address or subaddress of the agreed network (never integrated, never another
##      network, never a bad checksum); distinct shares at one subaddress; no share above a
##      Monero amount; its profile (each locus, binding implicit, shielded) and manifest
##      (monero_wallet_backend, installed by monero_wallet_ui); never netted
##   2. the backend seam: replies double-encoded, busy and unanswered read as unread,
##      subaddrIndex a comma-joined string, the call set closed (a spend is refused unsent)
##   3. the confirm rule, pure: in, payTo's subaddress alone, exactly the share, 10 deep,
##      not failed, unclaimed, from a wallet on the agreed network that can spend
##   4. live: mint → propose → agree → each debtor's link (from the agreed effect) → "I
##      paid" (never final) → the creditor's own history confirms each part → final on every
##      client; one transfer never settles two parts; a wallet on another network confirms
##      nothing; only read and mint methods were asked
##   5. on someone's behalf: the creditor's shared subaddress, agreed only if their own
##      wallet lists it

import std/[json, strutils, sets]
import ../src/drivers/manifest
import ../src/drivers/profile
import ./probes/xmr_room

# ── 1. the driver ─────────────────────────────────────────────────────────────
block driver:
  let d = newSplitDriver(MoneroSplitFamily, XmrStage, roster)
  let w = newFakeMonero("wallet-alice", "stagenet")
  let sub = w.mint().address
  proc eff(payTo: string, shares = @[(bob, "1000000000000"), (carol, "500000000000")], asset = "XMR"): Effect =
    var ss: seq[SplitShare]
    for (who, a) in shares: ss.add SplitShare(who: who, amount: a)
    effectFromJson(splitEffectJson(XmrStage, asset, "1500000000000", alice, payTo, ss, "rent"))
  doAssert d.signRefusal(eff(sub)) == "", d.signRefusal(eff(sub))
  doAssert d.signRefusal(eff(w.primary)) == "", "a standard address is a payTo too"
  # another network, an integrated address, a corrupted checksum
  doAssert "a mainnet address" in d.signRefusal(eff(walletAddress("wallet-alice", xmrMainnet, 1)))
  doAssert "integrated" in d.signRefusal(eff(walletAddress("wallet-alice", xmrStagenet, 1, makIntegrated)))
  var bad = sub
  bad[20] = (if bad[20] == 'A': 'B' else: 'A')
  doAssert d.signRefusal(eff(bad)).len > 0
  doAssert "XMR" in d.signRefusal(eff(sub, asset = "ETH"))
  # two debtors owing the same amount at one subaddress: refused at proposal (s4)
  doAssert "differ" in d.signRefusal(eff(sub, @[(bob, "700000000000"), (carol, "700000000000")]))
  # every share a Monero amount
  doAssert "Monero amount" in d.signRefusal(effectFromJson(splitEffectJson(XmrStage, "XMR", "18446744073709551616",
    alice, sub, @[SplitShare(who: bob, amount: "18446744073709551616")], "big")))
  doAssert d.signRefusal(effectFromJson(splitEffectJson(XmrStage, "XMR", "18446744073709551615",
    alice, sub, @[SplitShare(who: bob, amount: "18446744073709551615")], "max"))) == ""
  # the threshold: every debtor and the creditor
  doAssert d.describeFor(eff(sub)).threshold == 3
  # profile and manifest
  let p = d.profile().toJson()
  doAssert p["family"].getStr() == "monero.split" and p["settlement"].getStr() == "monero"
  doAssert p["locus"].getStr() == "each" and p["binding"].getStr() == "implicit"
  doAssert p["reveals"]["effect"].getStr() == "shielded" and p["reveals"]["signers"].getStr() == "never"
  doAssert d.profile().chain == XmrStage
  let m = d.manifest(eff(sub))
  doAssert m.declared
  var modReq = false
  var envReq = false
  for r in m.requirements:
    if r.kind == rqModule and r.name == "monero_wallet_backend" and r.installPackage() == "monero_wallet_ui": modReq = true
    if r.kind == rqEnvironment and r.name == XmrStage: envReq = true
  doAssert modReq and envReq, "the manifest names the wallet backend (install monero_wallet_ui) and the chain"
  doAssert m.consistencyFailures().len == 0, $m.consistencyFailures()
  doAssert familyOfChain(XmrStage) == MoneroSplitFamily
  # never netted
  let su = effectFromJson(settleUpEffectJson(XmrStage, "XMR",
    @[Cover(intent: "0x" & repeat("11", 8), debtor: bob, creditor: alice, amount: "300", payTo: sub)],
    @[NetTransfer(frm: bob, to: alice, payTo: sub, amount: "300")], "x"))
  doAssert "never netted" in d.signRefusal(su)
  let evm = newSplitDriver(EvmSplitFamily, "eip155:31337", roster)
  let su2 = effectFromJson(settleUpEffectJson("eip155:31337", "ETH",
    @[Cover(intent: "0x" & repeat("11", 8), debtor: bob, creditor: alice, amount: "300", payTo: sub,
            chain: XmrStage, asset: "XMR")],
    @[NetTransfer(frm: bob, to: alice, payTo: AlicePayTo, amount: "300")], "x",
    @[SettleRate(chain: XmrStage, asset: "XMR", rate: "1", per: "1", source: "s", at: "1")]))
  doAssert "never netted" in evm.signRefusal(su2), evm.signRefusal(su2)
  echo "1. the driver: monero.split, its payTo rules, distinct shares, profile, manifest, never netted OK"

# ── 2. the backend seam ─────────────────────────────────────────────────────────
block backend:
  let w = newFakeMonero("wallet-alice", "stagenet")
  doAssert moneroReply("\"{\\\"ok\\\":true,\\\"x\\\":1}\"")["x"].getInt() == 1, "a tstr reply is unwrapped"
  doAssert moneroReply("""{"success":true,"value":"{\"ok\":true}"}""")["ok"].getBool()
  doAssert moneroReply("") == nil and moneroReply("""{"success":false,"value":null}""") == nil
  let st = w.walletStatus()
  doAssert st.read == rsAnswered and st.network == "stagenet" and st.state == "ready"
  doAssert walletRefusal(st, XmrStage) == ""
  doAssert walletRefusal(st, XmrMain).startsWith("wallet-other-network")
  w.status = anBusy
  doAssert w.walletStatus().read == rsBusy
  w.status = anUnreachable
  doAssert w.walletStatus().read == rsUnread
  w.status = anAnswered
  w.rows = @[row(txidOf(1), "in", "42", 12, "1,4")]
  let h = w.history()
  doAssert h.read == rsAnswered and h.rows[0].subaddrIndex == @[1, 4] and h.rows[0].amount == "42"
  doAssert h.rows[0].confirmations == 12 and h.rows[0].txid == txidOf(1)
  # the call set is closed: a spend raises before anything is sent
  let before = w.calls.len
  for meth in ["prepare_send", "confirm_send", "cancel_send", "configure", "set_active_network",
               "reveal_seed", "open_wallet", "close_wallet", "restore_from_seed"]:
    var refused = false
    try: discard w.call(meth, newJArray())
    except MoneroRefused: refused = true
    doAssert refused, meth & " must be refused"
  doAssert w.calls.len == before, "nothing refused reached the backend"
  echo "2. the backend seam: double-encoded replies, busy/unread, subaddrIndex, a closed call set OK"

# ── 3. the confirm rule, pure ────────────────────────────────────────────────────
block rule:
  let w = newFakeMonero("wallet-alice", "stagenet")
  let sub = w.mint()
  let other = w.mint()
  let t = PartTransfer(ok: true, chain: XmrStage, asset: "XMR", to: sub.address, amount: "1000")
  let st = w.walletStatus()
  let info = w.receiveInfo()
  proc verdict(rows: seq[JsonNode], claimed = initHashSet[string]()): XmrVerdict =
    w.rows = rows
    matchXmrPayment(t, st, info, w.history(), claimed).verdict
  doAssert verdict(@[row(txidOf(1), "in", "1000", 10, $sub.index)]) == xvConfirmed
  doAssert verdict(@[row(txidOf(1), "in", "999", 10, $sub.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1001", 10, $sub.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1000", 9, $sub.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1000", 10, $other.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1000", 10, $sub.index & "," & $other.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "out", "1000", 10, $sub.index)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1000", 10, $sub.index, failed = true)]) == xvPending
  doAssert verdict(@[row(txidOf(1), "in", "1000", 10, $sub.index)], toHashSet([txidOf(1)])) == xvPending
  # a busy or unanswered history is pending — never paid, never refused
  w.rows = @[row(txidOf(1), "in", "1000", 10, $sub.index)]
  doAssert matchXmrPayment(t, st, info, History(read: rsBusy), initHashSet[string]()).verdict == xvPending
  doAssert matchXmrPayment(t, st, info, History(read: rsUnread), initHashSet[string]()).verdict == xvPending
  # the wallet on another network, or view-only: refused, whatever the history
  let main = newFakeMonero("wallet-alice", "mainnet")
  let r = matchXmrPayment(t, main.walletStatus(), info, w.history(), initHashSet[string]())
  doAssert r.verdict == xvRefused and "another network" in r.detail, r.detail
  w.watchOnly = true
  doAssert matchXmrPayment(t, w.walletStatus(), info, w.history(), initHashSet[string]()).verdict == xvRefused
  echo "3. the confirm rule: in, payTo's subaddress alone, exact, 10 deep, not failed, unclaimed, same network OK"

# ── 4. live: the request end to end ───────────────────────────────────────────────
block live:
  var x = newXmrRoom("/muster/1/xmr-live/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "1500000000000"), (carol, "250000000000")], "rent")
  doAssert x.stateOf(id) == "executable"
  # each debtor's link, from the agreed effect alone (no memo)
  let lb = x.linkOf("bob", id, "bob")
  doAssert lb.ok and lb.uri == makePaymentUri(XmrStage, payTo, 1_500_000_000_000'u64).uri, lb.uri & " " & lb.why
  doAssert lb.uri == "monero:" & payTo & "?tx_amount=1.500000000000"
  doAssert "rent" notin lb.uri
  doAssert x.linkOf("dave", id, "carol").uri == makePaymentUri(XmrStage, payTo, 250_000_000_000'u64).uri
  # "I paid" never confirms: submitted, not final, and the pump finds nothing yet
  doAssert x.reportPaid("bob", id, txidOf(7)) == "submitted"
  doAssert x.reportPaid("bob", id, txidOf(7)) == "already-settled"
  doAssert x.reportPaid("dave", id, "") == "not-a-party"
  doAssert x.reportPaid("carol", id, "not-a-txid") == "bad-txid"
  doAssert x.pump().len == 0 and x.stateOf(id) == "submitted"
  # Bob's transfer lands, 9 deep: still pending
  let si = x.subIndexOf(payTo)
  x.wallet("alice").rows = @[row(txidOf(7), "in", "1500000000000", 9, $si)]
  doAssert x.pump().len == 0 and not x.partOf(id, "bob").confirmed
  # 10 deep: confirmed, by the creditor's own read
  x.wallet("alice").rows = @[row(txidOf(7), "in", "1500000000000", 10, $si)]
  doAssert x.pump() == @[id & "/" & partName(bob)]
  doAssert x.partOf(id, "bob").confirmed and x.partOf(id, "bob").tx == txidOf(7)
  doAssert x.stateOf(id) == "settling"
  # Carol never reported: her transfer still confirms her part (the read decides)
  x.wallet("alice").rows.add row(txidOf(8), "in", "250000000000", 11, $si)
  doAssert x.pump() == @[id & "/" & partName(carol)]
  for viewer in ["alice", "bob", "carol", "dave"]:
    doAssert x.stateOf(id, viewer) == "final", viewer & " sees " & x.stateOf(id, viewer)
  doAssert x.wallet("alice").onlyAllowed(), $x.wallet("alice").calls
  for n in ["bob", "carol", "dave"]: doAssert x.wallet(n).calls.len == 0 or x.wallet(n).onlyAllowed()
  echo "4a. mint → propose → agree → link → I paid → the creditor's history confirms → final everywhere OK"

block oneRef:
  var x = newXmrRoom("/muster/1/xmr-oneref/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "300"), (carol, "200")], "split")
  let si = x.subIndexOf(payTo)
  x.wallet("alice").rows = @[row(txidOf(1), "in", "300", 20, $si), row(txidOf(1), "in", "300", 20, $si)]
  discard x.pump()
  doAssert x.partOf(id, "bob").confirmed and not x.partOf(id, "carol").confirmed
  # by hand: that txid for Carol's part is refused
  let (s, ks) = x.r.sessionOf("alice")
  doAssert liveConfirmPart(s, ks, xmrFor, id, partName(carol), x.seamOf("alice", cmNow), txidOf(1)) ==
           "refused: that payment already settled another share"
  # "Mark received" stays the creditor's word
  doAssert xmrConfirmByHand(s, ks, xmrFor, x.seamOf("alice", cmNow), id, partName(carol), fromWallet = false) == "final"
  doAssert x.partOf(id, "carol").tx == ""
  echo "4b. one transfer settles one part; Mark received is the creditor's word OK"

block crossNetwork:
  var x = newXmrRoom("/muster/1/xmr-net/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "300")], "net")
  let si = x.subIndexOf(payTo)
  x.wallet("alice").rows = @[row(txidOf(1), "in", "300", 20, $si)]
  x.wallet("alice").network = "mainnet"       # she opened her mainnet wallet instead
  doAssert x.pump().len == 0 and x.stateOf(id) == "executable"
  let (s, ks) = x.r.sessionOf("alice")
  let r = xmrConfirmByHand(s, ks, xmrFor, x.seamOf("alice", cmNow), id, partName(bob), fromWallet = true)
  doAssert "another network" in r, r
  x.wallet("alice").network = ""             # no wallet open
  doAssert x.pump().len == 0
  x.wallet("alice").network = "stagenet"
  doAssert x.pump().len == 1 and x.stateOf(id) == "final"
  echo "4c. a wallet on another network, or none, confirms nothing OK"

# ── 5. proposed on the creditor's behalf ──────────────────────────────────────────
block onBehalf:
  var x = newXmrRoom("/muster/1/xmr-behalf/proto", XmrStage)
  let shared = x.wallet("alice").mint("muster:share").address
  let (s, ks) = x.r.sessionOf("alice")
  let (_, ev) = newMessageEvent("0x" & alice, int64(Now), $xmrShareBody(XmrStage, shared), 1)
  s.publishAuthored(ks, ev)
  x.r.sync()
  doAssert sharedMoneroAddressOf(x.r.bob.roomEvents(), alice, XmrStage) == shared
  doAssert sharedMoneroAddressOf(x.r.bob.roomEvents(), alice, XmrMain) == ""
  let id = x.propose("bob", x.requestJson(shared, @[(bob, "400"), (carol, "300")], "on behalf"))
  doAssert id.startsWith("0x"), id
  x.r.sync()
  doAssert x.agree("alice", id) == "collecting"
  # a request naming an address Alice's wallet does not list: her client refuses to agree
  let id2 = x.propose("bob", x.requestJson(walletAddress("wallet-dave", xmrStagenet, 3),
                                           @[(bob, "401"), (carol, "300")], "not hers"))
  doAssert id2.startsWith("0x"), id2
  x.r.sync()
  doAssert x.agree("alice", id2).startsWith("payto-not-mine"), x.agree("alice", id2)
  echo "5. on someone's behalf: their shared subaddress, agreed only when their wallet lists it OK"

echo "split_monero_test: all OK"
