## exo-d4d.5 (R4) — a part paid through the platform's tx_sender_module.
##
## Under Basecamp a member's payment is not signed and broadcast by muster: it goes
## prepare → send → a person approves in the signer → send_status (the poll IS the
## broadcast), through the device's one sender and its one nonce ledger. Held here:
##   * the call a part pays is derived from the agreed transfer: ETH is {to: payTo, value},
##     a token share is transfer(payTo, share) on the token, byte for byte what the EVM
##     adapter builds;
##   * prepare's legs must be exactly that call — same to, same value, same data — or the
##     send is refused before any approval is asked (invariant 1: the person approves what
##     the room agreed, nothing a sender substituted);
##   * the request carries the room's purpose and meta naming the intent and part;
##   * send_status replies read as what they are: waiting on a person, broadcasting, a hash,
##     rejected / cancelled / failed (never a hash), or an id the sender no longer holds;
##   * the book of sends in flight shows each one's handle (for the signer) and never a hash
##     it has not seen.

import std/[json, strutils]
import ../src/wallet/tx_sender
import ../src/wallet/evm_adapter      # erc20TransferData: the adapter's own encoding
import ../src/crypto/secp256k1
import ../src/intents/materialization

const
  Alice = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  Devon = "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc"
  Token = "0x5fbdb2315678afecb367f032d93f642f64180aa3"

proc tr(asset, amount: string): PartTransfer =
  PartTransfer(ok: true, chain: "eip155:11155111", asset: asset, to: Devon, amount: amount)

proc raises(body: proc()): string =
  try: body()
  except TxSenderError as e: return e.msg
  doAssert false, "expected a raise"

# ── 1. the call a part pays ────────────────────────────────────────────────────
block:
  let eth = callFor(tr("ETH", "5000000000000000"))
  doAssert eth.to == Devon and eth.value == "5000000000000000" and eth.data == ""
  let tok = callFor(tr("erc20:" & Token, "900000"))
  doAssert tok.to == Token and tok.value == "0"
  var devon: Address
  for i in 0 ..< 20: devon[i] = byte(parseHexInt(Devon[2 + 2*i .. 3 + 2*i]))
  doAssert tok.data == erc20TransferData(devon, "900000"), "the adapter's own transfer() bytes"
  discard raises(proc() = discard callFor(tr("BTC", "1")))
  discard raises(proc() = discard callFor(PartTransfer(ok: false, error: "no part")))

# ── 2. the request ─────────────────────────────────────────────────────────────
block:
  let c = callFor(tr("ETH", "5000000000000000"))
  let r = requestJson(11155111, Alice, c, "Pay my share of 'dinner' to Devon",
                      %*{"muster": {"intent": "abc", "part": "p1"}})
  doAssert r["chainId"].getInt() == 11155111 and r["from"].getStr() == Alice
  doAssert r["calls"].len == 1
  doAssert r["calls"][0]["to"].getStr() == Devon
  doAssert r["calls"][0]["value"].getStr() == "0x11c37937e08000", "wei as 0x-hex: " & $r["calls"][0]
  doAssert not r["calls"][0].hasKey("data"), "a plain transfer carries no data"
  doAssert r["purpose"].getStr().startsWith("Pay my share")
  doAssert r["calls"][0]["meta"]["muster"]["part"].getStr() == "p1"
  # purpose is at most 256 bytes: longer is cut, never refused by the sender later
  doAssert requestJson(1, Alice, c, repeat("x", 400), newJObject())["purpose"].getStr().len <= 256

# ── 3. prepare's legs must be exactly the call ─────────────────────────────────
block:
  let c = callFor(tr("erc20:" & Token, "900000"))
  let good = %*{"ok": true, "legs": [{"to": Token.toUpperAscii().replace("0X", "0x"), "value": "0x0",
                                       "data": c.data.toUpperAscii().replace("0X", "0x"), "gasLimit": 52000}]}
  doAssert legsMismatch(good, c) == "", "case and 0x-hex vs decimal are not differences"
  let goodDec = %*{"ok": true, "legs": [{"to": Token, "value": "0", "data": c.data, "gasLimit": 52000}]}
  doAssert legsMismatch(goodDec, c) == ""
  doAssert "to" in legsMismatch(%*{"ok": true, "legs": [{"to": Alice, "value": "0", "data": c.data}]}, c)
  doAssert "value" in legsMismatch(%*{"ok": true, "legs": [{"to": Token, "value": "1", "data": c.data}]}, c)
  doAssert "data" in legsMismatch(%*{"ok": true, "legs": [{"to": Token, "value": "0", "data": "0xa9059cbb"}]}, c)
  doAssert "legs" in legsMismatch(%*{"ok": true, "legs": []}, c)
  doAssert "legs" in legsMismatch(%*{"ok": true, "legs": [{"to": Token, "value": "0", "data": c.data},
                                                          {"to": Token, "value": "0", "data": c.data}]}, c)
  doAssert "insufficient" in legsMismatch(%*{"ok": false, "error": "insufficient funds"}, c)
  let e = callFor(tr("ETH", "7"))
  doAssert legsMismatch(%*{"ok": true, "legs": [{"to": Devon, "value": "0x7"}]}, e) == "", "a plain transfer's leg has no data"
  doAssert legsMismatch(%*{"ok": true, "legs": [{"to": Devon, "value": "0x7", "data": "0x"}]}, e) == ""

