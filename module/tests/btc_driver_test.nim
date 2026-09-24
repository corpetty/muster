## The Bitcoin multisig driver (exo-a50.2.3, Phase B): btc.p2wsh-sortedmulti and
## btc.tapscript-multi-a behind the same Driver seam as the Safe and the room drivers.
##   1. an account — k of n compressed keys on a network — derives its witnessScript /
##      tapleaf, its scriptPubKey and its address (bcrt1q… / bcrt1p…), and its CAIP-2 /
##      CAIP-10 ids; the listed key order never changes any of it;
##   2. canonicalize re-derives every input's signature hash — BIP-143 over the
##      witnessScript, BIP-341/342 over the tapleaf — exactly as the primitives compute
##      them, and a change to an output, the fee or a prevout changes the bytes (inv 1);
##   3. a contribution is ONE signer's signature for EVERY input: it verifies only for an
##      account key, only over the right sighashes, only in the family's scheme (DER for
##      P2WSH, BIP-340 for tapscript); identifyContributor names the key;
##   4. both families pass the conformance suite and declare the profile the registry
##      has for them;
##   5. signRefusal: an input that is not this account's coins, a declared fee that is
##      not inputs − outputs, or an output worth nothing is refused before anyone signs;
##   6. the kinds are on the one list and account-bound: a disclosed Bitcoin account
##      resolves to its driver — unless its address does not commit to its keys, which
##      is refused rather than trusted;
##   7. PSBT, both ways: the driver exports the spend as a PSBT an outside signer can
##      sign, and a signature imported from a PSBT becomes a contribution the driver
##      verifies like its own.
## Needs the secp closure — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/dcbor/dcbor
import ../src/hashing/sha256
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/profile
import ../src/drivers/manifest
import ../src/drivers/kinds
import ../src/drivers/registry
import ../src/drivers/conformance
import ../src/drivers/btc_multisig
import ../src/bitcoin/[tx, script, sighash, taproot, keys, bech32, psbt, network]
import ../src/coordination/intent_events
import ../src/coordination/accounts

proc secretN(n: int): seq[byte] = @(sha256(cast[seq[byte]]("muster-btc-test-" & $n)))
let secrets = @[secretN(1), secretN(2), secretN(3)]
let pubs = secrets.mapIt(compressedPubKey(it))
let stranger = secretN(9)

proc accountOf(family: string, keys: seq[seq[byte]] = pubs): BtcAccount =
  btcAccount(family, "regtest", 2, keys)

let fundTxid = repeat("7a", 32)
let payTo = encodeSegwitAddress("bcrt", 0, hexToBytes("751e76e8199196d454941c45d1b3a323f1433bd6"))

proc spendJson(acct: BtcAccount, outValue = 90_000'u64, fee = 10_000'u64,
               inSpk = ""): string =
  $(%*{"effect": "btc-spend",
       "inputs": [{"txid": fundTxid, "vout": 1, "value": 100_000,
                   "scriptPubKey": (if inSpk.len > 0: inSpk else: toHex(acct.scriptPubKey)),
                   "sequence": 0xfffffffd}],
       "outputs": [{"address": payTo, "value": outValue}],
       "locktime": 0, "fee": fee})

# ── 1. accounts ─────────────────────────────────────────────────────────────────
block:
  let w = accountOf("btc.p2wsh-sortedmulti")
  doAssert w.witnessScript == sortedMultiScript(2, pubs)
  doAssert w.scriptPubKey == p2wshScriptPubKey(w.witnessScript)
  doAssert w.address.startsWith("bcrt1q") and scriptPubKeyOfAddress("bcrt", w.address) == w.scriptPubKey
  doAssert w.chain == "bip122:0f9188f13cb7b2c71f2a335e3a4fc328" and w.accountId == w.chain & ":" & w.address
  doAssert accountOf("btc.p2wsh-sortedmulti", @[pubs[2], pubs[0], pubs[1]]).address == w.address, "order-free"
  let t = accountOf("btc.tapscript-multi-a")
  let leaf = multiAScript(2, pubs.mapIt(xonlyOfCompressed(it)))
  doAssert t.leafScript == leaf
  let (q, _) = outputKey(hexToBytes(NumsH), @(tapLeafHash(leaf)))
  doAssert t.scriptPubKey == p2trScriptPubKey(q) and t.address.startsWith("bcrt1p")
  doAssert accountOf("btc.tapscript-multi-a", @[pubs[1], pubs[2], pubs[0]]).address == t.address
  doAssert btcAccount("btc.p2wsh-sortedmulti", "mainnet", 2, pubs).address.startsWith("bc1q")
  doAssert btcAccount("btc.p2wsh-sortedmulti", "mainnet", 2, pubs).chain == "bip122:000000000019d6689c085ae165831e93"
  echo "1. accounts derive script, scriptPubKey, address and CAIP ids, independent of key order OK"

