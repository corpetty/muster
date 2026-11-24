## exo-3b3.14 (P5-04): one payment settles one part across every room this keystore is in,
## not only within one room. The creditor's client keeps a ledger of the references it
## confirmed (a small file beside the identity, like joined_rooms.json), consulted before it
## confirms: a reference confirmed in another room is refused here. The ledger is the
## creditor's own record; it survives a restart, and a ledger file that cannot be read
## refuses every confirmation by reference rather than forgetting what it held.
##
## Monero: a request's payTo is a subaddress the creditor's own wallet minted for it; the
## creditor's client refuses to agree to one that already has incoming history, so a
## payment made in another room (or before) cannot settle this request.
##
## In-process: two rooms on the local transport, the stub ledger seam; the recording fake
## monero_wallet_backend for the Monero half.

import std/[json, os, strutils, sets]
import ../src/log/log
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/drivers/[driver, split, kinds]
import ../src/intents/materialization
import ../src/coordination/[session, intent_events, intents, live, parts, authorship, xmr_request]
import ./probes/fake_monero

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc idHex(ks: Keystore): string =
  const d = "0123456789abcdef"
  for x in ks.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

const Now = 1_800_000_000'u64
const Chain = "eip155:31337"
const Policy = "evm-split@" & Chain
const AlicePayTo = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let alice = idHex(aliceKs); let bob = idHex(bobKs)
let splitFor: DriverFor = proc(policy: string): Driver =
  if policy == Policy: newSplitDriver(EvmSplitFamily, Chain, @[alice, bob])
  else: newUnsupportedDriver(policy)

type Room = tuple[alice, bob: CoordinationSession]
proc newRoom(topic: string): Room =
  let net = newLocalNetwork()
  let ac = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
  let bc = newEpochJoiner(bobKs)
  bc.ingestGrant(ac.grantFor(0, bobKs.encIdentity()))
  (newCoordinationSession(newLocalTransport(net), ac, topic), newCoordinationSession(newLocalTransport(net), bc, topic))
proc sync(r: Room) = (r.alice.poll(); r.bob.poll())
proc bindCtx(): LinkContext = LinkContext(account: Chain & ":" & AlicePayTo, slot: "0", expiry: Now + 86_400)
proc agreed(r: Room, memo: string): string =
  let id = liveProposeIntent(r.alice, aliceKs, splitFor, Policy,
                             splitEffectJson(Chain, "ETH", "900", alice, AlicePayTo,
                                             @[SplitShare(who: bob, amount: "450")], memo),
                             int64(Now), 1, account = Chain & ":" & AlicePayTo, ttlSec = 3600)
  doAssert id.startsWith("0x"), id
  r.sync()
  discard liveContribute(r.bob, bobKs, splitFor, id, "", "", bindCtx(), Now)
  r.sync()
  doAssert intentState(r.alice.roomEvents(), splitFor, id) == "executable"
  id

let dir = getTempDir() / ("muster-ref-ledger-" & $getCurrentProcessId())
removeDir(dir)
createDir(dir)
let path = dir / "confirmed_refs.json"
setRefLedger(openRefLedger(path))

let ledger = newFakeLedger()
let roomA = newRoom("/muster/1/ref-ledger-a/proto")
let roomB = newRoom("/muster/1/ref-ledger-b/proto")
let lunchA = roomA.agreed("Lunch")
let lunchB = roomB.agreed("Lunch")

# ── 1. a payment confirmed in room A never confirms a part in room B ─────────────
block:
  let bobSeam = newFakePartSeam(ledger, "bob")
  let aliceSeam = newFakePartSeam(ledger, "alice")
  let (o, pp) = liveSettlePartSend(roomA.bob, bobKs, splitFor, lunchA, bobSeam, Now)
  doAssert o == "", o
  ledger.mine()
  doAssert liveSettlePartComplete(roomA.bob, bobKs, splitFor, bobSeam, pp) == "submitted"
  roomA.sync()
  doAssert liveConfirmPart(roomA.alice, aliceKs, splitFor, lunchA, partName(bob), aliceSeam, pp.tx) == "final"
  # the same transaction reported for the same amount, to the same address, in room B
  roomB.bob.publishAuthored(bobKs, partEvent(lunchB, partName(bob), "settled", bob, pp.tx))
  roomB.sync()
  let why = liveConfirmPart(roomB.alice, aliceKs, splitFor, lunchB, partName(bob), aliceSeam, pp.tx)
  doAssert why.startsWith("refused") and "another room" in why, "a payment confirmed in room A settles nothing in B: " & why
  doAssert liveConfirmParts(roomB.alice, aliceKs, splitFor, aliceSeam).len == 0, "the pump confirms nothing either"
  # confirming it again where it was confirmed is not "another room"
  doAssert fileExists(path), "the ledger is kept on disk"
  echo "1. a payment confirmed in one room is refused in another OK"

# ── 2. the ledger survives a restart; an unreadable one refuses, never forgets ───────
block:
  setRefLedger(openRefLedger(path))   # a relaunch reads it back
  let aliceSeam = newFakePartSeam(ledger, "alice")
  let tx = ledger.sent[0].tx
  doAssert "another room" in liveConfirmPart(roomB.alice, aliceKs, splitFor, lunchB, partName(bob), aliceSeam, tx)
  writeFile(path, "{not json")
  setRefLedger(openRefLedger(path))
  let why = liveConfirmPart(roomB.alice, aliceKs, splitFor, lunchB, partName(bob), aliceSeam, tx)
  doAssert why.startsWith("refused") and "ledger" in why, "an unreadable ledger refuses: " & why
  # the creditor's own word, with no reference, still stands
  doAssert liveConfirmPart(roomB.alice, aliceKs, splitFor, lunchB, partName(bob), aliceSeam, "") == "final"
  echo "2. the ledger is read back on restart; an unreadable one refuses by reference OK"

setRefLedger(nil)
removeDir(dir)

# ── 3. Monero: never agree to a payTo that already received ──────────────────────────
block:
  let XmrStage = caip2Of(xmrStagenet)
  let w = newFakeMonero("wallet-alice", "stagenet")
  let fresh = w.mint("fresh").address
  let used = w.mint("used").address
  w.rows = @[row(txidOf(7), "in", "450", 20, $w.subs[^1].index)]
  proc request(payTo: string): Effect =
    effectFromJson(splitEffectJson(XmrStage, "XMR", "900", alice, payTo, @[SplitShare(who: bob, amount: "450")], "x"))
  doAssert xmrCreditorRefusal(w, request(fresh), alice) == "", "a fresh subaddress is agreed to"
  let why = xmrCreditorRefusal(w, request(used), alice)
  doAssert why.startsWith("payto-used"), "a subaddress with incoming history is refused: " & why
  # an outgoing or failed row is not incoming history
  w.rows = @[row(txidOf(8), "out", "450", 20, $w.subs[^1].index), row(txidOf(9), "in", "450", 0, $w.subs[^1].index, failed = true)]
  doAssert xmrCreditorRefusal(w, request(used), alice) == ""
  # history the wallet did not answer is not "none": refused until it is read
  w.hist = anUnreachable
  doAssert xmrCreditorRefusal(w, request(fresh), alice).startsWith("wallet-unread")
  echo "3. a Monero payTo with incoming history is never agreed to OK"

echo "part_reference_ledger_test: all OK"
