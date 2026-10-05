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

import std/[json, tables, strutils, os, algorithm, times, sets, sequtils, options]
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
import ../src/coordination/authorship # the room's authentic view; author-bearing events signed (exo-f76)
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
import ../src/drivers/lez_frost        # a FROST group acting on LEZ (exo-55e)
import ../src/drivers/frost_group      # frostGroupOf: any FROST family's approval is two rounds
import std/sysrand                     # a multisig create key
import stint                           # LEZ nonces (u128)
import ../src/bitcoin/network          # networkByCaip2
import ../src/bitcoin/script           # p2wpkhAddress: a Bitcoin split pays from / is paid at wpkh(<my key>) (exo-d17)
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
import ../src/coordination/joined_rooms  # the rooms this member joined, re-entered on relaunch (exo-ecbe)
import ../src/coordination/home        # the home surface: what waits on THIS member (F-18, exo-ed5)
import ../src/coordination/effect_summary  # what an effect moves, in its family's words (exo-59c)
import ../src/wallet/types             # chain-agnostic wallet types
import ../src/wallet/adapter           # ChainAdapter seam + Wallet aggregate
import ../src/wallet/evm_adapter       # the EVM/Safe chain
import ../src/wallet/evm_rpc           # rpcChainId: the chain the configured RPC serves (a split's)
from ../src/wallet/rpc_budget import forgetCooldown   # Settings naming an endpoint tries it now (exo-14f.1)
import ../src/wallet/erc20_logs        # a token's symbol()/decimals(), display only (exo-5ab)
import ../src/wallet/mock_chain        # a second, non-EVM chain (proves agnosticism)
import ../src/wallet/lez_core          # the LEZ wallet seam + FakeLezCore (P-L3 swaps in real)
import ../src/wallet/lez_adapter       # the Logos Execution Zone chain (send assets via Logos)
import ../src/wallet/lez_lp            # LpLezCore — the real lez_core over lp_* (P-L3)
import ../src/wallet/btc_adapter       # the user's Bitcoin node (exo-a50.2.5/.6)
import ../src/wallet/redact            # a configured endpoint, as text may show it (exo-14f.2)
import ../src/coordination/attest      # readEvent: the external read a Bitcoin spend's coins cite (inv 10)
import ../src/drivers/split as splitdrv   # a split: each pays their own share (exo-a90)
import ../src/coordination/parts        # paying and confirming a part (exo-a90.4)
import ../src/coordination/parts_evm    # …on an EVM chain, through this member's own wallet and RPC
import ../src/coordination/settle_up    # net several splits into fewer payments (exo-3c6)
import ../src/transport/rln_status     # the node's RLN membership as a connectivity row (exo-eb6.3)
import ../src/transport/rln_probe      # …read from delivery and the two RLN modules
import ../src/wallet/keystore_status   # the official EVM keystore as a status row (exo-149.1 K1)
import ../src/wallet/keystore_probe    # …read from keystore_module over lp_*
import ../src/wallet/keystore_requests # pending signing requests (exo-149.2 K2)
import ../src/coordination/keystore_approval # an in-room approval keystore_module signs (K2)
import ../src/wallet/keystore_identity  # a keystore_module account as this member's identity (K5)
import ../src/wallet/keystore_legs      # KeystoreLegError: a binding that does not check
import ../src/crypto/binding            # its F-14 binding, stored and published
import ../src/coordination/covers       # whether a settle-up still covers a share, at this clock (exo-a90.16)
import ../src/coordination/pending_parts  # payments in flight, never forgotten while they might land (exo-a90.23)
import ../src/coordination/parts_btc    # …and in Bitcoin, from each debtor's own key, confirmed on the creditor's node (exo-d17)
import ../src/coordination/parts_lez    # …and privately on the LEZ, found by the creditor's scan (exo-a90.9)

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

const SubmitWatchS = 4.0
  ## how long a submit waits, inside the call, for the chain to say final; every RPC call
  ## has its own budget too (wallet/rpc_budget.nim), so no hung endpoint holds the module
  ## thread past this window plus one read (exo-14f)

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
proc roomIdentities(): seq[string]       ## forward — every member's room identity (64-byte enc identity hex)
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
  let (bare, chain) = splitPolicy(kind)
  if bare in ["evm-split", "lez-split", "btc-split"]:
    # a split (exo-a90): the policy names the CAIP-2 chain the parties pay on; the room's
    # members gate who may be named (the fold reads the parties from the effect alone)
    return newSplitDriver((if bare == "lez-split": LezSplitFamily elif bare == "btc-split": BtcSplitFamily
                           else: EvmSplitFamily), chain, roomIdentities())
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
var gRpcUrl = getEnv("MUSTER_RPC", "http://127.0.0.1:8545")   ## a saved setting wins (settings.json)
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
const DefaultFleet = "logos.dev"
  ## The fleet a fresh instance joins (exo-eb6.2). Since Testnet v0.3 (delivery
  ## v0.3.0) a node on logos.test needs the RLN modules loaded, and sends nothing until
  ## it has an active, funded RLN membership (exo-eb6.3); logos.dev (cluster 3) runs no RLN.

proc deliveryPreset(name: string): string =
  ## Embedded fleet createNode configs, so delivery WORKS out of the box (invariant 8
  ## says the infra is user-configurable, not that it must start empty). Keep in sync
  ## with infra/fleets/<name>.json — regenerate those via infra/fleets/refresh.sh and
  ## repaste here if the fleet's entry nodes rotate. A settings value may be one of
  ## these short names or a full createNode JSON.
  case name
  of "logos.dev":
    """{"mode":"Core","preset":"logos.dev","entryNodes":["/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP","/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby","/dns4/delivery-01.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm4S1JYkuzDKLKQvwgAhZKs9otxXqt8SCGtB4hoJP1S397","/dns4/delivery-02.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAkvwhGHKNry6LACrB8TmEFoCJKEX29XR5dDUzk3UT3UNSE","/dns4/delivery-02.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmMK7PYygBtKUQ8EHp7EfaD3bCEsJrkFooK8RQ2PVpJprH","/dns4/delivery-02.gc-us-central1-a.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8Y9kgBNtjxvCnf1X6gnZJW5EGE4UwwCL3CCm55TwqBiH"]}"""
  of "logos.test":
    """{"mode":"Core","preset":"logos.test","entryNodes":["/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF","/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj","/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3","/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV","/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG","/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7"]}"""
  else: ""

proc deliveryConfigFor(v: string): string =
  ## Resolve a delivery setting: a short fleet name → its embedded preset; empty or the
  ## inert "{}" → the default fleet (so a fresh instance connects instead of failing to
  ## autoshard); anything else → verbatim (a hand-written createNode JSON).
  if v.len == 0 or v == "{}": return deliveryPreset(DefaultFleet)
  let p = deliveryPreset(v)
  if p.len > 0: return p
  v

var gDeliveryConfig = deliveryPreset(DefaultFleet)   ## the room works with no env/flags

# Persist the infra settings beside the keystore, so a user's chosen endpoints
# survive a restart. Best-effort — a missing/malformed file leaves the defaults.
proc settingsPath(): string =
  var dir = context().instancePersistencePath
  if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
  dir / "settings.json"

var gKeystoreBackend = getEnv("MUSTER_KEYSTORE_BACKEND", "off")
  ## exo-149.2: "interim" lets a key ref naming a keystore_module account approve in-room
  ## through it, its attestation an opaque digest leg (docs/design/keystore-module-backend.md
  ## §4). "off" (the default) keeps every approval on muster's own keystore.
var gKeystoreAccount = ""
  ## exo-149.5: the keystore_module account this member approves Safe intents with ("" = none)
var gKeystoreBinding = ""
  ## …and its F-14 binding (encodeLink hex), signed once at selection; public, so it is
  ## saved beside the other settings and published beside each approval
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
      if j.hasKey("keystoreBackend"): gKeystoreBackend = j["keystoreBackend"].getStr("off")
      if j.hasKey("keystoreAccount"): gKeystoreAccount = j["keystoreAccount"].getStr()
      if j.hasKey("keystoreBinding"): gKeystoreBinding = j["keystoreBinding"].getStr()
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
                                   "lezMultisigProgram": gLezProgram,
                                   "keystoreBackend": gKeystoreBackend,
                                   "keystoreAccount": gKeystoreAccount,
                                   "keystoreBinding": gKeystoreBinding}))
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


proc myNames(): seq[string] =
  ## The names this member's approvals carry: its own keystore's keys, plus the
  ## keystore_module account it selected (exo-149.5), so its approvals read as its own
  ## here (approvedByMe), in readiness and in home's needs-you.
  result = myContributorNames(moduleKeystore())
  if gKeystoreBackend == "interim" and gKeystoreAccount.len > 0 and gKeystoreAccount notin result:
    result.add gKeystoreAccount

proc myIds(): seq[string] =
  ## Every form under which a surface may name THIS member: the 64-byte identity and the
  ## names its keys give its approvals (addresses, the Bitcoin key, "ed:" / "frost:").
  let ks = moduleKeystore()
  @[toHex(ks.encIdentity().toBytes()).toLowerAscii()] & myNames()

proc memberName(who: string, mine: seq[string]): string =
  ## The one name for a member on every surface (exo-221): "you", the contact alias, or
  ## one short id — the card, the approval slots and the room history all ask this.
  contactBook().memberLabel(who, mine)

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
    "x25519": toHex(enc.x),
    # the key a Bitcoin multisig names you by — what you give whoever sets one up (exo-59c)
    "btcPubKey": toHex(ks.btcPubKey())
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

  # Observe finality from the chain, within SubmitWatchS of wall clock (exo-14f: it was 51
  # polls, each unbounded). A failed read stops the wait: the intent stays submitted.
  var status = -1
  let until = epochTime() + SubmitWatchS
  while true:
    try: status = watchReceiptStatus(gRpcUrl, txHash)
    except CatchableError: break
    if status >= 0 or epochTime() >= until: break
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

proc roomIdentities(): seq[string] =
  ## Every current member's room identity — the 64-byte encryption identity, lowercase
  ## hex, the name a split gives its parties (exo-a90). Our own when no room is joined.
  if gSession != nil:
    for m in gSession.members(): result.add toHex(m.toBytes()).toLowerAscii()
  if result.len == 0:
    result.add toHex(moduleKeystore().encIdentity().toBytes()).toLowerAscii()

proc roomAccounts(): seq[RoomAccount] =
  ## The accounts members have disclosed into the joined room, folded from its log
  ## (coordination/accounts.nim, exo-a50.1.3). None without a room. (Forward-declared
  ## above driverForKind, which resolves account-bound policies against it.)
  if gSession == nil: return @[]
  reduceAccounts(gSession.roomEvents())

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

proc joinedRoomsPath(): string =
  var dir = context().instancePersistencePath
  if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
  dir / "joined_rooms.json"

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
  # Remember the room beside the keystore, so a relaunch re-enters it (exo-ecbe).
  discard rememberJoinedRoom(joinedRoomsPath(), ctopic)
  # Announce the room's join key (exo-661.7), so someone who knows only the topic can
  # ask to join without naming themselves on it. Rate-limited in the session.
  gSession.announceBeacon()
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
  ## a room. Invites are sealed to a pubkey, not an epoch, so the session holds no epoch
  ## key (a joiner's crypto): it never announces a join key or answers a beacon request,
  ## which would tell the topic when its owner is online (exo-661.7).
  gInboxTopics.incl ctopic
  if ctopic in gSessions: return gSessions[ctopic]
  let s = newCoordinationSession(newDeliveryTransport(gDeliveryConfig), newEpochJoiner(moduleKeystore()), ctopic)
  gSessions[ctopic] = s
  s

var gRoomsRestored = false

proc restoreJoinedRooms(): seq[string] =
  ## Re-enter every room this member joined before a relaunch (exo-ecbe), once per run:
  ## a session per remembered topic, as coordinate_join makes one, so Home lists the room
  ## and its state folds back from the store and the keystore. None is made active — the
  ## member opens one from Home, which re-activates it. Returns the topics re-entered.
  if gRoomsRestored: return
  gRoomsRestored = true
  let ks = moduleKeystore()
  for ctopic in loadJoinedRooms(joinedRoomsPath()):
    if ctopic in gSessions or ctopic in gInboxTopics: continue
    let s = newCoordinationSession(newDeliveryTransport(gDeliveryConfig), newEpochCrypto(ks), ctopic)
    gSessions[ctopic] = s
    s.announceBeacon()
    result.add ctopic
  if gLpDebug: stderr.writeLine("MUSTER-LP rooms restored=" & $result.len & " topics=" & $result)

