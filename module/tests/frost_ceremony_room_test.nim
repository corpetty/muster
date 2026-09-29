## FROST in the room (Phase D, exo-a50.4.5): the room is the coordinator ChillDKG asks for,
## and the signing rounds run over its log. Three members, a 2-of-3.
##   1. the ceremony: Alice opens it, each member joins with a host key its keystore
##      derives for this ceremony, and each advances by publishing its own step
##      messages. Every member computes the coordinator's steps from the log (the
##      coordinator only relays). All three reach the same account, and it is disclosed
##      into the room with its recovery data as config;
##   2. the disclosure is checked by re-deriving the address from the recovery data, and
##      the kind "btc-frost" acts from it: the room's driver for "btc-frost@<id>" is the
##      aggregate-locus driver over that ceremony's key;
##   3. a spend: Alice proposes; Alice and Carol each publish their round-1 nonces (from
##      their keystores, attested by their host keys). Round 1 closes at t=2;
##   4. round 2: each takes the signer set the log fixes (the first t round-1
##      contributions in the fold's order) and publishes a partial signature. The intent
##      is executable. Bob, outside the set, is told so and publishes nothing;
##   5. settlement aggregates one BIP-340 signature per input. Its witness is that
##      signature alone, and it verifies under the account key;
##   6. a restart between the rounds aborts: a member whose keystore lost its nonce
##      refuses round 2 and publishes nothing;
##   7. no secret enters the log: the ceremony's entries are its open, joins and step
##      messages; the shares and nonces never appear.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, tables]
import ../src/log/log
import ../src/drivers/[driver, kinds, btc_frost, btc_multisig]
import ../src/bitcoin/[tx, keys]
import ../src/wallet/[types, btc_adapter]
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, accounts, aggregate, attest]
import ./probes/live_room

var r = newRoom3("/muster/1/frost-room/proto")
let members = @[(r.alice, Keystore(aliceKs)), (r.bob, Keystore(bobKs)), (r.carol, Keystore(room3CarolKs))]
proc pollAll() =
  for (s, _) in members: s.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))

# ── 1. the ceremony ───────────────────────────────────────────────────────────
const Cid = "treasury-1"
discard frostCeremonyOpen(r.alice, Cid, "regtest", 2, 3)
pollAll()
for (s, ks) in members: discard frostCeremonyJoin(s, ks, Cid)
var outcomes: seq[string]
for step in 0 ..< 6:
  pollAll()
  outcomes = members.mapIt(frostCeremonyStep(it[0], it[1], Cid))
pollAll()
doAssert outcomes.allIt(it.startsWith("done")), $outcomes
let addrs = outcomes.mapIt(it.split(' ')[^1])
doAssert addrs.allIt(it == addrs[0] and it.startsWith("bcrt1p")), $addrs
let accts = reduceAccounts(r.bob.log.allEvents()).filterIt(it.family == FrostFamily)
doAssert accts.len == 1 and accts[0].address == addrs[0]
echo "1. a 2-of-3 ChillDKG over the room's log: one account for all three, disclosed ", addrs[0], " OK"

# ── 2. the disclosure checks, and the kind acts from it ───────────────────────
let a = accts[0]
let (checked, acct, detail) = frostAccountOfDisclosure(a.chain, a.address, parseJson(a.config)["recovery"].getStr())
doAssert checked, detail
let policy = qualify("btc-frost", a.id)
let drvA = res(r.alice)(policy)
doAssert drvA of BtcFrostDriver and BtcFrostDriver(drvA).account.address == a.address
echo "2. the disclosure re-derives from its recovery data; btc-frost@<id> is the aggregate driver OK"

# ── 3. round 1 ────────────────────────────────────────────────────────────────
let utxos = @[BtcUtxo(txid: "33".repeat(32), vout: 0, value: 80_000, scriptPubKey: toHex(acct.scriptPubKey))]
let effectJson = buildFrostSpend(acct, utxos, "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", 50_000, feeRate = 2)
let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson, int64(Now), 1,
                           account = a.address, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
