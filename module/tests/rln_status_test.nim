## The node's RLN membership as a connectivity row (exo-eb6.3 R1). Held: off logos.test
## it says RLN is not needed; on logos.test the membership decides when it is known; a
## payer short of the funding threshold reads "awaiting funding", names the payer and
## the registry's zone, and says what to send; nothing unread ever reads as ok; and the
## constants are the preset's own (the identifier is sha256 of delivery's scope).

import std/[json, strutils]
import ../src/hashing/sha256
import ../src/transport/rln_status

const Payer = "36390df30b719ab5415dff7bd2c538ae20001ecc0f49fc6e52367af602f5fc38"
let readyWallet = %*{"state": "ready", "ready": true, "payer": Payer, "network": "testnet", "detail": ""}

block constants:
  var scope: seq[byte]
  for ch in "rln/logos-delivery/v0.0.1": scope.add byte(ch)
  let d = sha256(scope)
  var hex = ""
  for b in d: hex.add toHex(b).toLowerAscii()
  doAssert hex == RlnIdentifierHex, hex
  doAssert presetOf("""{"mode":"Core","preset":"logos.test"}""") == "logos.test"
  doAssert presetOf("""{"clusterId":42}""") == "" and presetOf("nope") == ""
  echo "1. the identifier is sha256 of delivery's scope; a config's preset is read OK"

block notNeeded:
  for p in ["logos.dev", ""]:
    let r = rlnRow(RlnInputs(preset: p, node: "Disabled"))
    doAssert r["level"].getStr() == "ok" and "not needed" in r["detail"].getStr(), $r
  echo "2. off logos.test: not needed OK"

block awaitingFunding:
  let r = rlnRow(RlnInputs(preset: "logos.test", node: "Ready", wallet: readyWallet,
                           balance: %*{"account": Payer, "balance": "0"},
                           membership: %*{"registry_id": LogosTestRegistry, "state": "unknown"}))
  doAssert r["level"].getStr() == "warn" and "awaiting funding" in r["detail"].getStr(), $r
  doAssert r["payer"].getStr() == Payer and r["balance"].getStr() == "0"
  doAssert Payer in r["remedy"].getStr() and RegistryZone in r["remedy"].getStr() and
           FundingNative in r["remedy"].getStr(), $r
  # one short of the threshold is still short; at it, registration is under way
  let short = rlnRow(RlnInputs(preset: "logos.test", node: "Ready", wallet: readyWallet,
                               balance: %*{"balance": "199999999"}))
  doAssert "awaiting funding" in short["detail"].getStr()
  let funded = rlnRow(RlnInputs(preset: "logos.test", node: "Ready", wallet: readyWallet,
                                balance: %*{"balance": "1000000000"}))
  doAssert funded["level"].getStr() == "warn" and "under way" in funded["detail"].getStr(), $funded
  echo "3. a payer short of the threshold: awaiting funding, with the payer, the zone and the amount OK"

block membership:
  let active = rlnRow(RlnInputs(preset: "logos.test", node: "Ready", wallet: readyWallet,
                                membership: %*{"registry_id": LogosTestRegistry, "state": "active"}))
  doAssert active["level"].getStr() == "ok" and active["payer"].getStr() == Payer, $active
  let pending = rlnRow(RlnInputs(preset: "logos.test", node: "Ready", membership: %*{"state": "pending"}))
  doAssert pending["level"].getStr() == "warn" and "registering" in pending["detail"].getStr()
  for st in ["expired", "erased", "slashed", "failed"]:
    doAssert rlnRow(RlnInputs(preset: "logos.test", membership: %*{"state": st}))["level"].getStr() == "down", st
  echo "4. the membership decides when known: active ok, pending and grace warn, gone down OK"

block neverFalseGreen:
  let cases = @[
    RlnInputs(preset: "logos.test"),                                   # no node yet
    RlnInputs(preset: "logos.test", node: "Initializing"),             # wallet unread
    RlnInputs(preset: "logos.test", node: "Ready", wallet: %*{"state": "pending", "payer": ""}),
    RlnInputs(preset: "logos.test", node: "Ready", wallet: readyWallet),  # balance unread
  ]
  for c in cases:
    doAssert rlnRow(c)["level"].getStr() == "unknown", $rlnRow(c)
  doAssert rlnRow(RlnInputs(preset: "logos.test", node: "Failed", nodeMessage: "x"))["level"].getStr() == "down"
  doAssert rlnRow(RlnInputs(preset: "logos.test", node: "Ready",
                            wallet: %*{"state": "failed", "detail": "bad"}))["level"].getStr() == "down"
  echo "5. nothing unread reads as ok: no node, no wallet, no balance are unknown; failures are down OK"

block nodeState:
  # delivery's rlnState() is a `result`: its value may arrive as the state alone, as a
  # JSON object {state, message}, or inside the lp envelope; anything else is no state
  doAssert parseRlnState("Ready") == ("Ready", "")
  doAssert parseRlnState("""{"state":"Failed","message":"no chain"}""") == ("Failed", "no chain")
  doAssert parseRlnState("""{"success":true,"value":"Initializing","error":null}""") == ("Initializing", "")
  doAssert parseRlnState("""{"success":true,"value":"{\"state\":\"Ready\",\"message\":\"\"}"}""") == ("Ready", "")
  doAssert parseRlnState("""{"success":true,"value":{"state":"Disabled"}}""") == ("Disabled", "")
  doAssert parseRlnState("") == ("", "") and parseRlnState("{}") == ("", "")
  doAssert parseRlnState("""{"success":false,"error":"no node","value":null}""") == ("", "")
  echo "6. delivery's rlnState, however wrapped: the state and its message OK"
