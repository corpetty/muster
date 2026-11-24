## The creditor's Monero wallet, as muster reads it (exo-dcc.5, ADR-018): the platform's
## monero_wallet_backend, reached through a seam whose call set is closed. Pure: what to
## ask, what the replies mean, and whether a wallet may vouch for or confirm a payment on
## an agreed chain. The lp_* half is wallet/monero_backend_lp.nim, compiled only into the
## plugin; tests use a recording fake (tests/probes/fake_monero.nim).
##
## Muster never spends (derived-exo-dcc.5 s6). The backend's spending and role-changing
## methods — prepare_send, confirm_send, cancel_send, configure, set_*, reveal_*,
## open_wallet, close_wallet, restore_* — are not on `MoneroReadMethods`, and `call`, the
## only way this module reaches a backend, refuses any method that is not. A wallet is
## opened by the wallet app (`monero.wallet.unlock`), never by muster, and muster holds no
## Monero key and no wallet password.
##
## Every reply is read as the backend writes it (logos-monero-wallet-backend 7690984,
## rust-lib/src/glue.rs, model.rs): a JSON document delivered as a JSON STRING over lp_*
## (double-encoded; docs/labbook/monero-stack-from-muster.md), possibly inside lp's
## {success, value} envelope. A read that did not answer, answered busy (`busy: true`, the
## wallet engine's 750 ms read deadline behind a build) or answered `ok: false` is UNREAD:
## not yet known — never a zero, never "not paid", never "failed".

import std/[json, options, strutils]
import ../monero/address

const
  MoneroBackendModule* = "monero_wallet_backend"
  MoneroWalletApp* = "monero_wallet_ui"        ## the package that installs the stack and holds its roles
  MoneroUnlockIntent* = "monero.wallet.unlock" ## the wallet app's intent: it opens a wallet, the person types the password there
  MoneroReadMethods* = ["wallet_status", "receive_info", "create_subaddress", "history",
                        "caller_identity", "list_networks", "address_valid", "list_wallets",
                        "balances", "node_health"]
    ## Everything muster may ask the wallet backend: reads, and one mint
    ## (create_subaddress, which needs no role). Nothing that builds, signs or broadcasts
    ## a transfer, and nothing that changes the wallet's roles or opens a wallet.
    ## list_wallets (ungated: names and networks, no key) is read only to name the wallet a
    ## remedy asks Monero Wallet to open (monero.wallet.unlock needs {wallet}, exo-dcc.20) —
    ## never on a request's own steps. balances (account 0's total and unlocked, a read the
    ## engine serves without a role) is read only for the Wallet page, to show what the
    ## person's open wallet holds — never to decide anything on a request.
  XmrConfirmDepth* = 10
    ## CRYPTONOTE_DEFAULT_TX_SPENDABLE_AGE (monero src/cryptonote_config.h): a received
    ## output unlocks after 10 blocks, and that is the depth a part is confirmed at.
  XmrDecimals* = 12      ## CRYPTONOTE_DISPLAY_DECIMAL_POINT: 1 XMR = 10^12 atomic units