# the coins came from the proposer's node: the read is recorded (invariant 10), as the composer does
r.alice.publish(readEvent(id, "inputs", "bitcoind:scantxoutset", $parseJson(effectJson)["inputs"]))
pollAll()
block:
  let got = liveFrostContribute(r.alice, aliceKs, res(r.alice), id, Now)
  doAssert got == "collecting", got
pollAll()
block:
  let got = liveFrostContribute(r.carol, room3CarolKs, res(r.carol), id, Now)
  doAssert got == "collecting", got
pollAll()
let it1 = reduceIntents(r.bob.log.allEvents(), res(r.bob))[id]
doAssert it1.collection.round == 2, "round 1 closed at t = 2"
echo "3. round 1: Alice and Carol publish nonces from their keystores; round 1 closes OK"

# ── 4. round 2 ────────────────────────────────────────────────────────────────
doAssert liveFrostContribute(r.bob, bobKs, res(r.bob), id, Now).startsWith("not-in-signing-set")
block:
  let got = liveFrostContribute(r.alice, aliceKs, res(r.alice), id, Now)
  doAssert got == "collecting", got
pollAll()
block:
  let got = liveFrostContribute(r.carol, room3CarolKs, res(r.carol), id, Now)
  doAssert got == "executable", got
pollAll()
doAssert intentState(r.bob.log.allEvents(), res(r.bob), id) == "executable"
echo "4. round 2: the log fixes the signer set; partials make it executable; Bob outside the set publishes nothing OK"

# ── 5. settlement ─────────────────────────────────────────────────────────────
var contribs: seq[SettleContribution]
for e in r.bob.log.allEvents():
  let p = e.key.split('/')
  if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
    contribs.add (contributor: p[3], bytes: hexToBytes(e.value))
let drv = BtcFrostDriver(res(r.bob)(policy))
let stl = settlementFor(drv, newBitcoindAdapter("regtest", "http://127.0.0.1:1", "", ""),
                        Account(chain: acct.chain, form: afPublic, id: ""))
let asm0 = stl.assemble(drv, effectFromJson(effectJson), contribs)
doAssert asm0.ok and asm0.have == 2, asm0.error & " " & asm0.detail
let spent = drv.finalizeFrostSpend(effectFromJson(effectJson), contribs.mapIt(Contribution(bytes: it.bytes)))
doAssert spent.inputs[0].witness.len == 1 and spent.inputs[0].witness[0].len == 64
doAssert schnorrVerify(spent.inputs[0].witness[0], drv.sighashesOf(effectFromJson(effectJson))[0], acct.xonly)
echo "5. settlement: one BIP-340 signature, alone in the witness, under the account key OK"

# ── 6. a restart between the rounds aborts ────────────────────────────────────
let effectJson2 = buildFrostSpend(acct, utxos, "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", 40_000, feeRate = 2)
let id2 = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson2,
                            int64(Now), 2, account = a.address, ttlSec = Ttl)
doAssert id2.startsWith("0x"), id2
r.alice.publish(readEvent(id2, "inputs", "bitcoind:scantxoutset", $parseJson(effectJson2)["inputs"]))
pollAll()
block:
  let got = liveFrostContribute(r.alice, aliceKs, res(r.alice), id2, Now)
  doAssert got == "collecting", got
pollAll()
block:
  let got = liveFrostContribute(r.carol, room3CarolKs, res(r.carol), id2, Now)
  doAssert got == "collecting", got
pollAll()
let carolRestarted = restartedCarolKs()
let before = r.carol.log.allEvents().len
let refused = liveFrostContribute(r.carol, carolRestarted, res(r.carol), id2, Now)
doAssert refused.startsWith("refused") and "abort" in refused, refused
doAssert r.carol.log.allEvents().len == before, "nothing published"
echo "6. a restart between the rounds aborts the session: no nonce, no partial, nothing published OK"

# ── 7. no secret enters the log ───────────────────────────────────────────────
var entryKinds = initCountTable[string]()
for e in r.bob.log.allEvents():
  let p = e.key.split('/')
  if p.len >= 3 and p[0] == "frost": entryKinds.inc p[2]
