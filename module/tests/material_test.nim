## The holdings catalogue (exo-45e K2, docs/design/material-and-disclosure.md §3.1):
## sources fold into a local view; every Material carries a class + grade; and the
## ONLY projection that leaves the instance (disclosable) drops the handle and source
## — the boundary rule s1 (contracts/specs/derived-exo-45e). Hermetic: an in-memory
## keystore + a mock chain, no network. Links libsodium (keystore) + libsecp256k1.

import std/strutils
import ../src/wallet/material
import ../src/wallet/mock_chain
import ../src/crypto/keystore

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let ks = newInMemoryKeystore(seed(1), seed(2))

# ── 1. the keystore source yields the authorization key as verified authority ─────
block:
  let cat = catalogue(@[MaterialSource(newKeystoreSource(ks))])
  doAssert cat.len == 1
  let m = cat[0]
  doAssert m.class == mcAuthority and m.grade == mgVerifiedLocally and m.source == msKeystore
  doAssert m.form == "secp256k1"
  doAssert m.public.startsWith("0x") and m.public.len == 42, "public = the Ethereum address"
  doAssert m.handle == "keystore:secp:" & m.public, "the handle carries the KeyRef (K2b)"
  echo "1. keystore source: the authorization key is verified-local authority material OK"

# ── 2. an adapter source enumerates its accounts as ADDRESS material (per form) ───
block:
  let cat = catalogue(@[MaterialSource(newAdapterSource(newMockChain(), ks))])
  doAssert cat.len == 2, "the mock chain offers a public and a shielded account"
  var sawPublic, sawShielded = false
  for m in cat:
    doAssert m.class == mcAddress and m.source == msAdapter and m.grade == mgAttested
    if m.form == "public": sawPublic = true
    if m.form == "shielded": sawShielded = true
  doAssert sawPublic and sawShielded
  echo "2. adapter source: accounts become address material, one per form OK"

# ── 3. catalogue folds sources in order; forClass filters ─────────────────────────
block:
  let extra = newStaticSource(@[
    Material(class: mcAsset, chain: "evm:31337", form: "erc20", handle: "static:usdc",
             public: "USDC", grade: mgAttested, source: msHost)])
  let cat = catalogue(@[MaterialSource(newKeystoreSource(ks)),
                        MaterialSource(newAdapterSource(newMockChain(), ks)),
                        MaterialSource(extra)])
  doAssert cat.len == 4
  doAssert cat.forClass(mcAuthority).len == 1
  doAssert cat.forClass(mcAddress).len == 2
  doAssert cat.forClass(mcAsset).len == 1
  # deterministic order: keystore first, host-static last.
  doAssert cat[0].source == msKeystore and cat[^1].source == msHost
  echo "3. catalogue folds sources in order; forClass filters by material class OK"

# ── 4. the disclosure boundary (rule s1): disclosable() drops handle + source ─────
block:
  let cat = catalogue(@[MaterialSource(newKeystoreSource(ks)),
                        MaterialSource(newAdapterSource(newMockChain(), ks))])
  for m in cat:
    let d = m.disclosable()
    # the public face + class survive; the private handle does not cross.
    doAssert d.public == m.public and d.class == m.class
    doAssert not ($d).contains(m.handle), "a Material's handle must never reach its disclosable projection"
    doAssert not ($d).contains($m.source), "the source must never cross the boundary"
  echo "4. disclosable() carries the public face + class only — handle/source never cross OK"

echo "material_test: all OK"