type
  MoneroRefused* = object of CatchableError
    ## A method outside MoneroReadMethods was asked for: a bug, never a runtime choice.

  CallMode* = enum
    cmNow = "now"     ## a person's action (propose, agree, share, confirm): ask now, bounded
    cmPump = "pump"   ## a tick (the confirm pump, a card's projection): a cached answer will do,
                      ## and an unanswered one is unread this tick, never a wait

  MoneroBackend* = ref object of RootObj
    ## A member's access to monero_wallet_backend. `invoke` is the transport (lp_* in the
    ## plugin, a fake in tests); `call` below is the only way muster reaches it.

  ReadState* = enum
    rsAnswered = "answered"
    rsBusy = "busy"           ## the backend said busy: the wallet is held (a send being built)
    rsUnread = "unread"       ## no answer, an error, or nothing to ask

  WalletStatus* = object
    read*: ReadState
    detail*: string           ## why it is not answered, or the backend's lastError
    state*: string            ## no_wallet | opening | syncing | ready | closing | failed
    wallet*: string           ## the open wallet's registry name
    network*: string          ## the open wallet's network: mainnet | stagenet | testnet | regtest | ""
    watchOnly*: bool

  Subaddress* = object
    index*: int
    address*: string
    label*: string

  ReceiveInfo* = object
    read*: ReadState
    detail*: string
    primary*: string          ## the account's primary (standard) address: index 0
    subaddresses*: seq[Subaddress]

  HistoryRow* = object
    txid*: string
    direction*: string        ## "in" | "out"
    amount*: string           ## atomic units, canonical decimal ("" when unreadable)
    confirmations*: int64
    pending*: bool
    failed*: bool
    account*: int
    subaddrIndex*: seq[int]   ## the backend's comma-joined string ("3", "1,4"), parsed
    height*: int64            ## the block it is in (0 = none yet, or unreadable)
    unlockTime*: uint64       ## model.rs's unlockTime: 0 none; < 500,000,000 a block height, else unix time
    unlockUnread*: bool       ## unlockTime was written but could not be read: treated as a lock

  History* = object
    read*: ReadState
    detail*: string
    rows*: seq[HistoryRow]

  Balances* = object
    read*: ReadState
    detail*: string
    balance*: string          ## account 0's total, atomic units, canonical decimal
    unlocked*: string         ## of which spendable now (10 confirmations), atomic units

  RegisteredWallet* = object
    name*: string             ## the registry name monero.wallet.unlock takes
    network*: string          ## mainnet | stagenet | testnet | regtest | "" (a file never opened)
    viewOnly*: bool

  WalletList* = object
    read*: ReadState
    detail*: string
    wallets*: seq[RegisteredWallet]

  Minted* = object
    ok*: bool
    index*: int
    address*: string
    detail*: string

  BoundReply* = object
    raw*: string              ## the reply as it arrived ("" = none)
    at*: float                ## when it arrived
    key*: string              ## the wallet ("<wallet>|<network>|<state>") it was asked about
    seq*: int                 ## how many wallet_status replies had been read when it arrived

  WalletBoundCache* = object
    ## A pump's cached history or receive_info (exo-dcc.5 s7): neither names a wallet, so a
    ## reply is served only while the wallet the status named when it was asked is still the
    ## one named, and only once a status reply read AFTER it says so too.
    served*: BoundReply       ## the newest reply a later status confirmed
    fresh*: BoundReply        ## the newest reply, not yet confirmed

proc put*(c: var WalletBoundCache, raw: string, at: float, walletKey: string, statusSeq: int) =
  ## A reply asked now (cmNow): as current as the status read just before it.
  c.served = BoundReply(raw: raw, at: at, key: walletKey, seq: statusSeq - 1)
  c.fresh = BoundReply()

proc promote(c: var WalletBoundCache, walletKey: string, statusSeq: int) =
  ## The fresh reply becomes the served one once a status read after it names its wallet.
  if c.fresh.raw.len > 0 and c.fresh.key == walletKey and statusSeq > c.fresh.seq:
    c.served = c.fresh
    c.fresh = BoundReply()

proc offer*(c: var WalletBoundCache, raw: string, at: float, firedKey, walletKey: string, statusSeq: int) =
  ## A pump reply arrived. One asked about another wallet than the one named now is dropped.
  ## It waits as `fresh` until a later status confirms it; meanwhile the reply confirmed
  ## before it is still served (exo-dcc.20: replacing it unconfirmed starved the pump when
  ## the status and the reply arrived in lockstep, every tick).
  if raw.len == 0 or firedKey != walletKey: return
  c.promote(walletKey, statusSeq)
  c.fresh = BoundReply(raw: raw, at: at, key: walletKey, seq: statusSeq)

proc read*(c: var WalletBoundCache, walletKey: string, statusSeq: int, now, staleS: float): string =
  ## What may be served now ("" = nothing yet): confirmed by a later status, about the
  ## wallet named now, and no older than staleS. A fresh reply a later status confirms
  ## is promoted first.
  c.promote(walletKey, statusSeq)
  let r = c.served
  if r.raw.len == 0 or now - r.at > staleS or r.key != walletKey or statusSeq <= r.seq: return ""
  r.raw

proc clear*(c: var WalletBoundCache) = c = WalletBoundCache()

method invoke*(b: MoneroBackend, meth: string, args: JsonNode, mode: CallMode): string {.base, gcsafe.} =
  ## One raw call: lp's reply string as it arrives ("" = no answer). The base answers
  ## nothing: a host with no Monero stack.
  ""

proc isReadMethod*(meth: string): bool = meth in MoneroReadMethods

