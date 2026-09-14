## The LEZ ChainAdapter over a deterministic fake LezCore (P-L1/P-L2). Exercises the
## LEZ's real shape — public + shielded accounts, receive-by-scan, delayed finality,
## and the three failure conventions each translated into a WalletError raise — without
## any infra. The real lp_* LezCore (P-L3) slots behind the same seam. Link flags: the
## adapter imports the Keystore seam, so the crypto closure (secp + stint + libsodium)
## is on the path — the SECP..SODIUM set in module/tests/README.md.

import std/strutils
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/wallet/lez_core
import ../src/wallet/lez_adapter
import ../src/crypto/keystore   # for the Keystore type only
# The LEZ wallet signs internally (lez_core holds the key), so the adapter never
# touches muster's keystore — the seam still takes one, so pass a nil placeholder.
let ks: Keystore = nil

# ── 1. describe: not EVM — two forms, delayed finality ─────────────────────────
block:
  let a = newLezAdapter(newFakeLezCore())
  let d = a.describe()
  doAssert d.chain == "lez:testnet"
  doAssert afPublic in d.accountForms and afShielded in d.accountForms
  doAssert d.finality == finDelayed, "a shielded transfer proves — settlement is delayed"
  doAssert d.nativeAsset.symbol == "LEZ"
  echo "1. describe — public + shielded forms, delayed finality OK"

# ── 2. accounts are created once + cached (the wallet persists them) ────────────
block:
  let a = newLezAdapter(newFakeLezCore())
  let accs = a.accounts(ks)
  doAssert accs.len == 2
  doAssert accs[0].form == afPublic and accs[1].form == afShielded
  doAssert a.accounts(ks)[0].id == accs[0].id, "cached — not re-minted per call"
  echo "2. accounts — one public + one shielded, cached OK"

# ── 3. fund + a PUBLIC transfer settles at once ────────────────────────────────
block:
  let core = newFakeLezCore()
  let a = newLezAdapter(core)
  let accs = a.accounts(ks)
  let pub = accs[0]
  a.claimFaucet("pinata-1", pub)
  doAssert a.balance(pub, a.assets()[0]).raw == "1000000000", "faucet funded the public account"

  # a second public account to receive
  let other = core.createAccount(lakPublic)
  let tx = a.submit(a.prepareTransfer(pub, other.id, amount(a.assets()[0], "250000000")), ks)
  doAssert a.balance(pub, a.assets()[0]).raw == "750000000", "sender debited"
  doAssert core.getBalanceRaw(other.id) == "250000000", "recipient credited"
  doAssert a.finality(tx).status == fsFinal, "a public transfer is final immediately"
  echo "3. public transfer — funded, debited, credited, final OK"

# ── 4. a SHIELDED transfer: receive-by-scan + DELAYED finality ─────────────────
block:
  let core = newFakeLezCore()
  let a = newLezAdapter(core)
  let pub = a.accounts(ks)[0]
  a.claimFaucet("pinata-1", pub)

  # the recipient publishes a key node (npk/vpk); the sender addresses THAT, not an id.
  let recipient = core.createAccount(lakPrivate)
  let dest = "priv:" & recipient.npk & ":" & recipient.vpk
  let amt = amount(a.assets()[0], "100000000")
  doAssert a.estimateFee(pub, dest, amt).note.contains("proof"), "a shielded send pays a proof cost"

  let tx = a.submit(a.prepareTransfer(pub, dest, amt), ks)
  doAssert a.balance(pub, a.assets()[0]).raw == "900000000", "sender debited immediately"

  # DELAYED: the note isn't final on the first poll — it's still settling/being scanned.
  doAssert a.finality(tx).status == fsPending, "read right after is stale — still settling"
  doAssert a.finality(tx).status == fsFinal, "the next poll, after the scan, is final"

  # RECEIVE-BY-SCAN: the credited note lands at an account the recipient didn't name;
  # syncPrivate discovers it. (The original published account is NOT the credited one.)
  let discovered = a.syncPrivate()
  var credited = ""
  for acc in discovered:
    if core.getBalanceRaw(acc.id) == "100000000": credited = acc.id
  doAssert credited.len > 0 and credited != recipient.id,
           "the note is discovered at a fresh account, not the published id"
  echo "4. shielded transfer — proof cost, delayed finality, receive-by-scan OK"

# ── 5. every failure convention becomes a raise (never a false zero/receipt) ───
block:
  let core = newFakeLezCore()
  let a = newLezAdapter(core)
  let pub = a.accounts(ks)[0]
  a.claimFaucet("pinata-1", pub)

  # unanswerable balance read ("" sentinel) → raise, not a zero
  var raised = false
  try: discard a.balance(Account(chain: "lez:testnet", form: afPublic, id: "nope"), a.assets()[0])
  except WalletError: raised = true
  doAssert raised, "an unknown account's balance raises, never reads as 0"

  # a success:false envelope → raise, never a false receipt (labbook §4)
  core.failNextTransfer = true
  raised = false
  let other = core.createAccount(lakPublic)
  try: discard a.submit(a.prepareTransfer(pub, other.id, amount(a.assets()[0], "1")), ks)
  except WalletError: raised = true
  doAssert raised, "a success:false transfer raises"

  # the envelope parser: empty + unparseable + explicit false all fail
  doAssert not parseEnvelope("").success
  doAssert not parseEnvelope("not json").success
  doAssert not parseEnvelope("""{"success":false,"error":"x"}""").success
  doAssert parseEnvelope("""{"success":true,"tx_hash":"0xabc"}""").success

  # insufficient funds → raise
  raised = false
  try: discard a.submit(a.prepareTransfer(pub, other.id, amount(a.assets()[0], "999999999999")), ks)
  except WalletError: raised = true
  doAssert raised, "overspend raises"
  echo "5. failure conventions — empty / success:false / overspend all raise OK"

echo "wallet_lez_test: the LEZ adapter honours the zone's shape — all OK"
