## The aggregate-locus driver, btc.frost-bip445 (Phase D, exo-a50.4.5): a t-of-n taproot
## account made by a ChillDKG ceremony. Two rounds (nonces, then partial signatures) and
## a key-path spend whose witness is ONE BIP-340 signature, so the chain sees single-sig.
##   1. the account IS the ceremony: from its public recovery data alone, anyone derives
##      the threshold key, the public shares, the participants and t, and the address
##      (OP_1 x(Q), since ChillDKG's key is already a taproot output key). A disclosure
##      is checked by re-deriving it, and a wrong address is refused;
##   2. a spend from the account's coins is key-path: every input's BIP-341 SigMsg
##      without a leaf, under the family domain;
##   3. round 1: a participant's contribution is its public nonces, one per input, named
##      by its host key. A non-participant is refused, and so is a round-1 payload offered
##      in round 2;
##   4. round 2: a partial signature per input, carrying the signer set (t participants
##      and their round-1 nonces) it signs under. It verifies against that set and the
##      signer's public share. A tampered signature, a set without the signer, or a set of
##      the wrong size is refused;
##   5. settlement: the partials of one set aggregate into one BIP-340 signature per input,
##      verified under the account key before anything is built. The witness is that
##      signature alone. Below t there is no spend;
##   6. before anyone signs: foreign coins and a wrong fee are refused;
##   7. the profile is the registry's: aggregate locus, a threshold scheme, two rounds,
##      secret state, a key ceremony, and never revealing the policy or the signers.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[json, sequtils, strutils, options]
import ../src/crypto/keystore
import ../src/frost/[secp, chilldkg]
import ../src/bitcoin/[tx, keys, sighash]
import ../src/dcbor/dcbor
import ../src/intents/materialization
import ../src/drivers/[driver, profile, btc_multisig, btc_frost]
import ../src/wallet/types
import ../src/wallet/btc_adapter
import ../src/settlement/settlement

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let kss = @[Keystore(newInMemoryKeystore(seed(1), seed(11))), Keystore(newInMemoryKeystore(seed(2), seed(12))),
            Keystore(newInMemoryKeystore(seed(3), seed(13)))]
const L = "room-f/treasury"
let hosts = kss.mapIt(it.frostHostPubkey(L))
let params = SessionParams(hostpubkeys: hosts, t: 2)
let pm1 = kss.mapIt(it.frostDkgStep1(L, params))
let (cst, cmsg1) = coordinatorStep1(pm1, params)
let pm2 = kss.mapIt(it.frostDkgStep2(L, params, cmsg1))
let (cmsg2, _, rec) = coordinatorFinalize(cst, pm2)
for k in kss: discard k.frostDkgFinalize(L, params, cmsg2)