proc musterCoordinateStartInbox(): string =
  ## Begin listening on THIS identity's inbox so invites arrive even before any room is
  ## joined, and re-enter every room it joined before a relaunch (exo-ecbe). Idempotent;
  ## the UI calls it once at startup. Pulls any invites left while away.
  let ks = moduleKeystore()
  let myChat = toHex(ks.encIdentity().toBytes())
  let ctopic = inboxTopicFor(myChat)
  gInbox = inboxSessionFor(ctopic)
  try: gInbox.catchUp()
  except CatchableError: discard
  let rooms = restoreJoinedRooms()
  $(%*{"inbox": ctopic, "rooms": rooms})

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
  ## malformed) are skipped. Deduped by (from, topic).
  ##
  ## Starts the inbox itself when it isn't running yet. The UI calls start_inbox once at
  ## launch, but that call can land before the module is up and never arrive — found
  ## running the tour: Bob's inbox never started, so no invitation ever showed. Home polls
  ## this every 2 s, so the first poll that reaches the module brings the inbox up, and
  ## its deep store catch-up then fetches any invite left while it was down.
  if gInbox == nil:
    try: discard musterCoordinateStartInbox()
    except CatchableError as e:
      if gLpDebug: stderr.writeLine("MUSTER-LP inbox not started: " & e.msg)
      return "[]"
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
  if gLpDebug:
    stderr.writeLine("MUSTER-LP invites=" & $arr.len & " frames=" & $gInbox.receivedInvites().len &
                     " topics=" & $(arr.getElems().mapIt(it{"topic"}.getStr())))
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
  roomDriverKinds(gSession.roomEvents(), driverFor)

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
      let folded = reduceIntents(gSession.roomEvents(), driverFor)
      if id in folded and not folded[id].collection.complete: auto.add id
  gFrostAuto = auto

proc rpcChainCaip2(): tuple[ok: bool, chain, detail: string] =
  ## The CAIP-2 chain THIS member's configured EVM RPC actually serves (parts_evm).
  rpcChainCaip2(gRpcUrl)

proc splitLezAdapter(): LezAdapter   ## forward — the module's LEZ wallet (moduleWallet, below)

proc splitChainFor(kind: string): tuple[ok: bool, chain, detail: string] =
  ## The chain a split kind settles on when none is named: an EVM split, the chain this
  ## member's RPC serves; the private split, the LEZ zone this member's wallet is on.
  if "lez" in kindInfo(kind).settlesOn:
    try: (true, splitLezAdapter().describe().chain, "")
    except CatchableError as e: (false, "", "the LEZ wallet is unavailable: " & e.msg)
  elif "bip122" in kindInfo(kind).settlesOn:
    # a Bitcoin split: the chain this member's own node serves, asked of the node
    if gBtcRpc.len == 0: (false, "", "no Bitcoin node configured (Settings → Bitcoin node)")
    else: probeBitcoind(gBtcRpc)
  else: rpcChainCaip2()

# ── a split: each pays their own share (exo-a90; docs/design/split-the-bill.md) ─────
# Paying SENDS and returns; the settled report follows on the intents tick once the
# payment lands (a hosted call never waits on a block, exo-3c9). On the same tick, this
# member — if they are a split's creditor — confirms every reported payment their own RPC
# shows paying them the share (coordination/parts.nim). Nothing is published before the
# chain has it.
# The payments this client sent and has not seen land (coordination/pending_parts,
# exo-a90.23): in flight until they land, fail, or the chain says they never will — never
# dropped at a deadline — and saved beside the identity, so a restart forgets none of them.
var gSplitBook: PendingBook
var gSplitBookLoaded = false
var gSplitSeams = initTable[string, PartSeam]()   ## intent id -> the seam paying it (rebuilt after a restart)
var gSplitRecent: seq[JsonNode]  ## the last outcomes, newest last
var gSplitPumpAt = 0.0
var gLezScanNext = 0.0   ## when the private split's background scan steps next (exo-270a)
var gSplitLogged = initTable[string, string]()   ## intent id → the last state line logged (debug)

proc splitSeam(chain: string): EvmPartSeam =
  ## THIS member's own wallet on `chain`: their key signs (client-side EIP-155, through the
  ## keystore), their RPC sends and reads (invariant 8). The seam refuses a chain its RPC
  ## does not serve.
  let (_, cid) = evmChainId(chain)
  let wchain = "evm:" & $cid
  newEvmPartSeam(chain, gRpcUrl, newEvmAdapter(wchain, gRpcUrl, fromUnlocked = false), moduleKeystore(),
                 Account(chain: wchain, form: afPublic, id: addrHex(myAddress())))

var gTokenInfo = initTable[string, tuple[symbol: string, decimals: int]]()

