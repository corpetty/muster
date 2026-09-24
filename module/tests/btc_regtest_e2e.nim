## Phase B exit (exo-a50.2.7; docs/design/multisig-landscape.md §8): against a REAL
## Bitcoin Core on regtest (infra/bitcoind/regtest.sh), for BOTH families —
## btc.p2wsh-sortedmulti and btc.tapscript-multi-a:
##   1. muster's account (k=2 of Alice, Bob, Carol) derives the SAME address Bitcoin Core
##      derives from the descriptor — cross-checking scripts, keys and bech32(m);
##   2. the account is funded; its UTXOs are read back (scantxoutset) and a spend is
##      built from them — prevouts carried, fee declared, change back to the account;
##   3. Alice (a muster member) discloses the account and proposes; she approves IN-APP —
##      her keystore signs (DER / BIP-340), never handing out the key — attested;
##   4. Carol is a signer OUTSIDE muster: a Bitcoin Core wallet holding her key signs
##      the PSBT muster exports; muster imports her signature, verifies it like its own,
##      and it counts — graded "unattested" (signed outside muster), never "committed";
##   5. two of three → executable; the settlement seam finalizes the witnesses and the
##      Bitcoin adapter broadcasts; a block later it is final, the payee has the coins
##      and the account's spent UTXO is gone;
##   6. the two families' cards: the same rows, word for word — to an observer a P2WSH
##      multisig and a single-leaf tapscript multisig reveal the same at spend (policy
##      and signers); what differs is the account itself.
## Usage: btc_regtest_e2e [rpcUrl] [rpcUser] [rpcPassword]
## Needs a regtest bitcoind (infra/bitcoind/regtest.sh), the secp closure + libsodium.

import std/[os, json, strutils, sequtils, algorithm]
import ../src/hashing/sha256
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/kinds
import ../src/drivers/btc_multisig
import ../src/bitcoin/[tx, keys, psbt, taproot]
import ../src/crypto/keystore
import ../src/wallet/types
import ../src/wallet/adapter
import ../src/wallet/btc_adapter
import ../src/settlement/settlement
import ../src/coordination/accounts
import ../src/coordination/card_rows
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:18443")
let user = (if paramCount() >= 2: paramStr(2) else: "muster")
let pass = (if paramCount() >= 3: paramStr(3) else: "muster")

# ── base58check WIF (regtest) for handing Carol's key to Bitcoin Core ─────────────
proc base58(b: seq[byte]): string =
  const A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  var n = b
  var zeros = 0
  while zeros < n.len and n[zeros] == 0: inc zeros
  var digits: seq[int]
  for x in n:
    var carry = int(x)
    for i in 0 ..< digits.len:
      carry += digits[i] * 256
      digits[i] = carry mod 58
      carry = carry div 58
    while carry > 0: (digits.add carry mod 58; carry = carry div 58)
  result = repeat('1', zeros)
  for i in countdown(digits.len - 1, 0): result.add A[digits[i]]
proc wif(secret: seq[byte]): string =
  let payload = @[0xef'u8] & secret & @[0x01'u8]
  base58(payload & @(sha256d(payload))[0 ..< 4])

proc keyOf(hex: string): array[32, byte] =
  let b = hexToBytes(hex); (for i in 0 ..< 32: result[i] = b[i])
let aliceSecret = hexToBytes("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")   # aliceKs
let bobSecret = hexToBytes("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")     # bobKs
let carolSecret = @(sha256(cast[seq[byte]]("muster-phase-b-carol-outside")))
let A = compressedPubKey(aliceSecret)
let B = compressedPubKey(bobSecret)
let C = compressedPubKey(carolSecret)
doAssert aliceKs.btcPubKey() == A, "the member's keystore key is the account key"

let node = newBitcoindAdapter("regtest", url, user, pass)
proc rpc(meth: string, params: JsonNode = newJArray(), wallet = ""): JsonNode =
  node.call(meth, params, wallet)

# a miner wallet (funds + mines) and Carol's wallet (the outside signer)
for w in ["miner", "carol"]:
  try: discard rpc("createwallet", %*[w, false, w == "carol", "", false, true])
  except CatchableError: discard rpc("loadwallet", %*[w])
let minerAddr = rpc("getnewaddress", %*["", "bech32"], "miner").getStr()
discard rpc("generatetoaddress", %*[101, minerAddr])

proc descriptorOf(family: string): string =
  let body = (if family == P2wshFamily: "wsh(sortedmulti(2," & toHex(A) & "," & toHex(B) & "," & wif(carolSecret) & "))"
              else: "tr(" & NumsH & ",sortedmulti_a(2," & toHex(xonlyOfCompressed(A)) & "," &
                    toHex(xonlyOfCompressed(B)) & "," & wif(carolSecret) & "))")
  let info = rpc("getdescriptorinfo", %*[body])
  body & "#" & info["checksum"].getStr()

var rowsOf: seq[seq[CardRow]]
var profiles: seq[FamilyProfile]