proc moneroReply*(raw: string): JsonNode =
  ## A backend reply, however it arrives over lp_*: the JSON object itself, that object as
  ## a JSON string (the backend's tstr results), or either inside lp's {success, value}
  ## envelope. The object is returned as written, `ok: false` and `busy: true` included —
  ## the reader decides what they mean. nil when it carries no object, or the envelope
  ## says the call failed.
  if raw.len == 0: return nil
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return nil
  for _ in 0 .. 3:
    case j.kind
    of JString:
      let s = j.getStr()
      if s.len == 0: return nil
      try: j = parseJson(s)
      except CatchableError: return nil
    of JObject:
      if j.hasKey("success") and j.hasKey("value") and not j.hasKey("ok"):
        if not j["success"].getBool(false): return nil
        j = j["value"]
      else: return j
    else: return nil
  nil

proc call*(b: MoneroBackend, meth: string, args: JsonNode = newJArray(), mode = cmNow): JsonNode =
  ## The ONE way muster reaches the wallet backend: a method on MoneroReadMethods, or a
  ## MoneroRefused raise — nothing is sent (s6). nil when there is no backend or it did not
  ## answer.
  if not isReadMethod(meth):
    raise newException(MoneroRefused, "muster never calls " & MoneroBackendModule & "." & meth &
                       ": it reads the wallet and mints subaddresses, and never spends or takes a role")
  if b == nil: return nil
  moneroReply(b.invoke(meth, args, mode))

proc unread(j: JsonNode, what: string): tuple[read: ReadState, detail: string] =
  ## Whether a reply answered: (rsAnswered, "") when it says ok; busy; else unread, why.
  if j == nil or j.kind != JObject: return (rsUnread, "the Monero wallet backend did not answer " & what)
  if j{"busy"}.getBool(false):
    return (rsBusy, "the Monero wallet is busy (a send is being built): " & what & " is not read yet")
  if not j{"ok"}.getBool(false):
    return (rsUnread, "the Monero wallet backend could not answer " & what &
                      (if j{"error"}.getStr().len > 0: ": " & j{"error"}.getStr() else: ""))
  (rsAnswered, "")

# ── reads ─────────────────────────────────────────────────────────────────────
proc walletStatus*(b: MoneroBackend, mode = cmNow): WalletStatus =
  ## wallet_status(): the open wallet, its network and state.
  let j = b.call("wallet_status", newJArray(), mode)
  let (r, why) = unread(j, "wallet_status")
  if r != rsAnswered: return WalletStatus(read: r, detail: why)
  WalletStatus(read: rsAnswered, state: j{"state"}.getStr(), wallet: j{"wallet"}.getStr(),
               network: j{"network"}.getStr(), watchOnly: j{"watchOnly"}.getBool(false),
               detail: j{"lastError"}.getStr())

proc receiveInfo*(b: MoneroBackend, mode = cmNow): ReceiveInfo =
  ## receive_info(0): account 0's primary address and its subaddresses.
  let j = b.call("receive_info", %*[0], mode)
  let (r, why) = unread(j, "receive_info")
  if r != rsAnswered: return ReceiveInfo(read: r, detail: why)
  result = ReceiveInfo(read: rsAnswered, primary: j{"address"}.getStr())
  for s in j{"subaddresses"}.getElems():
    if s.kind != JObject: continue
    result.subaddresses.add Subaddress(index: s{"index"}.getInt(-1), address: s{"address"}.getStr(),
                                       label: s{"label"}.getStr())

proc indexOf*(info: ReceiveInfo, address: string): int =
  ## The subaddress index of `address` in this wallet (exact string: Monero addresses are
  ## case-sensitive), -1 when it does not list it. The primary address is index 0.
  if address.len == 0: return -1
  for s in info.subaddresses:
    if s.address == address and s.index >= 0: return s.index
  if info.primary == address: return 0
  -1

proc addresses*(info: ReceiveInfo): seq[string] =
  ## Every address this wallet's account 0 lists: the primary and each subaddress.
  if info.primary.len > 0: result.add info.primary
  for s in info.subaddresses:
    if s.address.len > 0 and s.address notin result: result.add s.address

