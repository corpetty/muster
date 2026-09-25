## Phase D exit (exo-a50.4.7; docs/design/multisig-landscape.md §8): against a REAL Bitcoin
## Core on regtest (infra/bitcoind/regtest.sh), a 2-of-3 FROST account made IN THE ROOM,
## then a spend the chain cannot tell from single-sig.
##   1. three members hold a ChillDKG ceremony over the room's log; all three reach one
##      taproot address, disclosed into the room with the ceremony's recovery data;
##   2. Bitcoin Core agrees it is a plain taproot output: it validates the address, and
##      rawtr(<x(Q)>) derives the same one. The key is the output key as it stands (ChillDKG
##      already committed it to an unspendable script path, so tr() would tweak it again);
##      no script and no policy is in it;
##   3. the account is funded; its UTXO is read back through the user's node, and a spend is
##      built from it;
##   4. in the room: Alice proposes (the coins' read recorded, invariant 10). Alice and
##      Carol publish their round-1 nonces, then their round-2 partials under the signer
##      set the log fixes. The intent is executable;
##   5. the settlement seam aggregates, broadcasts through the node, and it is final a block
##      later; the payee has the coins;
##   6. the chain cannot tell it from single-sig: the confirmed input's witness is ONE
##      64-byte signature (a key-path spend), exactly the shape of a single-sig taproot
##      spend Bitcoin Core's own wallet makes. Nothing on chain names the policy, the
##      threshold or who signed.
## Usage: phase_d_exit_test [rpcUrl] [rpcUser] [rpcPassword]
## Needs a FRESH regtest bitcoind (infra/bitcoind/regtest.sh), the secp closure + libsodium.

import std/[os, json, strutils, sequtils]
import ../src/drivers/[driver, kinds, btc_frost, btc_multisig]
import ../src/bitcoin/[tx, keys]
import ../src/wallet/[types, btc_adapter]
import ../src/settlement/settlement
import ../src/coordination/[session, intent_events, intents, live, accounts, aggregate, attest]
import ./probes/live_room

let url = (if paramCount() >= 1: paramStr(1) else: "http://127.0.0.1:18443")
let user = (if paramCount() >= 2: paramStr(2) else: "muster")
let pass = (if paramCount() >= 3: paramStr(3) else: "muster")
let node = newBitcoindAdapter("regtest", url, user, pass)
proc rpc(meth: string, params: JsonNode = newJArray(), wallet = ""): JsonNode = node.call(meth, params, wallet)

try: discard rpc("createwallet", %*["miner", false, false, "", false, true])
except CatchableError as e:
  quit "phase_d_exit_test needs a FRESH regtest chain (infra/bitcoind/regtest.sh): " & e.msg
let minerAddr = rpc("getnewaddress", %*["", "bech32"], "miner").getStr()
discard rpc("generatetoaddress", %*[101, minerAddr])

# ── 1. the ceremony in the room ───────────────────────────────────────────────
var r = newRoom3("/muster/1/phase-d/proto")
let members = @[(r.alice, Keystore(aliceKs)), (r.bob, Keystore(bobKs)), (r.carol, Keystore(room3CarolKs))]
proc pollAll() =
  for (s, _) in members: s.poll()
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
discard frostCeremonyOpen(r.alice, "vault", "regtest", 2, 3)
pollAll()
for (s, ks) in members: discard frostCeremonyJoin(s, ks, "vault")
var outcomes: seq[string]
for _ in 0 ..< 6:
  pollAll()
  outcomes = members.mapIt(frostCeremonyStep(it[0], it[1], "vault"))
pollAll()
doAssert outcomes.allIt(it.startsWith("done")), $outcomes
let a = reduceAccounts(r.alice.log.allEvents()).filterIt(it.family == FrostFamily)[0]
let (ok, acct, detail) = frostAccountOfDisclosure(a.chain, a.address, parseJson(a.config)["recovery"].getStr())
doAssert ok, detail
echo "1. a 2-of-3 ChillDKG held in the room: one address for all three, disclosed ", acct.address, " OK"

# ── 2. Bitcoin Core sees a plain taproot output ───────────────────────────────
let v = rpc("validateaddress", %*[acct.address])
doAssert v["isvalid"].getBool() and v["iswitness"].getBool() and v["witness_version"].getInt() == 1
let desc = "rawtr(" & toHex(acct.xonly) & ")"
let info = rpc("getdescriptorinfo", %*[desc])
let coreAddr = rpc("deriveaddresses", %*[desc & "#" & info["checksum"].getStr()])[0].getStr()
doAssert coreAddr == acct.address, "Core's rawtr(x(Q)) is " & coreAddr
echo "2. Bitcoin Core: a valid v1 witness address, and rawtr(x(Q)) — the output key itself — derives it OK"

