## A FROST group acting on LEZ from the room (lez.frost-public-account, exo-55e), on a REAL
## LEZ v0.2.4 sequencer (infra/lez/localnet.sh). The same ChillDKG ceremony and two rounds
## as btc.frost-bip445; what is signed is the LEZ public message hash.
##   1. a ceremony held in the room on "lez:local" discloses a LEZ public account whose
##      id is the threshold key's (SHA-256(prefix ‖ x(Q)), no tweak); the disclosure is
##      re-derived from the recovery data, and "lez-frost@<id>" is the aggregate driver;
##   2. setup: the account is minted tokens (co-signed by a keystore key and the group);
##   3. in the room: Alice proposes a token transfer from the account. The account's nonce
##      is read from the chain and recorded (invariant 10). The materialization is the
##      message hash with that nonce;
##   4. Alice and Carol publish their round-1 nonces and round-2 partials: executable;
##   5. the settlement seam re-reads the nonce, aggregates one BIP-340 signature, and sends
##      the transaction: final once included. The tokens moved;
##   6. a proposal whose nonce the chain has moved past is refused at settle: its signature
##      could never land, and the room is told to propose again.
## Usage: lez_frost_room_e2e [sequencerUrl] [blockSeconds] (default http://127.0.0.1:3040 15)
## Needs the web3 closure (chronos, json-rpc, bearssl) + the secp closure + libsodium.

import std/[os, json, strutils, sequtils, options, random, times]
import stint
import ../src/log/log
import ../src/crypto/keystore
import ../src/frost/[secp, signing, chilldkg]
import ../src/drivers/[driver, kinds, lez_frost]
import ../src/lez/multisig
import ../src/lez/tx as leztx
import ../src/bitcoin/tx                 # toHex / hexToBytes
import ../src/wallet/[types, lez_multisig_live]
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, accounts, aggregate, attest]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
let vectors = parseJson(readFile(currentSourcePath.parentDir / "vectors" / "lez-tx-v024" / "vectors.json"))
proc words(n: JsonNode): seq[uint32] = n.getElems().mapIt(uint32(it.getBiggestInt()))
let tokenProgram = hexToBytes("ccc4713e2b5ecdff37b0c67c295369effc04b7e8994eb11c3f410bb226b82e9b")
randomize()
let cid = "lez-vault-" & $getTime().toUnix() & "-" & $rand(1_000_000)

# ── 1. the ceremony in the room ───────────────────────────────────────────────
var r = newRoom3("/muster/1/lez-frost/" & cid)
let members = @[(r.alice, Keystore(aliceKs)), (r.bob, Keystore(bobKs)), (r.carol, Keystore(room3CarolKs))]
proc pollAll() =
  for (s, _) in members: s.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
discard frostCeremonyOpen(r.alice, cid, "lez:local", 2, 3)
pollAll()
for (s, ks) in members: discard frostCeremonyJoin(s, ks, cid)
var outcomes: seq[string]
for _ in 0 ..< 6:
  pollAll()
  outcomes = members.mapIt(frostCeremonyStep(it[0], it[1], cid))
pollAll()
doAssert outcomes.allIt(it.startsWith("done")), $outcomes
let disclosed = reduceAccounts(r.alice.log.allEvents()).filterIt(it.family == LezFrostFamily)
doAssert disclosed.len == 1
let a = disclosed[0]
let (ok, acct, detail) = lezFrostAccountOfDisclosure(a.chain, a.address, parseJson(a.config)["recovery"].getStr())
doAssert ok, detail
doAssert acct.accountId == publicAccountId(acct.group.xonly), "the account id is the threshold key's, untweaked"
let policy = qualify("lez-frost", a.id)
doAssert res(r.bob)(policy) of LezFrostDriver
echo "1. a 2-of-3 ceremony in the room on lez:local: LEZ account ", accountIdToBase58(acct.accountId), " disclosed OK"

# ── 2. setup: the account holds tokens ────────────────────────────────────────
let c = newLezMultisigLive(newLezRpc(url), aliceKs, "lez:local", psLee02, newSeq[byte](32), plAccountIds,
                           blockMs = blockSec * 1000)
