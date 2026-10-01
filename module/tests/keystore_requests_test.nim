## Pending keystore_module signing requests (exo-149.2 K2). Held: the receipt that
## alone authorises collecting a result never appears in any view; at most four are
## pending at once (the keystore's per-requester cap) and settled ones do not count;
## every approval_status reply moves the request where the keystore says (offered,
## rendered, settled approved / rejected / expired_no_ack / cancelled) and a refusal or
## an unexpected state fails it; only waiting requests are polled, at the cadence;
## one past its deadline is reported for cancellation; and fetched signatures count
## only when each recovers to the chosen account over MUSTER's own hash for its leg,
## in leg order — otherwise the request fails and nothing is returned. State and
## reason strings: keystore_module rust-lib/src/approval.rs @2318c679.

import std/[json, strutils]
import ../src/crypto/secp256k1
import ../src/wallet/keystore_requests

proc hexOf(b: openArray[byte]): string =
  result = "0x"
  for x in b: result.add toHex(x).toLowerAscii()

proc h(n: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = n

var sk: array[32, byte]
for i in 0 ..< 32: sk[i] = byte(200 - i)
let who = addressOf(sk)
let account = hexOf(who)
let legs = @[SignLeg(kind: "contribution", hash: h(1)), SignLeg(kind: "attestation", hash: h(2))]
const Receipt = "ksc_secret_receipt_value"

block receiptsAndCap:
  var r: SignRequests
  r.add("ksh_1", Receipt, "intent-a", account, legs, deadline = 100.0)
  doAssert Receipt notin $r.view() and r.receiptOf("ksh_1") == Receipt
  doAssertRaises(SignRequestError): r.add("ksh_1", "x", "intent-a", account, legs, 100.0)   # duplicate
  for i in 2 .. 4: r.add("ksh_" & $i, "r" & $i, "intent-" & $i, account, legs, 100.0)
  doAssert r.active() == 4 and not r.canRequest()
  doAssertRaises(SignRequestError): r.add("ksh_5", "r5", "intent-5", account, legs, 100.0)
  r.onStatus("ksh_2", %*{"ok": true, "state": "settled", "reason": "rejected"})
  doAssert r.active() == 3 and r.canRequest()
  echo "1. the receipt is in no view; four pending at most, settled ones do not count OK"

block transitions:
  var r: SignRequests
  for (st, reason, want) in [("offered", "", ssWaiting), ("rendered", "", ssShown),
                             ("settled", "approved", ssApproved), ("settled", "rejected", ssRejected),
                             ("settled", "expired_no_ack", ssExpired), ("settled", "cancelled", ssCancelled)]:
    let hd = "ksh_" & st & reason
    r.add(hd, Receipt, "i", account, legs, 100.0)
    var reply = %*{"ok": true, "state": st}
    if reason.len > 0: reply["reason"] = %reason
    r.onStatus(hd, reply)
    doAssert r.stateOf(hd) == want, hd & " → " & $r.stateOf(hd)
    r.remove(hd)
  r.add("ksh_err", Receipt, "i", account, legs, 100.0)
  r.onStatus("ksh_err", %*{"ok": false, "error": "not authorized"})
  doAssert r.stateOf("ksh_err") == ssFailed and "not authorized" in r.reasonOf("ksh_err")
  r.add("ksh_odd", Receipt, "i", account, legs, 100.0)
  r.onStatus("ksh_odd", %*{"ok": true, "state": "teleported"})
  doAssert r.stateOf("ksh_odd") == ssFailed
  r.add("ksh_nil", Receipt, "i", account, legs, 100.0)
  r.onStatus("ksh_nil", nil)
  doAssert r.stateOf("ksh_nil") == ssWaiting                 # an unread reply changes nothing
  echo "2. every status reply moves the request where the keystore says; a refusal or odd state fails it OK"

block cadenceAndDeadline:
  var r: SignRequests
  r.add("ksh_a", Receipt, "i", account, legs, deadline = 50.0)
  r.add("ksh_b", Receipt, "i", account, legs, deadline = 500.0)
  r.onStatus("ksh_b", %*{"ok": true, "state": "settled", "reason": "approved"})
  doAssert r.due(now = 10.0) == @["ksh_a"]                   # the settled one is not polled
  r.markPolled("ksh_a", 10.0)
  doAssert r.due(now = 11.0, every = 2.0).len == 0 and r.due(now = 12.5, every = 2.0) == @["ksh_a"]
  doAssert r.overdue(now = 49.0).len == 0
  doAssert r.overdue(now = 51.0) == @["ksh_a"] and r.stateOf("ksh_a") == ssCancelled
  doAssert r.reasonOf("ksh_a") == "deadline"
  echo "3. only waiting requests are polled, at the cadence; one past its deadline is reported and cancelled OK"

block fetched:
  var r: SignRequests
  let s1 = hexOf(signRecoverable(h(1), sk))
  let s2 = hexOf(signRecoverable(h(2), sk))
  r.add("ksh_ok", Receipt, "i", account, legs, 100.0)
  let ok = r.onFetched("ksh_ok", %*{"ok": true, "signed": [s1, s2]})
  doAssert ok.ok and ok.sigs == @[s1, s2], $ok
  r.add("ksh_swap", Receipt, "i", account, legs, 100.0)
  let sw = r.onFetched("ksh_swap", %*{"ok": true, "signed": [s2, s1]})    # legs out of order
  doAssert not sw.ok and sw.sigs.len == 0 and r.stateOf("ksh_swap") == ssFailed
  doAssert "does not recover" in sw.reason, sw.reason
  var other: array[32, byte]
  for i in 0 ..< 32: other[i] = byte(i + 7)
  r.add("ksh_foreign", Receipt, "i", account, legs, 100.0)
  let fo = r.onFetched("ksh_foreign", %*{"ok": true, "signed": [hexOf(signRecoverable(h(1), other)), s2]})
  doAssert not fo.ok and r.stateOf("ksh_foreign") == ssFailed
  r.add("ksh_count", Receipt, "i", account, legs, 100.0)
  doAssert not r.onFetched("ksh_count", %*{"ok": true, "signed": [s1]}).ok
  r.add("ksh_no", Receipt, "i", account, legs, 100.0)
  doAssert not r.onFetched("ksh_no", %*{"ok": false, "error": "not settled"}).ok
  echo "4. fetched signatures count only if each recovers to the account over muster's own hash, in leg order OK"

echo "keystore_requests_test: all passed"