proc tokenInfo(chain, token: string): tuple[symbol: string, decimals: int] =
  ## What a split's token says about itself — symbol() and decimals() — read through THIS
  ## member's own RPC when it serves `chain`, cached. Display only (exo-5ab): the effect's
  ## amounts are base units, and nothing here is ever signed. ("", -1) when unreadable, and
  ## the card then shows base units beside the token's address.
  let key = chain & "|" & token
  if key in gTokenInfo: return gTokenInfo[key]
  result = ("", -1)
  try:
    if "eip155:" & rpcChainId(gRpcUrl) == chain:
      let sym = abiString(toHex(rpcCall(gRpcUrl, token, @[0x95'u8, 0xd8, 0x9b, 0x41], "latest")))
      let dec = abiUint8(toHex(rpcCall(gRpcUrl, token, @[0x31'u8, 0x3c, 0xe5, 0x67], "latest")))
      result = (sym, dec)
      if dec >= 0: gTokenInfo[key] = result
  except CatchableError: discard

proc splitSeamFor(policy: string): PartSeam =
  ## The seam a split's policy settles through: this member's own EVM wallet + RPC, or —
  ## for the private split — their own LEZ wallet on the private rail (exo-a90.9).
  let (k, chain) = splitPolicy(policy)
  if k == "lez-split": PartSeam(newLezPartSeam(chain, splitLezAdapter(), moduleKeystore()))
  elif k == "btc-split":
    # this member's own node (Settings → Bitcoin node), on the network the split names
    PartSeam(newBtcPartSeam(chain, newBitcoindAdapterFromUrl(networkByCaip2(chain).name, gBtcRpc), moduleKeystore()))
  else: PartSeam(splitSeam(chain))

var gMyLezPayTos: seq[string]   # my LEZ receive addresses, as last read
var gMyLezPayTosAt = 0.0
proc myPayTos(family: string): seq[string] =
  ## The addresses this client holds that a split of `family` could pay: my EVM address, or
  ## my LEZ receive addresses (read at most every 30s — the intents projection runs each tick).
  if family == BtcSplitFamily:
    # every Bitcoin network this key could be paid on: its wpkh address per network
    for n in Networks: result.add p2wpkhAddress(n.hrp, moduleKeystore().btcPubKey())
    return
  if family != LezSplitFamily: return @[addrHex(myAddress())]
  if epochTime() - gMyLezPayTosAt > 30:
    gMyLezPayTosAt = epochTime()
    try:
      var fresh: seq[string]
      for r in splitLezAdapter().receiveAddresses(moduleKeystore()): fresh.add r.address
      gMyLezPayTos = fresh
    except CatchableError: discard
  gMyLezPayTos

proc splitBookPath(): string =
  var dir = context().instancePersistencePath
  if dir.len == 0: dir = getEnv("MUSTER_DATA_DIR", getTempDir() / "muster")
  dir / "split-pending.json"

proc loadSplitBook() =
  if gSplitBookLoaded: return
  gSplitBookLoaded = true
  try: gSplitBook = bookFromJson(parseJson(readFile(splitBookPath())))
  except CatchableError: discard       # nothing saved yet
  if gLpDebug: stderr.writeLine("MUSTER-LP split book " & splitBookPath() & ": " & $gSplitBook.entries.len &
                                " payment(s) in flight")

proc saveSplitBook() =
  try:
    let p = splitBookPath()
    createDir(parentDir(p))
    writeFile(p & ".tmp", $gSplitBook.toJson())
    moveFile(p & ".tmp", p)
  except CatchableError as e:
    if gLpDebug: stderr.writeLine("MUSTER-LP split book not saved: " & e.msg)

proc seamOfPending(s: CoordinationSession, pp: PendingPart): PartSeam =
  ## The seam a payment in the book is watched through: the one that sent it, or — after a
  ## restart — the one its intent's policy settles through.
  ## Right after a restart the room's log may not have caught up yet: until it names the
  ## intent's policy there is no seam to build — never a guessed one, which would watch the
  ## wrong chain for good (seen live: a Bitcoin payment watched through the EVM seam).
  if pp.intentId notin gSplitSeams:
    let policy = intentPolicyOf(s.roomEvents(), pp.intentId)
    if splitPolicy(policy).kind notin ["evm-split", "lez-split", "btc-split"]:
      raise newException(ValueError, "the room's log does not name " & pp.intentId & "'s policy yet")
    gSplitSeams[pp.intentId] = splitSeamFor(policy)
  gSplitSeams[pp.intentId]

proc splitPayingFor(intentId, part: string): bool =
  loadSplitBook()
  for e in gSplitBook.entries:
    if e.pp.intentId == intentId and e.pp.part == part: return true
  false

proc splitUnresolvedFor(intentId, part: string): bool =
  for e in gSplitBook.entries:
    if e.pp.intentId == intentId and e.pp.part == part and e.unresolved: return true
  false

proc splitPump() =
  if gSession == nil or epochTime() - gSplitPumpAt < 2.0: return
  gSplitPumpAt = epochTime()
  let ks = moduleKeystore()
  loadSplitBook()
  let now = epochTime()
  let seamOf = proc (pp: PendingPart): PartSeam = seamOfPending(gSession, pp)
  var note: proc (msg: string) = nil
  if gLpDebug: note = proc (msg: string) = stderr.writeLine("MUSTER-LP split pending " & msg)
  var changed = false
  for (pp, outcome, said) in gSplitBook.pumpBook(gTopic, gSession, ks, driverFor, seamOf, now, note):
    changed = true
    let seam = gSplitSeams.getOrDefault(pp.intentId, PartSeam())
    let full = (if said.len > 0: said & " — " & outcome else: outcome)
    if gLpDebug: stderr.writeLine("MUSTER-LP split reported " & pp.intentId & " " & full &
                                  " tx=" & seam.landedRef(pp.transfer, pp.tx))
    gSplitRecent.add %*{"intentId": pp.intentId, "part": pp.part,
                        "tx": seam.landedRef(pp.transfer, pp.tx),
                        "outcome": full, "at": int64(now)}
    if gSplitRecent.len > 20: gSplitRecent.delete(0)
  if changed: saveSplitBook()
  # a private split waiting on me — mine to pay or to confirm — keeps my LEZ wallet's scan
  # moving from the proposal on, so it is at the tip when the payment has to be sent or
  # found (a real scan is slow: lez_core stores after every block). One bounded step a
  # tick while behind, one every 15s at the tip; none while my wallet proves (exo-270a).
  var lezWaits = false
  for v in partsAwaiting(gSession.roomEvents(), driverFor, myIdentity(ks)):
    if splitPolicy(v.policy).kind == "lez-split": lezWaits = true
  if lezWaits and epochTime() >= gLezScanNext:
    try:
      let (ran, code) = splitLezAdapter().scanStep(minGapS = 1.5)
      if ran: gLezScanNext = epochTime() + (if code == LezSyncOk: 15.0 else: 0.0)
    except CatchableError:
      gLezScanNext = epochTime() + 15.0     # the zone unreachable: try again later
  # the creditor's side: confirm what my own read shows, per chain the room's splits use
  var policies: seq[string]
  for v in reduceIntentViews(gSession.roomEvents(), driverFor):
    if v.parts.len == 0 or v.state notin ["submitted", "settling"]: continue
    if splitPolicy(v.policy).kind in ["evm-split", "lez-split", "btc-split"] and v.policy notin policies and
       not (splitPolicy(v.policy).kind == "btc-split" and gBtcRpc.len == 0):   # no node: nothing to read with
      policies.add v.policy
  for pol in policies:
    try:
      let confirmed = liveConfirmParts(gSession, ks, driverFor, splitSeamFor(pol))
      if gLpDebug and confirmed.len > 0: stderr.writeLine("MUSTER-LP split confirmed " & $(%confirmed))
    except CatchableError: discard
  # a settle-up final (exo-3c6): the shares it covered that I am owed, marked received —
  # no chain read is involved (the reference is the settle-up), so no seam is used
  try:
    let covered = settleCovered(gSession, ks, driverFor, PartSeam())
    if gLpDebug and covered.len > 0: stderr.writeLine("MUSTER-LP settle-up covered " & $(%covered))
  except CatchableError: discard
  if gLpDebug and lezWaits:
    # a private split waits on me: say how far my wallet's scan has got
    let (synced, tip) = splitLezAdapter().scanProgress()
    let line = $synced & "/" & $tip
    if tip > 0 and gSplitLogged.getOrDefault("lez-scan", "") != line:
      gSplitLogged["lez-scan"] = line
      stderr.writeLine("MUSTER-LEZ scan " & line)
  if gLpDebug:
    # each split's state, once per change — what an offscreen self-test watches
    for v in reduceIntentViews(gSession.roomEvents(), driverFor):
      if v.parts.len == 0: continue
      var done = 0
      for pv in v.parts:
        if pv.confirmed: inc done
      let line = v.id & " state=" & v.state & " agreed=" & $v.approvals & "/" & $v.threshold &
                 " confirmed=" & $done & "/" & $v.parts.len & " refs=" & v.parts.mapIt(it.tx).join(",")
      if gSplitLogged.getOrDefault(v.id, "") != line:
        gSplitLogged[v.id] = line
        stderr.writeLine("MUSTER-LP split " & line)

proc musterCoordinateProposeSplitImpl(chain, total, sharesJson, memo: string): string =
  ## Propose splitting a bill THIS member fronted: they are the creditor, paid at their own
  ## address on `chain` (proposer material, written into the effect so it is reviewed and
  ## signed). With {creditor: <room identity>} it is proposed on that member's behalf
  ## (exo-770): paid at the address they last shared into the room, and payable only once
  ## they agree too. Returns the intent id, or {error}.
  if gSession == nil: return $(%*{"error": "not-joined"})
  # WHICH rail: the chain named, else the compose policy's (the Split composer's "Settles
  # on" row — evm-split or lez-split), else an EVM split on the chain the RPC serves. The
  # chain is written into the effect, so every member reviews it before agreeing.
  var chain = chain
  let (ck, cq) = splitPolicy(gCoordKind)
  var kind = (if chain.startsWith("lez:"): "lez-split"
              elif chain.startsWith("bip122:"): "btc-split"
              elif chain.len == 0 and ck in ["evm-split", "lez-split", "btc-split"]: ck
              else: "evm-split")
  if chain.len == 0: chain = cq
  if chain.len == 0:
    let (ok, c, detail) = splitChainFor(kind)
    if not ok: return $(%*{"error": (if kind == "lez-split": "no-lez-wallet" elif kind == "btc-split": "no-btc-node"
                                     else: "no-rpc"), "detail": detail})
    chain = c
  let lez = kind == "lez-split"
  let btc = kind == "btc-split"
  let (isEvm, _) = evmChainId(chain)
  var knownBtc = false
  if btc:
    try: (discard networkByCaip2(chain); knownBtc = true)
    except CatchableError: discard
  if not isCaip2(chain) or (lez and not chain.startsWith("lez:")) or (btc and not knownBtc) or
     (not lez and not btc and not isEvm):
    return $(%*{"error": "not-a-" & (if lez: "lez" elif btc: "bitcoin" else: "evm") & "-chain", "chain": chain})
  if kind notin roomKinds(): return $(%*{"error": "not-admitted", "kind": kind})
  let me = toHex(moduleKeystore().encIdentity().toBytes()).toLowerAscii()
  var creditor = me
  var shares: seq[SplitShare]
  var asset = (if lez: "LEZ" elif btc: "BTC" else: "ETH")
  var total = total
  var quote: SplitQuote
  try:
    let j = parseJson(sharesJson)
    # an Ethereum split in a token (exo-5ab): {…, "asset": "0x<token>" | "erc20:0x<token>"}
    if j.kind == JObject and j.hasKey("asset"):
      let a = j["asset"].getStr().strip().toLowerAscii()
      if a.len > 0 and a != "eth":
        if lez: return $(%*{"error": "bad-asset", "detail": "a private split is paid in LEZ"})
        if btc: return $(%*{"error": "bad-asset", "detail": "a Bitcoin split is paid in BTC"})
        asset = (if a.startsWith("erc20:"): a else: "erc20:" & a)
        if not isErc20Asset(asset): return $(%*{"error": "bad-asset", "detail": asset})
    # a bill in fiat (exo-3a4): {…, "fiat": {currency, amount, rate, source}} — the rate is
    # this member's quote (an external read, recorded with the proposal, invariant 10) and
    # the total is its exact conversion into the asset, never typed
    if j.kind == JObject and j{"fiat"} != nil and j["fiat"].kind == JObject:
      let f = j["fiat"]
      let dec = (if lez: 9 elif btc: 8 elif isErc20Asset(asset): tokenInfo(chain, asset[6 .. ^1])[1] else: 18)
      if dec < 0: return $(%*{"error": "bad-asset", "detail": "the token's decimals could not be read for the conversion"})
      let q = fiatQuote(f{"currency"}.getStr().strip().toUpperAscii(), f{"amount"}.getStr(), f{"rate"}.getStr(),
                        dec, f{"source"}.getStr(), int64(epochTime()))
      if not q.ok: return $(%*{"error": "bad-quote", "detail": q.why})
      total = q.total
      quote = q.quote
    if not isCanonDec(total) or total == "0": return $(%*{"error": "bad-total", "total": total})
    if j.kind == JObject and j{"creditor"}.getStr().len > 0:
      creditor = j["creditor"].getStr().toLowerAscii().replace("0x", "")
    if j.kind == JArray:
      # the private split needs every share distinct: its note is matched by amount (§4.7)
      shares = evenShares(total, creditor, j.getElems().mapIt(it.getStr().toLowerAscii()), distinctAmounts = lez)
    elif j.kind == JObject and j.hasKey("shares"):
      for x in j["shares"].getElems(): shares.add SplitShare(who: x{"who"}.getStr().toLowerAscii(), amount: x{"amount"}.getStr())
    elif j.kind == JObject and j.hasKey("parties"):
      shares = evenShares(total, creditor, j["parties"].getElems().mapIt(it.getStr().toLowerAscii()),
                          creditorShares = j{"creditorShares"}.getBool(true), distinctAmounts = lez)
    else: return $(%*{"error": "bad-shares", "detail": "an array of room identities, {parties}, or {shares}"})
  except CatchableError as e:
    return $(%*{"error": "bad-shares", "detail": e.msg})
  # payTo: my own address on the rail — the private split's is my shielded key node. On
  # someone's behalf, the address THEY last shared (their signed address-share), never one
  # typed here; their own client checks it before agreeing (creditorAgreeRefusal).
  var payTo = addrHex(myAddress())
  if creditor != me:
    if lez: return $(%*{"error": "on-behalf-private", "detail":
                        "a private split is proposed by whoever fronted it: their shielded address is not shared in the room"})
    if btc: return $(%*{"error": "on-behalf-bitcoin", "detail":
                        "a Bitcoin split is proposed by whoever fronted it: the room's shared addresses are Ethereum ones"})
    gSession.poll()
    payTo = sharedAddressOf(gSession.roomEvents(), creditor)
    if payTo.len == 0: return $(%*{"error": "no-shared-address", "creditor": creditor})
  elif btc:
    # my own wpkh address on the split's network — where I pay from, and am paid at
    payTo = p2wpkhAddress(networkByCaip2(chain).hrp, moduleKeystore().btcPubKey())
  elif lez:
    payTo = ""
    try:
      for r in splitLezAdapter().receiveAddresses(moduleKeystore()):
        if r.form == "shielded": payTo = r.address
    except CatchableError as e: return $(%*{"error": "no-lez-wallet", "detail": e.msg})
    if payTo.len == 0: return $(%*{"error": "no-lez-wallet", "detail": "no shielded account to be paid at"})
  let effect = splitEffectJson(chain, asset, total, creditor, payTo, shares, memo, quote)
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  inc gMsgSeq
  # a fiat quote is this member's read: recorded before their own agreement (invariant 10)
  let id = liveProposeIntent(gSession, moduleKeystore(), driverFor, kind & "@" & chain, effect,
                             int64(epochTime()), gMsgSeq, account = chain & ":" & payTo, ttlSec = ttl,
                             reads = (if quote.quoted: @[(field: "quote", source: "quote:proposer")] else: @[]))
  if id.startsWith("0x"): id else: $(%*{"error": id})

proc musterCoordinateSettlePartImpl(intentId: string): string =
  ## Pay THIS member's share of an agreed split from their own wallet — the transfer is
  ## derived from the agreed effect (invariant 1); the report follows once it lands.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let policy = intentPolicyOf(gSession.roomEvents(), intentId)
  if splitPolicy(policy).kind notin ["evm-split", "lez-split", "btc-split"]: return $(%*{"error": "not-a-split"})
  if splitPolicy(policy).kind == "btc-split" and gBtcRpc.len == 0:
    return $(%*{"error": "no-btc-node", "detail": "a Bitcoin share is paid through your own node: Settings → Bitcoin node"})
  let seam = splitSeamFor(policy)
  # what this host already sent in this room and has not yet seen land: never paid twice
  loadSplitBook()
  let inFlight = gSplitBook.inFlight(gTopic)
  let (outcome, pp) = liveSettlePartSend(gSession, moduleKeystore(), driverFor, intentId, seam,
                                         uint64(epochTime()), inFlight)
  if outcome.len > 0: return $(%*{"error": outcome})
  gSplitBook.add(gTopic, pp, epochTime(), seam.payDeadlineS())
  gSplitSeams[intentId] = seam
  saveSplitBook()
  $(%*{"pending": pp.tx, "amount": pp.transfer.amount, "to": pp.transfer.to, "chain": pp.transfer.chain})

proc musterCoordinateConfirmPartImpl(intentId, part, tx: string): string =
  ## As the creditor, confirm one share: from this member's own read of `tx`, or — with no
  ## reference — received outside muster.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let policy = intentPolicyOf(gSession.roomEvents(), intentId)
  if splitPolicy(policy).kind notin ["evm-split", "lez-split", "btc-split"]: return $(%*{"error": "not-a-split"})
  let r = liveConfirmPart(gSession, moduleKeystore(), driverFor, intentId, part, splitSeamFor(policy), tx)
  if r in ["executable", "submitted", "settling", "final"]: $(%*{"state": r}) else: $(%*{"error": r})

# The dispatch at the C ABI has no try/except at the pinned SDK rev (muster_gen.nim), so a
# raise inside a handler would cross it: each split handler answers {error} instead.
proc musterCoordinateProposeSplit(chain, total, sharesJson, memo: string): string =
  try: result = musterCoordinateProposeSplitImpl(chain, total, sharesJson, memo)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP split propose " & result)

proc musterCoordinateSettlePart(intentId: string): string =
  try: result = musterCoordinateSettlePartImpl(intentId)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP split pay " & intentId & " " & result)

proc musterCoordinateTokenInfo(chain, token: string): string =
  ## A token a split may be paid in, as it describes itself (exo-5ab) — for the composer's
  ## "in a token" field: its decimals turn "0.9" into base units, its symbol labels the
  ## preview, and its address is shown beside it. Display only.
  let t = token.strip().toLowerAscii()
  let asset = (if t.startsWith("erc20:"): t else: "erc20:" & t)
  if not isErc20Asset(asset): return $(%*{"error": "not-a-token", "detail": token})
  var chain = chain
  if chain.len == 0:                     # "" = the chain your configured RPC serves
    let (ok, c, detail) = rpcChainCaip2()
    if not ok: return $(%*{"error": "no-rpc", "detail": detail})
    chain = c
  let info = tokenInfo(chain, asset[6 .. ^1])
  if info.decimals < 0:
    return $(%*{"error": "unreadable", "detail": "your RPC does not serve " & chain &
                                                 ", or " & asset[6 .. ^1] & " does not answer decimals()"})
  $(%*{"asset": asset, "token": asset[6 .. ^1], "symbol": info.symbol, "decimals": info.decimals})

proc musterCoordinateProposeSettleUpImpl(chain, asset, memo: string): string =
  ## Net the room's agreed, unpaid split shares on one chain and asset into fewer payments
  ## (exo-3c6): composed from the log (openParts), netted (netTransfers), and proposed —
  ## the proposer's agreement made then if they are a party. Returns the intent id or {error}.
  if gSession == nil: return $(%*{"error": "not-joined"})
  var chain = chain.strip()
  if chain.len == 0: chain = splitPolicy(gCoordKind).account
  if chain.len == 0:
    let (ok, c, detail) = splitChainFor("evm-split")
    if not ok: return $(%*{"error": "no-rpc", "detail": detail})
    chain = c
  if chain.startsWith("lez:"):
    return $(%*{"error": "not-netted", "detail": "the private split is never netted: its shares are told apart by amount"})
  let kind = (if chain.startsWith("bip122:"): "btc-split" else: "evm-split")
  if kind notin roomKinds(): return $(%*{"error": "not-admitted", "kind": kind})
  var a = asset.strip().toLowerAscii()
  let assetName =
    if a.len == 0 or a == "eth" or a == "btc": (if kind == "btc-split": "BTC" else: "ETH")
    elif a.startsWith("erc20:"): a
    else: "erc20:" & a
  gSession.poll()
  let covers = openParts(gSession.roomEvents(), driverFor, chain, assetName, uint64(epochTime()))
  if covers.len < 2:
    return $(%*{"error": "nothing-to-net", "detail": "fewer than two agreed, unpaid shares on " & chain & " in " & assetName})
  let effect = settleUpEffectJson(chain, assetName, covers, netTransfers(covers), memo)
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  inc gMsgSeq
  let id = liveProposeIntent(gSession, moduleKeystore(), driverFor, kind & "@" & chain, effect,
                             int64(epochTime()), gMsgSeq, account = chain, ttlSec = ttl)
  if id.startsWith("0x"): id else: $(%*{"error": id})

proc musterCoordinateRenewSplitImpl(intentId: string): string =
  ## Renew a split past its expiry (exo-a90.15): a settle-up of its unpaid shares
  ## (settle_up.renewalOf), proposed under the split's own policy.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.roomEvents()
  let (effect, why, _) = renewalOf(events, driverFor, intentId, uint64(epochTime()))
  if why.len > 0: return $(%*{"error": why})
  let policy = intentPolicyOf(events, intentId)
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  inc gMsgSeq
  let id = liveProposeIntent(gSession, moduleKeystore(), driverFor, policy, effect,
                             int64(epochTime()), gMsgSeq, account = splitPolicy(policy).account, ttlSec = ttl)
  if id.startsWith("0x"): id else: $(%*{"error": id})

proc musterCoordinateRenewSplit(intentId: string): string =
  try: result = musterCoordinateRenewSplitImpl(intentId)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP split renew " & intentId & " " & result)

proc musterCoordinateProposeSettleUp(chain, asset, memo: string): string =
  try: result = musterCoordinateProposeSettleUpImpl(chain, asset, memo)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP settle-up propose " & result)

# ── settling up across assets and chains (exo-a90.17, split-the-bill.md §4.13) ─────────
proc assetDecimals(chain, asset: string): int =
  ## An asset's decimals: ETH 18, BTC 8, a token's own decimals() through my RPC (-1 when
  ## unreadable) — for the composer's "1 BTC = 21.4 ETH" and the card, never a check.
  if asset == "ETH": 18
  elif asset == "BTC": 8
  elif isErc20Asset(asset): tokenInfo(chain, asset[6 .. ^1]).decimals
  else: -1

proc assetSymbol(chain, asset: string): string =
  if isErc20Asset(asset):
    let t = tokenInfo(chain, asset[6 .. ^1])
    if t.symbol.len > 0: t.symbol else: "units"
  else: asset

proc musterCoordinateOpenAssets(): string =
  ## What a settle-up across assets could cover: the open shares on every public rail,
  ## grouped by chain and asset (openPartsAll).
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  var groups: seq[(string, string)]
  var counts = initTable[(string, string), int]()
  for c in openPartsAll(gSession.roomEvents(), driverFor, uint64(epochTime())):
    let k = (c.chain, c.asset)
    if k notin counts: groups.add k
    counts[k] = counts.getOrDefault(k) + 1
  var arr = newJArray()
  for k in groups:
    arr.add %*{"chain": k[0], "chainLabel": chainLabel(k[0]), "asset": k[1], "parts": counts[k],
               "symbol": assetSymbol(k[0], k[1]),
               "decimals": assetDecimals(k[0], k[1])}
  # the chain a settle-up proposed with chain "" pays on: the compose policy's, else my RPC's
  var payChain = splitPolicy(gCoordKind).account
  if payChain.len == 0:
    let (ok, c, _) = splitChainFor("evm-split")
    if ok: payChain = c
  $(%*{"assets": arr, "payChain": payChain, "payChainLabel": chainLabel(payChain)})

proc musterCoordinateProposeSettleUpAcrossImpl(chain, asset, ratesJson, memo: string): string =
  ## Settle up across assets and chains: paid on `chain` in `asset`, covering every open
  ## share in it or in an asset `ratesJson` prices ({chain, asset, rate per ONE unit, source}).
  ## The rates go into base units on both sides (settleRate) and are proposed as MY recorded
  ## read (invariant 10).
  if gSession == nil: return $(%*{"error": "not-joined"})
  var chain = chain.strip()
  if chain.len == 0: chain = splitPolicy(gCoordKind).account
  if chain.len == 0:
    let (ok, c, detail) = splitChainFor("evm-split")
    if not ok: return $(%*{"error": "no-rpc", "detail": detail})
    chain = c
  if chain.startsWith("lez:"):
    return $(%*{"error": "not-netted", "detail": "the private split is never netted: its shares are told apart by amount"})
  let kind = (if chain.startsWith("bip122:"): "btc-split" else: "evm-split")
  if kind notin roomKinds(): return $(%*{"error": "not-admitted", "kind": kind})
  proc assetOf(chain, a: string): string =
    let x = a.strip().toLowerAscii()
    if x.len == 0 or x == "eth" or x == "btc": (if chain.startsWith("bip122:"): "BTC" else: "ETH")
    elif x.startsWith("erc20:"): x
    else: "erc20:" & x
  let payAsset = assetOf(chain, asset)
  let payDec = assetDecimals(chain, payAsset)
  if payDec < 0: return $(%*{"error": "unknown-decimals", "chain": chain, "asset": payAsset})
  var rates: seq[SettleRate]
  let now = uint64(epochTime())
  var rj: JsonNode
  try: rj = parseJson(if ratesJson.strip().len == 0: "[]" else: ratesJson)
  except CatchableError: return $(%*{"error": "bad-rates", "detail": "rates is a JSON array"})
  for r in rj.getElems():
    let rc = r{"chain"}.getStr().strip()
    let ra = assetOf(rc, r{"asset"}.getStr())
    let dec = assetDecimals(rc, ra)
    if dec < 0: return $(%*{"error": "unknown-decimals", "chain": rc, "asset": ra})
    let sr = settleRate(rc, ra, r{"rate"}.getStr(), payDec, dec, r{"source"}.getStr(), int64(now))
    if not sr.ok: return $(%*{"error": "bad-rate", "asset": ra, "detail": sr.why})
    rates.add sr.rate
  gSession.poll()
  let events = gSession.roomEvents()
  let composed = settleUpAcross(events, driverFor, chain, payAsset, rates, memo, now)
  if composed.why.startsWith("no-address:"):
    let who = composed.why["no-address:".len .. ^1]
    return $(%*{"error": "no-address", "who": who, "name": memberName(who, myIds()), "chain": chain,
                "chainLabel": chainLabel(chain),
                "detail": memberName(who, myIds()) & " has shared no address on " & chainLabel(chain) & " to be paid at"})
  if composed.why.len > 0: return $(%*{"error": composed.why})
  # my own agreement is made by proposing: never for an address this client does not hold
  let family = (if kind == "btc-split": BtcSplitFamily else: EvmSplitFamily)
  let mine = settleAgreeRefusal(effectFromJson(composed.effectJson),
                                toHex(moduleKeystore().encIdentity().toBytes()).toLowerAscii(), myPayTos(family))
  if mine.len > 0: return $(%*{"error": mine, "detail": "you would be paid at an address this client does not hold"})
  var ttl = DefaultIntentTtl
  try: ttl = parseBiggestInt(getEnv("MUSTER_INTENT_TTL_S", $DefaultIntentTtl))
  except ValueError: discard
  inc gMsgSeq
  let reads = (if rates.len > 0: @[(field: "rates", source: "rates:proposer")] else: @[])
  let id = liveProposeIntent(gSession, moduleKeystore(), driverFor, kind & "@" & chain, composed.effectJson,
                             int64(now), gMsgSeq, account = chain, ttlSec = ttl, reads = reads)
  if id.startsWith("0x"): id else: $(%*{"error": id})

proc musterCoordinateProposeSettleUpAcross(chain, asset, rates, memo: string): string =
  try: result = musterCoordinateProposeSettleUpAcrossImpl(chain, asset, rates, memo)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP settle-up across propose " & result)

proc musterCoordinateShareAddress(chain: string): string =
  ## Post MY address for `chain` as an author-signed address-share card: my Ethereum
  ## address, or the Bitcoin address of my own key on that network.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let c = chain.strip()
  var body: JsonNode
  if c.startsWith("bip122:"):
    var hrp = ""
    try: hrp = networkByCaip2(c).hrp
    except CatchableError: return $(%*{"error": "unknown-network", "chain": c})
    body = %*{"kind": "address-share", "asset": "BTC", "chain": c,
              "address": p2wpkhAddress(hrp, moduleKeystore().btcPubKey()), "form": 1}
  elif c.len == 0 or c.startsWith("eip155:"):
    body = %*{"kind": "address-share", "asset": "ETH", "address": addrHex(myAddress()).toLowerAscii(), "form": 1}
  else: return $(%*{"error": "no-shared-address", "detail": "nothing is paid to a shared address on " & c})
  let author = toHex(moduleKeystore().encIdentity().toBytes())
  inc gMsgSeq
  let (_, ev) = newMessageEvent(author, int64(epochTime()), $body, gMsgSeq)
  gSession.publishAuthored(moduleKeystore(), ev)
  $(%*{"address": body["address"].getStr()})

proc musterCoordinateConfirmPart(intentId, part, tx: string): string =
  try: result = musterCoordinateConfirmPartImpl(intentId, part, tx)
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP split confirm " & intentId & " " & result)

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
  if not ok: return (known: false, signers: @[], threshold: 0, detail: pd)   # unreachable, or cooling down
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
  if not ok: (result["detail"] = %pd; return)
  if "eip155:" & $chain != a.chain:
    result["detail"] = %("the configured RPC serves eip155:" & $chain & ", the account is on " & a.chain)
    return
  # stop at the first failed read: a node that did not answer one will not answer the next,
  # and each costs a read budget on the module thread (exo-14f; after a no-answer the
  # endpoint cools down, so the reads of the accounts after this one cost nothing, exo-14f.1)
  let m = getModules(gRpcUrl, toAddress(a.address))
  if not m.known: (result["detail"] = %m.detail; return)
  let g = getGuard(gRpcUrl, toAddress(a.address))
  if not g.known: (result["detail"] = %g.detail; return)
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
    gSession.publishAuthored(moduleKeystore(), accountDiscloseEvent(a, me))
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
    gSession.publishAuthored(moduleKeystore(), accountDiscloseEvent(a, me))
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
  gSession.publishAuthored(moduleKeystore(), accountDiscloseEvent(a, me))
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
  if kindSettlesOnChain(k):
    # a chain-qualified kind (a split, exo-a90): its qualifier is the CAIP-2 chain the
    # parties pay on — the one named, or the one this member's RPC serves
    var chain = acct
    if chain.len == 0:
      let (ok, c, detail) = splitChainFor(k)
      if not ok: return $(%*{"error": (if "lez" in kindInfo(k).settlesOn: "no-lez-wallet" else: "no-rpc"),
                             "kind": k, "detail": detail})
      chain = c
    if not isCaip2(chain) or chain.split(':')[0] notin kindInfo(k).settlesOn:
      return $(%*{"error": "a " & k & " policy settles on " & kindInfo(k).settlesOn.join("/") &
                           " chains, not " & chain, "kind": k})
    gCoordKind = qualify(k, chain)
    return $policyJson()
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
    let ctx = intentContext(gSession.roomEvents(), intentId)
    if not ctx.isPlaceholder and ctx.account.len > 0: account = ctx.account
  LinkContext(account: account, slot: "0", expiry: uint64(epochTime()) + 86_400)

proc musterCoordinateVote(intentId: string): string =
  ## Approve a vote-locus intent with this member's own on-chain vote (exo-3c9): S5
  ## re-read, the member's Approve signed by their LEZ key and awaited, confirmed on chain,
  ## then the receipt (coordination/vote.nim).
  if gSession == nil: return "not-joined"
  gSession.poll()
  let drv = driverFor(intentPolicyOf(gSession.roomEvents(), intentId))
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

var gApprovedHere = initHashSet[string]()   ## intents THIS instance approved in-app this session (exo-59c)

proc initialsOf(name: string): string =
  ## One or two letters for an approval slot: a contact's initials, "Y" for you, or the
  ## first two hex digits of an unnamed key.
  var n = name.strip()
  if n == "you": return "Y"
  for p in ["0x", "ed:", "frost:"]:
    if n.startsWith(p): n = n[p.len .. ^1]
  if n.len == 0: return ""
  let words = n.splitWhitespace()
  if words.len >= 2: return ($words[0][0] & $words[1][0]).toUpperAscii()
  n[0 ..< min(2, n.len)].toUpperAscii()

# ── approvals signed by keystore_module (exo-149.2 K2) ───────────────────────────
var gKeystoreProbe: KeystoreProbe = nil
var gKsReq: SignRequests                        ## pending requests: receipts never leave
var gKsPlans: Table[string, KeystoreApproval]   ## handle → what the human is approving
var gKsOutcome: Table[string, string]           ## handle → what publishing it returned
var gKsEndedAt: Table[string, float]            ## handle → when it reached a terminal state
var gKsBindingCtx: Table[string, LinkContext]   ## handle → a K5 binding request's context
const KsDeadlineS = 600.0                       ## Basecamp's intent backstop is 10 min
const KsKeepS = 120.0                           ## a finished request stays in view this long

proc keystoreProbe(): KeystoreProbe =
  if gKeystoreProbe == nil: gKeystoreProbe = newKeystoreProbe()
  gKeystoreProbe

proc isKeystoreAccount(keyRef: string): bool =
  ## A key ref muster's own keystore does not hold, which keystore_module last listed.
  gKeystoreBackend == "interim" and keyRef.len > 0 and
    not moduleKeystore().hasKey(keyRef) and keyRef.toLowerAscii() in keystoreProbe().lastAccounts()

proc keystoreContribute(intentId, account: string): string =
  ## Ask keystore_module for a human's approval of `intentId` with `account`. Returns at
  ## once ("awaiting-approval"); keystorePump publishes when the human has approved.
  let req = planKeystoreApproval(gSession, driverFor, intentId, account, uint64(epochTime()))
  if req.refusal.len > 0: return req.refusal
  if not gKsReq.canRequest(): return "keystore-busy"
  let ans = keystoreProbe().requestApproval($req.intent)
  if ans == nil: return "keystore-unreachable"
  if not ans{"ok"}.getBool(false): return "keystore-refused: " & ans{"error"}.getStr("refused")
  let h = ans{"handle"}.getStr()
  let rc = ans{"receipt"}.getStr()
  try:
    gKsReq.add(h, rc, intentId, account, req.legs, epochTime() + KsDeadlineS)
  except SignRequestError:
    keystoreProbe().fireAndForget("cancel_approval", h, rc)
    return "keystore-busy"
  gKsPlans[h] = req
  if gLpDebug: stderr.writeLine("MUSTER-LP keystore-request " & $(%*{"intentId": intentId, "handle": h}))
  "awaiting-approval"

proc keystoreBindingNow(): string =
  ## The selected account's binding, if it still stands (valid or expiring); else "".
  if gKeystoreAccount.len == 0: return ""
  let st = bindingState(gKeystoreBinding, gKeystoreAccount, moduleKeystore().encIdentity(),
                        uint64(epochTime()))
  if st in ["valid", "expiring"]: gKeystoreBinding else: ""

proc musterKeystore_select(address: string): string =
  ## exo-149.5: approve Safe intents with this keystore_module account ("" stops). Selecting
  ## asks keystore_module, once, for the account's F-14 binding (a human approves it in
  ## the signer); until it comes back, approvals publish without one.
  discard moduleKeystore()      # settings are loaded with the identity: never save before they are
  if address.strip().len == 0:
    gKeystoreAccount = ""
    gKeystoreBinding = ""
    saveSettingsFile()
    return $(%*{"ok": true, "account": ""})
  if gKeystoreBackend != "interim":
    return $(%*{"ok": false, "error": "keystore-backend is off: set it to interim first"})
  let a = address.strip().toLowerAscii()
  if a notin keystoreProbe().lastAccounts():
    return $(%*{"ok": false, "error": "keystore_module does not list " & a})
  if not gKsReq.canRequest(): return $(%*{"ok": false, "error": "keystore-busy"})
  let ctx = keystoreBindingContext(a, uint64(epochTime()))
  let req = bindingApproval(moduleKeystore().encIdentity(), ctx, a)
  let ans = keystoreProbe().requestApproval($req.intent)
  if ans == nil: return $(%*{"ok": false, "error": "keystore-unreachable"})
  if not ans{"ok"}.getBool(false):
    return $(%*{"ok": false, "error": "keystore-refused: " & ans{"error"}.getStr("refused")})
  let h = ans{"handle"}.getStr()
  let rc = ans{"receipt"}.getStr()
  try:
    gKsReq.add(h, rc, "", a, req.legs, epochTime() + KsDeadlineS)
  except SignRequestError:
    keystoreProbe().fireAndForget("cancel_approval", h, rc)
    return $(%*{"ok": false, "error": "keystore-busy"})
  gKsBindingCtx[h] = ctx
  gKeystoreAccount = a
  gKeystoreBinding = ""
  saveSettingsFile()
  if gLpDebug: stderr.writeLine("MUSTER-LP keystore-select " & $(%*{"account": a, "handle": h}))
  $(%*{"ok": true, "account": a, "handle": h, "state": "awaiting-approval"})

proc noteApproved(intentId, r: string): string =
  ## Remember an in-app approval that went through, for "approved by me" when the log
  ## alone cannot say (a FROST-group or LEZ-vote approval is named by a per-ceremony or
  ## per-membership key). A refusal is not an approval.
  const failures = ["not-joined", "unknown-intent", "unsupported-driver", "rejected", "expired",
                    "no-context", "unaccountable-input", "unknown-key", "attestation-mismatch"]
  if r notin failures and not r.startsWith("refused") and not r.startsWith("not-") and
     "\"error\"" notin r:
    gApprovedHere.incl intentId
  r

proc keystorePump() =
  ## On the intents tick: read where each keystore request stands; once a human approved,
  ## fetch, check (each signature recovers to the account over muster's own hash) and
  ## publish through the same gates as an in-app approval, then ack. Cancels what passed
  ## its deadline; forgets what finished a while ago.
  if gKeystoreProbe == nil or gKsReq.handles().len == 0: return
  let p = keystoreProbe()
  let now = epochTime()
  for rep in p.drainOps():
    if rep.handle notin gKsPlans and rep.handle notin gKsBindingCtx: continue
    if rep.op == "status":
      gKsReq.onStatus(rep.handle, rep.reply)
    elif rep.op == "fetch" and rep.handle notin gKsOutcome and rep.handle in gKsBindingCtx:
      # K5: the account's binding came back — keep it only if it binds THIS identity to it
      let got = gKsReq.onFetched(rep.handle, rep.reply)
      if got.ok:
        let account = gKsReq.accountOf(rep.handle)
        try:
          let st = bindingFromSignature(moduleKeystore().encIdentity(), gKsBindingCtx[rep.handle],
                                        got.sigs[0], account, uint64(now))
          if account == gKeystoreAccount:
            var hex = "0x"
            for b in encodeLink(st): hex.add toHex(b).toLowerAscii()
            gKeystoreBinding = hex
            saveSettingsFile()
          gKsOutcome[rep.handle] = "bound"
        except KeystoreLegError as e:
          gKsOutcome[rep.handle] = "binding refused: " & e.msg
        p.fireAndForget("ack_result", rep.handle, gKsReq.receiptOf(rep.handle))
        if gLpDebug: stderr.writeLine("MUSTER-LP keystore-bound " &
                                      $(%*{"account": account, "result": gKsOutcome[rep.handle]}))
    elif rep.op == "fetch" and rep.handle notin gKsOutcome and gSession != nil:
      let got = gKsReq.onFetched(rep.handle, rep.reply)
      if got.ok:
        let id = gKsReq.intentOf(rep.handle)
        let account = gKsReq.accountOf(rep.handle)
        let bindingHex = (if account == gKeystoreAccount: keystoreBindingNow() else: "")
        if gLpDebug: stderr.writeLine("MUSTER-LP keystore-publishing " &
                                      $(%*{"intentId": id, "handle": rep.handle, "binding": bindingHex.len}))
        let r = noteApproved(id, publishKeystoreApproval(gSession, driverFor, id, gKsPlans[rep.handle],
                                                         got.sigs, uint64(now), bindingHex))
        gKsOutcome[rep.handle] = r
        if gLpDebug: stderr.writeLine("MUSTER-LP keystore-acking " & rep.handle)
        p.fireAndForget("ack_result", rep.handle, gKsReq.receiptOf(rep.handle))
        if gLpDebug: stderr.writeLine("MUSTER-LP keystore-published " &
                                      $(%*{"intentId": id, "handle": rep.handle, "result": r}))
  for h in gKsReq.overdue(now): p.fireAndForget("cancel_approval", h, gKsReq.receiptOf(h))
  for h in gKsReq.due(now):
    p.fireOp("status", h, gKsReq.receiptOf(h))
    gKsReq.markPolled(h, now)
  for h in gKsReq.handles():
    let st = gKsReq.stateOf(h)
    if st == ssApproved and h notin gKsOutcome: p.fireOp("fetch", h, gKsReq.receiptOf(h))
    elif st != ssWaiting and st != ssShown and (st != ssApproved or h in gKsOutcome):
      if h notin gKsEndedAt: gKsEndedAt[h] = now
      elif now - gKsEndedAt[h] > KsKeepS:
        gKsReq.remove(h)
        gKsPlans.del h
        gKsBindingCtx.del h
        gKsOutcome.del h
        gKsEndedAt.del h
        dropIo(h)

proc musterKeystore_requests(): string =
  ## The keystore_module signing requests this member has open or just finished: never
  ## a receipt. The UI raises evm.signing.approve {handle} from here (K3).
  keystorePump()
  var rows = newJArray()
  for r in gKsReq.view():
    var row = r
    let h = r["handle"].getStr()
    if h in gKsOutcome: row["published"] = %gKsOutcome[h]
    row["kind"] = %(if h in gKsBindingCtx: "binding" else: "approval")
    rows.add row
  result = $(%*{"backend": gKeystoreBackend, "selected": gKeystoreAccount, "requests": rows})
  if gLpDebug: stderr.writeLine("MUSTER-LP keystore-requests " & result)

proc musterCoordinateContribute(intentId: string, signatureHex: string, keyRef: string): string =
  ## Add a contribution (in-app signed when `signatureHex` is empty, else pasted). The
  ## live contribute path lives in coordination/live.nim (exo-ef1) so it can be driven
  ## in-process; this is plumbing over the module's session + keystore. A vote-locus
  ## intent is approved by the member's own chain vote instead (coordinate_vote).
  if gSession == nil: return "not-joined"
  if signatureHex.len == 0:
    let drv = driverFor(intentPolicyOf(gSession.roomEvents(), intentId))
    if drv of SplitDriver:
      # the creditor's agreement is their word that payTo is theirs (exo-770): never given
      # for an address this client does not hold
      let why = creditorAgreeRefusal(effectFromJson(effectJsonOf(gSession.roomEvents(), intentId)),
                                     toHex(moduleKeystore().encIdentity().toBytes()).toLowerAscii(),
                                     myPayTos(drv.profile().family))
      if why.len > 0: return why
      # a settle-up across chains paying me at an address I vouch for: only one I hold (§4.13)
      let whySettle = settleAgreeRefusal(effectFromJson(effectJsonOf(gSession.roomEvents(), intentId)),
                                         toHex(moduleKeystore().encIdentity().toBytes()).toLowerAscii(),
                                         myPayTos(drv.profile().family))
      if whySettle.len > 0: return whySettle
    if drv of LezMultisigDriver: return noteApproved(intentId, musterCoordinateVote(intentId))
    if drv.frostGroupOf().ok:
      # a FROST approval (Bitcoin or LEZ) is two rounds: this member's nonces now, its partial signature
      # under the log's signer set once round 1 closes (frostPump) — one approval, two halves
      let r = liveFrostContribute(gSession, moduleKeystore(), driverFor, intentId, uint64(epochTime()))
      if r in ["collecting", "executable"] or r.startsWith("waiting") or r == "already-contributed":
        if intentId notin gFrostAuto: gFrostAuto.add intentId
      return noteApproved(intentId, r)
  # exo-149.2: a key ref naming a keystore_module account is approved by a human there;
  # nothing is published until they have (keystorePump). Not an approval yet, so it does
  # not pass through noteApproved.
  var keyRef = keyRef
  if signatureHex.len == 0 and keyRef.len == 0 and gKeystoreBackend == "interim" and
     gKeystoreAccount.len > 0 and
     driverFor(intentPolicyOf(gSession.roomEvents(), intentId)) of SafeDriver:
    keyRef = gKeystoreAccount       # exo-149.5: the member's selected account approves its Safe intents
  if signatureHex.len == 0 and isKeystoreAccount(keyRef):
    return keystoreContribute(intentId, keyRef.toLowerAscii())
  let r = liveContribute(gSession, moduleKeystore(), driverFor, intentId, signatureHex, keyRef,
                         intentLinkContext(intentId), uint64(epochTime()))
  if signatureHex.len == 0: noteApproved(intentId, r) else: r

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
  splitPump()                          # report my landed payments; confirm what paid me (exo-a90)
  keystorePump()                       # publish what a human approved in keystore_module (exo-149.2)
  let events = gSession.roomEvents()
  let myEnc = moduleKeystore().encIdentity()
  let myEncHex = toHex(myEnc.toBytes()).toLowerAscii()
  let myNames = myNames()
  let mine = @[myEncHex] & myNames
  let nowS = uint64(epochTime())
  let views = reduceIntentViews(events, driverFor)
  let coveredNow = coverIndex(events, driverFor, views, nowS)
  # intents a proposal not yet agreed would settle part of (a renewal waiting for everyone):
  # not offered for renewal again meanwhile (exo-a90.15)
  var pendingCover: HashSet[string]
  for w in views:
    if w.state notin ["proposed", "collecting"]: continue
    try:
      for c in driverFor(w.policy).covers(effectFromJson(w.effectJson)): pendingCover.incl c.intent
    except CatchableError: discard
  var arr = newJArray()
  for v in views:
    # Each intent renders under ITS OWN driver — the policy it was proposed with
    # (v.policy) — so a room carrying a Safe intent and a threshold intent shows each
    # honestly at once (invariant 6). txhash is the driver-re-derived materialization —
    # the exact bytes a member signs (Safe's safeTxHash, or the threshold driver's
    # dCBOR materialization); threshold + domain come from describe(), never hardcoded.
    let drv = driverForKind(v.policy)
    let desc = describeFor(drv, effectFromJson(v.effectJson))   # THIS proposal's policy (exo-a90.2)
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
      let alias = (if item.account.len > 0: contactBook().nameFor(item.account) else: "")
      prov.add %*{"class": $item.cls, "logPos": item.logPos,
                  "account": item.account, "alias": alias,
                  "accountable": item.accountable, "what": item.what,
                  "detail": item.detail, "guarantee": item.guarantee,
                  # an approval's grade (exo-ef1): committed | unattested; "" otherwise
                  "attestation": item.attestation}
    o["provenance"] = prov
    let chainPending = lezPendingFor(v.id)   # "vote" | "settle" while the chain has not included it
    if chainPending.len > 0: o["chainPending"] = %chainPending
    # What it moves, in the family's own words and unit — the same reading the history
    # uses (effect_summary.nim), so a Bitcoin spend or a LEZ call shows its amount (exo-59c).
    let sm = effectSummary(v.effectJson)
    o["summary"] = %*{"kind": sm.kind, "amount": sm.amount, "unit": sm.unit, "to": sm.to, "text": sm.text}
    # Who approved, named from the address book (or "you"), and whether I did — read
    # from the log + my keys (attest.approvedByMe), or an in-app approval made here.
    var whos: seq[string]
    for g in approvalGrades(events, driverFor, v.id):
      if g.grade != agRejected and g.who notin whos: whos.add g.who
    var approvers = newJArray()
    for w in whos:
      let me = approvedByMe(events, v.id, @[w], myEnc, myNames)
      let name = (if me: "you" else: memberName(w, mine))
      approvers.add %*{"who": w, "name": name, "mine": me,
                       "initials": initialsOf(if name.len > 0: name else: w)}
    o["approvers"] = approvers
    o["approvedByMe"] = %(approvedByMe(events, v.id, whos, myEnc, myNames) or v.id in gApprovedHere)
    var decl = newJArray()
    for d in v.decliners:
      decl.add %*{"who": d, "name": memberName(d, mine)}
    o["declinerNames"] = decl
    # who proposed it — only a signed claim names anyone (exo-770); [] = unattributed
    var props = newJArray()
    for p in v.proposers:
      props.add %*{"who": p, "name": (if p == myEncHex: "you" else: memberName(p, mine)), "mine": p == myEncHex}
    o["proposedBy"] = props
    if prof.family in [EvmSplitFamily, BtcSplitFamily] and isSettleUp(effectFromJson(v.effectJson)):
      # a settle-up (exo-3c6): the net payments instead of the shares they cover — each with
      # its payer and recipient named, and where it stands (only what each disclosed, inv 9)
      try:
        let su = settleUpOf(effectFromJson(v.effectJson))
        var ts = newJArray()
        for t in su.transfers:
          let part = settlePart(t)
          var st = PartView()
          for pv in v.parts:
            if pv.part == part: st = pv
          # across chains (§4.13): a recipient owed only elsewhere, paid at an address they vouch for
          let vouched = su.rates.len > 0 and
                        not su.covers.anyIt(it.creditor == t.to and it.chain == su.chain and it.payTo == t.payTo)
          ts.add %*{"part": part, "from": t.frm, "fromName": memberName(t.frm, mine), "to": t.to,
                    "toName": memberName(t.to, mine), "amount": t.amount, "payTo": t.payTo,
                    "mine": t.frm == myEncHex, "toMe": t.to == myEncHex, "settled": st.settled,
                    "confirmed": st.confirmed, "tx": st.tx, "paying": splitPayingFor(v.id, part),
                    "unresolved": splitUnresolvedFor(v.id, part), "vouched": vouched,
                    "payToMine": t.to == myEncHex and
                                 settleAgreeRefusal(effectFromJson(v.effectJson), myEncHex, myPayTos(prof.family)).len == 0}
        var splits: seq[string]
        for c in su.covers:
          if c.intent notin splits: splits.add c.intent
        let tok = (if isErc20Asset(su.asset): tokenInfo(su.chain, su.asset[6 .. ^1]) else: ("", -1))
        # past its expiry with nothing paid, it pays nothing more; once the grace window has
        # passed too it covers nothing, and its shares are payable directly (exo-a90.16)
        let ctx = intentContext(events, v.id)
        let expiredUnpaid = not ctx.isPlaceholder and ctx.expired(nowS) and not beganSettling(v) and
                            su.transfers.len > 0
        # across assets (§4.13): each rate as signed and per ONE unit of its asset (in the
        # payment asset's base units, for the card to format), and the assets the covers are in
        var rs = newJArray()
        for r in su.rates:
          let dec = assetDecimals(r.chain, r.asset)
          rs.add %*{"chain": r.chain, "asset": r.asset, "symbol": assetSymbol(r.chain, r.asset), "decimals": dec,
                    "rate": r.rate, "per": r.per, "perUnit": ratePerUnit(r, dec), "source": r.source, "at": r.at}
        var inAssets = newJArray()
        var seenAssets: seq[string]
        for c in su.covers:
          if (c.chain & "|" & c.asset) in seenAssets: continue
          seenAssets.add c.chain & "|" & c.asset
          inAssets.add %*{"chain": c.chain, "chainLabel": chainLabel(c.chain), "asset": c.asset,
                          "symbol": assetSymbol(c.chain, c.asset),
                          "shares": su.covers.countIt(it.chain == c.chain and it.asset == c.asset)}
        o["settleUp"] = %*{"asset": su.asset, "memo": su.memo, "covers": su.covers.len, "splits": splits.len,
                           "chain": su.chain, "chainLabel": chainLabel(su.chain), "across": su.rates.len > 0,
                           "rates": rs, "coverAssets": inAssets,
                           "expired": expiredUnpaid, "lapsed": coverLapsed(events, driverFor, v, nowS),
                           "releasesAt": (if expiredUnpaid: $(ctx.expiry + CoverReleaseGraceS) else: ""),
                           "transfers": ts, "iAmParty": myEncHex in settleParties(su),
                           "decimals": (if su.asset == "BTC": 8 elif isErc20Asset(su.asset): max(tok[1], 0) else: 18),
                           "symbol": (if isErc20Asset(su.asset): (if tok[0].len > 0: tok[0] else: "units") else: su.asset)}
      except CatchableError: discard
    if v.parts.len > 0 and prof.family in [EvmSplitFamily, LezSplitFamily, BtcSplitFamily]:
      # a split (exo-a90): each person's share and where it stands — only what each disclosed
      # (their agreement, their payment report) and what the creditor confirmed (invariant 9)
      try:
        let sp = splitOf(effectFromJson(v.effectJson))
        var sum = "0"
        var parts = newJArray()
        for pv in v.parts:
          var who, amount = ""
          for sh in sp.shares:
            if partName(sh.who) == pv.part: (who = sh.who; amount = sh.amount)
          sum = addDec(sum, (if amount.len > 0: amount else: "0"))
          parts.add %*{"part": pv.part, "who": who,
                       "name": memberName(who, mine),
                       "amount": amount, "settled": pv.settled, "confirmed": pv.confirmed,
                       "tx": pv.tx, "mine": who == myEncHex, "paying": splitPayingFor(v.id, pv.part),
                       "unresolved": splitUnresolvedFor(v.id, pv.part),
                       # paid only through a settle-up that covers it, while one does (exo-3c6, exo-a90.16)
                       "covered": not pv.settled and not pv.confirmed and v.id & "/" & pv.part in coveredNow,
                       # confirmed with no chain reference because a settle-up paid it (exo-a90.19)
                       "settledUp": pv.confirmed and pv.tx.len == 0 and v.id & "/" & pv.part in coveredNow}
        o["parts"] = parts
        # a token says its own symbol and decimals (display only, exo-5ab); ETH and LEZ are known
        let tok = (if isErc20Asset(sp.asset): tokenInfo(sp.chain, sp.asset[6 .. ^1]) else: ("", -1))
        let sctx = intentContext(events, v.id)
        let splitExpired = not sctx.isPlaceholder and sctx.expired(nowS)
        o["split"] = %*{"total": sp.total, "asset": sp.asset, "payTo": sp.payTo, "memo": sp.memo,
                        # the asset's decimals, so the card shows 0.3 LEZ, not 0.0000000003
                        "decimals": (if sp.asset == "LEZ": 9 elif sp.asset == "BTC": 8
                                     elif isErc20Asset(sp.asset): max(tok[1], 0) else: 18),
                        "symbol": (if isErc20Asset(sp.asset): (if tok[0].len > 0: tok[0] else: "units") else: sp.asset),
                        "token": (if isErc20Asset(sp.asset): sp.asset[6 .. ^1] else: ""),
                        "private": prof.family == LezSplitFamily,
                        "creditor": sp.creditor, "iAmCreditor": sp.creditor == myEncHex,
                        "creditorName": memberName(sp.creditor, mine),
                        # the creditor is a party (exo-770): whether they agreed, and — on MY
                        # client, when I am the creditor — whether payTo is an address I hold
                        "creditorAgreed": partName(sp.creditor) in whos,
                        "payToMine": sp.creditor == myEncHex and
                                     creditorAgreeRefusal(effectFromJson(v.effectJson), myEncHex,
                                                          myPayTos(prof.family)).len == 0,
                        "creditorShare": subDec(sp.total, sum),
                        # past its expiry (exo-a90.15): no share of it is paid any more; while a
                        # share is unpaid and not being settled, it can be renewed (renewalOf)
                        "expired": splitExpired,
                        "renewable": splitExpired and v.id notin pendingCover and
                                     renewalOf(events, driverFor, v.id, nowS).why.len == 0,
                        "renewalPending": splitExpired and v.id in pendingCover}
        # a bill in fiat (exo-3a4): the quote the room is trusting — its currency, amount,
        # rate, source and time — for the card to name before anyone agrees
        if sp.quote.quoted:
          o["split"]["quote"] = %*{"currency": sp.quote.currency, "fiatTotal": sp.quote.fiatTotal,
                                   "fiatDecimals": sp.quote.fiatDecimals, "rateAsset": sp.quote.rateAsset,
                                   "rateFiat": sp.quote.rateFiat, "source": sp.quote.source, "at": sp.quote.at}
      except CatchableError: discard
    arr.add o
  $arr

proc musterCoordinateDecline(intentId: string): string =
  ## Decline to take part (the card's Deny). Keyed by THIS member's encryption identity
  ## (the same author id messages carry) so it folds once. Informational — the
  ## threshold is untouched; dropping is driver policy, not core policy.
  if gSession == nil: return $(%*{"error": "not-joined"})
  gSession.poll()
  let events = gSession.roomEvents()
  if effectJsonOf(events, intentId).len == 0:
    return $(%*{"error": "unknown-intent", "intentId": intentId})
  let who = toHex(moduleKeystore().encIdentity().toBytes())
  gSession.publishAuthored(moduleKeystore(), declineEvent(intentId, who))
  let after = gSession.roomEvents()
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
  let events = gSession.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let drv = driverForKind(intentPolicyOf(events, intentId))
  let effect = effectFromJson(effectJson)
  let m = drv.manifest(effect)
  # a share is offered only to a member who settles a part (exo-272): never the creditor
  let pays = drv.settlesAPart(effect, myNames())
  var o = offersPayload(recipientOffers(m.requirements, moduleCatalogue(), m, pays))
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
  let events = gSession.roomEvents()
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
  gSession.publishAuthored(moduleKeystore(), materialShareEvent(intentId, requirement, who, publicFace, form, class, field))
  result = $(%*{"intentId": intentId, "requirement": requirement, "field": field, "public": publicFace})
  if gLpDebug: stderr.writeLine("MUSTER-LP share_material " & result)

proc musterCoordinateProvenance(): string =
  ## Provenance for EVERY action in the room (M4): the log's lineage, each entry
  ## classed by the F-20 vocabulary and graded by the guarantee the code enforces.
  if gSession == nil: return "[]"
  gSession.poll()
  var arr = newJArray()
  for it in logProvenance(gSession.roomEvents(), driverFor):
    let alias = (if it.account.len > 0: contactBook().nameFor(it.account) else: "")
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
  $buildProof(gSession.log.allEvents(), 0, epochTo).toJson()   # the raw log: a proof accounts for every entry, forgeries included (exo-f76)

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
  let res = exportAudit(gSession.roomEvents(), driverFor, intentId, moduleKeystore())
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
  let events = gSession.roomEvents()
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
  let events = gSession.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let st = intentState(events, driverFor, intentId)
  if st != "executable":
    return $(%*{"error": "not-executable", "intentId": intentId, "state": st})
  let policy = intentPolicyOf(events, intentId)
  let folded = reduceIntents(events, driverFor)
  let root = folded[intentId].materialization.bytes
  let akind = splitPolicy(policy).kind
  # The grant binds to exactly the context the approvals were attested under (invariant 2,
  # exo-ef1): the intent's DECLARED context — its environment() (CAIP-2) and account —
  # never a second spelling of it rebuilt here (exo-ec8). A legacy proposal that declared
  # no context binds to this room, as before.
  let ctx = intentContext(events, intentId)
  let (environment, account) =
    if ctx.isPlaceholder: ("room", "room") else: (ctx.environment, ctx.account)
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
  var facts = HostFacts(rpcUrl: gRpcUrl, lezRpcUrl: gLezRpc, myAddress: myAddress(),
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
  let events = gSession.roomEvents()
  let effectJson = effectJsonOf(events, intentId)
  if effectJson.len == 0: return $(%*{"error": "unknown-intent", "intentId": intentId})
  let policy = intentPolicyOf(events, intentId)
  let drv = driverForKind(policy)
  let effect = effectFromJson(effectJson)
  let m = drv.manifest(effect)
  var facts = hostFacts(policy)
  # whether YOUR contribution to THIS intent would count, in the driver's own words — how a
  # split's parties (named in the effect) are graded (exo-272)
  facts.contributes = drv.mayContribute(effect, myNames())
  facts.pays = drv.settlesAPart(effect, myNames())   # is a share mine to pay
  let r = assessReadiness(m, probeFromFacts(facts))
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
  let events = gSession.roomEvents()
  let myEnc = moduleKeystore().encIdentity()
  let myNames = myNames()
  let mine = @[toHex(myEnc.toBytes()).toLowerAscii()] & myNames
  for a in reduceActivity(events, driverFor):
    # every line with a person in it — an approval, a decline, a part paid or confirmed —
    # names them as the card does: "you", the alias, or one short id (exo-59c, exo-221).
    # An approval this member made under a key the list misses is still "you".
    let title =
      if a.kind == "approve" and a.account.len > 0 and
         approvedByMe(events, a.intentId, @[a.account], myEnc, myNames): "Approved by you"
      elif a.kind == "propose":
        # "Proposed a split — …: 0.6 ETH, 1 person owes you": the effect's own people, named,
        # and a token in its own decimals and symbol (display only, exo-5ab)
        let ej = effectJsonOf(events, a.intentId)
        var onChain = ""
        try: onChain = parseJson(ej){"chain"}.getStr()
        except CatchableError: discard
        "Proposed " & effectSummary(ej, proc(who: string): string = memberName(who, mine),
                                    proc(asset: string): tuple[symbol: string, decimals: int] =
                                      tokenInfo(onChain, asset[6 .. ^1])).text
      else: activityTitle(a, proc(who: string): string = memberName(who, mine))
    arr.add %*{"seq": a.seq, "kind": a.kind, "intentId": a.intentId,
               "account": a.account, "title": title, "detail": a.detail}
  $arr

proc introducersJson(who: seq[Introducer]): JsonNode =
  result = newJArray()
  for w in who: result.add %*{"intentId": w.intentId, "policy": w.policy}

# ── the node's RLN membership (exo-eb6.3 R1) ─────────────────────────────────────
var gRlnProbe: RlnProbe = nil
var gRlnNode: tuple[state, message: string]
var gRlnNodeAt = 0.0

proc rlnRowNow(): JsonNode =
  ## This node's RLN membership row. Off logos.test it costs nothing; on it, delivery's
  ## state (local) is read at most every 5 s and the RLN modules' replies through the
  ## probe, whose chain reads never block this thread.
  let preset = presetOf(gDeliveryConfig)
  if preset == RlnPreset and gSession != nil and epochTime() - gRlnNodeAt > 5.0:
    gRlnNode = parseRlnState(gSession.rlnState())
    gRlnNodeAt = epochTime()
  elif gSession == nil:
    gRlnNode = ("", "")
  if gRlnProbe == nil: gRlnProbe = newRlnProbe()
  rlnRow(gRlnProbe.read(preset, gRlnNode.state, gRlnNode.message))

proc musterRln_status(): string =
  try: result = $rlnRowNow()
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP rln " & result)

# ── the official EVM keystore (exo-149.1 K1) ─────────────────────────────────────

proc musterKeystore_status(): string =
  ## keystore_module as a status row: does it attribute our calls to muster_module, is
  ## an approver named, which accounts could we ask it to sign with. The probe's reads
  ## are async, so this never waits on keystore_module (it may be busy in an approve).
  try:
    if gKeystoreProbe == nil: gKeystoreProbe = newKeystoreProbe()
    var row = keystoreRow(gKeystoreProbe.read())
    row["backend"] = %gKeystoreBackend
    row["selected"] = %gKeystoreAccount
    row["binding"] = %(if gKeystoreAccount.len == 0: "none"
                      else: bindingState(gKeystoreBinding, gKeystoreAccount,
                                         moduleKeystore().encIdentity(), uint64(epochTime())))
    result = $row
  except CatchableError as e: result = $(%*{"error": "failed", "detail": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP keystore " & result)

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
  # the node's RLN membership (exo-eb6.3), only where the room relies on it: a node on
  # logos.test sends nothing without one; elsewhere it is no dependency (exo-428), and
  # rln_status says "not needed" for Settings
  if presetOf(gDeliveryConfig) == RlnPreset: rows.add rlnRowNow()
  if gSession == nil:
    result = $(%*{"rows": rows})
    if gLpDebug: stderr.writeLine("MUSTER-LP connectivity " & result)
    return
  gSession.poll()
  let needs = roomInfraNeeds(gSession.roomEvents(), driverFor)
  # ── the RPC: one endpoint serves both an `infra:rpc` need and every `environment:
  # eip155:<id>` need, so they fold into ONE row, probed once (eth_chainId) against the
  # chain(s) the introducing proposals need.
  var rpcWho: seq[Introducer]
  var chains: seq[int]
  for n in needs:
    if not n.declared: continue
    let r = n.requirement
    if (r.kind == rqInfra and r.name == "rpc") or
       (r.kind == rqEnvironment and r.name.startsWith("eip155:")):
      for w in n.introducedBy: (if w notin rpcWho: rpcWho.add w)
      if r.kind == rqEnvironment:
        try: (let c = parseInt(r.name[7 .. ^1]); (if c notin chains: chains.add c))
        except ValueError: discard
  if rpcWho.len > 0:
    let row = rpcConnectivityRow(gRpcUrl, chains)   # the endpoint redacted (exo-14f.2)
    row["introducedBy"] = introducersJson(rpcWho)
    rows.add row
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
       (r.kind == rqEnvironment and r.name.startsWith("eip155:")): continue
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
  if drv of LezFrostDriver:
    # a FROST group's LEZ call (exo-55e): no member sends it as themselves — the group's
    # aggregate signature is the witness — so any member's instance submits it; the pump
    # watches for inclusion
    let a = LezFrostDriver(drv).account
    let c = lezLiveFor(a.chain, psLee02, newSeq[byte](32), plAccountIds)
    c.waitForInclusion = false
    return settlementFor(drv, c, Account(chain: a.chain, form: afPublic, id: a.address))
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
  let events = gSession.roomEvents()
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
                  "detail": e.msg & " — the Bitcoin node (" & redactUrl(gBtcRpc) & ") refused or could not be reached"})
    return $(%*{"id": intentId, "error": "rpc-unreachable", "relayer": gRelayer,
                "detail": e.msg & " — the relayer (" & asm0.tx.frm.id & ") must be able to pay gas on " &
                          asm0.tx.frm.chain & "; fund it, or set Settings → relayer"})
  # Fold the room forward: submit event → every member converges on "submitted".
  gSession.publish(submitEvent(intentId, chainRef = txRef.id))
  # Observe finality from the chain (never asserted), within SubmitWatchS of wall clock and
  # one read's budget (exo-14f): a slow, unreachable or hung node reports "pending" rather
  # than holding the module thread.
  let fin = st.watchWithin(txRef, SubmitWatchS)
  if fin.status == fsFinal: gSession.publish(finalEvent(intentId, chainRef = txRef.id))
  elif fin.status == fsPending:
    # Not final within ~4s (a block to come: a LEZ Execute, a Bitcoin confirmation, a slow
    # EVM node): the pump keeps watching and publishes final when the chain says so (exo-59c;
    # it used to watch only the LEZ, so a Safe or Bitcoin settle sat at "submitted").
    gLezPending.add LezPending(kind: lpSettle, session: gSession, settle: st, txRef: txRef, intentId: intentId,
                               started: epochTime())
  let onchain = (case fin.status
                 of fsFinal: "final"
                 of fsFailed: "failed"
                 else: "pending")
  $(%*{"id": intentId,
       "state": intentState(gSession.roomEvents(), driverFor, intentId),
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
    if j.hasKey("shards"):
      # a v0.3 call (exo-eb6.4.4): {target, shards: [{account, program}], data (hex), pdaSeeds}
      var shards: seq[tuple[account, program: seq[byte]]]
      for x in j["shards"]: shards.add (lezIdOf(x["account"].getStr()), lezIdOf(x["program"].getStr()))
      var data: seq[byte]
      var h = j["data"].getStr()
      if h.startsWith("0x"): h = h[2 .. ^1]
      for i in 0 ..< h.len div 2: data.add byte(parseHexInt(h[2*i .. 2*i+1]))
      return lezProposeAction(lezCallV03(lezIdOf(j["target"].getStr()), shards, data,
                                         j{"pdaSeeds"}.getElems().mapIt(lezIdOf(it.getStr()))))
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

proc lezFrostTransfer(recipient, amount: string): string =
  ## A FROST group's own LEZ account sends `amount` of the token it holds: token Transfer
  ## signed by the group, at the account's nonce read from the chain (a recorded read).
  let (_, pacct) = splitPolicy(gCoordKind)
  let (found, a) = findAccount(roomAccounts(), pacct)
  if not found: return $(%*{"error": "not-a-lez-policy", "detail": "the account is not disclosed in this room"})
  var rec = ""
  try: rec = parseJson(a.config)["recovery"].getStr()
  except CatchableError: return $(%*{"error": "not-a-lez-policy", "detail": "no recovery data"})
  let (ok, acct, detail) = lezFrostAccountOfDisclosure(a.chain, a.address, rec)
  if not ok: return $(%*{"error": "not-a-lez-policy", "detail": detail})
  var to: seq[byte]
  var amt: uint64
  try:
    to = lezIdOf(recipient)
    amt = uint64(parseBiggestUInt(amount.strip()))
  except CatchableError as e:
    return $(%*{"error": "not-an-action", "detail": "a recipient account (hex or base58) and a whole amount: " & e.msg})
  let words = @[0'u32, uint32(amt and 0xffff_ffff'u64), uint32(amt shr 32), 0'u32, 0'u32]
  var effectJson: string
  try:
    let rpc = newLezRpc(gLezRpc)
    let now = rpc.getAccount(acct.accountId)
    if now.v3:
      # the zone runs LEZ v0.3.0 (exo-eb6.4 L3): a native transfer from the group's own
      # account, which pays its own fee (the LEZ wallet's default declaration). Settlement
      # sends it only when the account covers it and that fee's cap (exo-eb6.4.6): say so
      # now, before the room runs two rounds for a transfer that cannot be sent
      let cap = defaultFee(acct.accountId).maxFee
      if now.balance < amt.stuint(128) + cap:
        return $(%*{"error": "not-covered", "detail": "the group's account holds " & $now.balance &
                    ", which does not cover " & $amt & " and its fee cap (" & $cap & "): on LEZ v0.3 a " &
                    "transfer it cannot cover would be included, pay its gas and move nothing"})
      effectJson = lezFrostCallEffect3(NativeTokenProgram, @[nativeShard(acct.accountId), nativeShard(to)],
                                       nativeTransfer(amt.stuint(128)), acct.accountId, @[now.nonce],
                                       some defaultFee(acct.accountId))
    else:
      effectJson = lezFrostCallEffect(rpc.programId("token"), @[acct.accountId, to], words, acct.accountId,
                                      now.nonce)
  except CatchableError as e:
    return $(%*{"error": "sequencer-unreachable", "detail": e.msg})
  let id = musterCoordinatePropose(effectJson)
  if not id.startsWith("0x"): return $(%*{"error": "refused", "detail": id})
  # the nonce came from the user's sequencer: the read is recorded (invariant 10)
  gSession.publish(readEvent(id, "nonces", "lez:getAccount", $parseJson(effectJson)["nonces"]))
  id

proc musterCoordinateProposeLezTransfer(recipient, amount: string): string =
  ## Transfer `amount` of the vault's token to `recipient`: token Transfer (variant 0,
  ## amount a u128 = four words), the vault the authorized PDA. For a FROST group's own
  ## LEZ account (lez-frost@), the group sends from the account itself.
  if gSession == nil: return $(%*{"error": "not-joined"})
  if splitPolicy(gCoordKind).kind == "lez-frost": return lezFrostTransfer(recipient, amount)
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return err
  var to: seq[byte]
  var amt: uint64
  try:
    to = lezIdOf(recipient)
    amt = uint64(parseBiggestUInt(amount.strip()))
  except CatchableError as e:
    return $(%*{"error": "not-an-action", "detail": "a recipient account (hex or base58) and a whole amount: " & e.msg})
  let vault = vaultPda(acct.scheme, acct.program, acct.createKey)
  if acct.layout == plV03:
    # the v0.3 port (exo-eb6.4.4): the vault holds native LEZ; a native transfer out of it,
    # the vault authorized to the native program by its seed
    let zero = newSeq[byte](32)
    return lezProposeAction(lezCallV03(NativeTokenProgram, @[(vault, zero), (to, zero)],
                                       nativeTransfer(amt.stuint(128)), @[vaultSeed(acct.createKey)]))
  let words = @[0'u32, uint32(amt and 0xffff_ffff'u64), uint32(amt shr 32), 0'u32, 0'u32]
  let (tok, action, terr) = lezTokenAction(@[vault, to], words, 0)
  if not tok: return terr
  lezProposeAction(action)

proc musterCoordinateProposeLezVaultInit(definition: string): string =
  ## Initialize the vault as a holding of the token `definition`: token
  ## InitializeAccount (variant 3), the vault the authorized PDA.
  if gSession == nil: return $(%*{"error": "not-joined"})
  let (ok, acct, err) = lezComposeAccount()
  if not ok: return err
  if acct.layout == plV03:
    return $(%*{"error": "not-an-action", "detail": "on LEZ v0.3 the vault holds native LEZ and needs no setup: " &
                "fund it by sending to " & lezHx(vaultPda(acct.scheme, acct.program, acct.createKey))})
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
  if not ceremonyView(gSession.roomEvents(), ceremonyId.strip()).open:
    return $(%*{"error": "not-open", "detail": "no ceremony " & ceremonyId & " is open in this room"})
  let host = frostCeremonyJoin(gSession, moduleKeystore(), ceremonyId.strip())
  gFrostJoined.add (gSession, ceremonyId.strip())
  $(%*{"ceremony": ceremonyId.strip(), "host": host})

proc musterFrostCeremonies(): string =
  if gSession == nil: return "[]"
  gSession.poll()
  frostPump()
  let events = gSession.roomEvents()
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
    # which line the zone runs, from how it answers (account_view): on v0.3 the program is
    # the port (exo-eb6.4.4), whose create is the creator's own transaction, and fee
    let v3 = newLezRpc(gLezRpc).getAccount(program).v3
    let layout = if v3: plV03 else: plAccountIds
    let c = lezLiveFor(gLezChain, psLee02, program, layout)
    c.waitForInclusion = false         # never wait on a block inside a hosted call
    var creator: seq[byte]
    if v3:
      let (mine, me) = c.lezOurMember(ms)
      if not mine:
        return $(%*{"error": "refused", "detail": "on LEZ v0.3 the create is a member's own transaction, and pays " &
                    "its fee: name one of your LEZ member accounts among the members"})
      creator = me
    let t = c.submit(creator, createOp(ck, k, ms))
    if not t.ok: return $(%*{"error": "refused", "detail": t.error})
    let config = %*{"program": gLezProgram, "createKey": lezHx(ck), "pda": "lee-v0.2", "layout": $layout}
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
  let events = gSession.roomEvents()
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
    # a refusal is an error the card names (exo-59c): it used to come back without one,
    # so the ready box read "Running…" for a call that never ran
    let err = (if ex.reason.startsWith("not-allowlisted"): "not-allowed" else: "invoke-rejected")
    return $(%*{"id": intentId, "executed": false, "state": "refused", "error": err,
                "module": module, "method": meth, "detail": ex.reason})
  # Fold forward: submit → (immediate finality) final. Event/receipt finality is a
  # later refinement — an immediate action folds straight to final here.
  gSession.publish(submitEvent(intentId))
  if ex.finalityEvent.len == 0:
    gSession.publish(finalEvent(intentId))
  $(%*{"id": intentId, "executed": true,
       "state": intentState(gSession.roomEvents(), driverFor, intentId),
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
  # Sealed to the room's announced join key (exo-661.7): only its members read who asks.
  gSession.poll()
  if gSession.requestJoin(moduleKeystore().bindingFor(
      LinkContext(account: gTopic, slot: "0", expiry: uint64(epochTime()) + 86_400))):
    "ok"
  else:
    "waiting-for-room-key"

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
                     $reduceMessages(gSession.roomEvents()).len)
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
  gSession.publishAuthored(moduleKeystore(), ev)
  id

proc musterCoordinateMessages(): string =
  ## The room's authored messages, oldest-first, folded from the shared log. Each
  ## carries its author's contact alias (so the chat log reads "Alice", not raw hex —
  ## the same resolution the roster/pending use) and a `self` flag for our own lines.
  if gSession == nil: return "[]"
  gSession.poll()
  let meHex = toHex(gSession.selfIdentity().toBytes())
  var arr = newJArray()
  for m in reduceMessages(gSession.roomEvents()):
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

proc homeSummary(ej: string, label: proc(who: string): string): string =
  ## What an intent moves, in words, as the room history says it: members named once
  ## (exo-221), a token in its own decimals and symbol (display only, exo-5ab).
  var onChain = ""
  try: onChain = parseJson(ej){"chain"}.getStr()
  except CatchableError: discard
  effectSummary(ej, label, proc(asset: string): tuple[symbol: string, decimals: int] =
                             tokenInfo(onChain, asset[6 .. ^1])).text

proc musterCoordinateConversations(): string =
  ## Every joined room, as {topic, address, lastTs, active, needs, waiting, settled} —
  ## the home surface's room list. The active room is flagged; lastTs is each room's
  ## latest message ts (0 if none yet), so home can order by recency. Multi-room: one
  ## entry per session. The home surface is a query over intents (F-18, exo-ed5): `needs`
  ## lists what waits on THIS member in that room ({id, what, text}), and `waiting` /
  ## `settled` count the rest, each classed from the room's log and this member's keys.
  var arr = newJArray()
  let ks = moduleKeystore()
  let myAddr = toHex(ks.address())
  let myEnc = ks.encIdentity()
  let myNames = myNames()
  let myEncHex = toHex(myEnc.toBytes()).toLowerAscii().replace("0x", "")
  let myPart = partName(myEncHex)
  let mine = @[myEncHex] & myNames
  let label = proc(who: string): string = memberName(who, mine)   # one name per member (exo-221)
  for topic, s in gSessions:
    if topic in gInboxTopics: continue      # an inbox is a drop-box, not a room to list
    s.poll()
    let events = s.roomEvents()
    let msgs = reduceMessages(events)
    let lastTs = if msgs.len > 0: msgs[^1].ts else: 0'i64
    # each room's intents resolve under THAT room's roster and disclosed accounts, which
    # the resolver reads from the active session: swap it in for the fold
    var items: seq[HomeItem]
    let saved = gSession
    gSession = s
    try: items = homeItems(events, driverFor, myEnc, myNames, uint64(epochTime()))
    except CatchableError as e:
      if gLpDebug: stderr.writeLine("MUSTER-LP home " & topic & " " & e.msg)
    finally: gSession = saved
    var needs = newJArray()
    var waiting, settled = 0
    for it in items:
      # a payment already on its way from this client waits on the chain, not on you
      let cls = (if it.what == "pay" and splitPayingFor(it.id, myPart): hcWaiting else: it.cls)
      case cls
      of hcNeedsYou:
        needs.add %*{"id": it.id, "what": it.what, "state": it.state,
                     "text": homeSummary(it.effectJson, label)}
      of hcWaiting: inc waiting
      of hcSettled: inc settled
    arr.add %*{"topic": topic, "address": myAddr, "lastTs": lastTs,
               "active": (topic == gTopic), "needs": needs, "waiting": waiting, "settled": settled}
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
          # its wallet on this instance's zone (the lez-rpc setting), as the multisig and
          # FROST paths are; lez_core's own default is the public testnet
          LezCore(newLpLezCore(dir, sequencer = gLezRpc))
        except CatchableError as e:
          stderr.writeLine("MUSTER-LEZ: real lez_core unavailable, using fake — " & e.msg)
          LezCore(newFakeLezCore())
      else:
        LezCore(newFakeLezCore())
    gLez = newLezAdapter(lezCore)
    # Fund the DEMO (fake) accounts at its genesis so a send is demonstrable: the fake
    # chain funds them as a zone's genesis would, never through a faucet (LEZ v0.3 has
    # none, exo-eb6.4). For the REAL core, do NOT create accounts here: that hits the
    # network and would block this first wallet call on the module thread. The real
    # accounts are created lazily on the first LEZ query (a bounded loading delay at
    # panel-open), and a proving transfer already runs async — so nothing freezes.
    if lezCore of FakeLezCore:
      for acc in gLez.accounts(ks):
        if acc.form == afPublic: FakeLezCore(lezCore).fund(acc.id, "1000000000")
    gWallet.register(gLez)
  gWallet

proc splitLezAdapter(): LezAdapter =
  discard moduleWallet()
  gLez

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

proc musterWalletSendImpl(chain, fromId, to, assetSymbol, raw: string): string =
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

proc musterWalletSend(chain, fromId, to, assetSymbol, raw: string): string =
  result = musterWalletSendImpl(chain, fromId, to, assetSymbol, raw)
  if gLpDebug: stderr.writeLine("MUSTER-LP wallet_send " & chain & " " & raw & " " & result)

proc musterWalletLezSetup(): string =
  ## Headless LEZ provisioning FALLBACK (exo-44b, the no-broker path): ensure a public
  ## LEZ account exists, directly over lez_core (core-to-core), and say whether it holds
  ## native LEZ. It funds nothing: LEZ v0.3 has no faucet (exo-eb6.4). Preferred path
  ## stays the LEZ Wallet App hand-off when the broker is available; this is what keeps
  ## muster from being hard-blocked when it is not.
  discard moduleWallet()                 # ensures the wallet + gLez are initialized
  if gLez == nil: return $(%*{"error": "LEZ chain unavailable"})
  try:
    let (account, state, detail) = gLez.provision(moduleKeystore())
    result = $(%*{"account": account, "state": state, "detail": detail})
  except CatchableError as e:
    result = $(%*{"error": e.msg})
  if gLpDebug: stderr.writeLine("MUSTER-LP wallet_lez_setup " & result)

proc musterWalletFinality(chain, txId: string): string =
  let w = moduleWallet()
  try:
    let f = w.finality(TxRef(chain: chain, id: txId))
    result = $(%*{"status": $f.status, "detail": f.detail})
  except CatchableError as e:
    result = $(%*{"error": e.msg})
  # a settled (or failed) transfer, once — what an offscreen self-test watches; pending
  # is polled every few seconds and is not logged
  if gLpDebug and "\"pending\"" notin result and gSplitLogged.getOrDefault("fin:" & txId, "") != result:
    gSplitLogged["fin:" & txId] = result
    stderr.writeLine("MUSTER-LP wallet_finality " & chain & " " & txId & " " & result)

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
# user-configurable infrastructure" is empty if they can't configure it. Persisted
# beside the keystore (settings.json, saveSettingsFile); inside basecamp they would
# come from the platform's own settings (the shell we don't rebuild).

proc musterSettings(): string =
  ## The current settings + the module identity, for a settings surface: the RPC
  ## endpoint the wallet/Safe path reads against, the delivery createNode config the
  ## next room join boots with, the environment, and who this module is.
  let ks = moduleKeystore()
  let enc = ks.encIdentity()
  $(%*{
    # each endpoint whole and as redactUrl shows it: a hosted URL may carry its key, so
    # Settings shows the masked form until its user presses Show (exo-14f.2). This reply
    # goes only to this user's own view, never to a room or a log.
    "rpc": gRpcUrl, "rpcMasked": redactUrl(gRpcUrl),
    "relayer": gRelayer,
    "btcRpc": gBtcRpc, "btcRpcMasked": redactUrl(gBtcRpc),
    "lez": {"rpc": gLezRpc, "rpcMasked": redactUrl(gLezRpc), "chain": gLezChain,
            "multisigProgram": gLezProgram},
    "delivery": gDeliveryConfig,
    "keystoreBackend": gKeystoreBackend,
    "environment": "eip155:" & $gDevSafe.chainId.int,   # the wallet's dev chain (CAIP-2)
    "identity": {"address": toHex(ks.address()),
                 "ed25519": toHex(enc.ed), "x25519": toHex(enc.x),
                 # the compressed key a Bitcoin multisig names you by (exo-59c)
                 "btcPubKey": toHex(ks.btcPubKey())}
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
    forgetCooldown(value)    # naming it again is "try it now" (wallet/rpc_budget.nim, exo-14f.1)
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
    forgetCooldown(gLezRpc)
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
  of "keystore-backend":
    # exo-149.2: whether a keystore_module account may approve in-room. "interim" carries
    # muster's attestation as an opaque digest leg the signer cannot read (the card says
    # so) until typed forms land (exo-149.6).
    if value notin ["off", "interim"]:
      return $(%*{"error": "keystore-backend is \"off\" or \"interim\""})
    gKeystoreBackend = value
  of "delivery":
    # Accept a fleet short-name ("logos.dev", "logos.test"), a full createNode JSON, or "{}"/"" to
    # fall back to the default fleet — and remember that the user chose, so it wins
    # over the env on the next launch.
    gDeliveryConfig = deliveryConfigFor(value)
    gDeliverySaved = true
  else:
    return $(%*{"error": "unknown setting: " & key})
  saveSettingsFile()         # persist beside the keystore, so it survives a restart
  musterSettings()
