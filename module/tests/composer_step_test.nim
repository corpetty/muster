## Composer third step (exo-45e / exo-fa1, docs/design/material-and-disclosure.md §3.3):
## the Safe driver declares the amount as PROPOSER material bound to "value", so
## compose_offers (proposerOffers) returns an asset slot the composer fills from my
## holdings — "compose from real holdings" (exo-bf9). The destination stays a counterparty
## slot (typed or requested), and the source account is the room's Safe. Links secp +
## stint + libsodium.

import std/[strutils, json]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/manifest
import ../src/drivers/safe
import ../src/crypto/secp256k1
import ../src/coordination/offers
import ../src/wallet/material

proc toAddr(hex: string): Address =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] in {'x','X'}): h = h[2 .. ^1]
  for i in 0 ..< min(20, h.len div 2): result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

let drv = newSafeDriver(chainId = 31337, safe = toAddr("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
                        owners = @[toAddr("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")], threshold = 1)
let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: @[
  ("to", cbText("")), ("value", cbUint(0'u64)), ("nonce", cbUint(0'u64))])

# ── 1. the Safe manifest declares the amount as a proposer asset slot bound to "value" ─
block:
  let m = drv.manifest(effect)
  doAssert m.consistent(effect), $consistencyFailures(m, effect)
  var amount: Requirement
  var found = false
  for r in m.requirements:
    if r.party == rpProposer and r.kind == rqAsset: (amount = r; found = true)
  doAssert found, "the composer's amount is proposer asset material"
  doAssert amount.needs.class == mcAsset and amount.needs.field == "value"
  echo "1. Safe manifest: the amount is a proposer asset slot bound to 'value' OK"

# ── 2. compose_offers (proposer slots) returns the amount, fillable from my ETH ───────
block:
  let m = drv.manifest(effect)
  let myCat = @[
    Material(class: mcAuthority, chain: "evm:31337", form: "safe-owner", handle: "safe:x",
             public: "0xSAFE", grade: mgDeclared, source: msConfigured),
    Material(class: mcAsset, chain: "evm:31337", form: "native", handle: "asset:evm:31337:ETH",
             public: "ETH", grade: mgDeclared, source: msConfigured)]
  let comp = proposerOffers(m.requirements, myCat, m)
  doAssert comp.len == 1 and comp[0].requirement.kind == rqAsset, "the composer sees only the amount slot"
  doAssert comp[0].status == osSatisfiable and comp[0].candidates[0].material.public == "ETH"
  # the payload the composer QML renders — public + grade + rows, no handle (s1).
  let payload = offersPayload(comp)
  doAssert payload["ready"].getBool() == true
  let c = payload["offers"][0]["candidates"][0]
  doAssert c["public"].getStr() == "ETH" and c["class"].getStr() == "asset"
  doAssert not c.hasKey("handle") and not c.hasKey("score")
  echo "2. compose_offers: the amount slot is fillable from my ETH; payload is public-only OK"

# ── 3. the destination stays a counterparty slot; recipientOffers keeps it, proposer sees the amount ─
block:
  let m = drv.manifest(effect)
  var proposerKinds, recipientParties: seq[string]
  for o in proposerOffers(m.requirements, @[], m): proposerKinds.add $o.requirement.kind
  for o in recipientOffers(m.requirements, @[], m): recipientParties.add $o.requirement.party
  doAssert "asset" in proposerKinds, "the composer's slot is the amount"
  doAssert "counterparty" in recipientParties, "the destination is still asked of the recipient"
  echo "3. amount is proposer (composer), destination is counterparty (recipient/request) OK"

echo "composer_step_test: all OK"
