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

import std/[json, tables, strutils, os, algorithm, times]
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/threshold      # a second coordination policy (Ed25519 k-of-n)
import ../src/drivers/registry
import ../src/drivers/safe_rpc
import ../src/crypto/secp256k1
import ../src/crypto/curve25519      # Ed25519 roster keys for the threshold policy
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle
import ../src/transport/lp_ffi        # the lp_* inter-module call binding (protocol ABI)
import ../src/transport/delivery      # DeliveryTransport (transport over lp_*)
import ../src/crypto/epoch_crypto     # EpochCrypto (ECIES-secp256k1 + libsodium AEAD)
import ../src/crypto/keystore         # persistent module identity (FS-4)
import ../src/coordination/session    # the multi-instance coordination flow
import ../src/coordination/intents     # intent lifecycle = reduce(log) (the multi-party fold)
import ../src/wallet/types             # chain-agnostic wallet types
import ../src/wallet/adapter           # ChainAdapter seam + Wallet aggregate
import ../src/wallet/evm_adapter       # the EVM/Safe chain
import ../src/wallet/mock_chain        # a second, non-EVM chain (proves agnosticism)

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

# Selected through the registry by kind + config (not hardcoded to newSafeDriver);
# a real deployment reads this from the module's persisted config. The single-
# instance Safe path below uses Safe-specific fields, so it holds the concrete type.
var gDriver = SafeDriver(newDriver("safe", %*{
  "chainId": 31337, "safe": SAFE_ADDR,
  "owners": [OWNER0, OWNER1, OWNER2], "threshold": 2}))

# ── the ROOM's coordination policy (the driver) — swappable per conversation ────
# The single-instance Safe dashboard above holds a concrete SafeDriver. A ROOM
# coordinates under a policy the room picks, so its driver is a base Driver here,
# defaulting to the Safe above. coordinate_set_policy swaps it — proving the policy
# is a driver, not hardcoded (invariant 6): the same propose/contribute/fold path
# runs under Safe (secp/EIP-712) or the threshold driver (Ed25519 k-of-n), and the
# intent view is described by the driver, never assumed Safe. A real deployment
# reads the policy + its config from the room; the threshold roster below is a demo
# fixture, exactly as the Safe owners are.
# Per-room policy: each conversation remembers its own driver. gCoordKind/gCoordDriver
# are the ACTIVE room's (so the fold below is unchanged); gCoordKinds keeps each room's
# choice, so switching rooms restores its policy rather than carrying the last one.
var gCoordKinds = initTable[string, string]()   # topic -> policy kind
var gCoordKind = "safe"
var gCoordDriver: Driver = gDriver

proc seedOf(n: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = n)
proc thrRosterKey(n: byte): Ed25519Pub = encFromSeed(seedOf(n)).identity().ed

proc driverForKind(kind: string): Driver =
  ## Build the driver for a policy kind (the demo threshold roster is a fixture, as
  ## the Safe owners are). Unknown kinds fall back to the Safe.
  case kind
  of "threshold":
    newThresholdDriver(@[thrRosterKey(1), thrRosterKey(2), thrRosterKey(3)], 2)
  else: gDriver

proc activatePolicy(topic: string) =
  ## Make the active driver the one this room chose (default safe).
  gCoordKind = gCoordKinds.getOrDefault(topic, "safe")
  gCoordDriver = driverForKind(gCoordKind)
var gIntents = initTable[string, Intent]()
var gHashes = initTable[string, array[32, byte]]()
var gEffects = initTable[string, Effect]()             ## the effect per intent (for execTransaction)
var gSigs = initTable[string, seq[Signature65]]()      ## collected owner sigs, for assembly
var gCounter = 0
var gNow: uint64 = 0

