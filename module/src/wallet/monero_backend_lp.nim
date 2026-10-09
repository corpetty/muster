## The platform half of wallet/monero_backend.nim (exo-dcc.5): monero_wallet_backend over
## lp_*. Not pure, so like keystore_probe.nim and tx_sender_lp.nim it is compiled only into
## the plugin. Muster calls the backend raw (no typed wrapper), as `muster_module`, which
## caller_identity attests (docs/labbook/monero-stack-from-muster.md).
##
## Two shapes of call, because the module thread must never wait on a wallet:
##   * cmPump — the intents tick (the confirm pump, a card's projection): the newest reply
##     no older than StaleS, and an async call fired at most every EveryS whose reply lands
##     in a queue the module thread drains. Nothing fresh yet reads as no answer — UNREAD,
##     never a zero and never "not paid" (a later tick answers).
##   * cmNow — a person's action (propose, agree, share, confirm by hand), and every
##     create_subaddress: one bounded lp_invoke. The wallet engine answers a read within
##     750 ms or says busy; create_subaddress and receive_info take the wallet lock without
##     that deadline and can wait ~15 s behind a send being built (atlas monero-wallet §6a).
## Whatever a call answers is cached for cmPump too. History and receive_info name no wallet
## or network, so a cached one is bound to the wallet_status replies around it
## (monero_backend.WalletBoundCache): it is used only while the wallet the status named when
## it was asked is still the one named, and only once a status reply received AFTER it says
## so too — a reply about the wallet that was open before is never read as one about the
## wallet open now (s7). Until a newer reply is confirmed, the one confirmed before it is
## served (exo-dcc.20: the status and the reply arrive in lockstep, every tick). A
## wallet_status naming another wallet or network drops them all. A successful
## create_subaddress drops the cached receive_info (it lists the new address).

import std/[json, strutils, tables, times]
import logos_sdk/ffi
import ../transport/inbound_queue
import ./monero_backend

const
  Ours = "muster_module"
  ReadMs = 5_000.cint        ## a person's read: the engine answers in 750 ms or says busy
  MintMs = 20_000.cint       ## create_subaddress: may wait behind a build (~15 s)
  AsyncMs = 15_000.cint
  EveryS = 2.0
  StaleS = 15.0

type
  Cached = ref object
    q: InboundQueue
    inFlight: bool
    sentAt: float
    last: string             ## the newest raw reply that parsed ("" = none), a method bound to no wallet
    lastAt: float
    firedKey: string         ## the wallet the status named when the call went out
    bound: WalletBoundCache  ## history and receive_info: served only once a later status confirms
  LpMoneroBackend* = ref object of MoneroBackend
    client: ptr LpClient
    cache: Table[string, Cached]
    walletKey: string        ## "<wallet>|<network>|<state>" of the last wallet_status read
    statusSeq: int           ## how many wallet_status replies have been read

proc newLpMoneroBackend*(): LpMoneroBackend =
  result = LpMoneroBackend()
  GC_ref(result)

proc reached(b: LpMoneroBackend): bool =
  if b.client == nil:
    b.client = lp_client_create(MoneroBackendModule.cstring, Ours.cstring, nil, nil)
  b.client != nil

proc onReply(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## On the callee's thread: copy the reply into the queue (no Nim GC), nothing more.
  let q = cast[ptr InboundQueue](userData)
  if ok != 0 and json != nil: q[].enqueue(json) else: q[].enqueue("")

proc entry(b: LpMoneroBackend, key: string): Cached =
  result = b.cache.getOrDefault(key)
  if result == nil:
    result = Cached()
    initInboundQueue(result.q)
    GC_ref(result)            # the callback holds a pointer into it
    b.cache[key] = result

const Bound = ["history", "receive_info"]   ## replies that name no wallet

proc forget(b: LpMoneroBackend, meth: string) =
  for k, c in b.cache:
    if k.startsWith(meth):
      c.last = ""
      c.lastAt = 0
      c.bound.clear()

proc noted(b: LpMoneroBackend, meth, raw: string) =
  ## A reply came back: a wallet_status that names another wallet or network than the last
  ## drops what was read about the one before; a mint drops the listed addresses.
  let j = moneroReply(raw)
  if j == nil or j.kind != JObject: return
  if meth == "wallet_status" and not j{"busy"}.getBool(false):
    inc b.statusSeq
    let key = j{"wallet"}.getStr() & "|" & j{"network"}.getStr() & "|" & j{"state"}.getStr()
    if key != b.walletKey:
      b.walletKey = key
      b.forget("receive_info")
      b.forget("history")
  if meth == "create_subaddress" and j{"ok"}.getBool(false):
    b.forget("receive_info")

proc drain(b: LpMoneroBackend, meth: string, c: Cached, now: float) =
  for raw in c.q.drain():
    c.inFlight = false
    var s = newString(raw.len)
    if raw.len > 0: copyMem(addr s[0], unsafeAddr raw[0], raw.len)
    if moneroReply(s) != nil:
      if meth in Bound: c.bound.offer(s, now, c.firedKey, b.walletKey, b.statusSeq)
      else:
        c.last = s
        c.lastAt = now
      b.noted(meth, s)
  if c.inFlight and now - c.sentAt > AsyncMs.float / 1000 + 5: c.inFlight = false

proc callNow(b: LpMoneroBackend, meth: string, args: JsonNode): string =
  var res, err: cstring
  let rc = lp_invoke(b.client, meth.cstring, ($args).cstring,
                     (if meth == "create_subaddress" or meth == "receive_info": MintMs else: ReadMs),
                     addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return ""
  $res

method invoke*(b: LpMoneroBackend, meth: string, args: JsonNode, mode: CallMode): string =
  ## `call` (monero_backend.nim) has already held `meth` to the read-and-mint set.
  if not isReadMethod(meth) or not b.reached(): return ""
  let key = meth & $args
  let now = epochTime()
  if mode == cmNow or meth == "create_subaddress":
    result = b.callNow(meth, args)
    if result.len > 0 and moneroReply(result) != nil:
      b.noted(meth, result)
      if meth != "create_subaddress":
        let c = b.entry(key)
        if meth in Bound: c.bound.put(result, now, b.walletKey, b.statusSeq)   # as current as the status before it
        else:
          c.last = result
          c.lastAt = now
    return
  let c = b.entry(key)
  b.drain(meth, c, now)
  if not c.inFlight and now - c.sentAt >= EveryS:
    c.sentAt = now
    c.firedKey = b.walletKey
    if lp_invoke_async(b.client, meth.cstring, ($args).cstring, AsyncMs, onReply, addr c.q) == LP_OK:
      c.inFlight = true
  # bound to the wallet: the one named when it was asked, still named, and named again by a
  # status reply read after it
  if meth in Bound: return c.bound.read(b.walletKey, b.statusSeq, now, StaleS)
  if c.last.len == 0 or now - c.lastAt > StaleS: return ""
  c.last