doAssert entryKinds["open"] == 1 and entryKinds["join"] == 3 and entryKinds["pmsg1"] == 3 and entryKinds["pmsg2"] == 3
doAssert toSeq(entryKinds.keys).allIt(it in ["open", "join", "pmsg1", "pmsg2"]), $entryKinds
echo "7. the ceremony's log: one open, three joins, three step-1 and three step-2 messages — no shares, no nonces OK"

# ── 8. junk under a member's name takes nothing from them (exo-c00) ──────────────
# Anyone holding the epoch key can publish an event under any name. Bob publishes junk as
# Alice's round-1 contribution before she makes hers: her pump must still contribute (it
# is not hers), the fold must count her real nonces even behind junk that sorts first, and
# the signer set round 2 signs under must include her. (Her approval links approvals only,
# exo-96d, so a second junk, published after it and ground to sort first, is what puts
# junk ahead of her real nonces.)
let effectJson3 = buildFrostSpend(acct, utxos, "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", 30_000, feeRate = 2)
let id3 = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson3,
                            int64(Now), 3, account = a.address, ttlSec = Ttl)
doAssert id3.startsWith("0x"), id3
r.alice.publish(readEvent(id3, "inputs", "bitcoind:scantxoutset", $parseJson(effectJson3)["inputs"]))
pollAll()
let aliceHost = toHex(aliceKs.frostHostPubkey(ceremonyLabel(Cid)))
var proposeIds: seq[EventId]
for e in r.bob.log.allEvents():
  if e.key == "intent/" & id3 & "/propose": proposeIds.add eventId(e)
r.bob.publish(contributeEvent(id3, aliceHost, "00".repeat(64), round = 1, parents = proposeIds))
pollAll()
block:
  let got = liveFrostContribute(r.alice, aliceKs, res(r.alice), id3, Now)
  doAssert got == "collecting", "junk under Alice's name blocked her round 1: " & got
pollAll()
block:
  var realA: Event
  for e in r.bob.log.allEvents():
    if e.key == "intent/" & id3 & "/sig/" & aliceHost & "/1" and e.value != "00".repeat(64): realA = e
  doAssert realA.key.len > 0, "Alice's real round-1 contribution"
  var junk2: Event
  for i in 1 .. 255:
    junk2 = contributeEvent(id3, aliceHost, toHex(i, 2).toLowerAscii.repeat(64), round = 1, parents = realA.parents)
    if eventId(junk2) < eventId(realA): break
  doAssert eventId(junk2) < eventId(realA), "no junk sorts first"
  r.bob.publish(junk2)
  pollAll()
  let order = canonicalOrder(r.bob.log.allEvents()).mapIt(eventId(it))
  doAssert order.find(eventId(junk2)) < order.find(eventId(realA)), "the junk sorts ahead of Alice's nonces"
block:
  let got = liveFrostContribute(r.carol, room3CarolKs, res(r.carol), id3, Now)
  doAssert got == "collecting", got
pollAll()
doAssert reduceIntents(r.bob.log.allEvents(), res(r.bob))[id3].collection.round == 2,
  "round 1 closed with Alice's real nonces and Carol's"
let set3 = signingSet(r.bob.log.allEvents(), res(r.bob), id3, res(r.bob)(policy))
doAssert set3.len == 2 and set3.anyIt(toHex(it[0]) == aliceHost),
  "the signer set leaves Alice out: " & $set3.mapIt(toHex(it[0]))
block:
  let got = liveFrostContribute(r.alice, aliceKs, res(r.alice), id3, Now)
  doAssert got == "collecting", got
pollAll()
block:
  let got = liveFrostContribute(r.carol, room3CarolKs, res(r.carol), id3, Now)
  doAssert got == "executable", got
echo "8. junk under Alice's round-1 name: her pump contributes, the fold counts her, round 2 signs with her OK"

echo "frost_ceremony_room_test: the room runs the ceremony and both rounds; the chain would see one signature — all OK"
