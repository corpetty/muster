## Muster module impl — the hosted coordination surface over the REAL Safe driver.
##
## Includes the generated surface (from muster.lidl) and wires propose/txhash/
## approve/status to the intent lifecycle engine over a Safe driver: propose
## canonicalizes the effect to the EIP-712 safeTxHash, txhash exposes those exact
## bytes to sign, and approve verifies each 65-byte owner signature (secp256k1
## recovery vs the owner set) before it counts toward the threshold. The full real
## flow now runs through the hosted logoscore module. The Safe/owner/chain config
## below is the anvil fixture (documented; a real deployment swaps these in).

include muster_gen

import std/[json, tables, strutils, os, algorithm]
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle
import ../src/transport/lp_ffi        # the lp_* inter-module call binding (protocol ABI)
import ../src/transport/delivery      # DeliveryTransport (transport over lp_*)
import ../src/crypto/epoch_crypto     # EpochCrypto (ECIES-secp256k1 + libsodium AEAD)
import ../src/crypto/keystore         # persistent module identity (FS-4)
import ../src/coordination/session    # the multi-instance coordination flow
import ../src/coordination/intents     # intent lifecycle = reduce(log) (the multi-party fold)

proc hexToBytes(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2..^1]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc toAddr(s: string): Address =
  let b = hexToBytes(s)
  for i in 0 ..< min(20, b.len): result[i] = b[i]

proc toHex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  result = "0x"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

# ── anvil fixture: chainId 31337, a fixed Safe, owners = anvil accounts 0/1/2 ──
const OWNER0 = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
const OWNER1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
const OWNER2 = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
const SAFE_ADDR = "0x5FbDB2315678afecb367f032d93F642f64180aa3"

var gDriver = newSafeDriver(chainId = 31337, safe = toAddr(SAFE_ADDR),
                            owners = @[toAddr(OWNER0), toAddr(OWNER1), toAddr(OWNER2)],
                            threshold = 2)
var gIntents = initTable[string, Intent]()
var gHashes = initTable[string, array[32, byte]]()
var gEffects = initTable[string, Effect]()             ## the effect per intent (for execTransaction)
var gSigs = initTable[string, seq[Signature65]]()      ## collected owner sigs, for assembly
var gCounter = 0
var gNow: uint64 = 0

# The user-configurable RPC endpoint (untrusted infra, invariant 8). The anvil
# fixture default; a real deployment points this at the user's own node.
const RPC_URL = "http://127.0.0.1:8545"

proc toSig65(b: seq[byte]): Signature65 =
  for i in 0 ..< min(65, b.len): result[i] = b[i]

proc cmpSigner(a, b: (Address, Signature65)): int =
  for i in 0 ..< 20:
    if a[0][i] != b[0][i]: return (if a[0][i] < b[0][i]: -1 else: 1)
  0

proc musterHealth(): string = "ok"

# ── persistent module identity (FS-4) ──────────────────────────────────────────
# Opened once, lazily. The keyfile lives under the host-provided instance path
# (gContext.instancePersistencePath, from muster_gen); the module's identity is
# stable across restarts. The passphrase is a stopgap wart — read from the env
# with a documented dev default — that the real OS-keystore/Keycard backend
# removes when it slots behind this same seam.
var gKeystore: Keystore = nil

proc moduleKeystore(): Keystore =
  if gKeystore == nil:
    var dir = gContext.instancePersistencePath
    if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
    let pass = getEnv("MUSTER_KEY_PASSPHRASE", "muster-dev-passphrase")
    gKeystore = openFileKeystore(dir / "identity.mks", pass)
  gKeystore

proc musterIdentity(): string =
  ## The module's persistent coordination identity (FS-4) — the secp256k1 address
  ## and public key it signs and does epoch key-agreement with (ADR-010, one
  ## curve). Minted on first call, then stable across restarts.
  let ks = moduleKeystore()
  $(%*{
    "address": toHex(ks.address()),
    "pubkey": toHex(ks.pubKey())
  })

proc musterDescribe(): string =
  ## The Safe account this module coordinates against, read straight from the
  ## driver so the UI displays domain facts it was told, not ones it hardcoded.
  ## The safeTxHash every intent produces commits to chainId+safe (EIP-712
  ## domain), so this is exactly the account those bytes are worthless outside of.
  var owners = newJArray()
  for o in gDriver.owners: owners.add %toHex(o)
  $(%*{
    "chainId": gDriver.chainId.int,
    "safe": SAFE_ADDR,
    "threshold": gDriver.threshold,
    "owners": owners,
    "environment": "anvil-31337",
    "protocol": $lp_protocol_version()   # the logos-protocol ABI this module speaks
  })

proc musterPropose(effectJson: string): string =
  ## Build a transfer effect from JSON {to, value, nonce}, canonicalize to the
  ## EIP-712 safeTxHash, and advance to proposed.
  var fields: seq[(string, CborValue)]
  try:
    let j = parseJson(effectJson)
    if j.kind == JObject:
      if j.hasKey("to"): fields.add ("to", cbText(j["to"].getStr()))
      if j.hasKey("value"): fields.add ("value", cbUint(uint64(j["value"].getInt())))
      if j.hasKey("nonce"): fields.add ("nonce", cbUint(uint64(j["nonce"].getInt())))
  except CatchableError: discard
  let effect = Effect(schemaId: "muster.effect.transfer.v1", fields: fields)
  let ctx = SigningContext(environment: "anvil-31337", account: SAFE_ADDR, slot: "0",
                           expiry: high(uint64))
  inc gCounter
  let id = "intent-" & $gCounter
  var it = newIntent(gDriver, effect, ctx)
  it.materialization = canonicalizeSafe(gDriver, effect)   # EIP-712 safeTxHash; sets pendingHash
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = it.materialization.bytes[i]
  gHashes[id] = h
  gEffects[id] = effect
  it.apply(gDriver, IntentEvent(kind: iePropose, now: gNow))
  gIntents[id] = it
  id

