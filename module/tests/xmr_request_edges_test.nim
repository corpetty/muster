## The XMR payment request's rough edges, found on display (exo-dcc.20): what the room
## shows a creditor and a debtor around a Monero request — over the recording fake
## monero_wallet_backend (tests/probes/fake_monero.nim) and the room of four
## (tests/probes/xmr_room.nim).
##
##   1. the wallet to unlock: monero.wallet.unlock needs {wallet}. The open one on the
##      agreed network; none open, the one registered there that can spend; several, all
##      of them for the person to pick; none at all, "no wallet" (monero.accounts.manage);
##      an unanswered list names nothing and never says "no wallet". It asks wallet_status
##      and list_wallets, nothing else.
##   2. n of 10: while a transfer of exactly a share is seen at payTo below depth, the
##      creditor's projection carries its confirmations (0–9); a busy or unanswered read,
##      a wrong amount, a confirmed part, or a debtor's client carry none.
##   3. "Share my Monero address": a fresh subaddress of the sharer's own wallet, on the
##      chain asked, posted as their author-signed address-share; refused (nothing posted)
##      when the wallet cannot vouch, or the chain is not Monero; a request on their behalf
##      pays it, and their client agrees only while their wallet lists it.
##   4. the Connections panel's Monero row: graded from wallet_status — met when the
##      creditor's wallet is open on the chain's network, unknown while unread or busy,
##      missing when closed or elsewhere; a debtor pays from any wallet (met). The chains a
##      member is owed on are the open requests naming them as creditor.
##   5. room history: a Monero debtor's "I paid" reads "says they paid" until the
##      creditor's wallet confirms it; another family's report is unchanged.

import std/[json, strutils, sets, tables, sequtils]
import ../src/coordination/readiness
import ./probes/xmr_room

# ── 1. the wallet to unlock ──────────────────────────────────────────────────────
block unlockTarget:
  let w = newFakeMonero("wallet-alice", "stagenet")
  # open on the agreed network: that one, named as wallet_status names it
  var t = xmrUnlockTarget(w, XmrStage)
  doAssert t.read == rsAnswered and t.wallet == "wallet-alice" and t.wallets.len == 0 and not t.none, $t
  # none open: the one registered on stagenet that can spend (not the mainnet one, not
  # a view-only one)
  w.network = ""
  w.registry = @[(name: "main-w", network: "mainnet", viewOnly: false),
                 (name: "stage-w", network: "stagenet", viewOnly: false),
                 (name: "view-w", network: "stagenet", viewOnly: true)]
  t = xmrUnlockTarget(w, XmrStage)
  doAssert t.wallet == "stage-w" and t.wallets.len == 0 and not t.none, $t
  # several on the network: none named, every one listed for the person to pick
  w.registry.add (name: "stage-2", network: "stagenet", viewOnly: false)
  t = xmrUnlockTarget(w, XmrStage)
  doAssert t.wallet == "" and t.wallets == @["stage-w", "stage-2"] and not t.none, $t
  # the open wallet is on mainnet: name the stagenet one the request needs
  w.network = "mainnet"
  w.registry = @[(name: "main-w", network: "mainnet", viewOnly: false),
                 (name: "stage-w", network: "stagenet", viewOnly: false)]
  t = xmrUnlockTarget(w, XmrStage)
  doAssert t.wallet == "stage-w", $t
  # a file never opened (network "") is a candidate only when none is known to be on it
  w.network = ""
  w.registry = @[(name: "fresh", network: "", viewOnly: false), (name: "main-w", network: "mainnet", viewOnly: false)]
  doAssert xmrUnlockTarget(w, XmrStage).wallet == "fresh"
  # no wallet on the network at all: "none" — create or restore one in Monero Wallet
  w.registry = @[(name: "main-w", network: "mainnet", viewOnly: false)]
  t = xmrUnlockTarget(w, XmrStage)
  doAssert t.read == rsAnswered and t.none and t.wallet == "" and t.wallets.len == 0, $t
  # the list unanswered or busy: nothing named, and never "none" (it is not known)
  for a in [anUnreachable, anBusy]:
    w.listing = a
    t = xmrUnlockTarget(w, XmrStage)
    doAssert t.read != rsAnswered and not t.none and t.wallet == "" and t.wallets.len == 0, $t
  w.listing = anAnswered
  # a busy status but an answered list: the list decides
  w.status = anBusy
  w.registry = @[(name: "stage-w", network: "stagenet", viewOnly: false)]
  doAssert xmrUnlockTarget(w, XmrStage).wallet == "stage-w"
  w.status = anAnswered
  # only a read of the status and the list: no mint, no history, nothing that opens
  for c in w.calls: doAssert c in ["wallet_status", "list_wallets"], c
  # not a Monero chain: nothing named
  doAssert xmrUnlockTarget(w, "eip155:1").wallet == ""
  # what the hosted remedies carry
  let j = unlockJson(XmrUnlockTarget(read: rsAnswered, wallets: @["a", "b"]))
  doAssert j["wallets"].getElems().mapIt(it.getStr()) == @["a", "b"] and j["wallet"].getStr() == "" and
           not j["noWallet"].getBool()
  doAssert unlockJson(XmrUnlockTarget(read: rsAnswered, none: true))["noWallet"].getBool()
  echo "1. the wallet to unlock: the open one, the one on the network, several to pick, none, unread OK"

