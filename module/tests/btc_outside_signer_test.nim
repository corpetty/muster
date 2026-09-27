## Signers outside muster (exo-a50.2.6, Phase B; seam S8, interop codecs) — decision
## 2026-09-23: outside signers where it makes sense, always surfaced:
##   1. export: a Bitcoin intent exports as a PSBT — the driver's own export of the
##      proposal's spend — for a signer outside muster (Keycard Shell, Sparrow, Bitcoin
##      Core); a driver with no outside format (a room decision) says so, never a guess;
##   2. import: a PSBT an outside signer returned is read by the DRIVER — each account key
##      that signed every input becomes a contribution verified like a native one — and
##      is published as a pasted approval: it counts toward k and is graded unattested
##      ("signed outside muster"), never committed; with a member's in-app approval, 2 of
##      3 is executable;
##   3. refusals: a PSBT of another spend is refused and nothing is published; a PSBT
##      carrying no account signature imports nothing (named); the same PSBT twice
##      counts once;
##   4. readiness for a Bitcoin intent: the bitcoind RPC is infrastructure the proposal
##      introduces (missing until configured); the chain is graded by asking THAT node
##      which chain it serves (met / missing / unknown without one); the authority is
##      whether MY key is one of the account's — never who else holds one.
## Needs the secp closure + libsodium — see tests/README.md.

import std/[json, strutils, sequtils]
import ../src/hashing/sha256
import ../src/log/log
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/kinds
import ../src/drivers/manifest
import ../src/drivers/interop
import ../src/drivers/btc_multisig
import ../src/bitcoin/[tx, keys, psbt, taproot, sighash]
import ../src/crypto/keystore
import ../src/coordination/intent_events
import ../src/coordination/intents
import ../src/coordination/live
import ../src/coordination/attest
import ../src/coordination/accounts
import ../src/coordination/readiness
import ./probes/live_room

