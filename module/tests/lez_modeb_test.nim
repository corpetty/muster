## LEZ Mode B (exo-45e / exo-5be, docs/design/lez-adapter.md §6): a room-coordinated
import std/strutils
## transfer via the invoke driver. When the effect names a `counterparty` field, the
## invoke manifest declares a COUNTERPARTY address slot bound to it, so the room asks the
## recipient to share their LEZ key-node (coordinate_share_material, K5/K6) and the offers
## machinery finds a LEZ address that fills it. Generic: the invoke driver stays
## module-blind — which arg is the recipient is named by the effect. Links secp + stint +
## libsodium (material) + libsodium (curve25519 roster).

import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/manifest
import ../src/drivers/invoke
import ../src/crypto/curve25519
import ../src/coordination/offers
import ../src/coordination/intents
import ../src/wallet/material

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let member = encFromSeed(seed(3))
let drv = newInvokeDriver(@[member.identity().ed], k = 1)

# A room-coordinated LEZ private transfer, recipient UNKNOWN at compose time: the effect
# names `counterparty: "to"` and carries a (placeholder) "to" field for it to land in.
let effect = Effect(schemaId: invokeDomain("lez_core", "transfer_private"), fields: @[
  ("module", cbText("lez_core")), ("method", cbText("transfer_private")),
  ("counterparty", cbText("to")), ("chain", cbText("lez:testnet")),
  ("to", cbText("")), ("amount", cbUint(5'u64))])

# ── 1. the invoke manifest declares a counterparty payee bound to the "to" arg ─────
block:
  let m = drv.manifest(effect)
  doAssert m.consistent(effect), $consistencyFailures(m, effect)
  var payee: Requirement
  var found = false
  for r in m.requirements:
    if r.party == rpCounterparty and r.kind == rqAddress:
      payee = r; found = true
  doAssert found, "a coordinated transfer declares the recipient as a counterparty address"
  doAssert payee.needs.class == mcAddress and payee.needs.field == "to"
  # the roster-member authority + the target module are still there.
  var sawAuth, sawModule, sawLezAccount = false
  for r in m.requirements:
    if r.kind == rqAuthority and r.party == rpContributor: sawAuth = true
    if r.kind == rqModule and r.name == "lez_core": sawModule = true
    # exo-44b L2: a LEZ chain effect declares the proposer's funded-account requirement.
    if r.kind == rqInfra and r.name == "lez-account" and r.party == rpInstance: sawLezAccount = true
  doAssert sawAuth and sawModule
  doAssert sawLezAccount, "a LEZ (lez:*) action declares the proposer's lez-account requirement"
  echo "1. invoke manifest: counterparty payee + roster auth + lez_core module + lez-account OK"

# ── 2. a plain invoke (no counterparty field) declares NO counterparty slot ────────
block:
  let plain = Effect(schemaId: invokeDomain("lez_core", "version"),
    fields: @[("module", cbText("lez_core")), ("method", cbText("version"))])
  let m = drv.manifest(plain)
  for r in m.requirements:
    doAssert r.party != rpCounterparty, "no counterparty slot unless the effect names one"
  doAssert m.consistent(plain)
  echo "2. a plain invoke names no counterparty — the slot is opt-in per effect OK"

# ── 3. the offers machinery fills the LEZ payee from my shielded key-node ──────────
block:
  let m = drv.manifest(effect)
  # my catalogue holds a LEZ shielded receiving address (a key-node).
  let myCat = @[
    Material(class: mcAuthority, chain: "", form: "ed25519", handle: "roster:me",
             public: "0xMEKEY", grade: mgVerifiedLocally, source: msKeystore),
    Material(class: mcAddress, chain: "lez:testnet", form: "shielded",
             handle: "adapter:lez:testnet:priv:npk:vpk", public: "priv:npk:vpk",
             grade: mgAttested, source: msAdapter)]
  let offers = recipientOffers(m.requirements, myCat, m)
  var payeeOffer: Offer
  for o in offers:
    if o.requirement.kind == rqAddress: payeeOffer = o
  doAssert payeeOffer.status == osSatisfiable, "my LEZ key-node fills the recipient slot"
  doAssert payeeOffer.candidates.len == 1 and payeeOffer.candidates[0].material.public == "priv:npk:vpk"
  doAssert payeeOffer.candidates[0].material.form == "shielded", "a shielded receive — the private rail"
  # only the public face (the key-node) leaves — never a handle (s1).
  doAssert not ($payeeOffer.candidates[0]).contains("adapter:lez")
  echo "3. offers: my shielded LEZ key-node fills the coordinated-transfer recipient slot (s1) OK"

# ── 4. a Mode B effect folded THROUGH effectFromJson (the propose/log path) ────────
block:
  # what the UI publishes as a proposal: an invoke effect naming the counterparty arg and
  # the chain. Folding it from JSON (as reduceIntents does) must yield an effect the invoke
  # manifest recognizes as a coordinated transfer — the driver test above builds the Effect
  # directly, this proves the JSON path (Room propose → log → fold) carries the same fields.
  let json = """{"effect":"invoke","module":"lez_core","method":"transfer_private",
                 "counterparty":"to","chain":"lez:testnet","args":{"to":"","amount":5}}"""
  let folded = effectFromJson(json)
  doAssert folded.fieldText("counterparty") == "to", "effectFromJson carries the counterparty arg name"
  doAssert folded.fieldText("chain") == "lez:testnet", "effectFromJson carries the chain"
  let m = drv.manifest(folded)
  doAssert m.consistent(folded), $consistencyFailures(m, folded)
  var sawPayee, sawLezAccount = false
  for r in m.requirements:
    if r.party == rpCounterparty and r.kind == rqAddress and r.needs.field == "to": sawPayee = true
    if r.kind == rqInfra and r.name == "lez-account" and r.party == rpInstance: sawLezAccount = true
  doAssert sawPayee, "the folded-from-JSON effect declares the counterparty payee slot (was dropped before)"
  doAssert sawLezAccount, "the folded-from-JSON effect declares the proposer's lez-account requirement"
  # a plain invoke JSON (no counterparty) still declares no counterparty slot.
  let plain = effectFromJson("""{"effect":"invoke","module":"lez_core","method":"version"}""")
  for r in drv.manifest(plain).requirements:
    doAssert r.party != rpCounterparty, "no counterparty slot unless the JSON names one"
  echo "4. a Mode B effect folded through effectFromJson declares the counterparty slot + lez-account OK"

echo "lez_modeb_test: all OK"
