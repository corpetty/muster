## A FROST group acting on LEZ from the room (lez.frost-public-account), on a REAL LEZ v0.3.0
## sequencer (exo-eb6.4 L3; infra/lez/localnet.sh, whose genesis funder stands in for anyone
## holding native LEZ: v0.3 has no faucet). The same ChillDKG ceremony and two rounds; what
## is signed is the v0.3 public message hash, and the group pays its own fee.
##   1. a ceremony held in the room on "lez:local" discloses a LEZ public account whose
##      id is the threshold key's (no tweak); "lez-frost@<id>" is the aggregate driver;
##   2. setup: the funder sends the account native LEZ;
##   3. in the room: Alice proposes a native transfer from the account (lez-call v2: the
##      native program, both rows' native shard, the fee the account pays). The account's
##      nonce is read from the chain and recorded (invariant 10);
##   4. Alice and Carol publish their round-1 nonces and round-2 partials: executable;
##   5. the settlement seam re-reads the nonce, aggregates one BIP-340 signature, builds the
##      v0.3 transaction and sends it: final once included. The amount moved, and the
##      account paid a fee within its cap;
##   6. a proposal whose nonce the chain has moved past is refused at settle;
##   7. a transfer of the account's whole balance — which leaves nothing for its fee — is
##      refused at settle: on v0.3 the chain would include it, charge its gas, move nothing
##      and report no outcome, so "included" read as final (exo-eb6.4.6).
## Usage: lez_frost_room_v030_e2e [sequencerUrl] [blockSeconds] (default http://127.0.0.1:3040 15)
## Needs the web3 closure (chronos, json-rpc, bearssl) + the secp closure + libsodium, and
## the local zone up (infra/lez/localnet.sh), or any v0.3 zone whose funder holds LEZ:
## accounts are funded by infra/lez/funder.sh on the zone the URL names (MUSTER_LEZ_E2E_FUND each).

import std/[os, osproc, json, strutils, sequtils, options, random, times]
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
import ./probes/lez_funding

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:3040")
let blockSec = (if paramCount() >= 2: parseInt(paramStr(2)) else: 15)
randomize()
let cid = "lez-vault-v030-" & $getTime().toUnix() & "-" & $rand(1_000_000)

proc fund(id: seq[byte], amount: string) =
  ## The zone's funder sends, as anyone holding native LEZ would (infra/lez/funder.sh).
  fundFrom(url, id, amount)

proc waitUntil(what: string, cond: proc(): bool) =
  for _ in 0 ..< blockSec * 4:
    if cond(): return
    sleep(1000)
  doAssert false, "not within four blocks: " & what

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

# ── 2. setup: the account holds native LEZ ───────────────────────────────────
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
let Funded = e2eFund()       # above the 134_400_000 fee cap: on the testnet MUSTER_LEZ_E2E_FUND=200000000
fund(acct.accountId, Funded)
waitUntil("the funding lands", proc(): bool = $c.rpc.getAccount(acct.accountId).balance == Funded)
let to = publicAccountId(aliceKs.lezMemberKey("to/" & cid))
doAssert c.rpc.getAccount(acct.accountId).v3, "the zone runs LEZ v0.3"
echo "2. setup: the group's account holds ", Funded, " native LEZ OK"

# ── 3. the proposal ───────────────────────────────────────────────────────────
proc propose(amount: string, seqNo: uint64): string =
  let nonce = c.rpc.getAccount(acct.accountId).nonce
  let effectJson = lezFrostCallEffect3(NativeTokenProgram, @[nativeShard(acct.accountId), nativeShard(to)],
                                       nativeTransfer(parse(amount, UInt128)), acct.accountId, @[nonce],
                                       some defaultFee(acct.accountId))
  let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson, int64(Now), seqNo,
                             account = a.address, ttlSec = Ttl)
  doAssert id.startsWith("0x"), id
  # the nonce came from the chain: the read is recorded (invariant 10)
  r.alice.publish(readEvent(id, "nonces", "lez:getAccount", $parseJson(effectJson)["nonces"]))
  pollAll()
  id
let id = propose("200", 1)
echo "3. proposed: a native transfer from the account, at its nonce read from the chain, its own fee OK"

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
doAssert $c.rpc.getAccount(to).balance == "200"
let fee = parse(Funded, UInt128) - 200.stuint(128) - c.rpc.getAccount(acct.accountId).balance
doAssert fee > 0.stuint(128) and fee <= defaultFee(acct.accountId).maxFee, "a fee within the cap: " & $fee
echo "5. settled: the nonce re-read, one aggregate signature, the v0.3 transaction included — 200 moved, fee ", fee, " OK"

# ── 6. a stale nonce is refused at settle ─────────────────────────────────────
let id2 = propose("100", 2)
rounds(id2)
# the account moves on before the room settles (the group signs in-process)
block:
  let n = c.rpc.getAccount(acct.accountId).nonce
  let m = LezMessage3(programAccount: NativeTokenProgram, shards: @[nativeShard(acct.accountId), nativeShard(to)],
                      nonces: @[n], instruction: nativeTransfer(parse("1", UInt128)), fee: some defaultFee(acct.accountId))
  let ws = @[groupSign(messageHash(m))]
  doAssert c.sendBuilt(leeTxPublic(m, ws), publicTxHash(m, ws)).ok
let stale = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.log.allEvents(), id2)), contributionsOf(id2))
doAssert not stale.ok and "nonce" in stale.detail, stale.detail
echo "6. a proposal whose nonce the chain moved past: refused at settle, never sent OK"

# ── 7. a transfer the account cannot cover is refused at settle ───────────────
let held = c.rpc.getAccount(acct.accountId).balance
let tooMuch = held                                  # all of it: nothing left for the fee
let id3 = propose($tooMuch, 3)
rounds(id3)
let uncovered = stl.assemble(drv, effectFromJson(effectJsonOf(r.alice.log.allEvents(), id3)), contributionsOf(id3))
doAssert not uncovered.ok and "cover" in uncovered.detail, "an uncovered transfer must not be sent: " &
  (if uncovered.ok: "assembled, and the chain would include it, revert it and charge its gas" else: uncovered.detail)
doAssert c.rpc.getAccount(acct.accountId).balance == held, "nothing was sent"
echo "7. a transfer of the account's whole balance (", held, "): refused at settle, never sent OK"

echo "lez_frost_room_v030_e2e: a FROST group acts on LEZ v0.3 from the room, paying its own fee — all OK"