# ── 2. canonicalize re-derives every sighash ─────────────────────────────────────
for fam in ["btc.p2wsh-sortedmulti", "btc.tapscript-multi-a"]:
  let acct = accountOf(fam)
  let drv = newBtcMultisigDriver(acct)
  let eff = effectFromJson(spendJson(acct))
  doAssert eff.schemaId == "muster.effect.btc-spend.v1"
  let (t, amounts, spks) = spendOf(eff)
  let expected = (if fam == "btc.p2wsh-sortedmulti":
                    @(bip143Sighash(t, 0, acct.witnessScript, 100_000, SighashAll.uint32))
                  else: @(bip341Sighash(t, 0, amounts, spks, SighashDefault, @(tapLeafHash(acct.leafScript)))))
  doAssert sighashesOf(drv, eff) == @[expected], fam
  let m = canonicalize(drv, eff)
  doAssert reviewAndCheck(drv, eff, m)
  doAssert not reviewAndCheck(drv, effectFromJson(spendJson(acct, outValue = 80_000, fee = 20_000)), m),
    "a different output is a different materialization"
  echo "2. ", fam, ": canonicalize re-derives the sighash the primitives compute; a changed spend is refused OK"

# ── 3. contributions ──────────────────────────────────────────────────────────────
for fam in ["btc.p2wsh-sortedmulti", "btc.tapscript-multi-a"]:
  let acct = accountOf(fam)
  let drv = newBtcMultisigDriver(acct)
  let eff = effectFromJson(spendJson(acct))
  let m = canonicalize(drv, eff)
  drv.expectMaterialization(m)
  let c0 = signContribution(drv, eff, pubs[0], proc(h: seq[byte]): seq[byte] =
    (if fam == "btc.p2wsh-sortedmulti": ecdsaSignDer(secrets[0], h) else: schnorrSign(secrets[0], h)))
  doAssert drv.verifyContribution(c0, 1)
  doAssert identifyContributor(drv, m, c0) == toHex(pubs[0])
  let cx = signContribution(drv, eff, compressedPubKey(stranger), proc(h: seq[byte]): seq[byte] =
    (if fam == "btc.p2wsh-sortedmulti": ecdsaSignDer(stranger, h) else: schnorrSign(stranger, h)))
  doAssert not drv.verifyContribution(cx, 1) and identifyContributor(drv, m, cx) == "", "a stranger never counts"
  let wrongScheme = signContribution(drv, eff, pubs[1], proc(h: seq[byte]): seq[byte] =
    (if fam == "btc.p2wsh-sortedmulti": schnorrSign(secrets[1], h) else: ecdsaSignDer(secrets[1], h)))
  doAssert not drv.verifyContribution(wrongScheme, 1), "the family's own scheme only"
  let other = effectFromJson(spendJson(acct, outValue = 80_000, fee = 20_000))
  let cOther = signContribution(drv, other, pubs[1], proc(h: seq[byte]): seq[byte] =
    (if fam == "btc.p2wsh-sortedmulti": ecdsaSignDer(secrets[1], h) else: schnorrSign(secrets[1], h)))
  drv.expectMaterialization(m)
  doAssert not drv.verifyContribution(cOther, 1), "a signature over another spend never counts"
  echo "3. ", fam, ": one signer's signatures for every input verify for account keys only, in the family's scheme OK"

# ── 4. conformance + profile ─────────────────────────────────────────────────────
for fam in ["btc.p2wsh-sortedmulti", "btc.tapscript-multi-a"]:
  let acct = accountOf(fam)
  let drv = newBtcMultisigDriver(acct)
  let eff = effectFromJson(spendJson(acct))
  let tampered = effectFromJson(spendJson(acct, outValue = 80_000, fee = 20_000))
  drv.expectMaterialization(canonicalize(drv, eff))
  let c = signContribution(drv, eff, pubs[0], proc(h: seq[byte]): seq[byte] =
    (if fam == "btc.p2wsh-sortedmulti": ecdsaSignDer(secrets[0], h) else: schnorrSign(secrets[0], h)))
  let r = checkConformance(drv, eff, tampered, c)
  doAssert r.allPass(), fam & ": " & $r.failed()
  doAssert checkProfileConformance(drv).allPass(), fam & ": " & $checkProfileConformance(drv).failed()
  let p = drv.profile()
  doAssert p.family == fam and p.chain == acct.chain and p.account == acct.accountId
  doAssert p.k == 2 and p.n == 3 and p.bypassesKnown and p.bypasses.len == 0,
    "nothing gets around a script: the chain enforces exactly k of n"
  echo "4. ", fam, ": passes conformance; declares its registry profile (chain, account, 2 of 3, no bypass) OK"

