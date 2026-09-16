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
  var sawAuth, sawModule = false
  for r in m.requirements:
    if r.kind == rqAuthority and r.party == rpContributor: sawAuth = true
    if r.kind == rqModule and r.name == "lez_core": sawModule = true
  doAssert sawAuth and sawModule
  echo "1. invoke manifest: a counterparty payee bound to 'to', + roster auth + lez_core module OK"

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

echo "lez_modeb_test: all OK"
