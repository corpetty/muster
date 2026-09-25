## A LEZ public account owned by a FROST key (Phase D, exo-a50.4.6), on a REAL LEZ v0.2.4
## sequencer (infra/lez/localnet.sh). It settles the registry's open question for
## lez.frost-public-account: can an aggregate key own a public account?
##   1. a 2-of-3 ChillDKG gives a threshold key Q; its LEZ public account id is
##      SHA-256("/LEE/v0.3/AccountId/Public/" ‖ x(Q)) with NO tweak, because the chain
##      checks exactly that and a BIP-340 signature under x(Q);
##   2. the FROST account co-signs a token mint with a keystore member: two witnesses, one
##      of them a two-round FROST aggregate. The chain includes it, and the account holds
##      the tokens (owned by the token program);
##   3. the FROST account alone signs a transfer out of its holding. The chain includes it,
##      the balances move, and the account's nonce advances;
##   4. an aggregate over the wrong message is refused by the chain (not included) and
##      nothing moves.
## Usage: lez_frost_account_e2e [sequencerUrl] [blockSeconds] (default http://127.0.0.1:3040 15)
## Needs the web3 closure (chronos, json-rpc, bearssl) + the secp closure + libsodium.

import std/[os, json, strutils, sequtils, options, random, times]
import stint
import ../src/crypto/keystore
import ../src/frost/[secp, signing, chilldkg]
import ../src/lez/multisig
import ../src/lez/multisig_chain
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/wallet/lez_multisig_live

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
let vectors = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-tx-v024" / "vectors.json"))
proc words(n: JsonNode): seq[uint32] = n.getElems().mapIt(uint32(it.getBiggestInt()))
let tokenProgram = hexToBytes("ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b")
proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

randomize()
let run = $getTime().toUnix() & "-" & $rand(1_000_000)

# ── 1. the ceremony, and the account ──────────────────────────────────────────
let kss = @[Keystore(newInMemoryKeystore(seed(41), seed(51))), Keystore(newInMemoryKeystore(seed(42), seed(52))),
            Keystore(newInMemoryKeystore(seed(43), seed(53)))]
let L = "lez-frost/" & run
let params = SessionParams(hostpubkeys: kss.mapIt(it.frostHostPubkey(L)), t: 2)
let pm1 = kss.mapIt(it.frostDkgStep1(L, params))
let (cst, cmsg1) = coordinatorStep1(pm1, params)
let pm2 = kss.mapIt(it.frostDkgStep2(L, params, cmsg1))
let (cmsg2, cout, rec) = coordinatorFinalize(cst, pm2)
for k in kss: discard k.frostDkgFinalize(L, params, cmsg2)
let xq = pointFromCompressed(cout.threshPk).toXonly()
let frostId = publicAccountId(xq)
var session = 0
proc frostSign(h: array[32, byte], signers = @[0, 2]): LezWitness =
  ## Two rounds among the signers' keystores; the aggregate is one BIP-340 signature.
  inc session
  let sid = "tx-" & $session
  let msgs = @[@h]
  let pubnonces = signers.mapIt(kss[it].frostNonceCommit(L, sid, rec, msgs))
  let partials = signers.mapIt(kss[it].frostPartialSign(L, sid, rec, signers, pubnonces, msgs))
  let ctx = SessionContext(n: 3, t: 2, ids: signers, pubshares: some(signers.mapIt(cout.pubshares[it])),
                           threshPk: cout.threshPk, aggnonce: nonceAgg(pubnonces.mapIt(it[0])), msg: @h)
  LezWitness(signature: partialSigAgg(partials.mapIt(it[0]), ctx), xonly: xq)

let c = newLezMultisigLive(newLezRpc(url), kss[0], "lez:local", psLee02, newSeq[byte](32), plAccountIds,
                           blockMs = blockSec * 1000)
doAssert not c.readAccount(frostId).found, "a fresh account"
echo "1. a 2-of-3 ceremony's key owns LEZ account ", accountIdToBase58(frostId), " (no tweak) OK"

proc balanceOf(id: seq[byte]): uint64 =
  let r = c.readAccount(id)
  doAssert r.found and r.owner == tokenProgram and r.data.len == 49, "not a token holding"
  for i in countdown(40, 33): result = (result shl 8) or uint64(r.data[i])

# ── 2. the FROST account co-signs a mint ──────────────────────────────────────
let def = c.addMember("def/" & run)
let defLabel = "def/" & run
let minted = c.sendWith(tokenProgram, @[def, frostId], @[def, frostId],
  words(vectors["token"]["new_fungible_definition_muster_test_1000000"]),
  proc(h: array[32, byte]): seq[LezWitness] =
    @[LezWitness(signature: kss[0].lezMemberSign(defLabel, h), xonly: kss[0].lezMemberKey(defLabel)), frostSign(h)])
doAssert minted.ok, minted.error
doAssert balanceOf(frostId) == 1_000_000
echo "2. a mint co-signed by a keystore key and a FROST aggregate: included; the FROST account holds 1,000,000 OK"

# ── 3. the FROST account alone ────────────────────────────────────────────────
let to = c.addMember("to/" & run)
doAssert c.sendSigned(tokenProgram, @[def, to], @[to], words(vectors["token"]["initialize_account"])).ok
let before = c.rpc.getAccount(frostId).nonce
let moved = c.sendWith(tokenProgram, @[frostId, to], @[frostId], words(vectors["token"]["transfer_200"]),
                       proc(h: array[32, byte]): seq[LezWitness] = @[frostSign(h, @[1, 2])])
doAssert moved.ok, moved.error
doAssert balanceOf(frostId) == 999_800 and balanceOf(to) == 200
doAssert c.rpc.getAccount(frostId).nonce == before + 1.u128
echo "3. a transfer signed by the FROST account alone (another pair of signers): included, 200 moved OK"

# ── 4. a wrong aggregate is refused ───────────────────────────────────────────
let refused = c.sendWith(tokenProgram, @[frostId, to], @[frostId], words(vectors["token"]["transfer_200"]),
                         proc(h: array[32, byte]): seq[LezWitness] =
                           var other = h
                           other[0] = other[0] xor 1
                           @[frostSign(other)])
doAssert not refused.ok
doAssert balanceOf(frostId) == 999_800 and balanceOf(to) == 200
echo "4. an aggregate over the wrong message: refused by the chain, nothing moved OK"

echo "lez_frost_account_e2e: an aggregate FROST key owns a LEZ public account on a real v0.2.4 chain — all OK"