for (family, kind) in [(P2wshFamily, "btc-p2wsh"), (TapscriptFamily, "btc-tapscript")]:
  # ── 1. the same address as Bitcoin Core ─────────────────────────────────────────
  let acct = btcAccount(family, "regtest", 2, @[A, B, C])
  let desc = descriptorOf(family)
  let coreAddr = rpc("deriveaddresses", %*[desc])[0].getStr()
  doAssert coreAddr == acct.address, family & ": muster " & acct.address & " vs Core " & coreAddr
  discard rpc("importdescriptors", %*[[{"desc": desc, "timestamp": "now"}]], "carol")
  echo "1. ", family, ": muster derives the address Bitcoin Core derives (", acct.address, ") OK"

  # ── 2. fund, read the UTXOs back, build a spend ──────────────────────────────────
  discard rpc("sendtoaddress", %*[acct.address, 1.0], "miner")
  discard rpc("generatetoaddress", %*[1, minerAddr])
  let utxos = node.utxosOf(acct.address)
  doAssert utxos.len == 1 and utxos[0].value == 100_000_000'u64
  let effectJson = buildBtcSpend(acct, utxos, minerAddr, 50_000_000'u64, feeRate = 2)
  let drv = newBtcMultisigDriver(acct)
  doAssert drv.signRefusal(effectFromJson(effectJson)) == "", drv.signRefusal(effectFromJson(effectJson))
  echo "2. ", family, ": funded; the UTXO read back; a spend built with prevouts, fee and change OK"

  # ── 3. disclose, propose, Alice approves in-app ────────────────────────────────
  var r = newRoom("/muster/1/btc-e2e-" & kind & "/proto")
  r.alice.publish(accountDiscloseEvent(RoomAccount(family: family, chain: acct.chain, address: acct.address,
    label: "Vault", signers: @[A, B, C].mapIt(toHex(it)), threshold: 2), "alice"))
  r.bob.poll()
  let resolver: DriverFor = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(r.alice.log.allEvents()), proc(k: string): Driver = newUnsupportedDriver(k))
  let policy = qualify(kind, acct.accountId)
  let id = liveProposeIntent(r.alice, aliceKs, resolver, policy, effectJson, int64(Now), 1,
                             account = acct.address, ttlSec = Ttl)
  doAssert id.len > 0 and not id.startsWith("refused") and id != "unsupported-driver", id
  r.alice.publish(readEvent(id, "inputs", "bitcoind://scantxoutset", $parseJson(effectJson)["inputs"]))
  doAssert liveContribute(r.alice, aliceKs, resolver, id, "", "", bindCtx(), Now) == "collecting"
  echo "3. ", family, ": disclosed, proposed, Alice approved in-app through her keystore OK"

  # ── 4. Carol signs OUTSIDE muster, through Bitcoin Core ─────────────────────────
  let exported = exportPsbt(drv, effectFromJson(effectJson)).toBase64()
  let signed = rpc("walletprocesspsbt", %*[exported, true, (if family == P2wshFamily: "ALL" else: "DEFAULT")], "carol")
  let imported = importPsbtContributions(drv, effectFromJson(effectJson), parsePsbtBase64(signed["psbt"].getStr()))
  doAssert imported.len == 1 and imported[0].signer == toHex(C), $imported.mapIt(it.signer)
  let st = liveContribute(r.alice, aliceKs, resolver, id, toHex(imported[0].contribution.bytes), "", bindCtx(), Now)
  doAssert st == "executable", st
  let grades = approvalGrades(r.alice.log.allEvents(), resolver, id)
  doAssert gradeOf(grades, toHex(A), 1) == agCommitted, "Alice approved in muster: attested"
  doAssert gradeOf(grades, toHex(C), 1) == agUnattested, "Carol signed outside muster: shown as such, never 'committed'"
  echo "4. ", family, ": Carol signed in Bitcoin Core; her imported signature counts, graded unattested OK"

  # ── 5. settle through the seam; final a block later ───────────────────────────
  let stl = settlementFor(drv, node, Account(chain: acct.chain, form: afPublic, id: ""))
  doAssert stl != nil and stl.family == family
  var contribs: seq[SettleContribution]
  for e in r.alice.log.allEvents():
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
      contribs.add (contributor: p[3], bytes: hexToBytes(e.value))
  let asm0 = stl.assemble(drv, effectFromJson(effectJson), contribs)
  doAssert asm0.ok, asm0.error & " " & asm0.detail
  let txRef = stl.submit(asm0.tx, aliceKs)
  doAssert stl.watch(txRef).status == fsPending, "broadcast, not yet mined"
  discard rpc("generatetoaddress", %*[1, minerAddr])
  doAssert stl.watch(txRef).status == fsFinal
  let paid = rpc("gettxout", %*[txRef.id, 0])
  doAssert paid.kind == JObject and paid["value"].getFloat() == 0.5, $paid
  let left = node.utxosOf(acct.address)
  doAssert left.len == 1 and left[0].txid == txRef.id, "the spent UTXO is gone; only the change remains"
  echo "5. ", family, ": settled through the seam; final after a block; the payee has 0.5 BTC OK"

  rowsOf.add cardRows(drv.profile())
  profiles.add drv.profile()

# ── 6. the two families' cards ─────────────────────────────────────────────────
doAssert rowsOf[0].mapIt(it.text) == rowsOf[1].mapIt(it.text),
  "a P2WSH and a single-leaf tapscript multisig reveal the same at spend: the cards say the same"
doAssert profiles[0].family != profiles[1].family and profiles[0].account != profiles[1].account
echo "6. the two families' cards read the same, row for row; only the account differs OK"

echo "btc_regtest_e2e: Bitcoin Core agrees on the address, a member signs in-app, an outside signer via PSBT, settled and final — both families OK"
