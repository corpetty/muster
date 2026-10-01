## The official keystore_module as one status row (exo-149.1 K1). Held: it reads ok only
## when keystore_module attributes muster's calls to muster_module and someone could
## approve them; every other caller kind, or another module's name, says each request
## would be refused; no approver, or no account, is a warning that names the remedy; an
## unreachable keystore, or a reply that did not parse or said ok:false, is down; and
## nothing unread ever reads as ok. Accounts join their labels and wallet names whatever
## case the addresses arrive in. Reply shapes: logos-evm-keystore-module@2318c679,
## rust-lib/src/glue.rs (caller_identity, list_accounts, get_labels, get_account_wallets).

import std/[json, strutils]
import ../src/wallet/keystore_status

const
  A0 = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
  A1 = "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"

let defaultRoles = %*{"ok": true, "kind": "module", "identity": "muster_module",
                      "approvers": ["evm_signer_ui"], "custodians": ["evm_keystore_ui"]}
let twoAccounts = %*{"ok": true, "accounts": [A0, A1], "staged": [], "unexplained": [], "mismatched": []}
let labels = %*{"ok": true, "labels": {A0.toLowerAscii(): "savings"}}
let wallets = %*{"ok": true, "wallets": {A0: {"wallet": "Main", "index": 0}}}

proc attested(accounts = twoAccounts): KeystoreInputs =
  KeystoreInputs(reached: true, identity: defaultRoles, accounts: accounts,
                 labels: labels, wallets: wallets)

block notLoaded:
  let r = keystoreRow(KeystoreInputs(reached: false))
  doAssert r["key"].getStr() == "keystore" and r["level"].getStr() == "down", $r
  doAssert "not loaded" in r["detail"].getStr(), $r
  doAssert "keystore_module" in r["remedy"].getStr(), $r
  echo "1. keystore_module not loaded: down, and the remedy names it OK"

block unread:
  for idReply in [newJNull(), %*{"ok": false, "error": "boom"}, %*{"kind": "module"}]:
    let r = keystoreRow(KeystoreInputs(reached: true, identity: (if idReply.kind == JNull: nil else: idReply)))
    doAssert r["level"].getStr() == "down", $r
    doAssert "caller_identity" in r["detail"].getStr(), $r
  echo "2. an unread, failed, or ok-less caller_identity: down, never ok OK"

block attestedOk:
  let r = keystoreRow(attested())
  doAssert r["level"].getStr() == "ok", $r
  doAssert "muster_module" in r["detail"].getStr() and "2 accounts" in r["detail"].getStr(), $r
  doAssert r["identity"]["kind"].getStr() == "module" and r["identity"]["identity"].getStr() == "muster_module"
  doAssert r["approvers"].len == 1 and r["approvers"][0].getStr() == "evm_signer_ui"
  let accts = r["accounts"]
  doAssert accts.len == 2
  doAssert accts[0]["address"].getStr() == A0 and accts[0]["label"].getStr() == "savings" and
           accts[0]["wallet"].getStr() == "Main", $accts
  doAssert accts[1]["address"].getStr() == A1 and accts[1]["label"].getStr() == "" and
           accts[1]["wallet"].getStr() == "", $accts
  echo "3. attested as muster_module, an approver named: ok; accounts joined to labels and wallets OK"

block refusedKinds:
  for (kind, ident) in [("host", ""), ("unknown", ""), ("derived", "muster_module.x"),
                        ("operator", "alice"), ("module", "core")]:
    var id = defaultRoles.copy()
    id["kind"] = %kind; id["identity"] = %ident
    var i = attested(); i.identity = id
    let r = keystoreRow(i)
    doAssert r["level"].getStr() == "down", kind & ": " & $r
    doAssert "refused" in r["detail"].getStr(), kind & ": " & $r
    doAssert r["identity"]["kind"].getStr() == kind
  echo "4. attributed as host / unknown / derived / operator / another module: down, every request refused OK"

block noApprover:
  var id = defaultRoles.copy(); id["approvers"] = newJArray()
  var i = attested(); i.identity = id
  let r = keystoreRow(i)
  doAssert r["level"].getStr() == "warn" and "approver" in r["detail"].getStr(), $r
  doAssert "evm_signer_ui" in r["remedy"].getStr(), $r
  echo "5. no approver named: warn, nothing could settle, the remedy names the signer OK"

block noAccounts:
  let r = keystoreRow(attested(%*{"ok": true, "accounts": []}))
  doAssert r["level"].getStr() == "warn" and "no accounts" in r["detail"].getStr(), $r
  doAssert "evm_keystore_ui" in r["remedy"].getStr(), $r
  doAssert r["accounts"].len == 0
  echo "6. attested but no accounts: warn, the remedy hands off to evm_keystore_ui OK"

block accountsUnread:
  var i = attested(); i.accounts = %*{"ok": false, "error": "unreadable keystore"}
  let r = keystoreRow(i)
  doAssert r["level"].getStr() == "warn" and "accounts" in r["detail"].getStr(), $r
  i.accounts = nil
  doAssert keystoreRow(i)["level"].getStr() == "warn"
  echo "7. attested but the accounts unread: warn, never ok OK"

block cosmeticsOptional:
  var i = attested(); i.labels = nil; i.wallets = %*{"ok": false}
  let r = keystoreRow(i)
  doAssert r["level"].getStr() == "ok", $r
  doAssert r["accounts"][0]["label"].getStr() == "" and r["accounts"][0]["wallet"].getStr() == ""
  echo "8. labels and wallet names are cosmetic: unread, the row stays ok without them OK"

block replyUnwrap:
  let inner = $defaultRoles
  doAssert ksReply(inner)["identity"].getStr() == "muster_module"
  doAssert ksReply($(%inner))["identity"].getStr() == "muster_module"          # JSON-in-a-string
  doAssert ksReply($(%*{"success": true, "value": inner}))["kind"].getStr() == "module"  # lp envelope
  doAssert ksReply($(%*{"success": false, "value": inner})) == nil
  doAssert ksReply("") == nil and ksReply("not json") == nil and ksReply("\"\"") == nil
  echo "9. a reply arrives bare, as JSON in a string, or in the lp envelope; a failed one is nil OK"

echo "keystore_status_test: all passed"