# ── 5. signRefusal ──────────────────────────────────────────────────────────────
block:
  let acct = accountOf("btc.p2wsh-sortedmulti")
  let drv = newBtcMultisigDriver(acct)
  doAssert drv.signRefusal(effectFromJson(spendJson(acct))) == ""
  doAssert "not this account" in drv.signRefusal(effectFromJson(spendJson(acct, inSpk = "0014" & repeat("11", 20))))
  doAssert "fee" in drv.signRefusal(effectFromJson(spendJson(acct, outValue = 90_000, fee = 5_000)))
  doAssert "dust" in drv.signRefusal(effectFromJson(spendJson(acct, outValue = 0, fee = 100_000)))
  echo "5. spending coins that are not this account's, a fee that is not inputs − outputs, or a zero output is refused OK"

# ── 6. kinds + resolution from a disclosed account ─────────────────────────────────
block:
  doAssert isKnownKind("btc-p2wsh") and isKnownKind("btc-tapscript")
  doAssert kindNeedsAccount("btc-p2wsh") and kindInfo("btc-tapscript").accountFamilies == @["btc.tapscript-multi-a"]
  doAssert "btc-p2wsh" in kindsFor("payment") and "btc-tapscript" in kindsFor("payment")
  let acct = accountOf("btc.p2wsh-sortedmulti")
  let ra = RoomAccount(family: acct.family, chain: acct.chain, address: acct.address,
                       signers: pubs.mapIt(toHex(it)), threshold: 2)
  let accts = reduceAccounts(@[accountDiscloseEvent(ra, "alice")])
  let roomBuild = proc(kind: string): Driver = newUnsupportedDriver(kind)
  let d = driverForPolicy(qualify("btc-p2wsh", acct.accountId), accts, roomBuild)
  doAssert d.profile().family == "btc.p2wsh-sortedmulti" and d.profile().account == acct.accountId
  var liar = ra
  liar.signers = @[toHex(pubs[0]), toHex(pubs[1]), toHex(compressedPubKey(stranger))]
  let bad = reduceAccounts(@[accountDiscloseEvent(liar, "mallory")])
  doAssert driverForPolicy(qualify("btc-p2wsh", acct.accountId), bad, roomBuild) of UnsupportedDriver,
    "a disclosure whose address does not commit to its keys is refused, not trusted"
  doAssert btcDisclosureCheck(bad[0]).status == acDisagrees and btcDisclosureCheck(accts[0]).status == acVerified
  doAssert newDriver("btc-tapscript", %*{"network": "regtest", "k": 2, "keys": pubs.mapIt(toHex(it))}).profile().family ==
    "btc.tapscript-multi-a"
  echo "6. the kinds are listed and account-bound; a disclosed account resolves unless its address betrays its keys OK"

# ── 7. PSBT both ways ─────────────────────────────────────────────────────────────
for fam in ["btc.p2wsh-sortedmulti", "btc.tapscript-multi-a"]:
  let acct = accountOf(fam)
  let drv = newBtcMultisigDriver(acct)
  let eff = effectFromJson(spendJson(acct))
  let m = canonicalize(drv, eff)
  var p = exportPsbt(drv, eff)
  doAssert p.witnessUtxo(0)[0]
  if fam == "btc.p2wsh-sortedmulti": doAssert p.witnessScript(0) == acct.witnessScript
  else: doAssert p.tapLeafScripts(0).len == 1 and p.tapLeafScripts(0)[0][1] == acct.leafScript
  # an outside signer signs the PSBT with its own tooling
  let h = sighashesOf(drv, eff)[0]
  if fam == "btc.p2wsh-sortedmulti":
    p.addPartialSig(0, pubs[2], ecdsaSignDer(secrets[2], h) & @[SighashAll])
  else:
    p.addTapScriptSig(0, xonlyOfCompressed(pubs[2]), @(tapLeafHash(acct.leafScript)), schnorrSign(secrets[2], h))
  let imported = importPsbtContributions(drv, eff, parsePsbtBase64(p.toBase64()))
  doAssert imported.len == 1 and imported[0].signer == toHex(pubs[2])
  drv.expectMaterialization(m)
  doAssert drv.verifyContribution(imported[0].contribution, 1)
  doAssert identifyContributor(drv, m, imported[0].contribution) == toHex(pubs[2])
  var otherSpend = exportPsbt(drv, effectFromJson(spendJson(acct, outValue = 80_000, fee = 20_000)))
  var refused = false
  try: discard importPsbtContributions(drv, eff, otherSpend)
  except PsbtError: refused = true
  doAssert refused, "a PSBT of another spend is refused, never partially imported"
  echo "7. ", fam, ": exports a PSBT an outside signer signs; the imported signature verifies like a native one OK"

echo "btc_driver_test: all OK"