proc atomicOf(v: JsonNode): string =
  ## An amount as the backend writes it — a decimal string of atomic units (model.rs) or,
  ## defensively, a JSON integer — as canonical decimal; "" when it is neither.
  if v == nil: return ""
  let s = (case v.kind
           of JString: v.getStr()
           of JInt: $v.getBiggestInt()
           else: "")
  if s.len == 0 or not s.allCharsInSet(Digits): return ""
  if s.len > 1 and s[0] == '0': return ""
  s

proc indicesOf(v: JsonNode): seq[int] =
  ## subaddrIndex: a comma-joined STRING ("3", "1,4") in the backend; a number or an array
  ## read the same way. An entry that is not a number is dropped.
  if v == nil: return
  case v.kind
  of JString:
    for p in v.getStr().split(','):
      try: result.add parseInt(p.strip())
      except ValueError: discard
  of JInt: result.add v.getInt()
  of JArray:
    for x in v: result.add indicesOf(x)
  else: discard

proc intOf(v: JsonNode): int64 =
  if v == nil: return 0
  case v.kind
  of JInt: v.getBiggestInt()
  of JString:
    try: parseBiggestInt(v.getStr()) except ValueError: 0
  of JFloat: int64(v.getFloat())
  else: 0

const XmrMaxBlockNumber* = 500_000_000'u64
  ## CRYPTONOTE_MAX_BLOCK_NUMBER: an unlock_time below it is a block height, at or above a unix time

