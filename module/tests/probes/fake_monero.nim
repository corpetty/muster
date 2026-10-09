## A recording fake of monero_wallet_backend (exo-dcc.5) for the tests and the spec's
## probes (derived-exo-dcc.5). It answers the backend's own reply shapes — a JSON document
## delivered as a JSON STRING, as lp_* delivers a tstr result (docs/labbook/
## monero-stack-from-muster.md) — so the real parsing path runs, and it records EVERY
## method it is asked, whatever it is, so a path that reaches past muster's closed call set
## is caught (s6). Not a probe itself (no `probe_` prefix).
##
## Its wallet's addresses are valid Monero addresses (Monero's base58, Keccak checksum,
## prime-order keys — Ed25519 public keys from libsodium) on the wallet's network; they are
## not wallet2's own subaddress derivation, which muster never computes.

import std/[json, options, strutils]
import ../../src/hashing/sha256
import ../../src/crypto/curve25519
import ../../src/monero/address
import ../../src/wallet/monero_backend
export monero_backend, address

type
  Answer* = enum
    anAnswered = "answered", anBusy = "busy", anUnreachable = "unreachable"
  FakeMoneroBackend* = ref object of MoneroBackend
    calls*: seq[string]          ## every method asked, in order — read and mint and anything else
    seed*: string                ## the wallet's identity: its keys derive from it
    network*: string             ## the open wallet's network; "" = no wallet open
    watchOnly*: bool
    status*, info*, hist*: Answer   ## how wallet_status / receive_info / history answer
    subs*: seq[Subaddress]       ## minted subaddresses (index ≥ 1)
    rows*: seq[JsonNode]         ## history rows, as the backend writes them
    listing*: Answer             ## how list_wallets answers (exo-dcc.20)
    registry*: seq[Registered]   ## the wallets list_wallets names; empty = the open one alone
  Registered* = tuple[name, network: string, viewOnly: bool]

proc keyOf(tag: string): array[32, byte] =
  var b: seq[byte]
  for c in tag: b.add byte(c)
  let d = sha256(b)
  var seed: array[32, byte]
  for i in 0 ..< 32: seed[i] = d[i]
  encFromSeed(seed).identity().ed

proc netOf*(chain: string): MoneroNetwork = networkOfChain(chain).get

proc walletAddress*(seed: string, net: MoneroNetwork, index: int, kind = makSubaddress): string =
  ## Address `index` of wallet `seed` on `net`: index 0 its primary (standard) address.
  let k = (if index == 0 and kind == makSubaddress: makStandard else: kind)
  let tag = seed & "/" & $index
  if k == makIntegrated:
    var pid: array[8, byte]
    for i in 0 ..< 8: pid[i] = byte(i + 1)
    return encodeAddress(net, k, keyOf(tag & "/spend"), keyOf(tag & "/view"), some(pid))
  encodeAddress(net, k, keyOf(tag & "/spend"), keyOf(tag & "/view"))

proc newFakeMonero*(seed, network: string): FakeMoneroBackend =
  FakeMoneroBackend(seed: seed, network: network)

proc primary*(f: FakeMoneroBackend): string =
  if f.network.len == 0: "" else: walletAddress(f.seed, parseEnum[MoneroNetwork](f.network), 0)

proc mint*(f: FakeMoneroBackend, label = ""): Subaddress =
  ## A subaddress as create_subaddress makes one (also how a test gives the wallet one).
  let i = f.subs.len + 1
  result = Subaddress(index: i, address: walletAddress(f.seed, parseEnum[MoneroNetwork](f.network), i), label: label)
  f.subs.add result

proc row*(txid, direction, amount: string, confirmations: int, subaddrIndex: string, failed = false,
          account = 0): JsonNode =
  ## A history row as model.rs writes it: amount a decimal string, subaddrIndex a
  ## comma-joined string, pending when unconfirmed.
  %*{"txid": txid, "direction": direction, "amount": amount, "amountXmr": "", "fee": "0", "feeXmr": "",
     "height": (if confirmations > 0: 1000 else: 0), "confirmations": confirmations, "timestamp": 0,
     "pending": confirmations == 0, "failed": failed, "unlockTime": 0, "account": account,
     "paymentId": "", "description": "", "subaddrIndex": subaddrIndex, "coinbase": false, "destinations": []}

proc txidOf*(n: int): string =
  ## A deterministic 64-hex txid.
  var b: seq[byte]
  for c in "txid/" & $n: b.add byte(c)
  for x in sha256(b): result.add toHex(int(x), 2).toLowerAscii()

proc tstr(j: JsonNode): string = $(%($j))   ## a document as a tstr reply: a JSON string of it

