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

import std/[json, tables, strutils, os, algorithm, times, sets, sequtils]
import ../src/dcbor/dcbor
import ../src/drivers/driver
import ../src/drivers/safe
import ../src/drivers/threshold      # a second coordination policy (Ed25519 k-of-n)
import ../src/drivers/frost          # 2-round FROST-style — the multi-round policy
import ../src/drivers/invoke         # the generic module-action driver (P-D1/P-D2)
import ../src/drivers/eip191         # EIP-191 personal-sign attestation (Tier-1, P-D6)
import ../src/drivers/registry
import ../src/drivers/profile         # the family profile each driver declares (exo-a50.1.1)
import ../src/drivers/kinds           # the one list of driver kinds; unknown → unsupported (exo-a50.1.2)
import ../src/drivers/safe_rpc
import ../src/wallet/types as wallet_types   # hexToDec + formatUnits: a live balance → "N ETH"
import ../src/crypto/secp256k1
import ../src/crypto/curve25519      # Ed25519 roster keys for the threshold policy
import ../src/intents/materialization
import ../src/intents/signing_payload
import ../src/intents/lifecycle
import logos_sdk/ffi                  # the lp_* inter-module call binding (protocol ABI, shared SDK)
import ../src/transport/delivery      # DeliveryTransport (transport over lp_*)
import ../src/crypto/epoch_crypto     # EpochCrypto (ECIES-secp256k1 + libsodium AEAD)
import ../src/crypto/keystore         # persistent module identity (FS-4)
import ../src/coordination/session    # the multi-instance coordination flow
import ../src/coordination/intents     # intent lifecycle = reduce(log) (the multi-party fold)
import ../src/coordination/live        # the live propose/contribute path, driveable in-process (exo-ef1)
import ../src/coordination/accounts    # accounts disclosed by members into the room (exo-a50.1.3)
import ../src/settlement/settlement     # the settlement seam: chosen by profile, through the adapter (exo-a50.1.5)
import ../src/drivers/btc_multisig     # Bitcoin multisig accounts (exo-a50.2.3)
import ../src/drivers/lez_multisig     # the LEZ multisig vote locus (exo-a50.3)
import ../src/lez/multisig as lezms    # its on-chain objects + PDAs
import ../src/lez/multisig_chain       # the chain seam
import ../src/lez/tx as leztx          # base58 ids, public account ids
import ../src/wallet/lez_multisig_live # the live chain: the member's own transactions (exo-3c9)
import ../src/coordination/vote        # a vote-locus approval = the member's own on-chain vote
import ../src/drivers/btc_frost        # FROST: the aggregate locus (Phase D)
import ../src/coordination/aggregate   # the ChillDKG ceremony + the two rounds over the log
import std/sysrand                     # a multisig create key
import stint                           # LEZ nonces (u128)
import ../src/bitcoin/network          # networkByCaip2
import ../src/coordination/card_rows   # the card's fixed rows, from the profile (exo-a50.1.6)
import ../src/coordination/invoker     # the execute seam + allowlist/capability gate (P-D2)
import ../src/coordination/readiness   # the action manifest + this instance's readiness (exo-002.2)
import ../src/coordination/offers      # requirements × my catalogue → offers (exo-45e K4)
import ../src/wallet/material          # the holdings catalogue (exo-45e K2)
import ../src/hashing/sha256
import ../src/log/proof                # exportable, self-verifying log proofs (M4)
import ../src/coordination/audit       # the signature-audit file (exo-403)
import ../src/coordination/flow        # the information-flow view (M5)
import ../src/coordination/room_infra  # the infrastructure the room's proposals introduce (exo-428)
import ../src/intents/authorization    # muster-issued authorizations for the host hook (M7)
import ../src/coordination/lp_invoker  # LpInvoker — call the target module over lp_*
import ../src/coordination/discovery   # discover coordinatable module actions (P-D3)
import ../src/coordination/contacts    # the address book (aliases for member ids)
import ../src/wallet/types             # chain-agnostic wallet types
import ../src/wallet/adapter           # ChainAdapter seam + Wallet aggregate
import ../src/wallet/evm_adapter       # the EVM/Safe chain
import ../src/wallet/mock_chain        # a second, non-EVM chain (proves agnosticism)
import ../src/wallet/lez_core          # the LEZ wallet seam + FakeLezCore (P-L3 swaps in real)
import ../src/wallet/lez_adapter       # the Logos Execution Zone chain (send assets via Logos)
import ../src/wallet/lez_lp            # LpLezCore — the real lez_core over lp_* (P-L3)
import ../src/wallet/btc_adapter       # the user's Bitcoin node (exo-a50.2.5/.6)
import ../src/coordination/attest      # readEvent: the external read a Bitcoin spend's coins cite (inv 10)

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
const SAFE_ADDR = "0xEb4520E32862D2adFa2aF042f0B5eA2041dEE841"
  ## the real Safe v1.4.1 proxy infra/anvil/devnet.sh creates on a fresh anvil (deterministic)

# The LOCAL TEST SAFE (the anvil fixture). It is NOT the room's account: accounts live
# in the room, disclosed by members (coordination/accounts.nim, exo-a50.1.3), and no
# room intent resolves to this. It is (a) the suggestion describe() offers a member to
# disclose into a room when they run against anvil, and (b) the account of the older
# single-instance lifecycle path (propose/approve/submit, the P4 harness).
var gDevSafe = SafeDriver(newDriver("safe", %*{
  "chainId": 31337, "safe": SAFE_ADDR,
  "owners": [OWNER0, OWNER1, OWNER2], "threshold": 2}))

# ── coordination policy (the driver) — a property of each INTENT, not the room ──
# The room is a security and privacy boundary; an individual intent is a POLICY
# boundary. A group (a room) can do several things at once, each under its own
# driver — so policy binds to the intent, not the conversation. A propose declares
# its intent's policy in the LOG (policyDeclEvent, keyed by the content-addressed
# intent id), and the fold resolves each intent's driver from that (intentPolicyOf +
# driverForKind). This is invariant 6 twice over: the driver is never hardcoded, and
# two intents under two drivers coexist in one thread.
#
# gCoordKind is only this instance's COMPOSE DEFAULT — the policy the *next* propose
# is stamped with. Changing it never re-folds an existing decision, because each
# intent already carries its own policy. driverFor() is the resolver the folds take.
var gCoordKind = "threshold"
var gInvoker: Invoker = nil   ## the execute/discovery/readiness seam to other modules, created lazily

proc seedOf(n: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = n)
proc thrRosterKey(n: byte): Ed25519Pub = encFromSeed(seedOf(n)).identity().ed

proc currentRoster(): seq[Ed25519Pub]   ## forward — defined once gSession + the keystore are
proc myAddress(): Address                ## forward — this instance's secp account, defined below

proc roomAccounts(): seq[RoomAccount]   ## forward — the room's disclosed accounts, folded from the log

var gDelegatecallAllow: seq[Address] = @[]
var gDelegatecallAllowLoaded = false
proc delegatecallAllow(): seq[Address] =
  ## The Safe delegatecall targets THIS client will propose or sign (exo-a50.1.4) —
  ## MUSTER_SAFE_DELEGATECALL_ALLOW, comma-separated addresses (e.g. MultiSendCallOnly).
  ## Empty by default: a delegatecall runs foreign code as the Safe, so it is refused
  ## until an operator opts a target in.
  if not gDelegatecallAllowLoaded:
    gDelegatecallAllowLoaded = true
    for t in getEnv("MUSTER_SAFE_DELEGATECALL_ALLOW").split(','):
      let a = t.strip()
      if a.len == 42: gDelegatecallAllow.add toAddress(a)
  gDelegatecallAllow

proc roomDriver(kind: string): Driver =
  ## Build a ROOM kind's driver. The roster is the room's ACTUAL members — their Ed25519
  ## encryption identities, from the membership fold — so THIS instance's own identity
  ## IS a signer and it endorses in-app (no pasted fixture). k is the configured
  ## threshold capped at the roster size (a 1-member room needs 1); "unanimous" is n-of-n.
  let roster = currentRoster()
  let n = max(1, roster.len)
  case kind
  of "threshold": newThresholdDriver(roster, min(2, n))
  of "unanimous": newThresholdDriver(roster, n)
  of "frost":     newFrostDriver(roster, min(2, n))
  of "invoke":    newInvokeDriver(roster, min(2, n))   # generic module-action (P-D2); action in the effect
  else: newUnsupportedDriver(kind)

proc driverForKind(kind: string): Driver =
  ## Resolve an intent's POLICY to its driver (coordination/accounts.driverForPolicy).
  ## A room kind is built from the roster (roomDriver). An account-bound kind — "safe",
  ## and "eip191" (an attestation by an account's signers: threshold 1, a per-signer
  ## act) — is built FROM the account a member disclosed into this room, named in the
  ## policy ("safe@<CAIP-10>"). The fold recognizes exactly the DISCLOSED signer set —
  ## never this instance's own key injected in (exo-45e K3) and never a module-global
  ## Safe: a bare "safe", an undisclosed account, or a kind not on the one list
  ## (drivers/kinds.nim) is UNSUPPORTED (exo-a50.1.2, exo-a50.1.3).
  driverForPolicy(kind, roomAccounts(), roomDriver, delegatecallAllow())

let driverFor: DriverFor = proc(kind: string): Driver = driverForKind(kind)
  ## The per-intent driver resolver the folds take: each intent's own policy → its driver.
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
var gRelayer = "self"
var gBtcRpc = getEnv("MUSTER_BTC_RPC", "")   ## the user's Bitcoin node, "http://user:pass@host:port"; "" = none (exo-a50.2.6)
# The LEZ multisig, live (exo-3c9): the user's sequencer (untrusted, invariant 8), the zone
# it serves, and the multisig program. By default: the public testnet (the LEZ wallet's
# own default), and the lez-multisig build deployed there (logos-co/lez-multisig#45).
const LezDeployedMultisig = "2ced3d301a4d1cd5db6cad9c428b9f3463155073f8bacf73179c6ea6536de4c7"
var gLezRpc = getEnv("MUSTER_LEZ_RPC", "https://testnet.lez.logos.co")
var gLezChain = getEnv("MUSTER_LEZ_CHAIN", "lez:testnet")
var gLezProgram = getEnv("MUSTER_LEZ_MULTISIG_PROGRAM", LezDeployedMultisig)
  ## who sends a settling transaction and pays its fee (exo-a50.1.5): "self" = this
  ## instance's own key, signed locally and sent raw; "unlocked:<0x…>" = an account the
  ## node itself unlocks (anvil's dev accounts) via eth_sendTransaction.
proc deliveryPreset(name: string): string =
  ## Embedded fleet createNode configs, so delivery WORKS out of the box (invariant 8
  ## says the infra is user-configurable, not that it must start empty). Keep in sync
  ## with infra/fleets/<name>.json — regenerate those via infra/fleets/refresh.sh and
  ## repaste here if the fleet's entry nodes rotate. A settings value may be one of
  ## these short names or a full createNode JSON.
  case name
  of "logos.test":
    """{"mode":"Core","preset":"logos.test","entryNodes":["/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF","/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj","/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3","/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV","/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG","/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7"]}"""
  else: ""

proc deliveryConfigFor(v: string): string =
  ## Resolve a delivery setting: a short fleet name → its embedded preset; empty or the
  ## inert "{}" → the default fleet (so a fresh instance connects instead of failing to
  ## autoshard); anything else → verbatim (a hand-written createNode JSON).
  if v.len == 0 or v == "{}": return deliveryPreset("logos.test")
  let p = deliveryPreset(v)
  if p.len > 0: return p
  v

var gDeliveryConfig = deliveryPreset("logos.test")   ## default: the logos.test fleet, so
                                                     ## the room works with no env/flags

# Persist the infra settings beside the keystore, so a user's chosen endpoints
# survive a restart. Best-effort — a missing/malformed file leaves the defaults.
proc settingsPath(): string =
  var dir = context().instancePersistencePath
  if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
  dir / "settings.json"

var gSettingsLoaded = false
var gDeliverySaved = false          ## did the user persist a delivery choice? (else env/default)
proc loadSettingsFile() =
  if gSettingsLoaded: return
  gSettingsLoaded = true
  try:
    let p = settingsPath()
    if fileExists(p):
      let j = parseJson(readFile(p))
      if j.hasKey("rpc"): gRpcUrl = j["rpc"].getStr()
      if j.hasKey("relayer"): gRelayer = j["relayer"].getStr("self")
      if j.hasKey("btcRpc"): gBtcRpc = j["btcRpc"].getStr()
      if j.hasKey("lezRpc"): gLezRpc = j["lezRpc"].getStr()
      if j.hasKey("lezChain"): gLezChain = j["lezChain"].getStr()
      if j.hasKey("lezMultisigProgram"): gLezProgram = j["lezMultisigProgram"].getStr()
      if j.hasKey("delivery"):
        gDeliveryConfig = deliveryConfigFor(j["delivery"].getStr())
        gDeliverySaved = true
  except CatchableError: discard
  # A host/runner can still point every instance at a specific bootstrap set via
  # MUSTER_DELIVERY_CONFIG (a full createNode JSON or a fleet short-name), the way
  # `make run-fleet` does. It applies only when the user has NOT persisted a delivery
  # choice — a saved setting always wins — and otherwise the built-in fleet default
  # (above) already works, so no env is needed to get a connected room.
  let envCfg = getEnv("MUSTER_DELIVERY_CONFIG")
  if envCfg.len > 0 and not gDeliverySaved:
    gDeliveryConfig = deliveryConfigFor(envCfg)

proc saveSettingsFile() =
  try:
    createDir(parentDir(settingsPath()))
    # the Bitcoin node URL may carry its RPC credentials — kept beside the keystore,
    # like a bitcoin.conf, and never shown back (settings() redacts them)
    writeFile(settingsPath(), $(%*{"rpc": gRpcUrl, "delivery": gDeliveryConfig, "relayer": gRelayer,
                                   "btcRpc": gBtcRpc, "lezRpc": gLezRpc, "lezChain": gLezChain,
                                   "lezMultisigProgram": gLezProgram}))
  except CatchableError: discard

proc toSig65(b: seq[byte]): Signature65 =
  for i in 0 ..< min(65, b.len): result[i] = b[i]

proc cmpSigner(a, b: (Address, Signature65)): int =
  for i in 0 ..< 20:
    if a[0][i] != b[0][i]: return (if a[0][i] < b[0][i]: -1 else: 1)
  0

proc musterHealth(): string = "ok"

# ── persistent module identity (FS-4) ──────────────────────────────────────────
# Opened once, lazily. The keyfile lives under the host-provided instance path
# (context().instancePersistencePath, from logos_sdk/api via muster_gen); the module's identity is
# stable across restarts. The passphrase is a stopgap wart — read from the env
# with a documented dev default — that the real OS-keystore/Keycard backend
# removes when it slots behind this same seam.
var gKeystore: Keystore = nil

# ── demo pre-seeded identities + contacts (exo-1fc) ─────────────────────────────
# For the recorded two-party demo the peers should already know each other by name —
# no on-camera "add contact" step. The demo peers are the three anvil owner keys
# (scripts/demo-peer.sh); their ENCRYPTION (chat) identity is derived deterministically
# from that key, so every role's room-membership id is known ahead of time. That is what
# lets a seeded peer derive the OTHER roles' chat ids on the fly — from public test keys —
# and drop them into the address book with their names. Demo-only: everything here is
# gated behind MUSTER_DEV_SECP_KEY; the real path derives and seeds nothing.
const DemoRoles = [
  ("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", "Alice"),
  ("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", "Bob"),
  ("5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", "Carol"),
]

proc hexSeed32(hexIn: string): seq[byte] =
  ## A 0x-optional hex string → its bytes (the anvil secp seeds; the demo secp seed too).
  var h = hexIn.strip()
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< h.len div 2:
    try: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    except CatchableError: discard

