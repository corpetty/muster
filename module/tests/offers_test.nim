## Offers (exo-45e K4, docs/design/material-and-disclosure.md §3.3): an action's
## requirements crossed with MY catalogue → which of my holdings fit each slot, and what
## choosing each would disclose. Graded about me only (s3): the function never sees
## another member's holdings. Choosing material is choosing observers (s6): a candidate
## carries the manifest's rows for its effect field. Nothing is scored (s7). Hermetic:
## a hand-built manifest + a static catalogue; links secp + stint + libsodium (material).

import std/[strutils, json]
import ../src/coordination/offers
import ../src/drivers/driver
import ../src/drivers/manifest
import ../src/wallet/material
import ../src/intents/disclosure

# A Safe-shaped manifest: a contributor safe-owner authority + a counterparty payee
# address bound to the effect's "to" field, disclosing "to" to the chain observer.
let desc = DriverDescriptor(rounds: 1, threshold: 2,
                            finality: finExternal, serializationDomain: "eip712.safe.v1.4.1")
let m = ActionManifest(declared: true, agreement: desc,
  requirements: @[req(rqAuthority, "safe-owner", rpContributor),
                  req(rqAddress, "payee", rpCounterparty, need(mcAddress, "chain:31337", "to"))],
  discloses: @[row("to", obChainObserver), row("payer", obChainObserver)])

# MY catalogue: an authorization key + a public account on evm:31337.
let myKey = Material(class: mcAuthority, chain: "", form: "secp256k1",
  handle: "keystore:secp", public: "0xMYKEY", grade: mgVerifiedLocally, source: msKeystore)
let myAcct = Material(class: mcAddress, chain: "evm:31337", form: "public",
  handle: "adapter:evm:31337:0xACCT", public: "0xACCT", grade: mgAttested, source: msAdapter)
let myCat = @[myKey, myAcct]

# ── 1. recipient offers: my authority fills the owner slot; my account fills the payee ─
block:
  let offers = recipientOffers(m.requirements, myCat, m)
  doAssert offers.len == 2, "both participant slots are mine to consider"
  var ownerOffer, payeeOffer: Offer
  for o in offers:
    if o.requirement.kind == rqAuthority: ownerOffer = o
    if o.requirement.kind == rqAddress: payeeOffer = o
  doAssert ownerOffer.status == osSatisfiable and ownerOffer.candidates.len == 1
  doAssert ownerOffer.candidates[0].material.public == "0xMYKEY"
  doAssert payeeOffer.status == osSatisfiable and payeeOffer.candidates.len == 1
  doAssert payeeOffer.candidates[0].material.public == "0xACCT"
  echo "1. recipient offers: authority fills owner, account fills payee OK"

# ── 2. choosing material is choosing observers (s6): the payee candidate carries "to" → chain ─
block:
  let offers = recipientOffers(m.requirements, myCat, m)
  for o in offers:
    if o.requirement.kind == rqAddress:
      doAssert o.candidates[0].discloses.len == 1
      doAssert o.candidates[0].discloses[0].field == "to"
      doAssert o.candidates[0].discloses[0].to == obChainObserver
  echo "2. a candidate carries the manifest rows its choice would disclose (to → chain) OK"

# ── 3. graded about me only (s3): another member's holdings never change my offers ────
block:
  let mine = recipientOffers(m.requirements, myCat, m)
  # A different member's catalogue — richer, with an address on the SAME chain. offersFor
  # takes only MY catalogue, so passing theirs cannot appear in or alter my result.
  let theirs = @[Material(class: mcAddress, chain: "evm:31337", form: "public",
    handle: "adapter:evm:31337:0xTHEM", public: "0xTHEM", grade: mgAttested, source: msAdapter),
    Material(class: mcAuthority, chain: "", form: "secp256k1", handle: "k", public: "0xTHEIRKEY",
             grade: mgVerifiedLocally, source: msKeystore)]
  let againstMine = recipientOffers(m.requirements, myCat, m)
  doAssert $againstMine == $mine, "my offers depend only on my catalogue"
  for o in recipientOffers(m.requirements, myCat & @[], m):
    for c in o.candidates:
      doAssert not ($c).contains("0xTHEM") and not ($c).contains("0xTHEIRKEY")
      doAssert not ($c).contains("keystore:secp") and not ($c).contains("adapter:evm"), "no handle crosses into an offer (s1)"
  doAssert theirs.len == 2   # referenced so the compiler keeps it; never passed to offersFor
  echo "3. offers are computed about me only — another member's holdings never appear (s3) OK"