method invoke*(f: FakeMoneroBackend, meth: string, args: JsonNode, mode: CallMode): string =
  f.calls.add meth
  case meth
  of "wallet_status":
    case f.status
    of anUnreachable: return ""
    of anBusy: return tstr(%*{"ok": false, "busy": true})
    of anAnswered: discard
    if f.network.len == 0:
      return tstr(%*{"activeNetwork": "stagenet", "address": "", "connected": false, "daemonHeight": 0,
                     "lastError": "", "libraryVersion": "0.18.5.3-RC1", "network": "", "ok": true,
                     "state": "no_wallet", "syncPercent": 0, "synchronized": false, "wallet": "",
                     "walletHeight": 0, "watchOnly": false})
    tstr(%*{"activeNetwork": f.network, "address": f.primary, "connected": true, "daemonHeight": 2000,
            "lastError": "", "libraryVersion": "0.18.5.3-RC1", "network": f.network, "ok": true,
            "state": "ready", "syncPercent": 100, "synchronized": true, "wallet": f.seed,
            "walletHeight": 2000, "watchOnly": f.watchOnly})
  of "receive_info":
    case f.info
    of anUnreachable: return ""
    of anBusy: return tstr(%*{"ok": false, "busy": true})
    of anAnswered: discard
    if f.network.len == 0: return tstr(%*{"ok": false, "error": "no wallet is open"})
    var subs = %*[{"index": 0, "address": f.primary, "label": "Primary account"}]
    for s in f.subs: subs.add %*{"index": s.index, "address": s.address, "label": s.label}
    tstr(%*{"ok": true, "address": f.primary, "subaddresses": subs})
  of "create_subaddress":
    if f.network.len == 0: return tstr(%*{"ok": false, "error": "no wallet is open"})
    let s = f.mint(if args.len > 1: args[1].getStr() else: "")
    tstr(%*{"ok": true, "index": s.index, "address": s.address})
  of "history":
    case f.hist
    of anUnreachable: return ""
    of anBusy: return tstr(%*{"ok": false, "busy": true})
    of anAnswered: discard
    if f.network.len == 0: return tstr(%*{"ok": false, "error": "no wallet is open"})
    var rows = newJArray()
    for r in f.rows: rows.add r
    tstr(%*{"ok": true, "rows": rows})
  of "caller_identity":
    tstr(%*{"approvers": ["monero_wallet_ui"], "custodians": ["monero_wallet_ui"], "identity": "muster_module",
            "kind": "module", "ok": true})
  of "list_wallets":
    # ungated: every wallet file the registry knows, open or not (glue.rs list_wallets);
    # a file never opened shows network "" (atlas monero-wallet §5)
    case f.listing
    of anUnreachable: return ""
    of anBusy: return tstr(%*{"ok": false, "busy": true})
    of anAnswered: discard
    var ws = newJArray()
    let reg = (if f.registry.len > 0: f.registry
               elif f.network.len > 0: @[(name: f.seed, network: f.network, viewOnly: f.watchOnly)]
               else: @[])
    for r in reg:
      ws.add %*{"name": r.name, "network": r.network, "label": "", "viewOnly": r.viewOnly,
                "restoreHeight": 0, "address": ""}
    tstr(%*{"ok": true, "wallets": ws})
  of "list_networks":
    tstr(%*{"active": (if f.network.len > 0: f.network else: "stagenet"),
            "networks": ["mainnet", "stagenet", "testnet", "regtest"], "ok": true})
  else:
    # a spend, a role change, an open: recorded, and answered as if it worked — the
    # recording is what catches a path that asks
    tstr(%*{"ok": true, "requestId": "s1", "jobId": "b1"})

const AllowedCalls* = ["wallet_status", "receive_info", "create_subaddress", "history",
                       "caller_identity", "list_networks", "address_valid"]
  ## What a request's steps may ask (s6). list_wallets is a read muster makes only to name
  ## the wallet a remedy asks Monero Wallet to open (xmrUnlockTarget, exo-dcc.20) — never
  ## on a request's own steps, so it stays off this set and a step that asks it fails here.
const ForbiddenCalls* = ["prepare_send", "confirm_send", "cancel_send", "configure", "open_wallet",
                         "close_wallet"]
const ForbiddenPrefixes* = ["set_", "reveal_", "restore_"]

proc forbidden*(meth: string): bool =
  if meth in ForbiddenCalls: return true
  for p in ForbiddenPrefixes:
    if meth.startsWith(p): return true
  false

proc onlyAllowed*(f: FakeMoneroBackend): bool =
  ## Every method asked is on the read-and-mint set, none forbidden.
  for c in f.calls:
    if c notin AllowedCalls or forbidden(c): return false
  true