# ── 4. send_status ─────────────────────────────────────────────────────────────
block:
  let h = "0x" & repeat("ab", 32)
  var s = parseSendStatus(%*{"ok": true, "requestId": "snd_1", "handle": "ksh_1",
                              "status": "awaitingApproval", "final": false, "hashes": []})
  doAssert s.state == ssAwaiting and not s.final and s.hash == ""
  s = parseSendStatus(%*{"ok": true, "status": "awaitingApproval", "final": false, "blocked": true})
  doAssert s.state == ssAwaiting and s.blocked
  s = parseSendStatus(%*{"ok": true, "status": "broadcasting", "final": false})
  doAssert s.state == ssBroadcasting
  s = parseSendStatus(%*{"ok": true, "status": "broadcast", "final": true, "hashes": [h], "hash": h})
  doAssert s.state == ssBroadcast and s.final and s.hash == h
  for st in ["rejected", "cancelled"]:
    s = parseSendStatus(%*{"ok": true, "status": st, "final": true})
    doAssert s.state == ssEnded and s.final and s.hash == "" and s.neverSent
  s = parseSendStatus(%*{"ok": true, "status": "failed", "final": true, "hashes": [], "reason": "nonce too low"})
  doAssert s.state == ssEnded and s.neverSent and "nonce too low" in s.reason
  s = parseSendStatus(%*{"ok": true, "status": "failed", "final": true, "hashes": [h], "hash": h})
  doAssert s.state == ssEnded and not s.neverSent and s.hash == h, "a failed bundle whose call landed still names it"
  s = parseSendStatus(%*{"ok": true, "status": "stuck", "final": true, "hashes": [h], "hash": h})
  doAssert s.state == ssStuck and s.hash == h
  # a refusal: final only when the sender holds no such id; any other may pass next poll
  s = parseSendStatus(%*{"ok": false, "error": "unknown request id", "final": true})
  doAssert s.state == ssUnknown and s.neverSent
  s = parseSendStatus(%*{"ok": false, "error": "budget spent", "final": false})
  doAssert s.state == ssAwaiting and not s.final, "a transient refusal is not an ending"
  s = parseSendStatus(nil)
  doAssert s.state == ssAwaiting and not s.final, "no answer is not an ending"

# ── 5. the book of sends in flight ─────────────────────────────────────────────
block:
  var b: SendBook
  b.add("snd_1", "ksh_1", "intent-a", "p1", "Pay my share")
  doAssert b.handleOf("snd_1") == "ksh_1"
  doAssert markerOf("snd_1") == "txs:snd_1" and requestOfMarker("txs:snd_1") == "snd_1"
  doAssert requestOfMarker("0x" & repeat("ab", 32)) == "", "a hash is not a marker"
  let v = b.view()
  doAssert v.len == 1 and v[0]["handle"].getStr() == "ksh_1" and v[0]["state"].getStr() == "waiting"
  doAssert v[0]["intentId"].getStr() == "intent-a" and v[0]["kind"].getStr() == "send"
  let h = "0x" & repeat("cd", 32)
  b.update("snd_1", parseSendStatus(%*{"ok": true, "status": "broadcast", "final": true, "hashes": [h], "hash": h}))
  doAssert b.hashOf("snd_1") == h
  doAssert b.view()[0]["state"].getStr() == "approved"
  b.update("snd_1", parseSendStatus(%*{"ok": true, "status": "awaitingApproval", "final": false}))
  doAssert b.hashOf("snd_1") == h, "a hash seen is never forgotten"
  b.add("snd_2", "ksh_2", "intent-b", "p2", "Pay")
  b.update("snd_2", parseSendStatus(%*{"ok": true, "status": "rejected", "final": true}))
  doAssert b.view()[1]["state"].getStr() == "rejected"
  doAssert b.hashOf("snd_2") == ""

echo "tx_sender_test: ok"