proc musterTxhash(intentId: string): string =
  ## The exact bytes owners sign (the safeTxHash), as hex.
  if intentId notin gIntents: return "unknown-intent"
  toHex(gIntents[intentId].materialization.bytes)

proc musterApprove(intentId: string, signatureHex: string): string =
  ## Verify a 65-byte owner signature over this intent's safeTxHash. A signature
  ## that does not recover to a configured owner is not a valid contribution and is
  ## refused ("rejected") without touching the intent; a valid one is counted toward
  ## the threshold. Returns the new lifecycle state, or "rejected".
  if intentId notin gIntents: return "unknown-intent"
  gDriver.pendingHash = gHashes[intentId]                 # verify against THIS intent's hash
  let sig65 = toSig65(hexToBytes(signatureHex))
  if not recoversToOwner(gHashes[intentId], sig65, gDriver.owners):
    return "rejected"                                     # not an owner — do not advance

  # Dedup by signer (Safe dedups too); a re-submission of an already-counted owner
  # signature is refused rather than double-applied.
  let signer = ecrecover(gHashes[intentId], sig65)
  var have = gSigs.getOrDefault(intentId)
  for existing in have:
    if ecrecover(gHashes[intentId], existing) == signer: return "rejected"
  have.add sig65
  gSigs[intentId] = have

  var it = gIntents[intentId]
  inc gNow
  it.apply(gDriver, IntentEvent(kind: ieContribute, now: gNow,
                                contribution: Contribution(bytes: @sig65)))
  gIntents[intentId] = it
  $it.state

proc musterStatus(intentId: string): string =
  if intentId notin gIntents: return "unknown-intent"
  $gIntents[intentId].state

proc musterSubmit(intentId: string): string =
  ## Assemble the Safe execTransaction from the collected owner signatures, submit
  ## it through the user's RPC, and observe finality from the receipt. No indexer,
  ## no Safe service; finality is read from the chain (R-8), never asserted.
  if intentId notin gIntents: return "unknown-intent"
  var it = gIntents[intentId]
  if it.state != lsExecutable: return $it.state       # only executable intents submit

  # Collected sigs, sorted by signer address ascending (Safe checkSignatures dedup).
  let hash = gHashes[intentId]
  var signed: seq[(Address, Signature65)]
  for s in gSigs.getOrDefault(intentId):
    signed.add (ecrecover(hash, s), s)
  signed.sort(cmpSigner)
  var sigbytes: seq[byte]
  for (_, s) in signed: sigbytes.add @s

  # Assemble + submit through the user's RPC. anvil unlocks the relayer, so no key
  # is held here; the Safe verifies the owners on-chain regardless of the sender.
  let tx = toSafeTx(gEffects[intentId])
  let calldata = assembleExecTransaction(tx.to, tx.value, @[], sigbytes)
  let txHash = submitExecTransaction(RPC_URL, toAddr(OWNER0), gDriver.safe, calldata)
  inc gNow
  it.apply(gDriver, IntentEvent(kind: ieSubmit, now: gNow))    # executable -> submitted
  gIntents[intentId] = it

  # Observe finality from the chain.
  var status = -1
  for _ in 0 .. 50:
    status = watchReceiptStatus(RPC_URL, txHash)
    if status >= 0: break
    sleep(200)
  if status == 1:
    inc gNow
    it.apply(gDriver, IntentEvent(kind: ieFinal, now: gNow))   # submitted -> final
    gIntents[intentId] = it
  $it.state

# ── hosted coordination surface (the multi-party path) ─────────────────────────
# The counterpart to propose/approve/submit: instead of one client driving the
# whole lifecycle over local state, participants converge on shared intents by
# folding a signed, encrypted log (state = reduce(log), invariant 4). This is what
# compiles session + intents + epoch + delivery + keystore into the plugin — the
# link-check stub is gone; these methods genuinely drive the stack. One active
# conversation per module instance (the conversation is the security boundary).
#
# Cross-host exchange needs a running delivery node and a membership/grant
# handshake (deferred, with the live two-instance test); today the transport is
# DeliveryTransport and the reduce/verify path below is the same one
# tests/coordination_surface_test.nim exercises in-process over LocalTransport.
var gSession: CoordinationSession = nil
var gTopic = ""

proc musterCoordinateJoin(topic: string): string =
  let ks = moduleKeystore()
  gTopic = topic
  gSession = newCoordinationSession(newDeliveryTransport(), newEpochCrypto(ks), topic)
  $(%*{"address": toHex(ks.address()), "topic": topic})

proc musterCoordinatePropose(effectJson: string): string =
  if gSession == nil: return "not-joined"
  let id = intentIdFor(effectJson)
  gSession.publish(proposeEvent(id, effectJson))
  id

proc musterCoordinateContribute(intentId: string, signatureHex: string): string =
  if gSession == nil: return "not-joined"
  gSession.poll()
  let effectJson = effectJsonOf(gSession.log.allEvents(), intentId)
  if effectJson.len == 0: return "unknown-intent"
  let who = contributorOf(gDriver, effectJson, signatureHex)   # "" iff not an owner
  if who.len == 0: return "rejected"
  gSession.publish(contributeEvent(intentId, who, signatureHex))
  intentState(gSession.log.allEvents(), gDriver, intentId)

proc musterCoordinateIntents(): string =
  if gSession == nil: return "[]"
  gSession.poll()
  let intents = reduceIntents(gSession.log.allEvents(), gDriver)
  var arr = newJArray()
  for id, it in intents: arr.add %*{"id": id, "state": $it.state}
  $arr