proc demoEncSeed(secpSeed: openArray[byte]): array[32, byte] =
  ## The deterministic encryption seed for a demo role — a domain-separated hash of its
  ## secp seed, so the chat id is a fixed function of the (public) anvil key. BOTH the
  ## keystore mint (this instance's own chat id) and the contact derivation (a peer's chat
  ## id) use this, so the two agree.
  var buf = newSeq[byte]()
  for c in "muster-demo-enc-v1": buf.add byte(c)
  for b in secpSeed: buf.add b
  sha256(buf)

proc toArr32(s: seq[byte]): array[32, byte] =
  for i in 0 ..< min(32, s.len): result[i] = s[i]

proc demoChatIdOf(secpSeed: seq[byte]): string =
  ## A demo role's room-membership id (ed25519 ++ x25519 hex, as members speak it).
  toHex(encFromSeed(demoEncSeed(secpSeed)).identity().toBytes())

proc moduleKeystore(): Keystore =
  if gKeystore == nil:
    var dir = context().instancePersistencePath
    if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
    let pass = getEnv("MUSTER_KEY_PASSPHRASE", "muster-dev-passphrase")
    # dev/demo: MUSTER_DEV_SECP_KEY seeds this instance's account with a known secp
    # key (e.g. an anvil Safe owner key) so it signs Safe intents in-app AS a real
    # on-chain owner — the seam that lets an in-app approval settle on-chain (exo-001).
    # Honoured only when minting a fresh keyfile; an existing identity is kept.
    var seed: seq[byte] = @[]
    let devKey = getEnv("MUSTER_DEV_SECP_KEY")
    if devKey.len > 0:
      seed = hexSeed32(devKey)
    # Demo peers also get a DETERMINISTIC encryption (chat) identity, derived from the
    # secp seed — so their room-membership id is known ahead of time and peers can be
    # pre-seeded as contacts (exo-1fc). Empty on the real path ⇒ a fresh random chat key.
    var encSeed: seq[byte] = @[]
    if seed.len == 32:
      encSeed = @(demoEncSeed(seed))
    let path = dir / "identity.mks"
    try:
      gKeystore = openFileKeystore(path, pass, seed, encSeed)
    except KeystoreError as e:
      # A wrong MUSTER_KEY_PASSPHRASE (or a corrupt/foreign keyfile) can't be
      # decrypted. Re-raise with an actionable message instead of leaking the raw
      # "wrong passphrase or corrupt keyfile" — and, crucially, DON'T let it blank
      # the account silently: describe() never touches the keystore, so the Safe
      # still shows; only keystore-dependent calls (wallet, identity, signing) fail,
      # each surfacing this line (the module dispatch turns a handler raise into a
      # {"error": …} response now, so one bad keyfile no longer crashes the module).
      raise newException(KeystoreError,
        "keystore locked (" & path & "): " & e.msg & ". The passphrase " &
        "MUSTER_KEY_PASSPHRASE=\"" & pass & "\" does not match this keyfile. " &
        "For a dev/demo peer, delete the file to re-mint a fresh identity " &
        "(scripts/demo-peer.sh … --isolate --fresh does this for you); otherwise " &
        "set the passphrase this keyfile was created with.")
    loadSettingsFile()      # infra settings live beside the identity — load them once
  gKeystore

proc myAddress(): Address = moduleKeystore().address()
  ## This instance's own secp account — its public authorization identity, and (once
  ## added to a room Safe's owner set) the owner it signs Safe intents in-app as.

# ── the address book (aliases for member ids) ───────────────────────────────────
# A persisted map from a room-membership id (the 64-byte encryption identity) to an
# alias + optional secp address, so members / pending / the composer / a decision's
# provenance show names, not raw hex. Beside the keystore, so it survives restarts
# (contacts.nim). Defined here — before the intent projection that resolves aliases.
var gContacts: ContactBook = nil

proc seedDemoContacts(book: ContactBook) =
  ## Pre-seed the OTHER demo roles as named contacts (alias + secp address), so the
  ## recorded demo needs no on-camera "add contact" step (exo-1fc). Only when this
  ## instance is itself a seeded demo peer (MUSTER_DEV_SECP_KEY set); never clobbers a
  ## contact the user has already named. Each id is derived on the fly from a public
  ## anvil key, so nothing needs precomputing and it works across machines.
  let devKey = getEnv("MUSTER_DEV_SECP_KEY")
  if devKey.len == 0: return
  let mine = normId(devKey)
  for r in DemoRoles:
    if normId(r[0]) == mine: continue           # not myself
    let ss = hexSeed32(r[0])
    if ss.len != 32: continue
    let chatId = demoChatIdOf(ss)
    if book.aliasOf(chatId).len > 0: continue    # the user already named this id — keep it
    book.add(chatId, r[1], toHex(addressOf(toArr32(ss))))

proc contactBook(): ContactBook =
  if gContacts == nil:
    var dir = context().instancePersistencePath
    if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
    gContacts = newContactBook(dir / "contacts.json")
    seedDemoContacts(gContacts)
  gContacts

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

proc safeProtocolVersion(): string =
  ## The logos-protocol ABI version, read defensively. describe() runs at
  ## context-ready — BEFORE any coordinate_join has initialized the lp/delivery
  ## library — so this FFI can return nil or raise then. It is informational only,
  ## and must never decide whether the account loads (a nil/raise here used to blank
  ## the whole SAFE ACCOUNT card as "not loaded"). Fall back to "unknown".
  try:
    let v = lp_protocol_version()
    if v.isNil: "unknown" else: $v
  except CatchableError:
    "unknown"