proc unlockOf(v: JsonNode): tuple[t: uint64, unread: bool] =
  ## A row's unlockTime: absent or null is no lock; a non-negative integer (or its decimal
  ## text) is the lock; anything else was written and cannot be read, which is a lock.
  if v == nil or v.kind == JNull: return (0'u64, false)
  case v.kind
  of JInt:
    if v.getBiggestInt() < 0: (0'u64, true) else: (uint64(v.getBiggestInt()), false)
  of JString:
    let t = v.getStr().strip()
    if t.len == 0 or not t.allCharsInSet(Digits) or t.len > 20: return (0'u64, true)
    try: (parseBiggestUInt(t), false) except ValueError: (0'u64, true)
  else: (0'u64, true)

proc lockedAt*(r: HistoryRow, nowUnix: float): string =
  ## Why a received transfer is still locked ("" = it is not), as wallet2's
  ## is_tx_spendtime_unlocked reads unlock_time (exo-3b3.14, P5-06): a height is reached once
  ## the chain's height (the transfer's block plus its confirmations) is at least it; a time
  ## once now is at least it. A lock the wallet wrote unreadably, or a height lock on a
  ## transfer in no block yet, is still a lock.
  if r.unlockUnread: return "its unlock time could not be read"
  if r.unlockTime == 0: return ""
  if r.unlockTime < XmrMaxBlockNumber:
    if r.height <= 0: return "locked until block " & $r.unlockTime
    if uint64(r.height) + uint64(max(0'i64, r.confirmations)) >= r.unlockTime: return ""
    return "locked until block " & $r.unlockTime
  if nowUnix >= float(r.unlockTime): return ""
  "locked until unix time " & $r.unlockTime

proc history*(b: MoneroBackend, mode = cmNow): History =
  ## history(): the open wallet's transfers, newest first.
  let j = b.call("history", newJArray(), mode)
  let (r, why) = unread(j, "history")
  if r != rsAnswered: return History(read: r, detail: why)
  result = History(read: rsAnswered)
  for row in j{"rows"}.getElems():
    if row.kind != JObject: continue
    result.rows.add HistoryRow(txid: row{"txid"}.getStr().toLowerAscii(), direction: row{"direction"}.getStr(),
                               amount: atomicOf(row{"amount"}), confirmations: intOf(row{"confirmations"}),
                               pending: row{"pending"}.getBool(false), failed: row{"failed"}.getBool(false),
                               account: int(intOf(row{"account"})), subaddrIndex: indicesOf(row{"subaddrIndex"}),
                               height: intOf(row{"height"}),
                               unlockTime: unlockOf(row{"unlockTime"}).t, unlockUnread: unlockOf(row{"unlockTime"}).unread)

proc balances*(b: MoneroBackend, mode = cmNow): Balances =
  ## balances(0): account 0's total and unlocked amounts ({ok, balance, unlocked, …}).
  let j = b.call("balances", %*[0], mode)
  let (r, why) = unread(j, "balances")
  if r != rsAnswered: return Balances(read: r, detail: why)
  let bal = atomicOf(j{"balance"})
  if bal.len == 0: return Balances(read: rsUnread, detail: "the Monero wallet backend's balance was unreadable")
  Balances(read: rsAnswered, balance: bal, unlocked: atomicOf(j{"unlocked"}))

type NodeHealth* = object
  ## node_health (exo-dcc.7): whose node the wallet syncs through. A read, naming no key.
  read*: ReadState
  detail*: string
  mode*: string        ## "local" (monerod_module, the member's own node) or "remote"
  reachable*: bool

proc nodeHealth*(b: MoneroBackend, mode = cmNow): NodeHealth =
  ## The active network's node, as the wallet backend reports it: local or remote.
  let j = b.call("node_health", newJArray(), mode)
  let (rd, d) = unread(j, "node_health")
  if rd != rsAnswered: return NodeHealth(read: rd, detail: d)
  NodeHealth(read: rsAnswered,
             mode: (if j{"local"}.getBool(false): "local" else: j{"mode"}.getStr("remote")),
             reachable: j{"reachable"}.getBool(false))

proc listWallets*(b: MoneroBackend, mode = cmNow): WalletList =
  ## list_wallets(): every wallet the backend's registry knows, open or not
  ## ({wallets:[{name, network, label, viewOnly, restoreHeight, address}]}). Ungated.
  let j = b.call("list_wallets", newJArray(), mode)
  if j != nil and j.kind == JObject and not j.hasKey("ok") and not j.hasKey("busy") and
     j{"wallets"} != nil and j["wallets"].kind == JArray:
    j["ok"] = %true                     # the registry's own shape: a list is an answer
  let (r, why) = unread(j, "list_wallets")
  if r != rsAnswered: return WalletList(read: r, detail: why)
  result = WalletList(read: rsAnswered)
  for w in j{"wallets"}.getElems():
    if w.kind != JObject or w{"name"}.getStr().len == 0: continue
    result.wallets.add RegisteredWallet(name: w{"name"}.getStr(), network: w{"network"}.getStr(),
                                        viewOnly: w{"viewOnly"}.getBool(false))

proc createSubaddress*(b: MoneroBackend, label: string): Minted =
  ## create_subaddress(0, label): a fresh subaddress of account 0, stored at once. Needs
  ## no role. Always a person's action (cmNow).
  let j = b.call("create_subaddress", %*[0, label], cmNow)
  let (r, why) = unread(j, "create_subaddress")
  if r != rsAnswered: return Minted(ok: false, detail: why)
  let a = j{"address"}.getStr()
  if a.len == 0: return Minted(ok: false, detail: "the wallet minted no address")
  Minted(ok: true, index: j{"index"}.getInt(-1), address: a)

# ── what a wallet may do on an agreed chain ──────────────────────────────────────
proc walletRefusal*(st: WalletStatus, chain: string): string =
  ## "" when the open wallet may vouch for a payTo or confirm a payment on `chain`:
  ## answered, a wallet open (ready or syncing), on the network the chain names, and not
  ## watch-only. Otherwise a code and why — "wallet-unread: …", "wallet-busy: …",
  ## "no-wallet: …", "wallet-other-network: …", "wallet-watch-only: …", "unknown-chain: …".
  ## No confirmation crosses networks (s7): a stagenet request is never settled by a
  ## mainnet wallet's history, or the reverse.
  let want = networkOfChain(chain)
  if want.isNone:
    return "unknown-chain: not a Monero chain muster knows: " & chain
  case st.read
  of rsUnread: return "wallet-unread: " & st.detail
  of rsBusy: return "wallet-busy: " & st.detail
  of rsAnswered: discard
  if st.state notin ["ready", "syncing"]:
    return "no-wallet: no Monero wallet is open (" & (if st.state.len > 0: st.state else: "no state") &
           "): open your " & $want.get & " wallet in Monero Wallet (" & MoneroUnlockIntent & ")"
  if st.network != $want.get:
    return "wallet-other-network: your wallet is on another network: the open wallet is on " &
           (if st.network.len > 0: st.network else: "no network") & ", the request is on " & $want.get &
           " — open your " & $want.get & " wallet in Monero Wallet (" & MoneroUnlockIntent & ")"
  if st.watchOnly:
    return "wallet-watch-only: the open wallet is view-only: a payment request is vouched for and " &
           "confirmed by the wallet that can spend what it receives"
  ""