# ── 1. the account is the ceremony ────────────────────────────────────────────
let acct = frostAccount("regtest", rec)
doAssert acct.params.hostpubkeys == hosts and acct.params.t == 2 and acct.pubshares.len == 3
doAssert acct.address.startsWith("bcrt1p") and acct.scriptPubKey == @[0x51'u8, 0x20] & acct.xonly
doAssert acct.xonly == pointFromCompressed(acct.threshPk).toXonly()
let (ok, _, detail) = frostAccountOfDisclosure(acct.chain, acct.address, toHex(rec))
doAssert ok, detail
let (bad, _, why) = frostAccountOfDisclosure(acct.chain, "bcrt1pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsz7mz8", toHex(rec))
doAssert not bad and "does not" in why, why
echo "1. the account from the ceremony's recovery data: key, shares, participants, t, address OK"

# ── 2. a key-path spend ───────────────────────────────────────────────────────
let utxos = @[BtcUtxo(txid: "11".repeat(32), vout: 0, value: 60_000, scriptPubKey: toHex(acct.scriptPubKey)),
              BtcUtxo(txid: "22".repeat(32), vout: 1, value: 50_000, scriptPubKey: toHex(acct.scriptPubKey))]
let effectJson = buildFrostSpend(acct, utxos, "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", 100_000, feeRate = 2)
let e = effectFromJson(effectJson)
let drv = newBtcFrostDriver(acct)
doAssert drv.describe().rounds == 2 and drv.describe().threshold == 2
let m = canonicalize(drv, e)
let hashes = drv.sighashesOf(e)
doAssert hashes.len == 2 and hashes.allIt(it.len == 32)
let (t0, amounts, spks) = spendOf(e)
doAssert hashes[1] == @(bip341Sighash(t0, 1, amounts, spks, SighashDefault)), "key path: no leaf"
doAssert drv.signRefusal(e) == ""
echo "2. a key-path spend: each input's BIP-341 SigMsg, no leaf OK"

# ── 3. round 1 ────────────────────────────────────────────────────────────────
drv.expectMaterialization(m)
let signers = @[0, 2]
let nonces = signers.mapIt(kss[it].frostNonceCommit(L, "intent-x", rec, hashes))
let r1 = signers.mapIt(round1Contribution(hosts[it], nonces[signers.find(it)]))
for k, c in r1:
  doAssert identifyContributor(drv, m, c) == toHex(hosts[signers[k]])
  doAssert drv.verifyContribution(c, 1) and not drv.verifyContribution(c, 2), "a round-1 payload is round 1's"
let stranger = newInMemoryKeystore(seed(9), seed(19)).frostHostPubkey(L)
doAssert identifyContributor(drv, m, round1Contribution(stranger, nonces[0])) == "", "not a participant"
echo "3. round 1: public nonces per input, named by the host key; strangers and wrong rounds refused OK"

# ── 4. round 2 ────────────────────────────────────────────────────────────────
let set = signers.mapIt((hosts[it], nonces[signers.find(it)]))
let psigs = signers.mapIt(kss[it].frostPartialSign(L, "intent-x", rec, signers, nonces, hashes))
let r2 = signers.mapIt(round2Contribution(hosts[it], set, psigs[signers.find(it)]))
for k, c in r2:
  doAssert identifyContributor(drv, m, c) == toHex(hosts[signers[k]])
  doAssert drv.verifyContribution(c, 2) and not drv.verifyContribution(c, 1)
var forged = psigs[0]
forged[0][5] = forged[0][5] xor 1
doAssert identifyContributor(drv, m, round2Contribution(hosts[0], set, forged)) == "", "a tampered partial"
doAssert identifyContributor(drv, m, round2Contribution(hosts[1], set, psigs[0])) == "", "a set without the signer"
doAssert identifyContributor(drv, m, round2Contribution(hosts[0], set[0 .. 0], psigs[0])) == "", "a set of t"
echo "4. round 2: partials verified against the carried set and the signer's share; forgeries refused OK"

# ── 5. settlement ─────────────────────────────────────────────────────────────
let stl = settlementFor(drv, newBitcoindAdapter("regtest", "http://127.0.0.1:1", "", ""),
                        Account(chain: acct.chain, form: afPublic, id: ""))
let asm0 = stl.assemble(drv, e, r1.mapIt((contributor: "", bytes: it.bytes)) & r2.mapIt((contributor: "", bytes: it.bytes)))
doAssert asm0.ok and asm0.have == 2 and asm0.need == 2, asm0.error & " " & asm0.detail
let spent = drv.finalizeFrostSpend(e, r2)
for i, input in spent.inputs:
  doAssert input.witness.len == 1 and input.witness[0].len == 64, "one 64-byte signature, like single-sig"
  doAssert schnorrVerify(input.witness[0], hashes[i], acct.xonly)
let short = stl.assemble(drv, e, @[(contributor: "", bytes: r2[0].bytes)])
doAssert not short.ok and short.have == 1, "below t: no spend"
echo "5. settlement: one BIP-340 signature per input from t partials — the witness a single-sig spend has OK"

# ── 6. refusals before signing ────────────────────────────────────────────────
var j = parseJson(effectJson)
j["fee"] = %1
doAssert "fee" in drv.signRefusal(effectFromJson($j))
j = parseJson(effectJson)
j["inputs"][0]["scriptPubKey"] = %("0014" & "ab".repeat(20))
doAssert "not this account" in drv.signRefusal(effectFromJson($j))
echo "6. foreign coins and a wrong fee refused before anyone signs OK"

# ── 7. the profile ────────────────────────────────────────────────────────────
let p = drv.profile()
doAssert p.family == FrostFamily and p.locus == loAggregate and p.scheme == scAggregateThreshold
doAssert p.rounds == 2 and p.secretState and p.setup == suDkg and p.k == 2 and p.n == 3
doAssert p.revealsPolicy == rvNever and p.revealsSigners == rvNever and p.approverCost == acNone
doAssert profileFailures(p, drv.describe()).len == 0, $profileFailures(p, drv.describe())
echo "7. the profile: aggregate, threshold, two rounds, secret state, a ceremony, reveals nothing OK"

echo "btc_frost_driver_test: a FROST account spends by key path — the chain sees single-sig — all OK"