proc musterDescribe(): string =
  ## The LOCAL TEST SAFE (the anvil fixture) — offered as a SUGGESTION a member may
  ## disclose into a room (coordinate_disclose_account), and the account of the older
  ## single-instance lifecycle path. It is not "the room's account": accounts live in
  ## the room, disclosed by members (exo-a50.1.3). `family` + `chain` (CAIP-2) make the
  ## suggestion disclosable as-is.
  var owners = newJArray()
  for o in gDevSafe.owners: owners.add %toHex(o)
  $(%*{
    "chainId": gDevSafe.chainId.int,
    "safe": SAFE_ADDR,
    "threshold": gDevSafe.threshold,
    "owners": owners,
    "environment": "eip155:" & $gDevSafe.chainId.int,
    "family": "evm.safe",
    "chain": "eip155:" & $gDevSafe.chainId.int,
    "label": "Local test Safe (anvil)",
    "suggestion": true,
    "protocol": safeProtocolVersion()   # the logos-protocol ABI this module speaks
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
  var it = newIntent(gDevSafe, effect, ctx)   # canonicalize dispatches to Safe (EIP-712 safeTxHash + pendingHash)
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = it.materialization.bytes[i]
  gHashes[id] = h
  gEffects[id] = effect
  it.apply(gDevSafe, IntentEvent(kind: iePropose, now: gNow))
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
  gDevSafe.pendingHash = gHashes[intentId]                 # verify against THIS intent's hash
  let sig65 = toSig65(hexToBytes(signatureHex))
  if not recoversToOwner(gHashes[intentId], sig65, gDevSafe.owners):
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
  it.apply(gDevSafe, IntentEvent(kind: ieContribute, now: gNow,
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
  let calldata = assembleExecTransaction(tx, sigbytes)   # the real ten-argument Safe ABI (exo-a50.1.4)
  let txHash = submitExecTransaction(gRpcUrl, toAddr(OWNER0), gDevSafe.safe, calldata)
  inc gNow
  it.apply(gDevSafe, IntentEvent(kind: ieSubmit, now: gNow))    # executable -> submitted
  gIntents[intentId] = it

  # Observe finality from the chain.
  var status = -1
  for _ in 0 .. 50:
    status = watchReceiptStatus(gRpcUrl, txHash)
    if status >= 0: break
    sleep(200)
  if status == 1:
    inc gNow
    it.apply(gDevSafe, IntentEvent(kind: ieFinal, now: gNow))   # submitted -> final
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

proc currentRoster(): seq[Ed25519Pub] =
  ## The room-native signer set: every current member's Ed25519 key (from the
  ## membership fold), including this instance. Falls back to just our own identity
  ## when no room is joined yet, so a driver is always well-formed. (forward-declared
  ## above driverForKind, which reads it.)
  if gSession != nil:
    for m in gSession.members(): result.add m.ed
  if result.len == 0:
    result.add moduleKeystore().encIdentity().ed

proc roomAccounts(): seq[RoomAccount] =
  ## The accounts members have disclosed into the joined room, folded from its log
  ## (coordination/accounts.nim, exo-a50.1.3). None without a room. (Forward-declared
  ## above driverForKind, which resolves account-bound policies against it.)
  if gSession == nil: return @[]
  reduceAccounts(gSession.log.allEvents())

var gMsgSeq: uint64 = 0     ## per-instance monotonic nonce, disambiguates identical posts

proc toContentTopic(t: string): string =
  ## Waku autosharding requires a 4-segment content topic — /app/version/name/encoding
  ## — to hash a room onto a shard and route it over the fleet. Room topics arrive in
  ## many shapes (the composer's dot form `muster.pay.abc`, a bare name a user types, a
  ## 3-segment path), none of which shard, so nothing crosses. Map any of them to a
  ## valid content topic deterministically, so two peers naming the same room derive
  ## the identical topic. An already-valid 4-part topic is passed through.
  if t.len > 0 and t[0] == '/':
    let parts = t.split('/')            # a valid one splits to ["", app, ver, name, enc]
    if parts.len == 5 and parts[1].len > 0 and parts[2].len > 0 and
       parts[3].len > 0 and parts[4].len > 0:
      return t
  var name = t.strip(chars = {'/'}).replace("/", ".")
  if name.len == 0: name = "room"
  "/muster/1/" & name & "/proto"

# ── cleared invites (dismissed OR joined) — persisted so they don't re-appear ───
var gDismissedInvites = initHashSet[string]()  ## invite room-topics (normalized content topic) never to re-show
var gDismissedLoaded = false
var gInvitesSince = -1'i64                      ## MUSTER_INVITES_SINCE: hide invites older than this epoch-sec (demo --fresh)

proc invitesSince(): int64 =
  ## An optional age floor for shown invites (epoch seconds), from MUSTER_INVITES_SINCE.
  ## demo-peer.sh --fresh sets it so a wiped peer doesn't re-surface the invite pile the
  ## store retains from earlier test runs (--fresh clears the local dismissed set, and
  ## the store keeps every invite). Unset / 0 ⇒ no age filter (the normal path).
  if gInvitesSince == -1:
    gInvitesSince = 0
    let e = getEnv("MUSTER_INVITES_SINCE")
    if e.len > 0:
      try: gInvitesSince = parseBiggestInt(e) except CatchableError: gInvitesSince = 0
  gInvitesSince

proc dismissedInvitesPath(): string =
  var dir = context().instancePersistencePath
  if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
  dir / "dismissed_invites.json"

proc loadDismissedInvites() =
  ## Load the cleared-invite set from disk once, so a dismissal (or a join) sticks across
  ## restarts — otherwise the store re-delivers the same invite on every launch.
  if gDismissedLoaded: return
  gDismissedLoaded = true
  try:
    let p = dismissedInvitesPath()
    if fileExists(p):
      let j = parseJson(readFile(p))
      if j.kind == JArray:
        for x in j: gDismissedInvites.incl x.getStr()
  except CatchableError: discard

proc clearInvite(ctopic: string) =
  ## Mark a room's invite handled (dismissed or joined) and persist beside the keystore.
  loadDismissedInvites()
  gDismissedInvites.incl ctopic
  try:
    let p = dismissedInvitesPath()
    createDir(parentDir(p))
    var arr = newJArray()
    for t in gDismissedInvites: arr.add %t
    writeFile(p, $arr)
  except CatchableError: discard

proc musterCoordinateJoin(topic: string): string =
  let ks = moduleKeystore()
  # Normalize to a valid Waku content topic so the room actually shards + routes over
  # the fleet (a bare/dotted/3-part topic silently goes nowhere). Both peers derive the
  # same one, so they meet. The normalized topic is the room's identity everywhere.
  let ctopic = toContentTopic(topic)
  if ctopic in gSessions:
    gSession = gSessions[ctopic]          # re-activate an already-joined room
  else:
    gSession = newCoordinationSession(newDeliveryTransport(gDeliveryConfig), newEpochCrypto(ks), ctopic)
    gSessions[ctopic] = gSession
  gTopic = ctopic
  # Joining a room clears any invite to it, permanently (persisted): you're in it now,
  # so it should never show as a pending invitation again, this session or after a restart.
  clearInvite(ctopic)
  # Policy is per-intent now, declared in the log at propose time — so join no longer
  # overrides this instance's compose default. It keeps whatever policy the user last
  # picked for the next thing they propose here.
  $(%*{"address": toHex(ks.address()), "topic": ctopic})

# ── the identity inbox: room invites without prior coordination (exo-3f0/A) ──────
# A room topic is undiscoverable to someone who wasn't told it — so "Start something
# with Bob" used to reach Bob only if he independently joined the same name. The inbox
# fixes that: each identity has a deterministic topic derived from its chat id that it
# listens on always. An invite is a small payload (the real room topic + who sent it)
# SEALED to the recipient's X25519 (a sealed box, no shared epoch needed) and dropped
# there; the owner opens it with its keystore. Anyone may drop; only the owner reads.
var gInbox: CoordinationSession = nil          ## this instance's own inbox session
var gInboxTopics = initHashSet[string]()       ## content topics that are inboxes (kept out of the room list)

proc inboxTopicFor(chatIdHex: string): string =
  ## A per-identity inbox content topic, derived from the chat id — deterministic, so a
  ## sender reaches a recipient's inbox with no prior contact. Domain-separated hash so
  ## it isn't the chat id in the clear on the wire.
  let id = normId(chatIdHex)
  var buf: seq[byte] = @[]
  for c in "muster-inbox-v1": buf.add byte(c)
  for c in id: buf.add byte(c)
  let h = sha256(buf)
  const d = "0123456789abcdef"
  var hx = ""
  for i in 0 ..< 8: (hx.add d[int(h[i] shr 4)]; hx.add d[int(h[i] and 0x0f)])
  toContentTopic("muster.inbox." & hx)

proc inboxSessionFor(ctopic: string): CoordinationSession =
  ## Get/create a session on an inbox topic. Tracked in gSessions (so it shares the one
  ## delivery node) but flagged an inbox, so coordinate_conversations never lists it as
  ## a room. Epoch crypto rides along unused — invites are sealed to a pubkey, not the epoch.
  gInboxTopics.incl ctopic
  if ctopic in gSessions: return gSessions[ctopic]
  let s = newCoordinationSession(newDeliveryTransport(gDeliveryConfig), newEpochCrypto(moduleKeystore()), ctopic)
  gSessions[ctopic] = s
  s

proc musterCoordinateStartInbox(): string =
  ## Begin listening on THIS identity's inbox so invites arrive even before any room is
  ## joined. Idempotent; the UI calls it once at startup. Pulls any invites left while away.
  let ks = moduleKeystore()
  let myChat = toHex(ks.encIdentity().toBytes())
  let ctopic = inboxTopicFor(myChat)
  gInbox = inboxSessionFor(ctopic)
  try: gInbox.catchUp()
  except CatchableError: discard
  $(%*{"inbox": ctopic})

proc musterCoordinateInvite(peerChatIdHex, roomTopic, note: string): string =
  ## Invite a peer (by their 64-byte chat id) to a room: seal {topic, from, note, ts} to
  ## their X25519 and drop it on their inbox topic. They need not be online — the store
  ## retains it. Returns {ok, inbox} or {error}. This is the ONLY new authority-free
  ## reach-out; it discloses only the room topic, and only to the named recipient.
  let ks = moduleKeystore()
  let peerId = normId(peerChatIdHex)
  let peerBytes = hexToBytes(peerId)
  if peerBytes.len != 64: return $(%*{"error": "bad peer chat id (need 64-byte ed25519++x25519 hex)"})
  let peerEnc = encIdentityFromBytes(peerBytes)
  let myChat = toHex(ks.encIdentity().toBytes())
  let payload = $(%*{"topic": roomTopic, "from": myChat, "note": note, "ts": int64(epochTime())})
  var pt: seq[byte] = @[]
  for c in payload: pt.add byte(c)
  let sealed = sealTo(peerEnc.x, pt)
  let ctopic = inboxTopicFor(peerChatIdHex)
  let s = inboxSessionFor(ctopic)
  s.sendInvite(sealed)
  $(%*{"ok": true, "inbox": ctopic})

proc musterCoordinateInvites(): string =
  ## The room invites this identity has received, newest-first, as [{topic, from,
  ## fromAlias, note, ts}]. Each is sealed to us; ones we can't open (not ours, or
  ## malformed) are skipped. Deduped by (from, topic). Empty until start_inbox is called.
  if gInbox == nil: return "[]"
  gInbox.poll()
  loadDismissedInvites()
  let ks = moduleKeystore()
  var seen = initHashSet[string]()
  var items: seq[JsonNode] = @[]
  for raw in gInbox.receivedInvites():
    try:
      let opened = ks.sealOpen(raw)
      var s = ""
      for b in opened: s.add char(b)
      let j = parseJson(s)
      let topic = j{"topic"}.getStr()
      let frm = j{"from"}.getStr()
      if topic.len == 0 or frm.len == 0: continue
      let ctopic = toContentTopic(topic)
      let ts = j{"ts"}.getBiggestInt(0)
      # Drop invites the user has cleared, ones for a room we've already joined (you're
      # in it), and — on a --fresh demo peer — ones older than the age floor (the store
      # re-delivers the whole pile every launch; this is how --fresh "wipes" them).
      if ctopic in gDismissedInvites: continue
      if ctopic in gSessions and ctopic notin gInboxTopics: continue
      let since = invitesSince()
      if since > 0 and ts > 0 and ts < since: continue
      let key = normId(frm) & "|" & topic
      if key in seen: continue
      seen.incl key
      items.add %*{"topic": topic, "from": frm,
                   "fromAlias": contactBook().aliasOf(frm),
                   "note": j{"note"}.getStr(), "ts": ts}
    except CatchableError: discard      # not for us / malformed — not an invite we hold
  items.reverse()                        # newest first
  var arr = newJArray()
  for n in items: arr.add n
  $arr

proc musterCoordinateDismissInvite(roomTopic: string): string =
  ## Clear a received invite so it stops showing (the user isn't joining that room).
  ## Keyed by the normalized content topic, so it matches however the topic was phrased.
  ## Persisted beside the keystore, so a dismissal sticks across restarts.
  clearInvite(toContentTopic(roomTopic))
  "ok"

proc policyJson(): JsonNode =
  ## The compose default: the full policy (qualified with its account for an account-
  ## bound kind), its kind, the account (CAIP-10, "" for a room kind), and its driver's
  ## threshold + domain.
  let d = driverForKind(gCoordKind).describe()
  let (kind, acct) = splitPolicy(gCoordKind)
  %*{"policy": gCoordKind, "kind": kind, "account": acct, "threshold": d.threshold,
     "domain": d.serializationDomain}

proc roomKinds(): seq[string] =
  ## The driver kinds the joined room may use (driver-as-proposal). Folded from the
  ## room's log; falls back to the founding set when no room is joined.
  if gSession == nil: return foundingKinds()
  roomDriverKinds(gSession.log.allEvents(), driverFor)

proc musterCoordinateDrivers(): string =
  ## Every driver kind this client has — the one list (drivers/kinds.nim) — each with
  ## its family, label, the proposals it serves, and whether the joined room has
  ## admitted it (folded from the shared log, invariant 6). The composer's picker is
  ## drawn from this, so the UI names no kind of its own (exo-a50.1.2).
  $kindsJson(roomKinds())

# ── the LEZ multisig, live (exo-3c9) ──────────────────────────────────────────
# A member's LEZ accounts are keystore-derived, one per slot label "lez-member/<i>", so
# which ones are ours is recomputed from keys, never stored (invariant 4).
const LezMemberSlots = 64

proc lezMemberLabel(i: int): string = "lez-member/" & $i

proc lezHx(b: openArray[byte]): string =
  for x in b: result.add toLowerAscii(toHex(x, 2))

proc lezLiveFor(chain: string, scheme: PdaScheme, program: seq[byte], layout: ProposalLayout): LezMultisigLive =
  newLezMultisigLive(newLezRpc(gLezRpc), moduleKeystore(), chain, scheme, program, layout,
                     blockMs = 45_000, pollMs = 3_000)

proc lezLiveOf(a: LezMultisigAccount): LezMultisigLive = lezLiveFor(a.chain, a.scheme, a.program, a.layout)

proc lezOurMember(c: LezMultisigLive, members: seq[seq[byte]]): tuple[found: bool, account: seq[byte]] =
  ## The first of this keystore's member accounts that is one of `members`, registered
  ## with the chain so it can sign for it.
  let ks = moduleKeystore()
  for i in 0 ..< LezMemberSlots:
    let id = publicAccountId(ks.lezMemberKey(lezMemberLabel(i)))
    if id in members:
      discard c.addMember(lezMemberLabel(i))
      return (true, id)
  (false, @[])

proc lezIdOf(s: string): seq[byte] =
  ## An account id given as hex (64, optional 0x) or base58; raises ValueError.
  var h = s.strip()
  if h.startsWith("0x"): h = h[2 .. ^1]
  if h.len == 64 and h.allCharsInSet(HexDigits):
    for i in 0 ..< 32: result.add byte(parseHexInt(h[2*i .. 2*i+1]))
    return
  accountIdFromBase58(s.strip())

# A hosted call must not wait on a block (a UI call times out at 20s; a testnet block is
# ~40s). So a LEZ step SENDS and returns, and completes on a later tick once the chain
# includes it (coordination/vote.nim). coordinate_intents drives the pump. Nothing is
# published before the chain has it: no intent before the proposal, no receipt before
# the vote, nothing final before Executed.
type
  LezPendingKind = enum lpCreate = "create", lpPropose = "propose", lpVote = "vote", lpSettle = "settle"
  LezPending = object
    kind: LezPendingKind
    session: CoordinationSession  ## the room the step belongs to; it completes only there
    seam: LezVoteSeam
    propose: PendingPropose
    vote: PendingVote
    settle: Settlement
    txRef: TxRef
    intentId: string
    created: JsonNode              ## a create's disclosure, published once the state is on chain
    started: float

const LezPendingDeadlineS = 600.0
var gLezPending: seq[LezPending]
var gLezRecent: seq[JsonNode]    ## the last outcomes, newest last (lez_pending)
var gLezPumpAt = 0.0

proc lezRecord(p: LezPending, outcome: string) =
  gLezRecent.add %*{"kind": $p.kind, "intentId": p.intentId, "index": p.propose.index,
                    "outcome": outcome, "at": int64(epochTime())}
  if gLezRecent.len > 20: gLezRecent.delete(0)

proc lezPump() =
  ## Complete what the chain has included since the last tick; at most every 2s, one or
  ## two quick reads per step. A step still not included after 10 minutes is dropped.
  if gLezPending.len == 0 or epochTime() - gLezPumpAt < 2.0: return
  gLezPumpAt = epochTime()
  var keep: seq[LezPending]
  for p in gLezPending:
    if p.session != gSession:          # it completes in its own room, when that is joined
      keep.add p
      continue
    var outcome = ""
    try:
      case p.kind
      of lpCreate:
        let r = musterCoordinateDiscloseAccount($p.created)
        let j = parseJson(r)
        if not j.hasKey("error"): outcome = "disclosed " & j{"id"}.getStr()
        elif j{"error"}.getStr() != "cannot read the multisig from the chain": outcome = "not disclosed: " & r
      of lpPropose:
        let r = liveProposeOnChainComplete(p.session, moduleKeystore(), driverFor, p.seam, p.propose)
        if r != "pending": outcome = r
      of lpVote:
        let r = liveVoteComplete(p.session, moduleKeystore(), driverFor, p.seam, p.vote)
        if not r.startsWith("unconfirmed"): outcome = r
      of lpSettle:
        let f = p.settle.watch(p.txRef)
        if f.status == fsFinal:
          p.session.publish(finalEvent(p.intentId, chainRef = p.txRef.id))
          outcome = "final"
        elif f.status == fsFailed: outcome = "failed: " & f.detail
    except CatchableError:
      discard                          # an unreachable sequencer: try again next tick
    if outcome.len == 0 and epochTime() - p.started > LezPendingDeadlineS:
      outcome = "timed out: the chain did not include it"
    if outcome.len == 0: keep.add p
    else: lezRecord(p, outcome)
  gLezPending = keep

proc lezPendingFor(intentId: string): string =
  for p in gLezPending:
    if p.intentId == intentId and p.kind in {lpVote, lpSettle}: return $p.kind
  ""

# FROST (Phase D): a joined ceremony advances, and an approved intent's round 2 follows,
# on the coordinate_intents tick, so a member acts once and nothing waits in a hosted call.
var gFrostJoined: seq[(CoordinationSession, string)]   ## (room, ceremony id) this member joined
var gFrostLast = initTable[string, string]()           ## ceremony id → this member's last step outcome
var gFrostAuto: seq[string]                            ## intents this member approved (round 2 follows)
var gFrostPumpAt = 0.0

proc frostPump() =
  if gSession == nil or epochTime() - gFrostPumpAt < 2.0: return
  gFrostPumpAt = epochTime()
  let ks = moduleKeystore()
  var keep: seq[(CoordinationSession, string)]
  for (s, cid) in gFrostJoined:
    if s != gSession:
      keep.add (s, cid)
      continue
    let r = frostCeremonyStep(s, ks, cid)
    gFrostLast[cid] = r
    if not (r.startsWith("done") or r.startsWith("refused") or r == "not-a-participant"): keep.add (s, cid)
  gFrostJoined = keep
  var auto: seq[string]
  for id in gFrostAuto:
    let r = liveFrostContribute(gSession, ks, driverFor, id, uint64(epochTime()))
    if r == "collecting" or r.startsWith("waiting") or r == "already-contributed":
      let folded = reduceIntents(gSession.log.allEvents(), driverFor)
      if id in folded and not folded[id].collection.complete: auto.add id
  gFrostAuto = auto

proc lezChainViewOf(a: RoomAccount): ChainView =
  if a.chain != gLezChain:
    return (known: false, signers: @[], threshold: 0,
            detail: "the configured LEZ sequencer serves " & gLezChain & ", the account is on " & a.chain)
  let (_, acct, detail) = lezMultisigAccountOf(a)
  if acct.statePda.len == 0: return (known: false, signers: @[], threshold: 0, detail: detail)
  try: lezChainView(lezLiveOf(acct), a)
  except CatchableError as e:
    (known: false, signers: @[], threshold: 0, detail: "the LEZ sequencer: " & e.msg)

proc chainViewOf(a: RoomAccount): ChainView =
  ## Read an account from the chain through the user's RPC, for checking a disclosure
  ## (an external read, invariant 10). Only when the RPC serves the account's chain —
  ## reading a Base Safe through an anvil node would answer the wrong question.
  if a.family == LezMultisigFamily: return lezChainViewOf(a)
  if a.family != "evm.safe": return (known: false, signers: @[], threshold: 0,
                                     detail: "no chain read for a " & a.family & " account yet")
  if gRpcUrl.len == 0: return (known: false, signers: @[], threshold: 0, detail: "no RPC configured")
  let (ok, chain, pd) = probeRpc(gRpcUrl)
  if not ok: return (known: false, signers: @[], threshold: 0, detail: "RPC unreachable: " & pd)
  if "eip155:" & $chain != a.chain:
    return (known: false, signers: @[], threshold: 0,
            detail: "the configured RPC serves eip155:" & $chain & ", the account is on " & a.chain)
  let owners = getOwners(gRpcUrl, toAddress(a.address))
  if not owners.known: return (known: false, signers: @[], threshold: 0, detail: owners.detail)
  let thr = getThreshold(gRpcUrl, toAddress(a.address))
  if not thr.known: return (known: false, signers: @[], threshold: 0, detail: thr.detail)
  (known: true, signers: owners.owners.mapIt(toHex(it)), threshold: thr.threshold, detail: "read from chain")

var gBypassCache = initTable[string, tuple[known: bool, list: seq[string]]]()
  ## account id → the ways around its threshold as last read from the chain (exo-a50.1.6)

proc bypassesOf(a: RoomAccount): JsonNode =
  if a.family.startsWith("btc."):
    # a Bitcoin script has no module, guard or admin: nothing gets around k of n
    return %*{"known": true, "modules": [], "guard": "", "detail": "a script has no way around it"}
  ## {known, modules:[addr], guard, detail} for a Safe, read through the user's RPC on
  ## the account's own chain. A module can move funds with NO owner signature; a guard
  ## can block a transaction the owners agreed to — both belong on the card.
  result = %*{"known": false, "modules": [], "guard": "", "detail": ""}
  if a.family != "evm.safe": (result["detail"] = %"no bypass read for this family yet"; return)
  if gRpcUrl.len == 0: (result["detail"] = %"no RPC configured"; return)
  let (ok, chain, pd) = probeRpc(gRpcUrl)
  if not ok: (result["detail"] = %("RPC unreachable: " & pd); return)
  if "eip155:" & $chain != a.chain:
    result["detail"] = %("the configured RPC serves eip155:" & $chain & ", the account is on " & a.chain)
    return
  let m = getModules(gRpcUrl, toAddress(a.address))
  let g = getGuard(gRpcUrl, toAddress(a.address))
  if not m.known or not g.known:
    result["detail"] = %(if not m.known: m.detail else: g.detail)
    return
  var mods = newJArray()
  var list: seq[string]
  for x in m.modules:
    mods.add %toHex(x)
    list.add "module " & toHex(x) & " can execute without the owners"
  if g.guard.len > 0: list.add "guard " & g.guard & " can block what the owners agree to"
  gBypassCache[a.id] = (known: true, list: list)
  result = %*{"known": true, "modules": mods, "guard": g.guard, "detail": "read from chain"}

proc musterCoordinateAccounts(): string =
  ## The accounts members have disclosed into the joined room (exo-a50.1.3), each with
  ## who disclosed it, whether disclosures disagree, and whether the CHAIN agrees with
  ## the disclosure: verified / disagrees (naming what differs) / unknown (why). The
  ## chain read goes through the user's RPC; a failed read is unknown, never verified.
  if gSession == nil: return "[]"
  gSession.poll()
  let accts = roomAccounts()
  var arr = accountsJson(accts)
  for i, a in accts:
    # a Bitcoin disclosure is checked by re-deriving its address from the keys (the
    # address commits to the policy — no chain read); an EVM one against the chain
    let (st, detail) = (if a.family.startsWith("btc."): btcDisclosureCheck(a)
                        else: checkAccount(a, chainViewOf(a)))
    arr[i]["check"] = %*{"status": $st, "detail": detail}
    # The ways around the threshold, READ from the chain (exo-a50.1.4): a Safe's enabled
    # modules execute without the owners, and a guard can veto. Unknown when unread —
    # never reported as "none".
    arr[i]["bypasses"] = bypassesOf(a)
    var names = newJArray()
    for d in a.disclosedBy: names.add %contactBook().aliasOf(d)
    arr[i]["disclosedByAlias"] = names
  $arr

proc musterCoordinateDiscloseAccount(accountJson: string): string =
  ## Disclose an account into the joined room, as this member (exo-a50.1.3). JSON
  ## {family, chain (CAIP-2), address, label, signers?, threshold?}. When signers or
  ## threshold are omitted they are read from the chain (and refused if unreadable —
  ## a disclosure never guesses). The disclosure names this member's encryption
  ## identity; every reader then checks it against the chain themselves.
  if gSession == nil: return $(%*{"error": "not-joined"})
  var a: RoomAccount
  try:
    let j = parseJson(accountJson)
    a = RoomAccount(family: j{"family"}.getStr("evm.safe"), chain: j{"chain"}.getStr(),
                    address: j{"address"}.getStr().toLowerAscii(), label: j{"label"}.getStr(),
                    threshold: j{"threshold"}.getInt(0))
    if j.hasKey("signers") and j["signers"].kind == JArray:
      for x in j["signers"]: a.signers.add x.getStr().toLowerAscii()
    if j.hasKey("config"):
      a.config = (if j["config"].kind == JString: j["config"].getStr() else: $j["config"])
  except CatchableError as e:
    return $(%*{"error": "not an account: " & e.msg})
  if a.family == LezMultisigFamily:
    # a LEZ multisig (exo-3c9): the address is the state PDA its config derives, and its
    # members and threshold are what the CHAIN holds at that PDA, never taken on trust
    if a.config.len == 0:
      return $(%*{"error": "a LEZ multisig account needs its config {program, createKey, pda, layout}"})
    if a.chain.len == 0: a.chain = gLezChain
    let (_, acct0, detail0) = lezMultisigAccountOf(a)
    if acct0.statePda.len == 0: return $(%*{"error": "not a LEZ multisig account", "detail": detail0})
    if a.address.len == 0: a.address = lezHx(acct0.statePda)
    let v = lezChainViewOf(a)
    if not v.known:
      return $(%*{"error": "cannot read the multisig from the chain", "detail": v.detail})
    if a.signers.len > 0 and (a.signers != v.signers or (a.threshold > 0 and a.threshold != v.threshold)):
      return $(%*{"error": "the chain disagrees with the given members or threshold", "detail": v.detail})
    a.signers = v.signers
    a.threshold = v.threshold
    let (ok, _, detail) = lezMultisigAccountOf(a)
    if not ok: return $(%*{"error": "the LEZ multisig account does not check out", "detail": detail})
    let me = toHex(moduleKeystore().encIdentity().toBytes())
    gSession.publish(accountDiscloseEvent(a, me))
    let (_, disclosed) = findAccount(roomAccounts(), accountId(a.chain, a.address))
    return $accountsJson(@[disclosed])[0]
  if a.family.startsWith("btc."):
    # a Bitcoin account (exo-a50.2.3): k of n compressed keys; its address is DERIVED from
    # them (so it may be omitted) and a given one must match — never taken on trust
    if a.signers.len == 0 or a.threshold <= 0:
      return $(%*{"error": "a Bitcoin account needs its signers (33-byte keys) and threshold"})
    var btcAddr = a.address
    if btcAddr.len == 0:
      try:
        btcAddr = btcAccount(a.family, networkByCaip2(a.chain).name, a.threshold,
                          a.signers.mapIt(hexToBytes(it))).address
      except CatchableError as e:
        return $(%*{"error": "not a valid Bitcoin account: " & e.msg})
    let (ok, _, detail) = btcAccountOfDisclosure(a.family, a.chain, btcAddr, a.threshold, a.signers)
    if not ok: return $(%*{"error": "the Bitcoin account does not check out", "detail": detail})
    a.address = btcAddr
    let me = toHex(moduleKeystore().encIdentity().toBytes())
    gSession.publish(accountDiscloseEvent(a, me))
    let (_, disclosed) = findAccount(roomAccounts(), accountId(a.chain, a.address))
    return $accountsJson(@[disclosed])[0]
  if a.family != "evm.safe":
    return $(%*{"error": "unsupported account family: " & a.family,
                "detail": "this client holds evm.safe, btc.* and lez.multisig-program accounts"})
  let (isEvm, _) = evmChainId(a.chain)
  if not isEvm or a.address.len != 42 or not a.address.startsWith("0x"):
    return $(%*{"error": "an evm.safe account needs an eip155:<id> chain and a 0x address"})
  if a.signers.len == 0 or a.threshold <= 0:
    let v = chainViewOf(a)
    if not v.known:
      return $(%*{"error": "cannot read the account's signers from the chain — pass them explicitly",
                  "detail": v.detail})
    a.signers = v.signers.mapIt(it.toLowerAscii())
    a.threshold = v.threshold
  if a.threshold > a.signers.len:
    return $(%*{"error": "threshold " & $a.threshold & " exceeds " & $a.signers.len & " signers"})
  let me = toHex(moduleKeystore().encIdentity().toBytes())
  gSession.publish(accountDiscloseEvent(a, me))
  let (_, disclosed) = findAccount(roomAccounts(), accountId(a.chain, a.address))
  $accountsJson(@[disclosed])[0]

proc musterCoordinateSetPolicy(kind: string): string =
  ## Choose the COMPOSE DEFAULT policy — the driver the next intent you propose runs
  ## on. "safe" is the EIP-712 Safe above; "threshold" is a k-of-n Ed25519 endorsement
  ## over a demo roster — nothing like Safe (no secp, no chain), yet the same
  ## propose/contribute/fold path. Policy is a property of each intent (declared in the
  ## log when you propose), so this is a local default, never a room-wide event — an
  ## intent already collecting signatures keeps the policy it was proposed under.
  ## The kind must be one the room has ADMITTED (driver-as-proposal): the founding set,
  ## or a kind a passed add-driver proposal granted (roomDriverKinds).
  ##
  ## An account-bound kind ("safe", "eip191") acts FROM an account a member disclosed
  ## into this room (exo-a50.1.3): pass "safe@<CAIP-10>" to choose it, or the bare kind
  ## when the room holds exactly one account of a family the kind can use. None →
  ## {error: no-account}; several → {error: choose-account, accounts}. Never a guess.
  let (k, acct) = splitPolicy(kind)
  if k notin roomKinds():
    return $(%*{"error": "policy not admitted in this room: " & k,
                "admitted": roomKinds()})
  if not kindNeedsAccount(k):
    if acct.len > 0:
      return $(%*{"error": "a " & k & " policy acts from no account", "kind": k})
    gCoordKind = k
    return $policyJson()
  let fams = kindInfo(k).accountFamilies
  var candidates: seq[RoomAccount]
  for a in roomAccounts():
    if a.family in fams: candidates.add a
  var target = acct
  if target.len == 0:
    if candidates.len == 0:
      return $(%*{"error": "no-account", "kind": k, "families": fams,
                  "detail": "no member has disclosed an account this policy can act from — disclose one into the room first"})
    if candidates.len > 1:
      return $(%*{"error": "choose-account", "kind": k, "accounts": accountsJson(candidates)})
    target = candidates[0].id
  elif not candidates.anyIt(it.id == target.toLowerAscii()):
    return $(%*{"error": "account not disclosed in this room: " & target, "kind": k})
  gCoordKind = qualify(k, target.toLowerAscii())
  $policyJson()

proc musterCoordinatePolicy(): string =
  ## This instance's compose default — {policy, threshold, domain}.
  $policyJson()

proc musterCoordinatePropose(effectJson: string): string =
  ## The live propose path lives in coordination/live.nim (exo-ef1) so it can be
  ## driven in-process; this is plumbing over the module's session + keystore.
  if gSession == nil: return "not-joined"
  inc gMsgSeq
  # The context every approval binds to (invariant 2, exo-ef1): a Safe intent is bound
  # to the Safe; a room-native decision to this room. MUSTER_INTENT_TTL_S overrides
  # how long the proposal stays signable (default a week).
  let (pkind, pacct) = splitPolicy(gCoordKind)
  let account = (if (pkind == "safe" or pkind.startsWith("btc-")) and pacct.len > 0:
                    splitAccountId(pacct).address else: gTopic)
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  liveProposeIntent(gSession, moduleKeystore(), driverFor, gCoordKind, effectJson,
                    int64(epochTime()), gMsgSeq, account = account, ttlSec = ttl)

proc musterCoordinateReannounce(): string =
  ## Re-publish every still-open intent into the CURRENT epoch for a just-admitted
  ## member — the live path lives in coordination/live.nim (exo-ef1/exo-403).
  if gSession == nil: return "not-joined"
  let n = liveReannounce(gSession, moduleKeystore(), driverFor, int64(epochTime()), gMsgSeq)
  $(%*{"reannounced": n})

proc intentLinkContext(intentId: string): LinkContext =
  ## The context our key binding is scoped to — THIS intent's account (the Safe it acts
  ## from, or the room), valid for a day. Wall-clock expiry is fine here: a binding is an
  ## admission-time credential, not a signing-path artifact (it never touches the
  ## deterministic log). Per intent, so two accounts in one room never share a binding.
  var account = gTopic
  if gSession != nil:
    let ctx = intentContext(gSession.log.allEvents(), intentId)
    if not ctx.isPlaceholder and ctx.account.len > 0: account = ctx.account
  LinkContext(account: account, slot: "0", expiry: uint64(epochTime()) + 86_400)

proc musterCoordinateVote(intentId: string): string =
  ## Approve a vote-locus intent with this member's own on-chain vote (exo-3c9): S5
  ## re-read, the member's Approve signed by their LEZ key and awaited, confirmed on chain,
  ## then the receipt (coordination/vote.nim).
  if gSession == nil: return "not-joined"
  gSession.poll()
  let drv = driverFor(intentPolicyOf(gSession.log.allEvents(), intentId))
  if not (drv of LezMultisigDriver): return "not-a-vote-locus"
  let a = LezMultisigDriver(drv).account
  if lezPendingFor(intentId) == "vote": return "pending: your vote is on its way to the chain"
  try:
    let c = lezLiveOf(a)
    c.waitForInclusion = false         # never wait on a block inside a hosted call
    let (mine, me) = c.lezOurMember(a.members)
    if not mine: return "refused: none of your LEZ member accounts is a member of this multisig"
    let seam = newLezVoteSeam(c, me)
    let (outcome, pv) = liveVoteCast(gSession, moduleKeystore(), driverFor, intentId, seam,
                                     intentLinkContext(intentId), uint64(epochTime()))
    if outcome.len > 0: return outcome
    gLezPending.add LezPending(kind: lpVote, session: gSession, seam: seam, vote: pv, intentId: intentId,
                               started: epochTime())
    "pending: your vote is on its way to the chain (tx " & pv.tx & ")"
  except CatchableError as e:
    "refused: the LEZ sequencer: " & e.msg

proc musterCoordinateContribute(intentId: string, signatureHex: string, keyRef: string): string =
  ## Add a contribution (in-app signed when `signatureHex` is empty, else pasted). The
  ## live contribute path lives in coordination/live.nim (exo-ef1) so it can be driven
  ## in-process; this is plumbing over the module's session + keystore. A vote-locus
  ## intent is approved by the member's own chain vote instead (coordinate_vote).
  if gSession == nil: return "not-joined"
  if signatureHex.len == 0:
    let drv = driverFor(intentPolicyOf(gSession.log.allEvents(), intentId))
    if drv of LezMultisigDriver: return musterCoordinateVote(intentId)
    if drv of BtcFrostDriver:
      # a FROST approval is two rounds: this member's nonces now, its partial signature
      # under the log's signer set once round 1 closes (frostPump) — one approval, two halves
      let r = liveFrostContribute(gSession, moduleKeystore(), driverFor, intentId, uint64(epochTime()))
      if r in ["collecting", "executable"] or r.startsWith("waiting") or r == "already-contributed":
        if intentId notin gFrostAuto: gFrostAuto.add intentId
      return r
  liveContribute(gSession, moduleKeystore(), driverFor, intentId, signatureHex, keyRef,
                 intentLinkContext(intentId), uint64(epochTime()))

proc musterCoordinateIntents(): string =
  ## The room's proposals, folded from the shared log and projected to what a card
  ## renders: the lifecycle state, the effect it carries, the driver threshold, and
  ## the distinct-owner approval count. Backward compatible — id + state are still
  ## present; effect/threshold/approvals/rail are the render fields the room needs so
  ## its cards come from real state (reduce(log)) rather than posted demo JSON.
  if gSession == nil: return "[]"
  gSession.poll()
  lezPump()                            # complete any LEZ step the chain has since included
  frostPump()                          # advance joined FROST ceremonies and round 2
  let events = gSession.log.allEvents()
  var arr = newJArray()
  for v in reduceIntentViews(events, driverFor):
    # Each intent renders under ITS OWN driver — the policy it was proposed with
    # (v.policy) — so a room carrying a Safe intent and a threshold intent shows each
    # honestly at once (invariant 6). txhash is the driver-re-derived materialization —
    # the exact bytes a member signs (Safe's safeTxHash, or the threshold driver's
    # dCBOR materialization); threshold + domain come from describe(), never hardcoded.
    let drv = driverForKind(v.policy)
    let desc = drv.describe()
    var o = intentViewJson(v, desc)
    # n = how many could sign, so the card reads "M of N" honestly (e.g. 2 of 3), not
    # "threshold of threshold". It comes from the driver's family profile — never from
    # branching on the concrete driver type (exo-a50.1.1) — and the whole profile rides
    # along so the card's fixed rows can be drawn from it (exo-a50.1.6).
    var prof = drv.profile()
    o["n"] = %(if prof.n > 0: prof.n else: desc.threshold)
    # The ways around a Safe's threshold, as last READ from the chain (coordinate_accounts
    # caches them — no chain read on this 1s tick); unread stays unknown (exo-a50.1.6).
    if prof.account.len > 0 and prof.account in gBypassCache:
      let b = gBypassCache[prof.account]
      prof.bypassesKnown = b.known
      prof.bypasses = b.list
    o["profile"] = prof.toJson()
    # The card's fixed rows — the same ten questions for every family, answered from
    # the profile alone, each with its credibility (coordination/card_rows.nim).
    o["rows"] = cardRowsJson(cardRows(prof))
    let (vkind, vacct) = splitPolicy(v.policy)
    o["kind"] = %vkind
    o["accountId"] = %vacct            # CAIP-10 for an account-bound intent, "" for a room kind
    if prof.family == "evm.safe":
      # a Safe signature is bound to its EIP-712 domain (chainId + safe); surface it
      # so the verify view names exactly what the bytes are worthless outside of (F-5).
      o["rail"] = %"safe"
      let (_, cid) = evmChainId(prof.chain)
      o["chainId"] = %cid.int
      o["safe"] = %splitAccountId(prof.account).address
      o["environment"] = %prof.chain    # CAIP-2 — the chain the signatures are bound to
    else:
      o["rail"] = %vkind
    if v.effectJson.len > 0:
      try: o["effect"] = parseJson(v.effectJson)
      except CatchableError: discard
    # provenance: the decision's lineage (invariant 10) — every log entry that put
    # this intent in front of the reader, by class + position + (named) account, so
    # the UI can answer "how do I know this, and why trust it".
    var prov = newJArray()
    for item in intentProvenance(events, driverFor, v.id):
      # Resolve the contributing account to an address-book name, so the lineage reads
      # "Alice", not raw hex, when known — the alias is investigative, the raw account
      # stays for verification.
      let alias = (if item.account.len > 0: contactBook().aliasOf(item.account) else: "")
      prov.add %*{"class": $item.cls, "logPos": item.logPos,
                  "account": item.account, "alias": alias,
                  "accountable": item.accountable, "what": item.what,
                  "detail": item.detail, "guarantee": item.guarantee,
                  # an approval's grade (exo-ef1): committed | unattested; "" otherwise
                  "attestation": item.attestation}
    o["provenance"] = prov
    let chainPending = lezPendingFor(v.id)   # "vote" | "settle" while the chain has not included it
    if chainPending.len > 0: o["chainPending"] = %chainPending
    arr.add o
  $arr

proc musterCoordinateDecline(intentId: string): string =
  ## Decline to take part (the card's Deny). Keyed by THIS member's encryption identity
  ## (the same author id messages carry) so it folds once. Informational — the
  ## threshold is untouched; dropping is driver policy, not core policy.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  if effectJsonOf(events, intentId).len == 0:
    return $(%*{"error": "unknown-intent", "intentId": intentId})
  let who = toHex(moduleKeystore().encIdentity().toBytes())
  gSession.publish(declineEvent(intentId, who))
  let after = gSession.log.allEvents()
  var declines = 0
  for v in reduceIntentViews(after, driverFor):
    if v.id == intentId: declines = v.declines
  result = $(%*{"intentId": intentId, "state": intentState(after, driverFor, intentId), "declines": declines})
  if gLpDebug: stderr.writeLine("MUSTER-LP decline " & result)

proc moduleCatalogue(): seq[Material] =
  ## MY holdings as a local view (exo-45e K2): every authorization key (verified-local),
  ## an EVM receive address per key on the configured chain, and the configured Safe as
  ## declared authority (chain-verified by readiness, K3). No network here — enumerating
  ## adapter accounts is a follow-on. It never leaves the instance; only a chosen
  ## material's PUBLIC face is ever shared (coordinate_share_material).
  let ks = moduleKeystore()
  let chain = "evm:" & $gDevSafe.chainId   # the wallet's configured (dev) chain for receive addresses
  for r in ks.keyRefs():
    result.add Material(class: mcAuthority, chain: "", form: "secp256k1",
      handle: "keystore:secp:" & r, public: r, grade: mgVerifiedLocally, source: msKeystore)
    result.add Material(class: mcAddress, chain: chain, form: "public",
      handle: "keystore:addr:" & r, public: r, grade: mgVerifiedLocally, source: msKeystore)
  # the Safes disclosed into the joined room (exo-a50.1.3) — declared authority,
  # chain-verified by readiness (K3); never a module-global Safe
  for a in roomAccounts():
    if a.family != "evm.safe": continue
    let (_, cid) = evmChainId(a.chain)
    result.add Material(class: mcAuthority, chain: "evm:" & $cid, form: "safe-owner",
      handle: "safe:" & a.address, public: a.address, grade: mgDeclared, source: msConfigured)
  # the native asset you can send on this chain — so compose_offers returns an amount
  # candidate for the proposer to pick (the balance-bounded amount is exo-bf9). Declared
  # (attested by config, not a live balance read here); a failed read is never a zero.
  result.add Material(class: mcAsset, chain: chain, form: "native",
    handle: "asset:" & chain & ":ETH", public: "ETH", grade: mgDeclared, source: msConfigured)

proc musterCoordinateOffers(intentId: string): string =
  ## The card's "From you" section (exo-45e K4/K6): which of MY OWN holdings fill the
  ## slots this proposal asks of me (contributor + counterparty). Graded about me only —
  ## it reads only moduleCatalogue(), never another member's holdings (invariant 9, s3).
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let m = driverForKind(intentPolicyOf(events, intentId)).manifest(effectFromJson(effectJson))
  var o = offersPayload(recipientOffers(m.requirements, moduleCatalogue(), m))
  o["intentId"] = %intentId
  result = $o
  if gLpDebug: stderr.writeLine("MUSTER-LP offers " & result)

proc musterComposeOffers(effectJson: string): string =
  ## The composer's account step (F-18 step three): which of my holdings fill the PROPOSER
  ## slots of a DRAFT effect under the room's current compose policy (gCoordKind). Same
  ## payload shape as coordinate_offers, graded about me only.
  let effect = try: effectFromJson(effectJson)
               except CatchableError: return $(%*{"error": "bad effect json"})
  let m = driverForKind(gCoordKind).manifest(effect)
  result = $offersPayload(proposerOffers(m.requirements, moduleCatalogue(), m))
  if gLpDebug: stderr.writeLine("MUSTER-LP compose_offers " & result)

proc musterCoordinateShareMaterial(intentId, requirement, publicFace: string): string =
  ## Share one of MY holdings into a room intent to fill a slot it asks of me (exo-45e
  ## K5/K6): only its PUBLIC face, class and form are published (never a handle, s1),
  ## bound to the intent and the effect field the requirement lands in — the request-first
  ## path by which a complete effect gets its counterparty material. Keyed by this member
  ## (its encryption identity); folds once per (requirement, sharer).
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let m = driverForKind(intentPolicyOf(events, intentId)).manifest(effectFromJson(effectJson))
  # find the requirement this share fills → its effect field + material class.
  var field, class = ""
  for r in m.requirements:
    if r.name == requirement: (field = r.needs.field; class = $r.needs.class)
  if field.len == 0: return $(%*{"error": "no such counterparty/proposer requirement", "requirement": requirement})
  # confirm the chosen public is one of MY holdings for that class, and read its form.
  var form = ""
  var mine = false
  for mat in moduleCatalogue():
    if $mat.class == class and mat.public == publicFace: (form = mat.form; mine = true)
  if not mine: return $(%*{"error": "not one of your holdings for this slot", "public": publicFace})
  let who = toHex(moduleKeystore().encIdentity().toBytes())
  gSession.publish(materialShareEvent(intentId, requirement, who, publicFace, form, class, field))
  result = $(%*{"intentId": intentId, "requirement": requirement, "field": field, "public": publicFace})
  if gLpDebug: stderr.writeLine("MUSTER-LP share_material " & result)

proc musterCoordinateProvenance(): string =
  ## Provenance for EVERY action in the room (M4): the log's lineage, each entry
  ## classed by the F-20 vocabulary and graded by the guarantee the code enforces.
  if gSession == nil: return "[]"
  gSession.poll()
  var arr = newJArray()
  for it in logProvenance(gSession.log.allEvents(), driverFor):
    let alias = (if it.account.len > 0: contactBook().aliasOf(it.account) else: "")
    arr.add %*{"seq": it.seq, "class": $it.cls, "kind": it.kind, "intentId": it.intentId,
               "account": it.account, "alias": alias, "accountable": it.accountable,
               "what": it.what, "detail": it.detail, "guarantee": it.guarantee, "epoch": it.epoch}
  $arr

proc musterCoordinateProof(): string =
  ## An exportable, self-verifying proof of the room's log (M4). Epoch-scoped: the
  ## range is the founding epoch to the current one; only holders can read it.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  var epochTo = 0
  try: epochTo = gSession.epoch()
  except CatchableError: discard
  $buildProof(gSession.log.allEvents(), 0, epochTo).toJson()

proc musterCoordinateVerifyProof(proofJson: string): string =
  ## Refuse-on-mismatch verification of a log proof — pure, reads only the proof.
  var p: LogProof
  try: p = proofFromJson(parseJson(proofJson))
  except CatchableError as e:
    return $(%*{"ok": false, "reason": "not a proof: " & e.msg})
  let (ok, reason) = verifyProof(p)
  $(%*{"ok": ok, "reason": reason, "proofDigest": (if ok: p.proofDigest() else: ""),
       "events": p.events.len})

proc auditHex(b: seq[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc musterCoordinateAudit(intentId: string): string =
  ## The signature-audit file for one room intent (exo-403): the canonical bytes as hex,
  ## the readable report rendered from them, and their digest — or the refusal.
  if gSession == nil: return $(%*{"ok": false, "reason": "not-joined"})
  gSession.poll()
  let res = exportAudit(gSession.log.allEvents(), driverFor, intentId, moduleKeystore())
  if not res.ok:
    result = $(%*{"ok": false, "reason": res.reason, "intentId": intentId})
  else:
    result = $(%*{"ok": true, "intentId": intentId, "file": auditHex(res.bytes),
                  "report": renderAuditReport(res.bytes), "digest": auditDigest(res.bytes)})
  if gLpDebug:
    stderr.writeLine("MUSTER-LP audit " & $(%*{"ok": res.ok, "reason": res.reason,
      "digest": (if res.ok: auditDigest(res.bytes) else: ""), "bytes": res.bytes.len}))

proc musterCoordinateVerifyAudit(fileHex: string): string =
  ## Refuse-on-mismatch verification of an audit file — pure, reads only the file.
  var b: seq[byte]
  var h = fileHex
  if h.startsWith("0x"): h = h[2 .. ^1]
  try:
    for i in 0 ..< h.len div 2: b.add byte(parseHexInt(h[2*i .. 2*i+1]))
  except CatchableError:
    return $(%*{"ok": false, "reason": "not hex"})
  let v = verifyAudit(b)
  var apps = newJArray()
  for a in v.approvals: apps.add %*{"who": a.who, "round": a.round, "grade": a.grade}
  var st = newJArray()
  for x in v.settlement: st.add %*{"kind": x.kind, "chainRef": x.chainRef, "grade": x.grade}
  $(%*{"ok": v.ok, "reason": v.reason, "intentId": v.intentId, "stage": v.stage,
       "issuer": v.issuer, "digest": v.digest, "firstEpoch": v.firstEpoch,
       "approvals": apps, "settlement": st})

proc musterCoordinateFlow(): string =
  ## Who could see what, per action (M5). Founders = the current roster minus every
  ## joiner the log admits — the log names admits, not the founding set.
  if gSession == nil: return $(%*{"rows": [], "matrix": {}})
  gSession.poll()
  let events = gSession.log.allEvents()
  var admitted = initHashSet[string]()
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "membership" and p[2] == "admit": admitted.incl p[3]
  var founders: seq[string]
  for mem in gSession.members():
    let hexId = toHex(mem.toBytes())
    if hexId notin admitted: founders.add hexId
  let rows = reduceFlow(events, driverFor, founders)
  result = $(%*{"rows": rows.toJson(),
                 "matrix": rows.observerMatrix(introducedObservers(events, driverFor))})
  if gLpDebug: stderr.writeLine("MUSTER-LP flow " & result)

proc musterCoordinateAuthorization(intentId: string): string =
  ## The grant a host hook checks before dispatch (M7). Only for an EXECUTABLE
  ## intent: the room's agreement is the permission; nothing is authorized before it.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let st = intentState(events, driverFor, intentId)
  if st != "executable":
    return $(%*{"error": "not-executable", "intentId": intentId, "state": st})
  let policy = intentPolicyOf(events, intentId)
  let folded = reduceIntents(events, driverFor)
  let root = folded[intentId].materialization.bytes
  let (akind, aacct) = splitPolicy(policy)
  let (achain, aaddr) = splitAccountId(aacct)
  let (isEvm, acid) = evmChainId(achain)
  let environment = (if aacct.len > 0 and isEvm: "chain:" & $acid else: "room")
  let account = (if akind == "safe" and aacct.len > 0: "safe:" & aaddr else: "room")
  let a = issueAuthorization(moduleKeystore(), intentId, capabilityOf(akind, effectJson),
                             environment, account, root, uint64(epochTime()) + 600)
  result = $a.toJson()
  if gLpDebug: stderr.writeLine("MUSTER-LP authorization " & result)

proc musterCoordinateCheckAuthorization(authJson: string): string =
  ## Pure verification of a grant's own integrity (issuer recovery, slot, expiry).
  var a: Authorization
  try: a = authorizationFromJson(parseJson(authJson))
  except CatchableError as e:
    return $(%*{"ok": false, "reason": "not an authorization: " & e.msg})
  let r = checkAuthorization(a, uint64(epochTime()))
  $(%*{"ok": r.ok, "reason": r.reason, "issuer": (if r.ok: "0x" & toHex(r.issuer) else: ""),
       "capability": a.capability, "materializationRoot": a.toJson()["materializationRoot"],
       "expiry": a.context.expiry})

var gLez: LezAdapter = nil          ## the LEZ chain (fake core until P-L3 wires lez_core); set lazily by the wallet init below

proc lezReadyClosure(adapter: LezAdapter, minRaw: string): proc(): Grade {.gcsafe.} =
  ## Wrap the LEZ adapter's account status (wallet/lez_readiness) into a readiness Grade
  ## closure (exo-44b L2). The adapter is a PARAM (not the captured global) so the closure
  ## is gcsafe. Detect only — the remedy names the LEZ Wallet App.
  (proc(): Grade {.gcsafe.} =
    let (s, d) = adapter.lezStatusOf(minRaw)
    case s
    of "met": (rdMet, d)
    of "missing": (rdMissing, d)
    else: (rdUnknown, d))

proc hostFacts(policy = ""): HostFacts =
  ## The host's facts → the readiness probe, for one intent's POLICY: an account-bound
  ## policy's expected chain, Safe and signer set come from the account a member
  ## disclosed (exo-a50.1.3); the roster is the membership fold. No policy (the room's
  ## connectivity) → no account facts, so an account requirement grades unknown.
  var facts = HostFacts(rpcUrl: gRpcUrl, myAddress: myAddress(),
                        myEd: moduleKeystore().encIdentity().ed, roster: currentRoster())
  let (_, pacct) = splitPolicy(policy)
  if pacct.len > 0:
    let (found, a) = findAccount(roomAccounts(), pacct)
    if found:
      let (_, cid) = evmChainId(a.chain)
      facts.expectedChainId = cid.int
      facts.safe = toAddress(a.address)
      facts.signers = a.signers.mapIt(toAddress(it))
      if a.family.startsWith("btc."): facts.btcSigners = a.signers   # exo-a50.2.6
  # The Safe owner set is read FROM THE CHAIN (getOwners, F-10), never a configured or
  # self-injected set: without a chain read the authority grade is unknown, and a key the
  # chain does not recognize grades missing (rule s4, contracts/specs/derived-exo-45e, K3).
  if gInvoker == nil: gInvoker = newLpInvoker("muster_module")
  facts.invoker = gInvoker
  # A Bitcoin proposal introduces the user's node (exo-a50.2.6): graded by asking IT
  # which chain it serves; my key is graded against the account's keys.
  facts.btcRpcUrl = gBtcRpc
  try: facts.myBtcKey = toHex(moduleKeystore().btcPubKey())
  except CatchableError: discard
  # A LEZ action's `lez-account` requirement is graded against the live zone (exo-44b L2):
  # detect only — the remedy names the LEZ Wallet App. `gLez` may be nil (LEZ not yet
  # initialized) → the closure stays nil → the requirement grades unknown, never a false
  # met. The adapter is a PARAM (not the captured global) so the closure is gcsafe.
  if gLez != nil:
    facts.lezReady = lezReadyClosure(gLez, "1")   # "1" = a funded account (any spendable balance)
  facts

proc musterCoordinateReadiness(intentId: string): string =
  ## The proposal card's five questions for ONE room intent — what will it do (the
  ## effect), what is needed (requirements), what will it touch, what will happen (the
  ## full disclosure, baseline included), how we agree (the driver's policy) — plus
  ## THIS instance's readiness to take part: every requirement graded met / missing /
  ## unknown with the remedy the card offers (docs/design/action-manifest.md,
  ## exo-002.2). Graded against this instance only: whether YOUR key is a recognized
  ## signer, never who else is (invariant 9). unknown is first-class — a probe this
  ## host cannot run reports unknown, never a silent met. The module names remedies;
  ## the host performs them (invariant 3: nothing is installed or fetched here).
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let policy = intentPolicyOf(events, intentId)
  let drv = driverForKind(policy)
  let effect = effectFromJson(effectJson)
  let m = drv.manifest(effect)
  let r = assessReadiness(m, probeFromFacts(hostFacts(policy)))
  var o = r.toJson()
  o["intentId"] = %intentId
  o["policy"] = %policy
  o["kind"] = %kindOf(policy)
  o["manifest"] = m.toJson()
  o["profile"] = drv.profile().toJson()   # which multisig family, for this instance (exo-a50.1.1)
  try: o["effect"] = parseJson(effectJson)
  except CatchableError: o["effect"] = %effectJson
  result = $o
  if gLpDebug: stderr.writeLine("MUSTER-LP readiness " & result)

proc musterCoordinateActivity(): string =
  ## The room's coordination history as reduce(log): every state transition that
  ## moved a proposal along — proposed, each approval (running count, and who under a
  ## named driver), threshold reached, submitted on-chain, settled — in canonical
  ## (causal) order. The education seam (docs/00-vision): a member sees how the room
  ## reached its state and watches it change as it happens, from the SAME sealed log
  ## the cards are drawn from, inventing nothing. Returns a JSON array of
  ## {seq, kind, intentId, account, title, detail}.
  if gSession == nil: return "[]"
  gSession.poll()
  var arr = newJArray()
  for a in reduceActivity(gSession.log.allEvents(), driverFor):
    arr.add %*{"seq": a.seq, "kind": a.kind, "intentId": a.intentId,
               "account": a.account, "title": a.title, "detail": a.detail}
  $arr

proc introducersJson(who: seq[Introducer]): JsonNode =
  result = newJArray()
  for w in who: result.add %*{"intentId": w.intentId, "policy": w.policy}

proc musterConnectivity(): string =
  ## Liveness of the infrastructure the room relies on (invariant 8: store nodes and
  ## RPC are untrusted, user-chosen infra — so their reachability must be *visible*,
  ## never assumed) — and ONLY the infrastructure it relies on (exo-428). The room's
  ## own baseline is the delivery node its encrypted transport rides. Everything else
  ## is dictated by the drivers: a proposal whose manifest declares an instance-party
  ## infra/environment requirement INTRODUCES it (room_infra.roomInfraNeeds, a pure fold
  ## over the log), and the row names the proposals that brought it in. A room that
  ## only decides or talks never probes an RPC; the first Safe proposal brings the RPC
  ## and the chain it must serve into view. An undeclared driver shows as unknown
  ## infrastructure, never guessed. Probed live; never a false green. Levels: "ok",
  ## "warn" (reachable but not what the proposal needs), "down", "unknown".
  ## Returns {rows:[{key,name,level,detail,source,endpoint?,remedy?,introducedBy:[{intentId,policy}]}]}.
  var rows = newJArray()
  # ── the room's baseline: the delivery node (source "room") ──────────────────
  var delLevel = "down"
  var delDetail = "no node — join a room to start it"
  if gSession != nil:
    let ni = gSession.nodeInfo()
    if ni.len > 2:                       # something past an empty "{}"
      delLevel = "ok"; delDetail = "node running"
      try:
        let j = parseJson(ni)
        if j.kind == JObject:
          for k in ["connectedPeers", "peers", "numConnected"]:
            if j.hasKey(k) and j[k].kind == JArray:
              delDetail = $j[k].len & " peers"; break
            elif j.hasKey(k) and j[k].kind == JInt:
              delDetail = $j[k].getInt() & " peers"; break
      except CatchableError: discard
    else:
      delLevel = "warn"; delDetail = "joined; node info unavailable"
  rows.add %*{"key": "delivery", "name": "Delivery", "level": delLevel, "detail": delDetail,
              "source": "room", "introducedBy": []}
  if gSession == nil:
    result = $(%*{"rows": rows})
    if gLpDebug: stderr.writeLine("MUSTER-LP connectivity " & result)
    return
  gSession.poll()
  let needs = roomInfraNeeds(gSession.log.allEvents(), driverFor)
  # ── the RPC: one endpoint serves both an `infra:rpc` need and every `environment:
  # chain:<id>` need, so they fold into ONE row, probed once (eth_chainId) against the
  # chain(s) the introducing proposals need.
  var rpcWho: seq[Introducer]
  var chains: seq[int]
  for n in needs:
    if not n.declared: continue
    let r = n.requirement
    if (r.kind == rqInfra and r.name == "rpc") or
       (r.kind == rqEnvironment and r.name.startsWith("chain:")):
      for w in n.introducedBy: (if w notin rpcWho: rpcWho.add w)
      if r.kind == rqEnvironment:
        try: (let c = parseInt(r.name[6 .. ^1]); (if c notin chains: chains.add c))
        except ValueError: discard
  if rpcWho.len > 0:
    var level, detail: string
    if gRpcUrl.len == 0:
      level = "down"; detail = "no RPC endpoint configured"
    else:
      let (ok, chain, d) = probeRpc(gRpcUrl)
      if not ok: (level = "down"; detail = d)
      elif chains.len == 0 or chain in chains: (level = "ok"; detail = d)
      else:
        level = "warn"
        detail = d & " (the proposal needs chain " & chains.mapIt($it).join(" / ") & ")"
    rows.add %*{"key": "rpc", "name": "RPC", "level": level, "detail": detail,
                "endpoint": gRpcUrl, "source": "proposal",
                "remedy": (if level == "ok": "" else: "point the RPC setting at a node for chain " &
                            chains.mapIt($it).join(" / ") & " (Settings)"),
                "introducedBy": introducersJson(rpcWho)}
  # ── every other declared need, graded by the SAME readiness probe the card uses ──
  var probe: ReadinessProbe
  var probed = false
  for n in needs:
    if not n.declared:
      rows.add %*{"key": "undeclared", "name": "Undeclared driver", "level": "unknown",
                  "detail": "a proposal's driver has not declared what it needs — its infrastructure is unknown",
                  "source": "proposal", "introducedBy": introducersJson(n.introducedBy)}
      continue
    let r = n.requirement
    if (r.kind == rqInfra and r.name == "rpc") or
       (r.kind == rqEnvironment and r.name.startsWith("chain:")): continue
    if not probed: (probe = probeFromFacts(hostFacts()); probed = true)
    let f = if r.kind == rqInfra: probe.infraConfigured else: probe.environmentReachable
    var g: Grade = (rdUnknown, "this host cannot check " & r.name)
    if f != nil:
      try: g = f(r.name)
      except CatchableError as e: g = (rdUnknown, "probe failed: " & e.msg)
    let level = case g.status
                of rdMet: "ok"
                of rdMissing: "down"
                of rdUnknown: "unknown"
    rows.add %*{"key": $r.kind & ":" & r.name, "name": r.name, "level": level, "detail": g.detail,
                "source": "proposal", "remedy": (if g.status == rdMet: "" else: remedyFor(r)),
                "introducedBy": introducersJson(n.introducedBy)}
  result = $(%*{"rows": rows})
  if gLpDebug: stderr.writeLine("MUSTER-LP connectivity " & result)

proc musterCoordinateAccount(): string =
  ## The room's sending context for the composer — WHAT an intent proposed here would
  ## move, and WHO you would act as. Ask-then-disclose (not assumed on entry): the
  ## composer surfaces this only at propose time. For a Safe room: the Safe (the account
  ## whose funds actually move) with its live ETH balance — what is available to send,
  ## so the amount isn't typed blind — and YOUR owner address (who you sign as) with an
  ## owner check, so you learn *before* proposing whether your approval will count on
  ## chain (this is exactly the "insufficient-signatures" surprise, surfaced early). A
  ## non-Safe policy settles nothing on-chain, so there is no balance to show. Never a
  ## false balance: an unreachable RPC surfaces an error, not a zero.
  let policy = gCoordKind
  let (kind, acctId) = splitPolicy(policy)
  var o = %*{"policy": policy, "kind": kind, "accountId": acctId}
  let acting = toHex(myAddress())
  o["actingAs"] = %acting
  # WHAT identity backs a signature here. Safe approvals and eip191 attestations are
  # made with THIS instance's secp256k1 AUTHORIZATION key (the same key that signs
  # Safe transactions) — NOT the Ed25519/X25519 encryption identity that names you in
  # the room and encrypts messages. The threshold/frost policies instead endorse with
  # that Ed25519 encryption key. Disclosed so a signer always knows what they're using.
  o["signsWith"] = %(if kindNeedsAccount(kind): "secp256k1 authorization key"
                     else: "Ed25519 encryption identity")
  if not kindNeedsAccount(kind): return $o
  # An account-bound policy acts FROM an account a member disclosed into this room
  # (exo-a50.1.3) — its signer set, its balance, its nonce. None chosen → say so.
  let (found, a) = findAccount(roomAccounts(), acctId)
  if not found:
    o["error"] = %"no-account"
    return $o
  o["accountLabel"] = %a.label
  o["disclosedBy"] = %a.disclosedBy
  # A recognized-signer check: your key must be one of the account's DISCLOSED signers
  # or your signature won't count (the "nothing happened" you'd otherwise hit).
  let isOwner = acting.toLowerAscii() in a.signers
  o["isSigner"] = %isOwner
  o["isOwner"] = %isOwner                 # kept for the Safe composer's existing read
  o["signerSet"] = %(if kind == "eip191": "the signers of " & (if a.label.len > 0: a.label else: a.id)
                     else: "the Safe owners")
  if kind == "safe":
    o["account"] = %a.address             # the Safe address (the composer's existing read)
    let safeAddr = toAddress(a.address)
    var assets = newJArray()
    var eth = %*{"symbol": "ETH", "decimals": 18}
    try:
      let raw = hexToDec(getBalance(gRpcUrl, safeAddr))
      eth["raw"] = %raw
      eth["display"] = %(formatUnits(raw, 18) & " ETH")
    except CatchableError as e:
      eth["error"] = %e.msg
    assets.add eth
    o["assets"] = assets
    # The Safe's live nonce — the value the NEXT proposal must commit to (invariant 2).
    # A proposal built at propose time reads this so sequential settles each use the
    # right nonce; without it every proposal used 0 and only the first could settle
    # (exo-275). Best-effort: a failed read omits it and the UI falls back to 0.
    try:
      o["nonce"] = %(safeNonce(gRpcUrl, safeAddr).int)
    except CatchableError:
      discard
  $o

proc settlementFor(drv: Driver): Settlement =
  ## The settlement this driver's family needs (settlement/settlement.nim), over an
  ## adapter on the family's own chain through the user's RPC, sent by the configured
  ## relayer. nil when the family settles nowhere (exo-a50.1.5).
  let p = drv.profile()
  if not p.declared or p.settlement == "none": return nil
  if drv of LezMultisigDriver:
    # the LEZ multisig (exo-3c9): Execute is a member's own transaction, so the relayer
    # is this instance's member account; nil when it holds none (submit names why)
    let a = LezMultisigDriver(drv).account
    let c = lezLiveOf(a)
    c.waitForInclusion = false         # the Execute's finality is watched by the pump
    let (mine, me) = c.lezOurMember(a.members)
    if not mine: return nil
    return settlementFor(drv, c, Account(chain: a.chain, form: afPublic, id: lezHx(me)))
  if p.chain.startsWith("bip122:"):
    # Bitcoin (exo-a50.2.5/.6): the user's own node; nil without one (submit names why)
    if gBtcRpc.len == 0: return nil
    try:
      let adapter = newBitcoindAdapterFromUrl(networkByCaip2(p.chain).name, gBtcRpc)
      return settlementFor(drv, adapter, Account(chain: p.chain, form: afPublic, id: ""))
    except CatchableError: return nil
  let (isEvm, cid) = evmChainId(p.chain)
  if not isEvm: return nil
  let unlocked = gRelayer.startsWith("unlocked:")
  let who = (if unlocked: gRelayer["unlocked:".len .. ^1] else: toHex(myAddress()))
  let adapter = newEvmAdapter("evm:" & $cid, gRpcUrl, fromUnlocked = unlocked)
  settlementFor(drv, adapter, Account(chain: "evm:" & $cid, form: afPublic, id: who))

proc musterCoordinateSubmit(intentId: string): string =
  ## Settle a room intent FROM the room (exo-a50.1.5): the intent's family SETTLEMENT —
  ## chosen from its driver's profile, never a policy string — assembles from the
  ## contributions on the shared LOG (only those the driver accepts; the hash is
  ## re-derived from the effect, invariant 1), submits through the ChainAdapter seam
  ## from the configured relayer, and finality is watched, never asserted (R-8). A
  ## submit event is published so every member's fold converges on submitted. A family
  ## that settles nowhere (a room family) returns not-onchain.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let policy = intentPolicyOf(events, intentId)
  let drv = driverFor(policy)
  let isBtc = drv.profile().chain.startsWith("bip122:")
  if isBtc and gBtcRpc.len == 0:
    return $(%*{"id": intentId, "error": "no-bitcoin-node",
                "detail": "a Bitcoin payment settles through your own node — set Settings → Bitcoin node (btc-rpc)"})
  if drv of LezMultisigDriver:
    let a = LezMultisigDriver(drv).account
    var mine = false
    try: mine = lezLiveOf(a).lezOurMember(a.members).found
    except CatchableError: discard
    if not mine:
      return $(%*{"id": intentId, "error": "not-a-lez-member",
                  "detail": "Execute is a member's own transaction, and none of your LEZ member accounts is a member of this multisig"})
  let st = settlementFor(drv)
  if st == nil:
    return $(%*{"id": intentId, "error": "not-onchain",
                "detail": "a " & kindOf(policy) & " decision settles nothing on-chain"})
  let state = intentState(events, driverFor, intentId)
  if state != "executable":
    return $(%*{"id": intentId, "error": "not-executable", "state": state})
  # invariant 2 at submit time: past the intent's declared expiry nothing settles.
  let pre = liveSubmitPrecheck(gSession, driverFor, intentId, uint64(epochTime()))
  if pre.len > 0: return $(%*{"id": intentId, "error": pre})
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent"})
  var contribs: seq[SettleContribution]
  for e in events:
    let p = e.key.split('/')
    if p.len >= 4 and p[0] == "intent" and p[1] == intentId and p[2] == "sig":
      contribs.add (contributor: p[3], bytes: hexToBytes(e.value))
  let asm0 = st.assemble(drv, effectFromJson(effectJson), contribs)
  if not asm0.ok:
    return $(%*{"id": intentId, "error": asm0.error, "detail": asm0.detail,
                "have": asm0.have, "need": asm0.need})
  var txRef: TxRef
  try:
    txRef = st.submit(asm0.tx, moduleKeystore())
  except CatchableError as e:
    if isBtc:
      return $(%*{"id": intentId, "error": "rpc-unreachable",
                  "detail": e.msg & " — the Bitcoin node (" & redactUserinfo(gBtcRpc) & ") refused or could not be reached"})
    return $(%*{"id": intentId, "error": "rpc-unreachable", "relayer": gRelayer,
                "detail": e.msg & " — the relayer (" & asm0.tx.frm.id & ") must be able to pay gas on " &
                          asm0.tx.frm.chain & "; fund it, or set Settings → relayer"})
  # Fold the room forward: submit event → every member converges on "submitted".
  gSession.publish(submitEvent(intentId, chainRef = txRef.id))
  # Observe finality from the chain (never asserted). Bounded poll (~4s) so a slow or
  # unreachable node reports "pending" rather than freezing the UI.
  var fin = Finality(status: fsPending)
  for _ in 0 .. 20:
    try: fin = st.watch(txRef)
    except CatchableError: discard
    if fin.status != fsPending: break
    sleep(200)
  if fin.status == fsFinal: gSession.publish(finalEvent(intentId, chainRef = txRef.id))
  elif fin.status == fsPending and drv of LezMultisigDriver:
    # a LEZ Execute lands a block later: the pump publishes final when the chain says Executed
    gLezPending.add LezPending(kind: lpSettle, session: gSession, settle: st, txRef: txRef, intentId: intentId,
                               started: epochTime())
  let onchain = (case fin.status
                 of fsFinal: "final"
                 of fsFailed: "failed"
                 else: "pending")
  $(%*{"id": intentId,
       "state": intentState(gSession.log.allEvents(), driverFor, intentId),
       "onchain": onchain, "txHash": txRef.id, "relayer": asm0.tx.frm.id})

# ── signers outside muster + composing a Bitcoin payment (exo-a50.2.6) ────────
proc musterCoordinateExportOutside(intentId: string): string =
  ## The intent in its driver's outside-signer format (a Bitcoin spend: a base64 PSBT).
  if gSession == nil: return $(%*{"error": "not-joined"})
  let r = liveExportOutside(gSession, driverFor, intentId)
  if not r.ok: return $(%*{"intentId": intentId, "error": r.error})
  $(%*{"intentId": intentId, "format": r.format, "encoded": r.encoded})

proc musterCoordinateImportOutside(intentId, encoded: string): string =
  ## An outside signer's response: published as pasted approvals — counted, and graded
  ## unattested (signed outside muster) by every member, never committed.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let r = liveImportOutside(gSession, moduleKeystore(), driverFor, intentId, encoded,
                            intentLinkContext(intentId), uint64(epochTime()))
  if not r.ok:
    return $(%*{"intentId": intentId, "error": r.error, "detail": r.detail,
                "imported": r.imported, "state": r.state})
  $(%*{"intentId": intentId, "imported": r.imported, "already": r.already, "state": r.state})

proc musterCoordinateProposeBtcSpend(payTo, amountSat, feeRate: string): string =
  ## Propose a Bitcoin payment from the room's chosen Bitcoin account: its coins read
  ## from the user's node (an external read, recorded in the log so every signer can
  ## account for the inputs, invariant 10), the spend built largest-first with change
  ## back to the account, then proposed like any intent.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let (pkind, pacct) = splitPolicy(gCoordKind)
  if not pkind.startsWith("btc-") or pacct.len == 0:
    return $(%*{"error": "not-a-bitcoin-policy",
                "detail": "choose a Bitcoin account for this room first (coordinate_set_policy btc-p2wsh@… / btc-tapscript@…)"})
  if gBtcRpc.len == 0:
    return $(%*{"error": "no-bitcoin-node",
                "detail": "a Bitcoin payment reads its coins from your own node — set Settings → Bitcoin node (btc-rpc)"})
  let (found, a) = findAccount(roomAccounts(), pacct)
  if not found: return $(%*{"error": "cannot-build", "detail": "the account is not disclosed in this room"})
  var amount: uint64
  var rate: int
  try:
    amount = uint64(parseBiggestUInt(amountSat.strip()))
    rate = parseInt(feeRate.strip())
  except ValueError:
    return $(%*{"error": "cannot-build", "detail": "amount_sat and fee_rate are whole numbers (sat, sat/vB)"})
  var effectJson: string
  try:
    if a.family == FrostFamily:
      # a FROST account (Phase D): its key-path spend, sized for one signature per input
      let (fok, facct, fdetail) = frostDisclosureOf(a)
      if not fok: return $(%*{"error": "cannot-build", "detail": fdetail})
      let node = newBitcoindAdapterFromUrl(facct.network.name, gBtcRpc)
      effectJson = buildFrostSpend(facct, node.utxosOf(facct.address), payTo.strip(), amount, feeRate = rate)
    else:
      let (ok, acct, detail) = btcAccountOfDisclosure(a.family, a.chain, a.address, a.threshold, a.signers)
      if not ok: return $(%*{"error": "cannot-build", "detail": detail})
      let node = newBitcoindAdapterFromUrl(acct.network.name, gBtcRpc)
      effectJson = buildBtcSpend(acct, node.utxosOf(acct.address), payTo.strip(), amount, feeRate = rate)
  except WalletError as e:
    return $(%*{"error": "node-unreachable", "detail": e.msg})
  except CatchableError as e:
    return $(%*{"error": "cannot-build", "detail": e.msg})
  let id = musterCoordinatePropose(effectJson)
  if id.len == 0 or id.startsWith("refused") or id in ["not-joined", "unsupported-driver"]:
    return $(%*{"error": "cannot-build", "detail": id})
  # the coins came from the proposer's node: record the read (inv 10) — the source names
  # the kind of read, never the node's address
  gSession.publish(readEvent(id, "inputs", "bitcoind:scantxoutset", $parseJson(effectJson)["inputs"]))
  id

# ── the LEZ multisig composers (exo-3c9) ───────────────────────────────────────
proc lezComposeAccount(): tuple[ok: bool, acct: LezMultisigAccount, err: string] =
  let (pkind, pacct) = splitPolicy(gCoordKind)
  if pkind != "lez-multisig" or pacct.len == 0:
    return (false, LezMultisigAccount(), $(%*{"error": "not-a-lez-policy",
      "detail": "choose a LEZ multisig account for this room first (coordinate_set_policy lez-multisig@…)"}))
  let (found, a) = findAccount(roomAccounts(), pacct)
  if not found:
    return (false, LezMultisigAccount(), $(%*{"error": "not-a-lez-policy", "detail": "the account is not disclosed in this room"}))
  let (ok, acct, detail) = lezMultisigAccountOf(a)
  if not ok: return (false, acct, $(%*{"error": "not-a-lez-policy", "detail": detail}))
  (true, acct, "")

proc lezProposeAction(action: LezAction): string =
  ## The proposer's own Propose transaction, then the room intent pointing at it.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return err
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  try:
    let c = lezLiveOf(acct)
    let (mine, me) = c.lezOurMember(acct.members)
    if not mine:
      return $(%*{"error": "not-a-member", "detail": "none of your LEZ member accounts is a member of this multisig"})
    c.waitForInclusion = false         # never wait on a block inside a hosted call
    inc gMsgSeq
    let seam = newLezVoteSeam(c, me)
    let (outcome, pp) = liveProposeOnChainStart(gSession, moduleKeystore(), driverFor, gCoordKind, action, seam,
                                                int64(epochTime()), gMsgSeq, ttlSec = ttl)
    if outcome.len > 0: return $(%*{"error": "refused", "detail": outcome})
    gLezPending.add LezPending(kind: lpPropose, session: gSession, seam: seam, propose: pp, started: epochTime())
    $(%*{"pending": "propose", "index": pp.index, "tx": pp.tx,
         "detail": "proposal #" & $pp.index & " is on its way to the chain; it appears in the room once included"})
  except CatchableError as e:
    $(%*{"error": "sequencer-unreachable", "detail": e.msg})

proc musterCoordinateProposeLez(actionJson: string): string =
  var action: LezAction
  try:
    let j = parseJson(actionJson)
    action.target = lezIdOf(j["target"].getStr())
    for w in j["instruction"]: action.instruction.add uint32(w.getBiggestInt())
    for x in j["accounts"]: action.accounts.add lezIdOf(x.getStr())
    for x in j{"pdaSeeds"}.getElems(): action.pdaSeeds.add lezIdOf(x.getStr())
    for x in j{"authorized"}.getElems(): action.authorized.add uint8(x.getInt())
  except CatchableError as e:
    return $(%*{"error": "not-an-action", "detail": e.msg})
  lezProposeAction(action)

proc lezTokenAction(accounts: seq[seq[byte]], words: seq[uint32], authorized: uint8): tuple[ok: bool, action: LezAction, err: string] =
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return (false, LezAction(), err)
  try:
    let token = newLezRpc(gLezRpc).programId("token")
    (true, LezAction(target: token, instruction: words, accounts: accounts,
                     pdaSeeds: @[vaultSeed(acct.createKey)], authorized: @[authorized]), "")
  except CatchableError as e:
    (false, LezAction(), $(%*{"error": "sequencer-unreachable", "detail": e.msg}))

proc musterCoordinateProposeLezTransfer(recipient, amount: string): string =
  ## Transfer `amount` of the vault's token to `recipient`: token Transfer (variant 0,
  ## amount a u128 = four words), the vault the authorized PDA.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return err
  var to: seq[byte]
  var amt: uint64
  try:
    to = lezIdOf(recipient)
    amt = uint64(parseBiggestUInt(amount.strip()))
  except CatchableError as e:
    return $(%*{"error": "not-an-action", "detail": "a recipient account (hex or base58) and a whole amount: " & e.msg})
  let words = @[0'u32, uint32(amt and 0xffff_ffff'u64), uint32(amt shr 32), 0'u32, 0'u32]
  let vault = vaultPda(acct.scheme, acct.program, acct.createKey)
  let (tok, action, terr) = lezTokenAction(@[vault, to], words, 0)
  if not tok: return terr
  lezProposeAction(action)

proc musterCoordinateProposeLezVaultInit(definition: string): string =
  ## Initialize the vault as a holding of the token `definition`: token
  ## InitializeAccount (variant 3), the vault the authorized PDA.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return err
  var def: seq[byte]
  try: def = lezIdOf(definition)
  except CatchableError as e: return $(%*{"error": "not-an-action", "detail": "a token definition account: " & e.msg})
  let vault = vaultPda(acct.scheme, acct.program, acct.createKey)
  let (tok, action, terr) = lezTokenAction(@[def, vault], @[3'u32], 1)
  if not tok: return terr
  lezProposeAction(action)

proc musterFrostCeremonyOpen(ceremonyId, network, t, n: string): string =
  ## Open a FROST ceremony in the joined room and join it.
  if gSession == nil: return $(%*{"error": "not-joined"})
  var ti, ni: int
  try:
    ti = parseInt(t.strip())
    ni = parseInt(n.strip())
  except ValueError: return $(%*{"error": "t and n are whole numbers"})
  if ceremonyId.strip().len == 0 or '/' in ceremonyId: return $(%*{"error": "a ceremony id is a name without /"})
  if ni < 2 or ti < 1 or ti > ni: return $(%*{"error": "a t-of-n needs 1 <= t <= n and n >= 2"})
  let net = (if network.strip().len > 0: network.strip() else: "regtest")
  discard frostCeremonyOpen(gSession, ceremonyId.strip(), net, ti, ni)
  let host = frostCeremonyJoin(gSession, moduleKeystore(), ceremonyId.strip())
  gFrostJoined.add (gSession, ceremonyId.strip())
  $(%*{"ceremony": ceremonyId.strip(), "network": net, "t": ti, "n": ni, "host": host})

proc musterFrostCeremonyJoin(ceremonyId: string): string =
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  if not ceremonyView(gSession.log.allEvents(), ceremonyId.strip()).open:
    return $(%*{"error": "not-open", "detail": "no ceremony " & ceremonyId & " is open in this room"})
  let host = frostCeremonyJoin(gSession, moduleKeystore(), ceremonyId.strip())
  gFrostJoined.add (gSession, ceremonyId.strip())
  $(%*{"ceremony": ceremonyId.strip(), "host": host})

proc musterFrostCeremonies(): string =
  if gSession == nil: return "[]"
  gSession.poll()
  frostPump()
  let events = gSession.log.allEvents()
  let mine = moduleKeystore()
  var arr = newJArray()
  var seen: seq[string]
  for e in events:
    let p = e.key.split('/')
    if p.len != 3 or p[0] != "frost" or p[2] != "open" or p[1] in seen: continue
    seen.add p[1]
    let cid = p[1]
    let v = ceremonyView(events, cid)
    var address = ""
    for a in roomAccounts():
      if a.family == FrostFamily:
        try:
          if parseJson(a.config)["ceremony"].getStr() == cid: address = a.address
        except CatchableError: discard
    arr.add %*{"ceremony": cid, "network": v.network, "t": v.t, "n": v.n, "joined": v.hosts.len,
               "step1": v.pmsg1.len, "step2": v.pmsg2.len,
               "participant": mine.frostHostPubkey(ceremonyLabel(cid)) in v.hosts,
               "address": address, "last": gFrostLast.getOrDefault(cid, "")}
  $arr

proc musterLezPending(): string =
  ## The LEZ steps sent and not yet included, and the last outcomes.
  lezPump()
  var pend = newJArray()
  for p in gLezPending:
    pend.add %*{"kind": $p.kind, "intentId": p.intentId, "index": p.propose.index,
                "since": int64(p.started), "room": (if p.session == gSession: "this" else: "another")}
  $(%*{"pending": pend, "recent": gLezRecent})

proc musterLezMemberAccount(index: string): string =
  ## One of this instance's LEZ member accounts; empty index = the first still fresh.
  let ks = moduleKeystore()
  proc entry(i: int, fresh: JsonNode): JsonNode =
    let id = publicAccountId(ks.lezMemberKey(lezMemberLabel(i)))
    %*{"index": i, "account": lezHx(id), "base58": accountIdToBase58(id), "fresh": fresh}
  proc isFresh(rpc: LezRpc, i: int): bool =
    let a = rpc.getAccount(publicAccountId(ks.lezMemberKey(lezMemberLabel(i))))
    a.owner.len == 0 and a.data.len == 0 and a.nonce.isZero
  let rpc = newLezRpc(gLezRpc)
  if index.strip().len > 0:
    var i: int
    try: i = parseInt(index.strip())
    except ValueError: return $(%*{"error": "index is a whole number 0-" & $(LezMemberSlots - 1)})
    if i < 0 or i >= LezMemberSlots: return $(%*{"error": "index is a whole number 0-" & $(LezMemberSlots - 1)})
    var fresh = newJNull()
    try: fresh = %rpc.isFresh(i)
    except CatchableError: discard
    return $entry(i, fresh)
  try:
    for i in 0 ..< LezMemberSlots:
      if rpc.isFresh(i): return $entry(i, %true)
    $(%*{"error": "all " & $LezMemberSlots & " of your LEZ member accounts are in use"})
  except CatchableError as e:
    $(%*{"error": "sequencer-unreachable", "detail": e.msg})

proc musterLezMultisigCreate(threshold, members: string): string =
  ## Create a k-of-n LEZ multisig on chain; the result is ready to disclose.
  var ms: seq[seq[byte]]
  try:
    for m in members.split({',', ' ', '\n'}):
      if m.strip().len > 0: ms.add lezIdOf(m)
  except CatchableError as e:
    return $(%*{"error": "bad-member", "detail": e.msg})
  var k: int
  try: k = parseInt(threshold.strip())
  except ValueError: return $(%*{"error": "bad-threshold", "detail": "a whole number"})
  if ms.len == 0 or k < 1 or k > ms.len:
    return $(%*{"error": "bad-threshold", "detail": "k=" & $k & " does not fit " & $ms.len & " members"})
  var ck = newSeq[byte](32)
  if not urandom(ck): return $(%*{"error": "refused", "detail": "no randomness for the create key"})
  var program: seq[byte]
  for i in 0 ..< 32: program.add byte(parseHexInt(gLezProgram[2*i .. 2*i+1]))
  try:
    let c = lezLiveFor(gLezChain, psLee02, program, plAccountIds)
    c.waitForInclusion = false         # never wait on a block inside a hosted call
    let t = c.submit(@[], createOp(ck, k, ms))
    if not t.ok: return $(%*{"error": "refused", "detail": t.error})
    let config = %*{"program": gLezProgram, "createKey": lezHx(ck), "pda": "lee-v0.2", "layout": "account-ids"}
    let created = %*{"family": LezMultisigFamily, "chain": gLezChain, "address": lezHx(statePda(psLee02, program, ck)),
                     "config": $config, "threshold": k, "members": ms.mapIt(lezHx(it)), "tx": t.hash,
                     "label": "LEZ " & $k & "-of-" & $ms.len}
    # in a room, it is disclosed there once the chain has the state (the pump)
    if gSession != nil:
      gLezPending.add LezPending(kind: lpCreate, session: gSession, created: created, started: epochTime())
    created["pending"] = %"create"
    $created
  except CatchableError as e:
    $(%*{"error": "sequencer-unreachable", "detail": e.msg})

# ── invoke-intent execution (P-D2) — the generic counterpart to coordinate_submit ─
# An executable invoke intent is executed by the CORE (invariant 3): call the module
# method the effect names over lp_*, gated by the ALLOWLIST (only configured
# module.method pairs run) AND the target's own CAPABILITY policy (the lp_* layer
# rejects an unauthorized call, surfaced as a refusal — never a false success). Start
# CLOSED: the allowlist is empty until an operator opts actions in via
# MUSTER_INVOKE_ALLOWLIST (JSON [{"module","method","finalityEvent"}]).
var gInvokeAllowlist: Allowlist = @[]
var gAllowlistLoaded = false

proc invokeAllowlist(): Allowlist =
  if not gAllowlistLoaded:
    gAllowlistLoaded = true
    let env = getEnv("MUSTER_INVOKE_ALLOWLIST")
    if env.len > 0:
      try: gInvokeAllowlist = parseAllowlist(parseJson(env))
      except CatchableError: discard
  gInvokeAllowlist

proc musterCoordinateExecute(intentId: string): string =
  ## Execute an invoke-policy intent that reached executable — the room-side
  ## counterpart to coordinate_submit for generic module actions. The effect
  ## (module/method/args) comes from the shared LOG and the fold proves the room
  ## endorsed it; the core re-derived the materialization to fold it (invariant 1).
  ## Gate on allowlist + capability, invoke, and fold the room forward.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.log.allEvents()
  let policy = intentPolicyOf(events, intentId)
  if policy != "invoke":
    return $(%*{"id": intentId, "error": "not-invoke",
                "detail": "a " & policy & " intent is not a generic module action"})
  let st = intentState(events, driverFor, intentId)
  if st != "executable":
    return $(%*{"id": intentId, "error": "not-executable", "state": st})
  let ej = effectJsonOf(events, intentId)
  var module, meth, argsJson: string
  try:
    let je = parseJson(ej)
    module = je{"module"}.getStr()
    meth = je{"method"}.getStr()
    argsJson = (if je.hasKey("args"): $je["args"] else: "[]")
  except CatchableError:
    return $(%*{"id": intentId, "error": "bad-effect"})
  if gInvoker == nil: gInvoker = newLpInvoker("muster_module")
  let ex = executeInvoke(gInvoker, invokeAllowlist(), module, meth, argsJson)
  if not ex.executed:
    return $(%*{"id": intentId, "executed": false, "state": "refused", "detail": ex.reason})
  # Fold forward: submit → (immediate finality) final. Event/receipt finality is a
  # later refinement — an immediate action folds straight to final here.
  gSession.publish(submitEvent(intentId))
  if ex.finalityEvent.len == 0:
    gSession.publish(finalEvent(intentId))
  $(%*{"id": intentId, "executed": true,
       "state": intentState(gSession.log.allEvents(), driverFor, intentId),
       "detail": ex.reason})

proc musterCoordinateAvailableActions(): string =
  ## The coordinatable module actions available to the room (P-D3): the compose menu.
  ## Candidate modules = the invoke allowlist's modules + MUSTER_INVOKE_MODULES (muster
  ## does not blind-scan every loaded module). Each is queried for its lp_get_methods
  ## descriptors, reads pruned, and the allowlisted ones marked executable-now.
  let allow = invokeAllowlist()
  var modules: seq[string]
  for e in allow:
    if e.module notin modules: modules.add e.module
  for m in getEnv("MUSTER_INVOKE_MODULES").split(','):
    let t = m.strip()
    if t.len > 0 and t notin modules: modules.add t
  if gInvoker == nil: gInvoker = newLpInvoker("muster_module")
  $discoverAcross(gInvoker, modules, allow)

proc musterCoordinateRequestJoin(): string =
  if gSession == nil: return "not-joined"
  # A join request is scoped to the ROOM (no account yet — a joiner has disclosed
  # nothing); the admitter checks the binding's signer against the room's disclosed
  # accounts' signers (coordinate_pending.bindsOwner), never a module-global Safe.
  gSession.requestJoin(moduleKeystore().bindingFor(
    LinkContext(account: gTopic, slot: "0", expiry: uint64(epochTime()) + 86_400)))
  "ok"

proc musterContacts(): string =
  ## The address book — [{identity, alias, address}].
  $contactBook().asJson()
proc musterContactAdd(identityHex, alias: string): string =
  ## Add or update a contact by its 64-byte encryption identity hex (0x optional).
  contactBook().add(identityHex, alias); "ok"
proc musterContactSetAlias(identityHex, alias: string): string =
  contactBook().setAlias(identityHex, alias); "ok"
proc musterContactRemove(identityHex: string): string =
  contactBook().remove(identityHex); "ok"

proc musterCoordinatePending(): string =
  ## Each pending requester with whether its binding proves Safe ownership (F-9),
  ## so a host admits knowingly rather than blindly. Carries the address-book alias
  ## (if any) so the admit prompt shows a name, not raw hex.
  if gSession == nil: return "[]"
  gSession.poll()
  let nowSec = uint64(epochTime())
  var arr = newJArray()
  for st in gSession.pendingBindings():
    let idHex = toHex(st.enc.toBytes())
    arr.add %*{"identity": idHex,
               "alias": contactBook().aliasOf(idHex),
               "bindsOwner": bindingBinds(st, allSigners(roomAccounts()), nowSec)}
  if gLpDebug:
    stderr.writeLine("MUSTER-LP pending=" & $arr.len & " members=" &
                     $gSession.members().len & " msgs=" &
                     $reduceMessages(gSession.log.allEvents()).len)
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
  ## The room's authored messages, oldest-first, folded from the shared log. Each
  ## carries its author's contact alias (so the chat log reads "Alice", not raw hex —
  ## the same resolution the roster/pending use) and a `self` flag for our own lines.
  if gSession == nil: return "[]"
  gSession.poll()
  let meHex = toHex(gSession.selfIdentity().toBytes())
  var arr = newJArray()
  for m in reduceMessages(gSession.log.allEvents()):
    arr.add %*{"id": m.id, "author": m.author, "ts": m.ts, "body": m.body,
               "alias": contactBook().aliasOf(m.author),
               "self": (normId(m.author) == normId(meHex))}
  $arr

proc musterCoordinateMembers(): string =
  ## The ADMITTED members of the joined room (the current roster), each flagged
  ## whether it is our own identity. Distinct from coordinate_pending (requests).
  if gSession == nil: return "[]"
  gSession.poll()
  let me = gSession.selfIdentity()
  var arr = newJArray()
  for m in gSession.members():
    let idHex = toHex(m.toBytes())
    arr.add %*{"identity": idHex, "self": (m == me),
               "alias": contactBook().aliasOf(idHex)}
  $arr

proc musterCoordinateConversations(): string =
  ## Every joined room, as {topic, address, lastTs, active} — the home surface's
  ## room list. The active room is flagged; lastTs is each room's latest message ts
  ## (0 if none yet), so home can order by recency. Multi-room: one entry per session.
  var arr = newJArray()
  let myAddr = toHex(moduleKeystore().address())
  for topic, s in gSessions:
    if topic in gInboxTopics: continue      # an inbox is a drop-box, not a room to list
    s.poll()
    let msgs = reduceMessages(s.log.allEvents())
    let lastTs = if msgs.len > 0: msgs[^1].ts else: 0'i64
    arr.add %*{"topic": topic, "address": myAddr, "lastTs": lastTs,
               "active": (topic == gTopic)}
  $arr

proc musterSecurityLevels(): string =
  ## The joined room's ACTIVE null-ladder level on the three axes (exo-1ec.5): the strongest
  ## guarantee each GOVERNING seam provides, combined into one envelope — authentication from
  ## the compose-default driver (every driver binds the speaker), provenance from the signed
  ## hash-linked log, and
  ## confidentiality from the room's crypto seam (the real epoch layer, or the null). The
  ## level is never a silent fallback — a consumer that requires the real level and cannot
  ## get it refuses (DowngradeRefused), which is why this reports honestly rather than assumes.
  if gSession == nil: return "not-joined"
  let auth = driverForKind(gCoordKind).describe().securityLevel()
  let prov = securityLevel(
    axisLevel(rungNull, "-"),
    axisLevel(rungReal, "signed hash-linked log (reduce(log), invariant 4)"),
    axisLevel(rungNull, "-"))
  let conf = gSession.securityLevel()
  $combine(auth, prov, conf).toJson()

# ── wallet: chain-agnostic account/asset/transfer surface ──────────────────────
# The account-level view of the chains the module touches — distinct from the
# coordinated intent path. The EVM chain is the same one the Safe settles on; the
# mock shielded chain is registered alongside it to demonstrate that a second,
# non-EVM chain is a registration, not a code change (F-Design: chain-agnostic).
var gWallet: Wallet = nil
var gMock: MockChain = nil
var gEvm: EvmAdapter = nil          ## typed handle for the EVM-specific verified path
# gLez is declared before musterCoordinateReadiness (exo-44b L2); set lazily below.

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
    # The Logos Execution Zone — send assets via Logos, public + shielded. Real
    # (LpLezCore over lez_core, against testnet.lez.logos.co) when MUSTER_LEZ_REAL is
    # set AND lez_core is loaded; otherwise the deterministic fake, so a runner without
    # lez_core bundled still demonstrates the flow. Any failure to reach the real core
    # falls back to the fake rather than breaking the wallet.
    let lezCore: LezCore =
      if getEnv("MUSTER_LEZ_REAL").len > 0:
        try:
          let dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
          LezCore(newLpLezCore(dir))
        except CatchableError as e:
          stderr.writeLine("MUSTER-LEZ: real lez_core unavailable, using fake — " & e.msg)
          LezCore(newFakeLezCore())
      else:
        LezCore(newFakeLezCore())
    gLez = newLezAdapter(lezCore)
    # Fund the DEMO (fake) accounts eagerly so a send is demonstrable. For the REAL
    # core, do NOT create/register/fund accounts here: those hit the network (and the
    # pinata PoW) and would block this first wallet call on the module thread. The real
    # accounts are created lazily on the first LEZ query (a bounded loading delay at
    # panel-open), and a proving transfer already runs async — so nothing freezes.
    if getEnv("MUSTER_LEZ_REAL").len == 0:
      for acc in gLez.accounts(ks):
        if acc.form == afPublic:
          try: gLez.claimFaucet("EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7", acc)
          except CatchableError: discard
    gWallet.register(gLez)
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
  ## Every account across chains. LEZ accounts also carry a `share` — the address to
  ## hand out to BE paid (Mode A's request→share→send): a public id, or a shielded key
  ## node "priv:npk:vpk". PER-CHAIN resilient: one chain that can't answer (e.g. the LEZ
  ## zone unreachable, or its wallet not yet set up) contributes an {chain, error} entry
  ## instead of emptying the whole list — so the UI can SAY why, not just show nothing.
  let w = moduleWallet()
  let ks = moduleKeystore()
  var arr = newJArray()
  for desc in w.chains():
    let chain = desc.chain
    try:
      # the LEZ shareable addresses (best-effort; drives account creation for the real
      # core, which is where a zone/setup failure would surface).
      var lezShare = initTable[string, string]()
      if chain == lez_adapter.ChainId and gLez != nil:
        for r in gLez.receiveAddresses(ks): lezShare[r.form] = r.address
      for a in w.adapterFor(chain).accounts(ks):
        var o = %*{"chain": a.chain, "form": $a.form, "id": a.id}
        if ($a.form) in lezShare: o["share"] = %lezShare[$a.form]
        arr.add o
    except CatchableError as e:
      arr.add %*{"chain": chain, "error": e.msg}
  $arr

proc musterWalletBalances(): string =
  ## Every account × asset, each entry a balance OR an error — never a false zero.
  ## Per-chain resilient: a chain whose accounts can't be listed (the LEZ zone
  ## unreachable) contributes an error entry, never empties the whole list.
  let w = moduleWallet()
  let ks = moduleKeystore()
  var arr = newJArray()
  var accts: seq[Account]
  for desc in w.chains():
    try:
      for a in w.adapterFor(desc.chain).accounts(ks): accts.add a
    except CatchableError as e:
      arr.add %*{"chain": desc.chain, "error": e.msg}
  for acc in accts:
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
    let src = accountOn(w, chain)
    let fee = w.estimateFee(chain, src, to, amount(asset, raw))
    var o = %*{"fee": fee.fee.display(), "raw": fee.fee.raw, "note": fee.note}
    # LEZ preview: name the rail + what it would disclose, so the sender sees the
    # honesty BEFORE committing (a public id names the payee; a shielded key node
    # doesn't). Best-effort — a bad destination just omits the preview.
    if chain == lez_adapter.ChainId and gLez != nil:
      try:
        let p = parseJson(gLez.prepareTransfer(src, to, amount(asset, raw)).payload)
        o["rail"] = p{"form"}; o["discloses"] = p{"discloses"}
      except CatchableError: discard
    $o
  except CatchableError as e:
    $(%*{"error": e.msg})

proc accountFormOf(w: Wallet, chain, id: string): AccountForm =
  ## The real form of a source account (public vs shielded) — the LEZ rail depends on
  ## it, so a hardcoded afPublic would send a shielded balance down the public rail.
  for a in w.accounts():
    if a.chain == chain and a.id == id: return a.form
  afPublic

proc musterWalletSend(chain, fromId, to, assetSymbol, raw: string): string =
  let w = moduleWallet()
  try:
    let asset = assetBySymbol(w, chain, assetSymbol)
    let frm = Account(chain: chain, form: accountFormOf(w, chain, id = fromId), id: fromId)
    # LEZ: the rail (public/shield/deshield/private) and the DISCLOSURE follow from
    # (source form, what the recipient shared). Surface both so the send reports which
    # honesty it took — the education payoff of sending assets via Logos.
    if chain == lez_adapter.ChainId and gLez != nil:
      let prepared = gLez.prepareTransfer(frm, to, amount(asset, raw))
      let p = parseJson(prepared.payload)
      let r = gLez.submit(prepared, moduleKeystore())
      return $(%*{"txId": r.id, "chain": r.chain,
                  "rail": p{"form"}.getStr(), "discloses": p{"discloses"},
                  "fee": prepared.fee.fee.display(), "note": prepared.fee.note})
    let r = w.send(chain, frm, to, amount(asset, raw))
    $(%*{"txId": r.id, "chain": r.chain})
  except CatchableError as e:
    $(%*{"error": e.msg})

proc musterWalletLezSetup(pinataId: string): string =
  ## Headless LEZ provisioning FALLBACK (exo-44b, the no-broker path): ensure a public
  ## LEZ account exists and — with a pinata challenge id — fund it from the faucet,
  ## directly over lez_core (core-to-core). Preferred path stays the LEZ Wallet App
  ## hand-off when the broker is available; this is what keeps muster from being
  ## hard-blocked when it is not. A faucet failure raises, never a false receipt.
  discard moduleWallet()                 # ensures the wallet + gLez are initialized
  if gLez == nil: return $(%*{"error": "LEZ chain unavailable"})
  try:
    let (account, state, detail) = gLez.provision(moduleKeystore(), pinataId)
    result = $(%*{"account": account, "state": state, "detail": detail})
  except CatchableError as e:
    result = $(%*{"error": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP wallet_lez_setup " & result)

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
  ## Admit a requester the model is "a member decides": an existing member chooses
  ## whom to let in. The binding must be VALID (F-9 — unexpired and self-consistent:
  ## its secp signature recovers a real signer over exactly this encryption identity,
  ## so it can't be forged or replayed), but admission does NOT additionally require
  ## the signer to be a Safe owner — that is one driver's policy, not the membership
  ## model. Whether the requester is an owner is surfaced to the admitter as
  ## `bindsOwner` in coordinate_pending, so a Safe room can still choose owners-only.
  if gSession == nil: return "not-joined"
  let b = hexToBytes(identityHex)
  if b.len != 64: return "bad-key"          # a member identity: ed25519(32) ++ x25519(32)
  let m = encIdentityFromBytes(b)
  let nowSec = uint64(epochTime())
  var verified = false
  for st in gSession.pendingBindings():
    if st.enc == m:
      try:
        discard bindingSigner(st, nowSec)   # F-9: recovers a signer, raises if expired
        verified = true
      except CatchableError: discard        # malformed/expired binding — not admissible
  if not verified: return "unverified"      # no valid binding for this identity
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
    "relayer": gRelayer,
    "btcRpc": redactUserinfo(gBtcRpc),
    "lez": {"rpc": gLezRpc, "chain": gLezChain, "multisigProgram": gLezProgram},
    "delivery": gDeliveryConfig,
    "environment": "eip155:" & $gDevSafe.chainId.int,   # the wallet's dev chain (CAIP-2)
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
  of "relayer":
    # who sends settling transactions: "self" or "unlocked:<0x…>" (exo-a50.1.5)
    if value != "self" and not (value.startsWith("unlocked:0x") and value.len == 51):
      return $(%*{"error": "relayer must be \"self\" or \"unlocked:<0x address>\""})
    gRelayer = value
  of "btc-rpc":
    # the user's own Bitcoin node (exo-a50.2.6); "" clears it
    let v = value.strip()
    if v.len > 0 and not (v.startsWith("http://") or v.startsWith("https://")):
      return $(%*{"error": "btc-rpc must be an http(s) URL, e.g. http://user:pass@127.0.0.1:8332"})
    gBtcRpc = v
  of "lez-rpc":
    # the user's LEZ sequencer (exo-3c9); "" restores the public testnet
    let v = value.strip()
    if v.len > 0 and not (v.startsWith("http://") or v.startsWith("https://")):
      return $(%*{"error": "lez-rpc must be an http(s) URL, e.g. https://testnet.lez.logos.co"})
    gLezRpc = (if v.len == 0: "https://testnet.lez.logos.co" else: v)
  of "lez-chain":
    let v = value.strip()
    if not v.startsWith("lez:") or v.len < 5:
      return $(%*{"error": "lez-chain is a CAIP-2 LEZ zone, e.g. lez:testnet"})
    gLezChain = v
  of "lez-multisig-program":
    var v = value.strip().toLowerAscii()
    if v.startsWith("0x"): v = v[2 .. ^1]
    if v.len == 0: v = LezDeployedMultisig
    if v.len != 64 or not v.allCharsInSet(HexDigits):
      return $(%*{"error": "lez-multisig-program is the program's image id: 64 hex characters"})
    gLezProgram = v
  of "delivery":
    # Accept a fleet short-name ("logos.test"), a full createNode JSON, or "{}"/"" to
    # fall back to the default fleet — and remember that the user chose, so it wins
    # over the env on the next launch.
    gDeliveryConfig = deliveryConfigFor(value)
    gDeliverySaved = true
  else:
    return $(%*{"error": "unknown setting: " & key})
  saveSettingsFile()         # persist beside the keystore, so it survives a restart
  musterSettings()
