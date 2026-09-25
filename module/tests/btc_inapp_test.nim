## In-app Bitcoin signing through the keystore (exo-a50.2.4, Phase B) — no node needed:
##   1. the keystore's Bitcoin operations: btcPubKey is the compressed key of its secp
##      secret; signEcdsaDer makes a strict low-S DER signature, signSchnorr a BIP-340
##      one, both verifying under that key — operations only, the secret never leaves;
##   2. for BOTH families a member approves IN-APP: the driver's signInApp hook signs
##      every input through the keystore (DER for P2WSH, BIP-340 for tapscript), the
##      contribution counts under the member's compressed key, and the attestation — a
##      recoverable signature by that SAME key — grades committed;
##   3. a signature made outside muster (a key muster never held) pasted in counts
##      toward k and grades unattested, never committed; two of three → executable;
##   4. a member whose key is not one of the account's approves in-app: rejected,
##      nothing published, nothing counted;
##   5. a keyRef other than the key the hook signs with is refused — never a silent
##      fall-through to a different key than the caller chose (K2b);
##   6. a driver that does not override the hook (the Safe) leaves in-app signing to the
##      live path: handled = false.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/log/log
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/inapp
import ../src/drivers/btc_multisig
import ../src/bitcoin/[tx, keys]
import ../src/crypto/keystore
import ../src/coordination/intent_events
import ../src/coordination/live
import ../src/coordination/attest
import ../src/coordination/accounts
import ./probes/live_room

let aliceSecret = hexToBytes("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let carolSecret = @(sha256(cast[seq[byte]]("muster-btc-inapp-carol")))
let daveSecret = @(sha256(cast[seq[byte]]("muster-btc-inapp-dave")))
let A = compressedPubKey(aliceSecret)
let B = bobKs.btcPubKey()
let C = compressedPubKey(carolSecret)
let D = compressedPubKey(daveSecret)

# ── 1. the keystore's Bitcoin operations ─────────────────────────────────────────
block:
  doAssert aliceKs.btcPubKey() == A, "the keystore's Bitcoin key is its secp key, compressed"
  let h = sha256(cast[seq[byte]]("a sighash"))
  let der = aliceKs.signEcdsaDer(h)
  doAssert ecdsaVerifyDer(der, h, A), "DER ECDSA verifies under the compressed key"
  let sch = aliceKs.signSchnorr(h)
  doAssert sch.len == 64 and schnorrVerify(sch, h, xonlyOfCompressed(A)), "BIP-340 verifies under the x-only key"
  echo "1. the keystore signs DER and BIP-340 under its compressed key; the secret stays in OK"

proc spendJson(acct: BtcAccount): string =
  $(%*{"effect": "btc-spend",
       "inputs": [{"txid": repeat("5c", 32), "vout": 0, "value": 200_000,
                   "scriptPubKey": toHex(acct.scriptPubKey), "sequence": 0xfffffffd}],
       "outputs": [{"address": acct.address, "value": 150_000}],
       "locktime": 0, "fee": 50_000})

proc resolverOf(r: Room): DriverFor =
  let s = r.alice
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(s.log.allEvents()), proc(k: string): Driver = newUnsupportedDriver(k))

proc disclose(r: Room, acct: BtcAccount, keys: seq[seq[byte]]) =
  r.discloseAs("alice", RoomAccount(family: acct.family, chain: acct.chain,
    address: acct.address, label: "Vault", signers: keys.mapIt(toHex(it)), threshold: acct.k))
  r.bob.poll()

var seqNo = 0'u64
proc proposeOn(r: Room, resolver: DriverFor, kind: string, acct: BtcAccount): string =
  inc seqNo
  let effectJson = spendJson(acct)
  result = liveProposeIntent(r.alice, aliceKs, resolver, qualify(kind, acct.accountId), effectJson,
                             int64(Now), seqNo, account = acct.address, ttlSec = Ttl)
  doAssert result.len > 0 and not result.startsWith("refused") and result != "unsupported-driver", result