var setupSession = 0
proc groupSign(h: array[32, byte]): LezWitness =
  ## Setup only: the group signs in-process (the room path is §3–5).
  inc setupSession
  let sid = "setup-" & $setupSession
  let who = @[Keystore(aliceKs), Keystore(room3CarolKs)]
  # participant ids are the ceremony order (the log canonical join order): look them up
  let signers = who.mapIt(acct.group.params.hostpubkeys.find(it.frostHostPubkey(ceremonyLabel(cid))))
  let rec = acct.group.recoveryData
  let pubnonces = who.mapIt(it.frostNonceCommit(ceremonyLabel(cid), sid, rec, @[@h]))
  let partials = who.mapIt(it.frostPartialSign(ceremonyLabel(cid), sid, rec, signers, pubnonces, @[@h]))
  let ctx = SessionContext(n: 3, t: 2, ids: signers, pubshares: some(signers.mapIt(acct.group.pubshares[it])),
                           threshPk: acct.group.threshPk, aggnonce: nonceAgg(pubnonces.mapIt(it[0])), msg: @h)
  LezWitness(signature: partialSigAgg(partials.mapIt(it[0]), ctx), xonly: acct.group.xonly)
let def = c.addMember("def/" & cid)
let defLabel = "def/" & cid
doAssert c.sendWith(tokenProgram, @[def, acct.accountId], @[def, acct.accountId],
  words(vectors["token"]["new_fungible_definition_muster_test_1000000"]),
  proc(h: array[32, byte]): seq[LezWitness] =
    @[LezWitness(signature: aliceKs.lezMemberSign(defLabel, h), xonly: aliceKs.lezMemberKey(defLabel)), groupSign(h)]).ok
let to = c.addMember("to/" & cid)
doAssert c.sendSigned(tokenProgram, @[def, to], @[to], words(vectors["token"]["initialize_account"])).ok
proc balanceOf(id: seq[byte]): uint64 =
  let rd = c.readAccount(id)
  doAssert rd.found and rd.owner == tokenProgram and rd.data.len == 49
  for i in countdown(40, 33): result = (result shl 8) or uint64(rd.data[i])
doAssert balanceOf(acct.accountId) == 1_000_000
echo "2. setup: the group's account holds 1,000,000 MusterTest OK"

# ── 3. the proposal ───────────────────────────────────────────────────────────
proc propose(n: uint64, seqNo: uint64): string =
  let nonce = c.rpc.getAccount(acct.accountId).nonce
  let effectJson = lezFrostCallEffect(tokenProgram, @[acct.accountId, to], words(vectors["token"]["transfer_200"]),
                                      acct.accountId, nonce)
  let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson, int64(Now), seqNo,
                             account = a.address, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  # the nonce came from the chain: the read is recorded (invariant 10)
  r.alice.publish(readEvent(id, "nonces", "lez:getAccount", $parseJson(effectJson)["nonces"]))
  pollAll()
  id
let id = propose(1, 1)
echo "3. proposed: a transfer from the account, at its nonce read from the chain OK"

# ── 4. the two rounds ─────────────────────────────────────────────────────────
proc rounds(intent: string) =
  for (s, ks, want) in [(r.alice, Keystore(aliceKs), "collecting"), (r.carol, Keystore(room3CarolKs), "collecting"),
                        (r.alice, Keystore(aliceKs), "collecting"), (r.carol, Keystore(room3CarolKs), "executable")]:
    let got = liveFrostContribute(s, ks, res(s), intent, Now)
    doAssert got == want, got
    pollAll()
rounds(id)
echo "4. round 1 and round 2 in the room: executable OK"

# ── 5. settle ─────────────────────────────────────────────────────────────────
proc contributionsOf(intent: string): seq[SettleContribution] =
  for e in r.alice.log.allEvents():
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == intent and p[2] == "sig":
      result.add (contributor: p[3], bytes: hexToBytes(e.value))
let drv = res(r.alice)(policy)
let stl = settlementFor(drv, c, Account(chain: "lez:local", form: afPublic, id: ""))
doAssert stl != nil
let asm0 = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.log.allEvents(), id)), contributionsOf(id))
doAssert asm0.ok, asm0.error & " " & asm0.detail
doAssert stl.watch(stl.submit(asm0.tx, aliceKs)).status == fsFinal
doAssert balanceOf(acct.accountId) == 999_800 and balanceOf(to) == 200
echo "5. settled: the nonce re-read, one aggregate signature, included — 200 moved OK"

# ── 6. a stale nonce is refused at settle ─────────────────────────────────────
let id2 = propose(2, 2)
rounds(id2)
# the account moves on before the room settles
doAssert c.sendWith(tokenProgram, @[acct.accountId, to], @[acct.accountId], words(vectors["token"]["transfer_200"]),
                    proc(h: array[32, byte]): seq[LezWitness] = @[groupSign(h)]).ok
let stale = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.log.allEvents(), id2)), contributionsOf(id2))
doAssert not stale.ok and "nonce" in stale.detail, stale.detail
echo "6. a proposal whose nonce the chain moved past: refused at settle, never sent OK"

echo "lez_frost_room_e2e: a FROST group acts on LEZ from the room — one signature on chain — all OK"
