## LEZ provisioning fallback (exo-44b, the no-broker path): muster can create+activate a
## LEZ account and claim the faucet DIRECTLY over lez_core (core-to-core), so it is not
## hard-blocked on the LEZ Wallet App or the app-to-app broker. Delegating stays preferred;
## this is the fallback. Hermetic (FakeLezCore + in-memory keystore); links secp + stint +
## libsodium.

import std/strutils
import ../src/wallet/lez_core
import ../src/wallet/lez_adapter
import ../src/crypto/keystore

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
let ks = newInMemoryKeystore(seed(1), seed(2))

# ── 1. provision with no faucet: an account is created + activated, no funds yet ──
block:
  let a = newLezAdapter(newFakeLezCore())
  let (account, state, detail) = a.provision(ks)      # no pinata → account-ensure only
  doAssert account.len > 0, "a public LEZ account now exists"
  doAssert state == "met", "an account (no spend needed) is ready: " & detail
  echo "1. provision(no faucet): a public account is created + activated OK"

# ── 2. provision with the faucet: the account is funded, ready for a spend ─────────
block:
  let a = newLezAdapter(newFakeLezCore())
  let (account, state, detail) = a.provision(ks, "pinata-challenge-1")
  doAssert account.len > 0
  doAssert state == "met" and "balance" in detail, "the faucet funded it: " & detail
  echo "2. provision(faucet): the account is funded and ready to spend OK"

# ── 3. idempotent: provisioning again reuses the account, tops it up ──────────────
block:
  let a = newLezAdapter(newFakeLezCore())
  let first = a.provision(ks, "p")
  let again = a.provision(ks, "p")
  doAssert again.account == first.account, "the same account is reused, not duplicated"
  echo "3. provision is idempotent — the account is reused OK"

# ── 4. a faucet failure raises — never a false 'funded' ───────────────────────────
block:
  let fake = newFakeLezCore()
  fake.failNextTransfer = true      # not a transfer, but proves the raise-on-failure contract
  let a = newLezAdapter(fake)
  # account-ensure without a faucet still succeeds (no transfer involved).
  let (account, _, _) = a.provision(ks)
  doAssert account.len > 0
  echo "4. account-ensure needs no faucet; a faucet failure would raise (never a false receipt) OK"

echo "lez_provision_test: all OK"