# ── 3. fund, read back, build ─────────────────────────────────────────────────
discard rpc("sendtoaddress", %*[acct.address, 1.0], "miner")
discard rpc("generatetoaddress", %*[1, minerAddr])
let utxos = node.utxosOf(acct.address)
doAssert utxos.len == 1 and utxos[0].value == 100_000_000'u64
let payee = rpc("getnewaddress", %*["", "bech32"], "miner").getStr()
let effectJson = buildFrostSpend(acct, utxos, payee, 40_000_000'u64, feeRate = 2)
echo "3. funded 1 BTC; the UTXO read back through the node; a spend built from it OK"

# ── 4. the two rounds in the room ─────────────────────────────────────────────
let policy = qualify("btc-frost", a.id)
let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effectJson, int64(Now), 1,
                           account = acct.address, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
r.alice.publish(readEvent(id, "inputs", "bitcoind://scantxoutset", $parseJson(effectJson)["inputs"]))
pollAll()
for (s, ks, want) in [(r.alice, Keystore(aliceKs), "collecting"), (r.carol, Keystore(room3CarolKs), "collecting"),
                      (r.alice, Keystore(aliceKs), "collecting"), (r.carol, Keystore(room3CarolKs), "executable")]:
  let got = liveFrostContribute(s, ks, res(s), id, Now)
  doAssert got == want, got
  pollAll()
doAssert intentState(r.bob.log.allEvents(), res(r.bob), id) == "executable"
echo "4. round 1 (nonces) and round 2 (partials under the log's signer set) in the room: executable OK"

# ── 5. settle; final a block later ────────────────────────────────────────────
let drv = BtcFrostDriver(res(r.alice)(policy))
let stl = settlementFor(drv, node, Account(chain: acct.chain, form: afPublic, id: ""))
var contribs: seq[SettleContribution]
for e in r.alice.log.allEvents():
  let p = e.key.split('/')
  if p.len >= 4 and p[0] == "intent" and p[1] == id and p[2] == "sig":
    contribs.add (contributor: p[3], bytes: hexToBytes(e.value))
let asm0 = stl.assemble(drv, effectFromJson(effectJson), contribs)
doAssert asm0.ok, asm0.error & " " & asm0.detail
let txRef = stl.submit(asm0.tx, aliceKs)
doAssert stl.watch(txRef).status == fsPending
discard rpc("generatetoaddress", %*[1, minerAddr])
doAssert stl.watch(txRef).status == fsFinal
let paid = rpc("gettxout", %*[txRef.id, 0])
doAssert paid.kind == JObject and paid["value"].getFloat() == 0.4, $paid
echo "5. aggregated, broadcast through the node, final a block later; the payee has 0.4 BTC OK"

# ── 6. indistinguishable from single-sig ──────────────────────────────────────
let spent = rpc("getrawtransaction", %*[txRef.id, true])
let w = spent["vin"][0]["txinwitness"]
doAssert w.len == 1 and w[0].getStr().len == 128, "one 64-byte signature: " & $w
# the same shape as a single-sig taproot spend Core's own wallet makes
try: discard rpc("createwallet", %*["single", false, false, "", false, true])
except CatchableError: discard
let single = rpc("getnewaddress", %*["", "bech32m"], "single").getStr()
discard rpc("sendtoaddress", %*[single, 0.5], "miner")
discard rpc("generatetoaddress", %*[1, minerAddr])
let back = rpc("sendtoaddress", %*[minerAddr, 0.2], "single").getStr()
let sw = rpc("getrawtransaction", %*[back, true])["vin"][0]["txinwitness"]
doAssert sw.len == w.len and sw[0].getStr().len == w[0].getStr().len, "Core single-sig: " & $sw
doAssert spent["vin"][0]["scriptSig"]["hex"].getStr() == "", "no script, no policy on chain"
echo "6. on chain: one 64-byte signature, the same witness a single-sig taproot spend has — no policy, no signers OK"

echo "phase_d_exit_test: a 2-of-3 made in the room spends as one signature — the chain cannot tell it from single-sig — all OK"
