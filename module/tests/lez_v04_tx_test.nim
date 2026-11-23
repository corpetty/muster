## LEZ v0.4.0-rc3 public transactions in Nim (roadmap M3, exo-0d3.9), held byte for byte to
## tests/vectors/lez-msig/v04.json, which LEZ's own crates generated
## (programs/lez-msig/lez04/host/src/bin/msig_vectors04.rs):
##   1. a lez-msig Create on a fresh public PDA: the actors, the admission evidence, the fee and
##      the payer's nonce; the message, its signing hash, the signed transaction, its hash and
##      LeeTransaction::Public;
##   2. a 2-of-2 payment: the multisig's actor and both native balances, sorted as a set; the
##      approvals re-signed here with the generator's aux, so the envelope matches too;
##   3. the signature in the vectors verifies against the hash computed here.
## Needs the secp closure.

import std/[json, options, strutils, os, sequtils]
import stint
import ../src/lez/msig
import ../src/lez/tx as leztx
import ../src/wallet/lez_msig_chain
import ../src/bitcoin/keys as btckeys

proc hb(s: string): seq[byte] =
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))
proc fill(x: byte): seq[byte] = (result = newSeq[byte](32); for i in 0 ..< 32: result[i] = x)

let v = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-msig" / "v04.json"))
let program = hb(v["program"].getStr())
let ck = hb(v["createKey"].getStr())
let a = multisigPublic(program, ck)
doAssert hexOf(a) == v["multisig"].getStr(), "the public PDA is unchanged on v0.4"

let secrets = @[fill(1), fill(2)]
let keys = secrets.mapIt(btckeys.xonlyPubKey(it))
let zone = fill(0x2e)

proc check(name: string, vec: JsonNode, ins: MsigInstruction) =
  let payer = hb(vec["payer"].getStr())
  let m = LezMessage4(
    root: LezActor(account: a, program: program),
    message: envelopePublic(ck, ins),
    actors: msigActors(program, a, ins),
    nonces: @[(account: payer, nonce: parse(vec["nonce"].getStr(), UInt128))],
    fee: some(LezFee(payer: payer, gasLimit: 2_000_000, tip: 7, maxFee: 134_400_000.u128)),
    evidence: msigAdmission(program, ck, ins))
  doAssert hexOf(messageBorsh(m)) == vec["message"].getStr(), name & ": the message's borsh"
  let h = messageHash(m)
  doAssert hexOf(h) == vec["hash"].getStr(), name & ": the signing hash"
  let sig = hb(vec["signature"].getStr())
  doAssert btckeys.schnorrVerify(sig, h, hb(vec["payerKey"].getStr())), name & ": LEZ's signature verifies over our hash"
  let ws = @[LezWitness(signature: sig, xonly: hb(vec["payerKey"].getStr()))]
  doAssert hexOf(publicTxBorsh(m, ws)) == vec["tx"].getStr(), name & ": the transaction"
  doAssert publicTxHash(m, ws) == vec["txHash"].getStr(), name & ": its hash"
  doAssert hexOf(leeTxPublic(m, ws)) == vec["leeTx"].getStr(), name & ": LeeTransaction::Public"

block:
  let config = MsigConfig(members: keys.mapIt(MsigMember(key: it, roles: RoleAll, weight: 1)), threshold: 2,
                          openExecution: true, actions: ActAll)
  check("create", v["create"], MsigInstruction(kind: ikCreate, zone: zone, config: config))
  echo "1. a Create on a fresh PDA, admitted by evidence, with a fee: every byte matches LEZ's OK"

block:
  let p = MsigProposal(multisig: a, zone: zone, epoch: 0, nonce: 0,
                       action: MsigAction(kind: akTransfer, to: fill(0x0e), amount: 1200.u128),
                       expiresMs: 1_800_000_000_000'u64, proposer: keys[0])
  let am = approveMsg(proposalId(p))
  var approvals: seq[MsigSigned]
  for s in secrets: approvals.add MsigSigned(key: btckeys.xonlyPubKey(s), sig: btckeys.schnorrSign(s, am, fill(0x11)))
  check("pay", v["pay"], MsigInstruction(kind: ikExecute, proposal: p, approvals: approvals))
  echo "2. a 2-of-2 payment: the actors sorted as a set, the approvals re-signed here, every byte matches OK"
echo "3. LEZ's signatures verify over the hashes computed here OK"

# ── 4. a v0.4 account, as a v0.4.0-rc3 sequencer's getAccount answered (2026-11-20) ───
import ../src/lez/account_view
block:
  let funded = parseJson("""{"nonce":0,"data":{"actor_states":{"11111111111111111111111111111111":[0,160,114,78,24,9,0,0,0,0,0,0,0,0,0,0]}}}""")
  let st = accountStateOf(funded)
  doAssert st.v4 and not st.v3 and st.balance == 10_000_000_000_000.u128 and st.shards.len == 1
  try:
    discard accountStateOf(newJNull())
    doAssert false, "a null answer is never read as an account here (exo-496)"
  except ValueError: discard
  echo "4. a v0.4 account: its native balance from the actor states; a bare null still raises OK"