# ── 2. n of 10 confirmations ─────────────────────────────────────────────────────
block seen:
  var x = newXmrRoom("/muster/1/xmr-seen/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "300"), (carol, "200")], "seen")
  let si = $x.subIndexOf(payTo)
  let w = x.wallet("alice")
  proc seenOn(viewer = "alice"): Table[string, int] =
    x.r.sync()
    let (s, ks) = x.r.sessionOf(viewer)
    xmrSeenConfirmations(s.roomEvents(), xmrFor, x.seamOf(viewer), myIdentity(ks))
  let pb = id & "/" & partName(bob)
  let pc = id & "/" & partName(carol)
  doAssert seenOn().len == 0, "nothing arrived: no count"
  w.rows = @[row(txidOf(1), "in", "300", 0, si)]
  doAssert seenOn() == {pb: 0}.toTable, $seenOn()
  w.rows = @[row(txidOf(1), "in", "300", 4, si)]
  doAssert seenOn() == {pb: 4}.toTable, $seenOn()
  # a wrong amount, another subaddress, an outgoing row: not this share — no count
  w.rows.add row(txidOf(2), "in", "201", 7, si)
  w.rows.add row(txidOf(3), "in", "200", 7, "0")
  w.rows.add row(txidOf(4), "out", "200", 7, si)
  doAssert seenOn() == {pb: 4}.toTable, $seenOn()
  w.rows.add row(txidOf(5), "in", "200", 9, si)
  doAssert seenOn() == {pb: 4, pc: 9}.toTable, $seenOn()
  # a busy or unanswered history invents nothing
  w.hist = anBusy
  doAssert seenOn().len == 0
  w.hist = anUnreachable
  doAssert seenOn().len == 0
  w.hist = anAnswered
  # the wallet on another network: nothing it shows is counted
  w.network = "mainnet"
  doAssert seenOn().len == 0
  w.network = "stagenet"
  # a debtor's client reads no one's wallet for this
  doAssert seenOn("bob").len == 0
  # at 10, the pump confirms Bob's part: no count for it any more
  w.rows[0] = row(txidOf(1), "in", "300", 10, si)
  doAssert x.pump() == @[pb]
  doAssert seenOn() == {pc: 9}.toTable, $seenOn()
  # the pure rule says what it saw, and how deep
  let t = PartTransfer(ok: true, chain: XmrStage, asset: "XMR", to: payTo, amount: "200")
  let m = matchXmrPayment(t, w.walletStatus(), w.receiveInfo(), w.history(), initHashSet[string]())
  doAssert m.verdict == xvPending and m.seen and m.confirmations == 9, $m
  echo "2. n of 10: the matched row's confirmations while below depth; nothing invented OK"

# ── 3. "Share my Monero address" ─────────────────────────────────────────────────
block share:
  var x = newXmrRoom("/muster/1/xmr-share/proto", XmrStage)
  let (s, ks) = x.r.sessionOf("alice")
  let w = x.wallet("alice")
  let before = w.subs.len
  let r = xmrShareAddress(s, ks, w, XmrStage, 1)
  doAssert r.ok and r.why == "", r.why
  doAssert w.subs.len == before + 1 and w.subs[^1].address == r.address and w.subs[^1].label == "muster:share"
  doAssert acceptablePayTo(r.address, XmrStage).ok
  x.r.sync()
  doAssert sharedMoneroAddressOf(x.r.bob.roomEvents(), alice, XmrStage) == r.address
  doAssert sharedMoneroAddressOf(x.r.bob.roomEvents(), alice, XmrMain) == ""
  # refused, nothing minted and nothing posted: no wallet open, another network, not Monero
  let nMsgs = reduceMessages(x.r.bob.roomEvents()).len
  w.network = ""
  doAssert xmrShareAddress(s, ks, w, XmrStage, 2).why.startsWith("no-wallet")
  w.network = "mainnet"
  doAssert xmrShareAddress(s, ks, w, XmrStage, 3).why.startsWith("wallet-other-network")
  w.network = "stagenet"
  doAssert xmrShareAddress(s, ks, w, "eip155:1", 4).why.startsWith("unknown-chain")
  w.watchOnly = true
  doAssert xmrShareAddress(s, ks, w, XmrStage, 5).why.startsWith("wallet-watch-only")
  w.watchOnly = false
  x.r.sync()
  doAssert reduceMessages(x.r.bob.roomEvents()).len == nMsgs, "a refusal posts nothing"
  doAssert w.subs.len == before + 1, "a refusal mints nothing"
  # on her behalf: Bob proposes at the address she shared; she agrees, her wallet lists it
  let id = x.propose("bob", x.requestJson(r.address, @[(bob, "400"), (carol, "300")], "on behalf"))
  doAssert id.startsWith("0x"), id
  x.r.sync()
  doAssert x.agree("alice", id) == "collecting"
  # a newer share wins
  let r2 = xmrShareAddress(s, ks, w, XmrStage, 6)
  x.r.sync()
  doAssert r2.ok and r2.address != r.address
  doAssert sharedMoneroAddressOf(x.r.carol.roomEvents(), alice, XmrStage) == r2.address
  # the share's mint and the agreement asked only read-and-mint methods
  doAssert w.onlyAllowed(), $w.calls
  echo "3. Share my Monero address: minted by the sharer's wallet, on the chain, refused unposted, paid on their behalf OK"

# ── 4. the Connections panel's Monero row ────────────────────────────────────────
block connections:
  let w = newFakeMonero("wallet-alice", "stagenet")
  var g = moneroWalletGrade(w.walletStatus(), XmrStage, creditor = true)
  doAssert g.status == rdMet and "stagenet" in g.detail, $g
  w.status = anBusy
  doAssert moneroWalletGrade(w.walletStatus(), XmrStage, creditor = true).status == rdUnknown
  w.status = anUnreachable
  doAssert moneroWalletGrade(w.walletStatus(), XmrStage, creditor = true).status == rdUnknown
  w.status = anAnswered
  w.network = ""
  g = moneroWalletGrade(w.walletStatus(), XmrStage, creditor = true)
  doAssert g.status == rdMissing and g.detail.startsWith("no-wallet"), $g
  w.network = "mainnet"
  doAssert moneroWalletGrade(w.walletStatus(), XmrStage, creditor = true).detail.startsWith("wallet-other-network")
  # a debtor pays from any wallet: met, whatever is open
  doAssert moneroWalletGrade(w.walletStatus(), XmrStage, creditor = false).status == rdMet
  # the panel's probe over these facts: no longer "this host cannot read a Monero wallet"
  w.network = "stagenet"
  var facts = HostFacts()
  facts.moneroWallet = moneroWalletProbe(w.walletStatus(), @[XmrStage])
  let probe = probeFromFacts(facts)
  doAssert probe.environmentReachable(XmrStage).status == rdMet, $probe.environmentReachable(XmrStage)
  # a chain this member is owed nothing on: a debtor's view
  w.network = ""
  doAssert probeFromFacts(HostFacts(moneroWallet: moneroWalletProbe(w.walletStatus(), @[]))).
             environmentReachable(XmrStage).status == rdMet
  doAssert probeFromFacts(HostFacts(moneroWallet: moneroWalletProbe(w.walletStatus(), @[XmrStage]))).
             environmentReachable(XmrStage).status == rdMissing
  # which chains: the open requests that name me as creditor
  var x = newXmrRoom("/muster/1/xmr-owed/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "300")], "owed")
  x.r.sync()
  doAssert xmrOwedOn(x.r.alice.roomEvents(), xmrFor, alice) == @[XmrStage]
  doAssert xmrOwedOn(x.r.bob.roomEvents(), xmrFor, bob).len == 0
  # once final, nothing is owed on it
  x.wallet("alice").rows = @[row(txidOf(1), "in", "300", 12, $x.subIndexOf(payTo))]
  doAssert x.pump().len == 1 and x.stateOf(id) == "final"
  doAssert xmrOwedOn(x.r.alice.roomEvents(), xmrFor, alice).len == 0
  echo "4. Connections: the Monero row graded from wallet_status, unknown while unread, met for a debtor OK"

# ── 5. room history: "says they paid" ────────────────────────────────────────────
block history:
  var x = newXmrRoom("/muster/1/xmr-history/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "300")], "history")
  doAssert x.reportPaid("bob", id, txidOf(9)) == "submitted"
  x.r.sync()
  proc lines(viewer: string): seq[string] =
    let evs = x.r.sessionOf(viewer)[0].roomEvents()
    let me = identityOf(viewer)
    for a in reduceActivity(evs, xmrFor):
      if a.kind == "part-settled":
        result.add activityTitle(a, proc(who: string): string =
          (if who == partName(me): "you" elif who == partName(bob): "Bob" else: who))
  doAssert lines("alice") == @["Bob says they paid"], $lines("alice")
  doAssert lines("bob") == @["You said you paid"], $lines("bob")
  for a in reduceActivity(x.r.alice.roomEvents(), xmrFor):
    if a.kind == "part-settled":
      doAssert a.title.endsWith("says they paid") and "settled" notin a.title, a.title
      doAssert "confirms" in a.detail, a.detail
  # the creditor's wallet confirms it: now it reads as settled
  x.wallet("alice").rows = @[row(txidOf(9), "in", "300", 10, $x.subIndexOf(payTo))]
  doAssert x.pump().len == 1
  x.r.sync()
  doAssert lines("alice") == @["Bob settled their part"], $lines("alice")
  echo "5. history: a Monero report says they paid until the creditor's wallet confirms it OK"

echo "xmr_request_edges_test: all OK"