# User-settable now (invariant 8: untrusted, user-configurable infrastructure — and
# that is empty if the user can't configure it). Defaults to the anvil fixture; a
# settings surface (settings / set_setting) points it at the user's own node/nodes.
var gRpcUrl = "http://127.0.0.1:8545"
var gDeliveryConfig = "{}"          ## delivery createNode config (store/bootstrap nodes)

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
  ## The module's persistent coordination identity (FS-4, two-identity model,
  ## F-14). The secp256k1 authorization address that signs Safe transactions, and
  ## the Ed25519/X25519 encryption identity it encrypts to members with — bound to
  ## the secp key by a signature the room verifies (see binding.nim). Minted on
  ## first call, stable across restarts.
  let ks = moduleKeystore()
  let enc = ks.encIdentity()
  $(%*{
    "address": toHex(ks.address()),
    "ed25519": toHex(enc.ed),
    "x25519": toHex(enc.x)
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
  var it = newIntent(gDriver, effect, ctx)   # canonicalize dispatches to Safe (EIP-712 safeTxHash + pendingHash)
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
  let txHash = submitExecTransaction(gRpcUrl, toAddr(OWNER0), gDriver.safe, calldata)
  inc gNow
  it.apply(gDriver, IntentEvent(kind: ieSubmit, now: gNow))    # executable -> submitted
  gIntents[intentId] = it

  # Observe finality from the chain.
  var status = -1
  for _ in 0 .. 50:
    status = watchReceiptStatus(gRpcUrl, txHash)
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
# Multi-room: the module holds a session per joined topic; gSession/gTopic are the
# ACTIVE one, so every method below operates on the active room unchanged. Joining a
# topic already in the map re-activates it (no new session, no re-key); a new topic
# creates one. coordinate_conversations lists them all.
var gSessions = initTable[string, CoordinationSession]()
var gSession: CoordinationSession = nil
var gTopic = ""
var gMsgSeq: uint64 = 0     ## per-instance monotonic nonce, disambiguates identical posts

proc musterCoordinateJoin(topic: string): string =
  let ks = moduleKeystore()
  if topic in gSessions:
    gSession = gSessions[topic]           # re-activate an already-joined room
  else:
    gSession = newCoordinationSession(newDeliveryTransport(gDeliveryConfig), newEpochCrypto(ks), topic)
    gSessions[topic] = gSession
  gTopic = topic
  activatePolicy(topic)                 # restore this room's chosen policy (per-room)
  $(%*{"address": toHex(ks.address()), "topic": topic})

proc policyJson(): JsonNode =
  let d = gCoordDriver.describe()
  %*{"policy": gCoordKind, "threshold": d.threshold,
     "domain": d.serializationDomain, "membership": $d.membership}

proc musterCoordinateSetPolicy(kind: string): string =
  ## Choose the room's coordination policy (its driver). "safe" is the EIP-712 Safe
  ## above; "threshold" is a k-of-n Ed25519 endorsement over a demo roster — nothing
  ## like Safe (no secp, no chain), yet the same propose/contribute/fold path. Set
  ## before proposing; a real deployment fixes this at room creation.
  case kind
  of "safe", "threshold":
    gCoordKind = kind
    gCoordDriver = driverForKind(kind)
    if gTopic.len > 0: gCoordKinds[gTopic] = kind   # remember it for THIS room
  else:
    return $(%*{"error": "unknown policy: " & kind})
  $policyJson()

proc musterCoordinatePolicy(): string =
  ## The room's current policy — {policy, threshold, domain, membership}.
  $policyJson()

proc musterCoordinatePropose(effectJson: string): string =
  if gSession == nil: return "not-joined"
  let id = intentIdFor(effectJson)
  gSession.publish(proposeEvent(id, effectJson))
  # Announce the proposal INTO the conversation: a reference card, authored and
  # timestamped like any message, so the proposal appears inline in the thread
  # among the chat (the conversation is the substrate — a proposal is a card in it,
  # not a side panel). The author attributes who proposed. Its live state, verify,
  # and provenance still come from the verified intent fold keyed by this id — the
  # card is a positional reference, never the source of truth.
  let author = toHex(moduleKeystore().encIdentity().toBytes())
  inc gMsgSeq
  let refBody = $(%*{"kind": "intent-ref", "intentId": id})
  let (_, ev) = newMessageEvent(author, int64(epochTime()), refBody, gMsgSeq)
  gSession.publish(ev)
  id

proc musterCoordinateContribute(intentId: string, signatureHex: string): string =
  if gSession == nil: return "not-joined"
  gSession.poll()
  let effectJson = effectJsonOf(gSession.log.allEvents(), intentId)
  if effectJson.len == 0: return "unknown-intent"
  # The room's policy verifies the contribution: a Safe owner's secp signature, or a
  # threshold roster member's Ed25519 endorsement — "" iff it isn't a valid one.
  let who = contributorOf(gCoordDriver, effectJson, signatureHex)
  if who.len == 0: return "rejected"
  gSession.publish(contributeEvent(intentId, who, signatureHex))
  intentState(gSession.log.allEvents(), gCoordDriver, intentId)

proc musterCoordinateIntents(): string =
  ## The room's proposals, folded from the shared log and projected to what a card
  ## renders: the lifecycle state, the effect it carries, the driver threshold, and
  ## the distinct-owner approval count. Backward compatible — id + state are still
  ## present; effect/threshold/approvals/rail are the render fields the room needs so
  ## its cards come from real state (reduce(log)) rather than posted demo JSON.
  if gSession == nil: return "[]"
  gSession.poll()
  let events = gSession.log.allEvents()
  let desc = gCoordDriver.describe()             # threshold + domain are driver-described
  var arr = newJArray()
  for v in reduceIntentViews(events, gCoordDriver):
    # txhash is the driver-re-derived materialization — the exact bytes a member
    # signs (Safe's safeTxHash, or the threshold driver's dCBOR materialization).
    # threshold + domain come from describe(), never hardcoded — so the card renders
    # whatever policy the room chose (invariant 6). rail names the policy.
    var o = %*{"id": v.id, "state": v.state,
               "threshold": desc.threshold, "approvals": v.approvals,
               "policy": gCoordKind, "domain": desc.serializationDomain,
               "txhash": v.txhash}
    if gCoordDriver of SafeDriver:
      # a Safe signature is bound to its EIP-712 domain (chainId + safe); surface it
      # so the verify view names exactly what the bytes are worthless outside of (F-5).
      let sd = SafeDriver(gCoordDriver)
      o["rail"] = %"safe"
      o["chainId"] = %sd.chainId.int
      o["safe"] = %toHex(sd.safe)
      o["environment"] = %"anvil-31337"
    else:
      o["rail"] = %gCoordKind
    if v.effectJson.len > 0:
      try: o["effect"] = parseJson(v.effectJson)
      except CatchableError: discard
    # provenance: the decision's lineage (invariant 10) — every log entry that put
    # this intent in front of the reader, by class + position + (named) account, so
    # the UI can answer "how do I know this, and why trust it".
    var prov = newJArray()
    for item in intentProvenance(events, gCoordDriver, v.id):
      prov.add %*{"class": $item.cls, "logPos": item.logPos,
                  "account": item.account, "accountable": item.accountable,
                  "what": item.what}
    o["provenance"] = prov
    arr.add o
  $arr

proc roomContext(): LinkContext =
  ## The context our binding is scoped to — this Safe, valid for a day. Wall-clock
  ## expiry is fine here: a binding is an admission-time credential, not a signing-
  ## path artifact (so it never touches the deterministic log).
  LinkContext(account: SAFE_ADDR, slot: "0", expiry: uint64(epochTime()) + 86_400)

proc musterCoordinateRequestJoin(): string =
  if gSession == nil: return "not-joined"
  gSession.requestJoin(moduleKeystore().bindingFor(roomContext()))
  "ok"

proc musterCoordinatePending(): string =
  ## Each pending requester with whether its binding proves Safe ownership (F-9),
  ## so a host admits knowingly rather than blindly.
  if gSession == nil: return "[]"
  gSession.poll()
  let nowSec = uint64(epochTime())
  var arr = newJArray()
  for st in gSession.pendingBindings():
    arr.add %*{"identity": toHex(st.enc.toBytes()),
               "bindsOwner": bindingBinds(st, gDriver.owners, nowSec)}
  $arr

# ── chat/room surface (messages · roster · conversations) ──────────────────────
# The product layer the UI renders as a room: authored messages folded from the
# SAME sealed log the intents ride (state = reduce(log), invariant 4), the admitted
# roster from the ConversationCrypto seam, and the joined room descriptor. Messages
# are opaque strings — plain text or a typed card as JSON — the core never
# interprets them. Reads drive inbound delivery (poll) first, exactly like
# coordinate_intents, so they reflect what arrived from other participants.

proc musterCoordinatePostMessage(body: string): string =
  ## Post an authored message (chat text or a JSON card) to the joined room over
  ## the existing encrypted transport, as a new "message/<id>" event on the shared
  ## log. Returns the message id.
  if gSession == nil: return "not-joined"
  let author = toHex(moduleKeystore().encIdentity().toBytes())
  inc gMsgSeq
  let ts = int64(epochTime())
  let (id, ev) = newMessageEvent(author, ts, body, gMsgSeq)
  gSession.publish(ev)
  id

proc musterCoordinateMessages(): string =
  ## The room's authored messages, oldest-first, folded from the shared log.
  if gSession == nil: return "[]"
  gSession.poll()
  var arr = newJArray()
  for m in reduceMessages(gSession.log.allEvents()):
    arr.add %*{"id": m.id, "author": m.author, "ts": m.ts, "body": m.body}
  $arr

proc musterCoordinateMembers(): string =
  ## The ADMITTED members of the joined room (the current roster), each flagged
  ## whether it is our own identity. Distinct from coordinate_pending (requests).
  if gSession == nil: return "[]"
  gSession.poll()
  let me = gSession.selfIdentity()
  var arr = newJArray()
  for m in gSession.members():
    arr.add %*{"identity": toHex(m.toBytes()), "self": (m == me)}
  $arr

proc musterCoordinateConversations(): string =
  ## Every joined room, as {topic, address, lastTs, active} — the home surface's
  ## room list. The active room is flagged; lastTs is each room's latest message ts
  ## (0 if none yet), so home can order by recency. Multi-room: one entry per session.
  var arr = newJArray()
  let myAddr = toHex(moduleKeystore().address())
  for topic, s in gSessions:
    s.poll()
    let msgs = reduceMessages(s.log.allEvents())
    let lastTs = if msgs.len > 0: msgs[^1].ts else: 0'i64
    arr.add %*{"topic": topic, "address": myAddr, "lastTs": lastTs,
               "active": (topic == gTopic)}
  $arr

# ── wallet: chain-agnostic account/asset/transfer surface ──────────────────────
# The account-level view of the chains the module touches — distinct from the
# coordinated intent path. The EVM chain is the same one the Safe settles on; the
# mock shielded chain is registered alongside it to demonstrate that a second,
# non-EVM chain is a registration, not a code change (F-Design: chain-agnostic).
var gWallet: Wallet = nil
var gMock: MockChain = nil
var gEvm: EvmAdapter = nil          ## typed handle for the EVM-specific verified path

proc moduleWallet(): Wallet =
  if gWallet == nil:
    let ks = moduleKeystore()
    gWallet = newWallet(ks)
    gEvm = newEvmAdapter("evm:31337", gRpcUrl)
    gWallet.register(gEvm)
    gMock = newMockChain()
    gWallet.register(gMock)
    for acc in gMock.accounts(ks):        # seed the mock so its balances are demonstrable
      if acc.form == afPublic:
        gMock.credit(acc.id, "MOCK", "5000000000")
        gMock.credit(acc.id, "MTK", "1230000")
  gWallet

proc assetBySymbol(w: Wallet, chain, symbol: string): AssetId =
  for a in w.assets():
    if a.chain == chain and a.symbol == symbol: return a
  raise newException(WalletError, "unknown asset " & symbol & " on " & chain)

proc accountOn(w: Wallet, chain: string): Account =
  for a in w.accounts():
    if a.chain == chain and a.form == afPublic: return a
  raise newException(WalletError, "no account on " & chain)

proc musterWalletAccounts(): string =
  let w = moduleWallet()
  var arr = newJArray()
  for a in w.accounts(): arr.add %*{"chain": a.chain, "form": $a.form, "id": a.id}
  $arr

proc musterWalletBalances(): string =
  ## Every account × asset, each entry a balance OR an error — never a false zero.
  let w = moduleWallet()
  var arr = newJArray()
  for acc in w.accounts():
    for asset in w.assets():
      if asset.chain != acc.chain: continue
      # grade (F-10): "attested" — this reads the balance from the user's RPC and
      # trusts it. It becomes "verified-locally" only when checked against a
      # consensus state root (wallet_verified_balance), which needs the beacon
      # light-client sidecar. The UI renders the grade so the user sees which it is.
      var entry = %*{"chain": acc.chain, "account": acc.id, "asset": asset.symbol,
                     "grade": "attested"}
      try:
        let bal = w.balance(acc.chain, acc, asset)
        entry["display"] = %bal.display()
        entry["raw"] = %bal.raw
      except CatchableError as e:
        entry["error"] = %e.msg
      arr.add entry
  $arr

proc musterWalletEstimateFee(chain, to, assetSymbol, raw: string): string =
  let w = moduleWallet()
  try:
    let asset = assetBySymbol(w, chain, assetSymbol)
    let fee = w.estimateFee(chain, accountOn(w, chain), to, amount(asset, raw))
    $(%*{"fee": fee.fee.display(), "raw": fee.fee.raw, "note": fee.note})
  except CatchableError as e:
    $(%*{"error": e.msg})

proc musterWalletSend(chain, fromId, to, assetSymbol, raw: string): string =
  let w = moduleWallet()
  try:
    let asset = assetBySymbol(w, chain, assetSymbol)
    let frm = Account(chain: chain, form: afPublic, id: fromId)
    let r = w.send(chain, frm, to, amount(asset, raw))
    $(%*{"txId": r.id, "chain": r.chain})
  except CatchableError as e:
    $(%*{"error": e.msg})

proc musterWalletFinality(chain, txId: string): string =
  let w = moduleWallet()
  try:
    let f = w.finality(TxRef(chain: chain, id: txId))
    $(%*{"status": $f.status, "detail": f.detail})
  except CatchableError as e:
    $(%*{"error": e.msg})

proc musterWalletVerifiedBalance(accountId, stateRootHex: string): string =
  ## The EVM balance verified against a trusted state root (F-10 verified-locally):
  ## a valid proof upgrades the grade from "attested" to "verified-locally"; an
  ## invalid one is an error, never a trusted number.
  discard moduleWallet()
  try:
    let acc = Account(chain: "evm:31337", form: afPublic, id: accountId)
    let bal = gEvm.verifiedBalance(acc, stateRootHex)
    $(%*{"display": bal.display(), "raw": bal.raw, "grade": "verified-locally"})
  except CatchableError as e:
    $(%*{"error": e.msg})

proc musterCoordinateAdmit(identityHex: string): string =
  ## Admit a requester — but only one whose binding proves it is a Safe owner (F-9,
  ## the admission policy over the "a member decides" model). A request without a
  ## valid binding is "unverified", never silently admitted.
  if gSession == nil: return "not-joined"
  let b = hexToBytes(identityHex)
  if b.len != 64: return "bad-key"          # a member identity: ed25519(32) ++ x25519(32)
  let m = encIdentityFromBytes(b)
  let nowSec = uint64(epochTime())
  var verified = false
  for st in gSession.pendingBindings():
    if st.enc == m and bindingBinds(st, gDriver.owners, nowSec): verified = true
  if not verified: return "unverified"      # no binding proving Safe ownership (F-9)
  gSession.admit(m)
  "ok"

# ── settings: user-configurable infrastructure (invariant 8) ────────────────────
# The endpoints and infra Muster points at are the user's to choose — "untrusted,
# user-configurable infrastructure" is empty if they can't configure it. In-memory
# today; a real deployment persists these beside the keystore, and inside basecamp
# reads them from the platform's own settings (the shell we don't rebuild).

proc musterSettings(): string =
  ## The current settings + the module identity, for a settings surface: the RPC
  ## endpoint the wallet/Safe path reads against, the delivery createNode config the
  ## next room join boots with, the environment, and who this module is.
  let ks = moduleKeystore()
  let enc = ks.encIdentity()
  $(%*{
    "rpc": gRpcUrl,
    "delivery": gDeliveryConfig,
    "environment": "anvil-31337",
    "identity": {"address": toHex(ks.address()),
                 "ed25519": toHex(enc.ed), "x25519": toHex(enc.x)}
  })

proc musterSetSetting(key, value: string): string =
  ## Set one setting. "rpc" repoints the wallet/Safe RPC (the wallet re-inits on next
  ## use so the new endpoint takes effect); "delivery" changes the createNode config
  ## the NEXT coordinate_join boots with (existing sessions keep their node). Returns
  ## the updated settings, or an error for an unknown key.
  case key
  of "rpc":
    gRpcUrl = value
    gWallet = nil            # re-init the EVM adapter against the new endpoint
  of "delivery":
    gDeliveryConfig = value
  else:
    return $(%*{"error": "unknown setting: " & key})
  musterSettings()
