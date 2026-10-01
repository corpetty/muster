## LEZ provisioning fallback (exo-44b, the no-broker path): muster can make sure this
## instance has a LEZ account DIRECTLY over lez_core (core-to-core), so it is not
## hard-blocked on the LEZ Wallet App or the app-to-app broker. Delegating stays preferred;
## this is the fallback. Since LEZ v0.3 (exo-eb6.4) there is no faucet and no account
## registration: provisioning funds nothing, and an account is ready only once someone
## who holds native LEZ sends it some. Hermetic (FakeLezCore + in-memory keystore); links
## secp + stint + libsodium.

import std/strutils
import ../src/wallet/lez_core
import ../src/wallet/lez_adapter
import ../src/crypto/keystore

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let ks = newInMemoryKeystore(seed(1), seed(2))

# ── 1. a fresh instance: an account exists, unfunded, and the detail names it ─────
block:
  let a = newLezAdapter(newFakeLezCore())
  let (account, state, detail) = a.provision(ks)
  doAssert account.len > 0, "a public LEZ account now exists"
  doAssert state == "missing", "an unfunded account is not ready: " & detail
  doAssert account in detail and "no faucet" in detail,
    "the detail names the account to fund and says why nothing funded it: " & detail
  echo "1. provision: a public account exists, unfunded, and the account to fund is named OK"

# ── 2. once someone funds it (here, genesis), it is ready ─────────────────────────
block:
  let core = newFakeLezCore()
  let a = newLezAdapter(core)
  let first = a.provision(ks)
  core.fund(first.account, "1000000000")
  let (account, state, detail) = a.provision(ks)
  doAssert account == first.account, "the same account is reused, not duplicated"
  doAssert state == "met" and "balance" in detail, "a funded account is ready: " & detail
  echo "2. funded from outside, the same account is ready OK"

# ── 3. provisioning funds nothing, however often it is asked ──────────────────────
block:
  let core = newFakeLezCore()
  let a = newLezAdapter(core)
  for _ in 0 ..< 3: discard a.provision(ks)
  let (account, _, _) = a.provision(ks)
  doAssert core.getBalanceRaw(account, true) == "0", "no faucet, no free money"
  echo "3. provisioning never credits an account OK"

echo "lez_provision_test: all OK"
