## A LEZ public account owned by a FROST key, on a REAL LEZ v0.3.0 sequencer (exo-eb6.4 L3;
## infra/lez/localnet.sh, whose genesis funder stands in for anyone holding native LEZ:
## v0.3 has no faucet). What v0.2.4's lez_frost_account_e2e settled, held again where
## every transaction now declares and pays a fee:
##   1. a 2-of-3 ChillDKG gives a threshold key Q; its LEZ public account id is still
##      SHA-256("/LEE/v0.3/AccountId/Public/" ‖ x(Q)) with no tweak;
##   2. funded by transfer (the funder), the FROST account ALONE sends native LEZ: one
##      two-round aggregate signs the message, which names the account as its own fee
##      payer. The chain includes it, the recipient holds the amount, the account's nonce
##      advances, and it paid a fee no larger than it declared;
##   3. a keystore member pays the fee for the group: the member co-signs as the payer,
##      its nonce after the account's. The group's balance moves by the amount only;
##   4. an aggregate over the wrong message is refused by the chain and nothing moves.
## Usage: lez_frost_v030_e2e [sequencerUrl] [blockSeconds] (default http://127.0.0.1:3040 15)
## Needs the web3 closure (chronos, json-rpc, bearssl) + the secp closure + libsodium, and
## the local zone up (infra/lez/localnet.sh), or any v0.3 zone whose funder holds LEZ:
## accounts are funded by infra/lez/funder.sh on the zone the URL names (MUSTER_LEZ_E2E_FUND each).

import std/[os, osproc, strutils, sequtils, options, random, times]
import stint
import ../src/crypto/keystore
import ../src/frost/[secp, signing, chilldkg]
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex
import ../src/wallet/lez_multisig_live

import ./probes/lez_funding
let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

randomize()
let run = $getTime().toUnix() & "-" & $rand(1_000_000)
let rpc = newLezRpc(url)

proc fund(id: seq[byte], amount: string) =
  ## The zone's funder sends, as anyone holding native LEZ would (infra/lez/funder.sh).
  fundFrom(url, id, amount)

proc waitUntil(what: string, cond: proc(): bool) =
  for _ in 0 ..< blockSec * 4:
    if cond(): return
    sleep(1000)
  doAssert false, "not within four blocks: " & what

proc settleFor(blocks: int) = sleep(blocks * blockSec * 1000)

# ── 1. the ceremony, and the account ──────────────────────────────────────────
let kss = @[Keystore(newInMemoryKeystore(seed(61), seed(71))), Keystore(newInMemoryKeystore(seed(62), seed(72))),
            Keystore(newInMemoryKeystore(seed(63), seed(73)))]
let L = "lez-frost-v030/" & run
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

doAssert rpc.getAccount(frostId).fresh, "a fresh account"
echo "1. a 2-of-3 ceremony's key owns LEZ v0.3 account ", accountIdToBase58(frostId), " (no tweak) OK"

# ── 2. funded by transfer, the FROST account alone sends and pays its fee ──────
let Funded = e2eFund()       # above the 134_400_000 fee cap: on the testnet MUSTER_LEZ_E2E_FUND=200000000
fund(frostId, Funded)
waitUntil("the funding lands", proc(): bool = $rpc.getAccount(frostId).balance == Funded)
let to = publicAccountId(kss[1].lezMemberKey("to/" & run))
let n0 = rpc.getAccount(frostId).nonce
var m = LezMessage3(programAccount: NativeTokenProgram, shards: @[nativeShard(frostId), nativeShard(to)],
                    nonces: @[n0], instruction: nativeTransfer(parse("200", UInt128)),
                    fee: some defaultFee(frostId))
discard rpc.sendTransaction(leeTxPublic(m, @[frostSign(messageHash(m))]))
waitUntil("the transfer lands", proc(): bool = $rpc.getAccount(to).balance == "200")
let a2 = rpc.getAccount(frostId)
doAssert a2.nonce == n0 + 1.stuint(128), "the account's nonce advanced"
let fee2 = parse(Funded, UInt128) - 200.stuint(128) - a2.balance
doAssert fee2 > 0.stuint(128) and fee2 <= defaultFee(frostId).maxFee, "a fee was paid, within the cap: " & $fee2
echo "2. the FROST account alone sent 200 and paid its own fee (", fee2, " ≤ ", defaultFee(frostId).maxFee, ") OK"

# ── 3. a keystore member pays the group's fee ─────────────────────────────────
let payerLabel = "payer/" & run
let payer = publicAccountId(kss[0].lezMemberKey(payerLabel))
fund(payer, Funded)
waitUntil("the payer's funding lands", proc(): bool = $rpc.getAccount(payer).balance == Funded)
let n3 = rpc.getAccount(frostId).nonce
let p3 = rpc.getAccount(payer).nonce
m = LezMessage3(programAccount: NativeTokenProgram, shards: @[nativeShard(frostId), nativeShard(to)],
                nonces: @[n3, p3], instruction: nativeTransfer(parse("100", UInt128)),
                fee: some defaultFee(payer))
let h3 = messageHash(m)
discard rpc.sendTransaction(leeTxPublic(m, @[frostSign(h3, @[1, 2]),
  LezWitness(signature: kss[0].lezMemberSign(payerLabel, h3), xonly: kss[0].lezMemberKey(payerLabel))]))
waitUntil("the co-paid transfer lands", proc(): bool = $rpc.getAccount(to).balance == "300")
doAssert rpc.getAccount(frostId).balance == a2.balance - 100.stuint(128), "the group moved the amount only"
let fee3 = parse(Funded, UInt128) - rpc.getAccount(payer).balance
doAssert fee3 > 0.stuint(128) and fee3 <= defaultFee(payer).maxFee, "the member paid the fee: " & $fee3
echo "3. a keystore member co-signed as the fee payer (", fee3, "); the group moved 100 only OK"

# ── 4. a wrong aggregate is refused ───────────────────────────────────────────
let before = rpc.getAccount(frostId)
m = LezMessage3(programAccount: NativeTokenProgram, shards: @[nativeShard(frostId), nativeShard(to)],
                nonces: @[before.nonce], instruction: nativeTransfer(parse("50", UInt128)),
                fee: some defaultFee(frostId))
var other = messageHash(m)
other[0] = other[0] xor 1
try: discard rpc.sendTransaction(leeTxPublic(m, @[frostSign(other)]))
except CatchableError: discard                    # refused at the door, or dropped later
settleFor(2)
let after = rpc.getAccount(frostId)
doAssert after.nonce == before.nonce and after.balance == before.balance and $rpc.getAccount(to).balance == "300"
echo "4. an aggregate over the wrong message: refused by the chain, nothing moved OK"

echo "lez_frost_v030_e2e: a FROST key owns a LEZ public account and pays its fees on a real v0.3.0 chain — all OK"