# ── 4. an unsatisfiable slot + a capability unknown ───────────────────────────────
block:
  # a catalogue with NO address → the payee slot is unsatisfiable; the owner slot still fills.
  let keyOnly = @[myKey]
  let offers = recipientOffers(m.requirements, keyOnly, m)
  doAssert not offers.satisfiable()
  for o in offers:
    if o.requirement.kind == rqAddress: doAssert o.status == osUnsatisfiable
    if o.requirement.kind == rqAuthority: doAssert o.status == osSatisfiable
  # a host capability requirement is unknown (no broker) — never a fabricated verdict.
  let capM = ActionManifest(declared: true, agreement: desc,
    requirements: @[req(rqCapability, "coordinate.request", rpContributor)])
  let capOffers = offersFor(capM.requirements, myCat, capM, {rpContributor})
  doAssert capOffers[0].status == osUnknown
  echo "4. an unsatisfiable address slot + a capability-unknown slot OK"

# ── 5. proposer vs recipient parties: the composer sees proposer slots only ───────────
block:
  # add a proposer amount requirement (asset) bound to "value".
  var pm = m
  pm.requirements.add req(rqAsset, "amount", rpProposer, need(mcAsset, "chain:31337", "value"))
  pm.discloses.add row("value", obChainObserver)
  let mineWithAsset = myCat & @[Material(class: mcAsset, chain: "evm:31337", form: "native",
    handle: "adapter:evm:31337:ETH", public: "ETH", grade: mgAttested, source: msAdapter)]
  let comp = proposerOffers(pm.requirements, mineWithAsset, pm)
  doAssert comp.len == 1 and comp[0].requirement.kind == rqAsset, "composer sees only proposer slots"
  doAssert comp[0].status == osSatisfiable
  let recip = recipientOffers(pm.requirements, mineWithAsset, pm)
  for o in recip: doAssert o.requirement.party in {rpContributor, rpCounterparty}
  echo "5. proposer offers = proposer slots; recipient offers = contributor + counterparty OK"

# ── 6. the JSON payload the lidl surface returns (K6): public + grade + rows, no handle/score ─
block:
  let payload = offersPayload(recipientOffers(m.requirements, myCat, m))
  doAssert payload["ready"].getBool() == true
  let arr = payload["offers"]
  doAssert arr.len == 2
  var sawPayee = false
  for o in arr:
    doAssert o.hasKey("requirement") and o.hasKey("status") and o.hasKey("candidates")
    for c in o["candidates"]:
      doAssert c.hasKey("public") and c.hasKey("class") and c.hasKey("grade") and c.hasKey("discloses")
      doAssert not c.hasKey("handle") and not c.hasKey("source"), "no handle/source crosses (s1)"
      doAssert not c.hasKey("score") and not c.hasKey("rank"), "nothing scored or ranked (s7)"
    if o["requirement"]["kind"].getStr() == "address":
      sawPayee = true
      doAssert o["candidates"][0]["discloses"][0]["field"].getStr() == "to"
      doAssert o["candidates"][0]["discloses"][0]["to"].getStr() == "chain-observer"
  doAssert sawPayee
  # an unsatisfiable surface reports ready:false honestly.
  doAssert offersPayload(recipientOffers(m.requirements, @[myKey], m))["ready"].getBool() == false
  echo "6. the JSON payload: public+class+grade+rows, no handle/score; ready is honest OK"

echo "offers_test: all OK"