let aliceSecret = hexToBytes("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
let carolSecret = @(sha256(cast[seq[byte]]("muster-btc-outside-carol")))
let A = compressedPubKey(aliceSecret)
let B = bobKs.btcPubKey()
let C = compressedPubKey(carolSecret)

proc spendJson(acct: BtcAccount, value = 150_000): string =
  $(%*{"effect": "btc-spend",
       "inputs": [{"txid": repeat("6d", 32), "vout": 1, "value": 200_000,
                   "scriptPubKey": toHex(acct.scriptPubKey), "sequence": 0xfffffffd}],
       "outputs": [{"address": acct.address, "value": value}],
       "locktime": 0, "fee": 200_000 - value})

proc carolSigns(drv: BtcMultisigDriver, e: Effect, p: var Psbt) =
  ## what an outside signer does with the exported PSBT: sign every input, in the format
  let hashes = drv.sighashesOf(e)
  for i in 0 ..< hashes.len:
    var h: array[32, byte]
    for x in 0 ..< 32: h[x] = hashes[i][x]
    if drv.account.family == P2wshFamily:
      p.addPartialSig(i, C, ecdsaSignDer(carolSecret, h) & @[SighashAll])
    else:
      p.addTapScriptSig(i, xonlyOfCompressed(C), @(tapLeafHash(drv.account.leafScript)), schnorrSign(carolSecret, h))

var seqNo = 0'u64
for (family, kind) in [(P2wshFamily, "btc-p2wsh"), (TapscriptFamily, "btc-tapscript")]:
  let acct = btcAccount(family, "regtest", 2, @[A, B, C])
  var r = newRoom("/muster/1/btc-outside-" & kind & "/proto")
  r.discloseAs("alice", RoomAccount(family: family, chain: acct.chain, address: acct.address,
    label: "Vault", signers: @[A, B, C].mapIt(toHex(it)), threshold: 2))
  let s = r.alice
  let resolver: DriverFor = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(s.log.allEvents()), proc(k: string): Driver = liveDriverFor(k))
  inc seqNo
  let id = liveProposeIntent(r.alice, aliceKs, resolver, qualify(kind, acct.accountId), spendJson(acct),
                             int64(Now), seqNo, account = acct.address, ttlSec = Ttl)
  doAssert id.len > 0 and not id.startsWith("refused") and id != "unsupported-driver", id
  let drv = BtcMultisigDriver(resolver(qualify(kind, acct.accountId)))
  let e = effectFromJson(spendJson(acct))

  # ── 1. export ──────────────────────────────────────────────────────────────────
  let ex = liveExportOutside(r.alice, resolver, id)
  doAssert ex.ok and ex.format == "psbt", ex.error
  doAssert canonicalBytes(parsePsbtBase64(ex.encoded)) == canonicalBytes(drv.exportPsbt(e)),
    "the export is the driver's PSBT of THIS proposal's spend"
  inc seqNo
  let roomId = liveProposeIntent(r.alice, aliceKs, resolver, "threshold", effectFor("threshold", 1),
                                 int64(Now), seqNo, account = r.topic, ttlSec = Ttl)
  let none = liveExportOutside(r.alice, resolver, roomId)
  doAssert not none.ok and none.error == "no-outside-format", none.error
  doAssert liveExportOutside(r.alice, resolver, "nope").error == "unknown-intent"
  echo "1. ", family, ": exports the proposal's spend as a PSBT; a room decision has no outside format OK"

  # ── 2. import ──────────────────────────────────────────────────────────────────
  doAssert liveContribute(r.alice, aliceKs, resolver, id, "", "", bindCtx(), Now) == "collecting"
  var p = parsePsbtBase64(ex.encoded)
  carolSigns(drv, e, p)
  let im = liveImportOutside(r.alice, aliceKs, resolver, id, p.toBase64(), bindCtx(), Now)
  doAssert im.ok and im.imported == @[toHex(C)] and im.state == "executable", $im
  let grades = approvalGrades(r.alice.log.allEvents(), resolver, id)
  doAssert gradeOf(grades, toHex(C), 1) == agUnattested, "signed outside muster: graded as such"
  doAssert gradeOf(grades, toHex(A), 1) == agCommitted
  let views = reduceIntentViews(r.alice.log.allEvents(), resolver).filterIt(it.id == id)
  doAssert views.len == 1 and views[0].approvals == 2 and views[0].unattested == 1 and views[0].committed == 1
  echo "2. ", family, ": an outside signer's PSBT imports as a counted, unattested approval; executable OK"

  # ── 3. refusals ────────────────────────────────────────────────────────────────
  let before = r.alice.log.allEvents().len
  var other = drv.exportPsbt(effectFromJson(spendJson(acct, 140_000)))
  carolSigns(drv, effectFromJson(spendJson(acct, 140_000)), other)
  let wrong = liveImportOutside(r.alice, aliceKs, resolver, id, other.toBase64(), bindCtx(), Now)
  doAssert not wrong.ok and wrong.error == "not-this-spend", $wrong
  doAssert r.alice.log.allEvents().len == before, "nothing published"
  let empty = liveImportOutside(r.alice, aliceKs, resolver, id, ex.encoded, bindCtx(), Now)
  doAssert not empty.ok and empty.error == "no-signatures", $empty
  doAssert not liveImportOutside(r.alice, aliceKs, resolver, id, "not base64 at all", bindCtx(), Now).ok
  discard liveImportOutside(r.alice, aliceKs, resolver, id, p.toBase64(), bindCtx(), Now)
  let again = reduceIntentViews(r.alice.log.allEvents(), resolver).filterIt(it.id == id)
  doAssert again[0].approvals == 2, "the same PSBT twice counts once"
  echo "3. ", family, ": another spend's PSBT refused, an unsigned one imports nothing, a repeat counts once OK"

  # ── 4. readiness ───────────────────────────────────────────────────────────────
  proc statusOf(rd: Readiness, name: string): ReadyStatus =
    for it in rd.items:
      if it.requirement.name == name: return it.status
    raise newException(ValueError, "no requirement " & name)
  let m = drv.manifest(e)
  var facts = HostFacts(myBtcKey: toHex(A), btcSigners: @[A, B, C].mapIt(toHex(it)))
  var rd = assessReadiness(m, probeFromFacts(facts))
  doAssert rd.statusOf("bitcoind-rpc") == rdMissing, "no Bitcoin RPC configured: missing, with a remedy"
  doAssert rd.statusOf(acct.chain) == rdUnknown, "no node to ask which chain: unknown, never met"
  doAssert rd.statusOf("btc-multisig-key") == rdMet, "my key is one of the account's"
  facts.btcRpcUrl = "http://127.0.0.1:18443"
  facts.btcProbe = proc(url: string): tuple[ok: bool, chain: string, detail: string] {.gcsafe.} =
    (true, "bip122:0f9188f13cb7b2c71f2a335e3a4fc328", "regtest")
  rd = assessReadiness(m, probeFromFacts(facts))
  doAssert rd.statusOf("bitcoind-rpc") == rdMet and rd.statusOf(acct.chain) == rdMet
  facts.btcProbe = proc(url: string): tuple[ok: bool, chain: string, detail: string] {.gcsafe.} =
    (true, "bip122:000000000019d6689c085ae165831e93", "main")
  doAssert assessReadiness(m, probeFromFacts(facts)).statusOf(acct.chain) == rdMissing, "the node serves another chain"
  facts.myBtcKey = toHex(compressedPubKey(@(sha256(cast[seq[byte]]("someone else")))))
  doAssert assessReadiness(m, probeFromFacts(facts)).statusOf("btc-multisig-key") == rdMissing
  echo "4. ", family, ": readiness — the node is introduced by the proposal, asked for its chain; my key graded OK"

echo "btc_outside_signer_test: PSBT out, PSBT in — outside signatures count and are always surfaced; readiness asks the node — all OK"