for (family, kind) in [(P2wshFamily, "btc-p2wsh"), (TapscriptFamily, "btc-tapscript")]:
  # ── 2. a member approves in-app ─────────────────────────────────────────────────
  let acct = btcAccount(family, "regtest", 2, @[A, B, C])
  var r = newRoom("/muster/1/btc-inapp-" & kind & "/proto")
  r.disclose(acct, @[A, B, C])
  let resolver = resolverOf(r)
  let id = r.proposeOn(resolver, kind, acct)
  doAssert liveContribute(r.alice, aliceKs, resolver, id, "", "", bindCtx(), Now) == "collecting"
  let sigs = r.alice.log.allEvents().filterIt(it.key.startsWith("intent/" & id & "/sig/"))
  doAssert sigs.len == 1 and sigs[0].key.split('/')[3] == toHex(A), "counted under Alice's compressed key"
  let drv = resolver(qualify(kind, acct.accountId))
  let effect = effectFromJson(spendJson(acct))
  let m = canonicalize(drv, effect)
  doAssert identifyContributor(drv, m, Contribution(bytes: hexToBytes(sigs[0].value))) == toHex(A)
  var grades = approvalGrades(r.alice.log.allEvents(), resolver, id)
  doAssert gradeOf(grades, toHex(A), 1) == agCommitted, "an in-app approval is attested by the same key"
  echo "2. ", family, ": Alice approved in-app through her keystore; counted and attested OK"

  # ── 3. a signature from outside muster ────────────────────────────────────────
  let outside = BtcMultisigDriver(drv).signContribution(effect, C, proc(h: seq[byte]): seq[byte] =
    var a: array[32, byte]
    for i in 0 ..< 32: a[i] = h[i]
    if family == P2wshFamily: ecdsaSignDer(carolSecret, a) else: schnorrSign(carolSecret, a))
  doAssert liveContribute(r.alice, aliceKs, resolver, id, toHex(outside.bytes), "", bindCtx(), Now) == "executable"
  grades = approvalGrades(r.alice.log.allEvents(), resolver, id)
  doAssert gradeOf(grades, toHex(C), 1) == agUnattested, "signed outside muster: shown as such"
  doAssert gradeOf(grades, toHex(A), 1) == agCommitted
  echo "3. ", family, ": a signature made outside muster counts, graded unattested; 2 of 3 executable OK"

  # ── 4. a member who is not a signer ─────────────────────────────────────────────
  let other = btcAccount(family, "regtest", 2, @[A, C, D])
  var r2 = newRoom("/muster/1/btc-inapp-other-" & kind & "/proto")
  r2.disclose(other, @[A, C, D])
  let res2 = resolverOf(r2)
  let id2 = r2.proposeOn(res2, kind, other)
  r2.bob.poll()
  let before = r2.bob.log.allEvents().len
  doAssert liveContribute(r2.bob, bobKs, res2, id2, "", "", bindCtx(), Now) == "rejected"
  doAssert r2.bob.log.allEvents().len == before, "nothing published"
  echo "4. ", family, ": a member whose key is not the account's is rejected, nothing published OK"

  # ── 5. a keyRef the hook does not sign with ───────────────────────────────────
  var r3 = newRoom("/muster/1/btc-inapp-ref-" & kind & "/proto")
  r3.disclose(acct, @[A, B, C])
  let res3 = resolverOf(r3)
  let id3 = r3.proposeOn(res3, kind, acct)
  let extra = newInMemoryKeystore((block:
    var k: array[32, byte]
    for i in 0 ..< 32: k[i] = aliceSecret[i]
    k), (block:
    var s: array[32, byte]
    for i in 0 ..< 32: s[i] = 7
    s))
  let second = extra.addKey((block:
    var k: array[32, byte]
    for i in 0 ..< 32: k[i] = daveSecret[i]
    k), (block:
    var s: array[32, byte]
    for i in 0 ..< 32: s[i] = 8
    s))
  doAssert liveContribute(r3.alice, extra, res3, id3, "", second, bindCtx(), Now) == "unknown-key",
    "a chosen key the Bitcoin hook would not sign with is refused, never swapped for another"
  echo "5. ", family, ": a keyRef other than the signing key is refused OK"

# ── 6. a driver that does not override the hook ──────────────────────────────────
block:
  let h = safeDrv.signInApp(effectFromJson(effectFor("safe", 1)), aliceKs, sha256(cast[seq[byte]]("p")))
  doAssert not h.handled, "the Safe is signed by the live path, not the hook"
  echo "6. a driver without the hook leaves in-app signing to the live path OK"

echo "btc_inapp_test: a member signs Bitcoin in-app through the keystore — attested; outside signatures count, unattested OK"
