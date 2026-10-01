## Reads the node's RLN membership from the two RLN modules, for the connectivity row
## (exo-eb6.3 R1); rln_status.nim says what the replies mean. Not pure: lp_* calls, so
## like delivery.nim it is compiled only into the plugin.
##
## What each read costs decides how it is made. wallet_status never touches the chain
## (the payer comes from local configuration), so it is read on the call, at most every
## 5 s. The payer's balance and the membership state are chain reads, the membership's
## budgeted at 70 s by the RLN module, so they go out async, at most every 20 s, and
## land in queues the module thread drains: a blocking cross-module call on the module
## thread is what stalled sends once already (exo-eb6.1, the store-window trap).

import std/[json, times]
import logos_sdk/ffi
import ./inbound_queue
import ./rln_status

const
  LezRlnModule = "liblogos_lez_rln_module"
  RlnModule = "liblogos_rln_module"
  SyncMs = 2000.cint            ## wallet_status: local, answers at once
  AsyncMs = 75_000.cint         ## a chain read: the RLN module's own budget is 70 s
  WalletEveryS = 5.0
  ChainEveryS = 20.0

type
  AsyncRead = object
    q: InboundQueue
    inFlight: bool
    sentAt: float
    last: JsonNode              ## the last reply that parsed; nil until one does
  RlnProbe* = ref object
    lezRln, rln: ptr LpClient
    wallet: JsonNode
    walletAt: float
    balance, membership: AsyncRead

proc onRead(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## On the callee's thread: copy the reply into the queue (no Nim GC), nothing more.
  let q = cast[ptr InboundQueue](userData)
  if ok != 0 and json != nil: q[].enqueue(json) else: q[].enqueue("")

proc newRlnProbe*(): RlnProbe =
  result = RlnProbe()
  initInboundQueue(result.balance.q)
  initInboundQueue(result.membership.q)
  GC_ref(result)                # the callbacks hold pointers into it

proc client(p: RlnProbe, name: string): ptr LpClient =
  ## Created on first use: on a preset without RLN the modules are never asked.
  if name == LezRlnModule:
    if p.lezRln == nil: p.lezRln = lp_client_create(name.cstring, "muster_module", nil, nil)
    p.lezRln
  else:
    if p.rln == nil: p.rln = lp_client_create(name.cstring, "muster_module", nil, nil)
    p.rln

proc reply(raw: string): JsonNode =
  ## A tstr reply carrying JSON, maybe inside the lp envelope → that JSON; nil if none.
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return nil
  for _ in 0 .. 3:
    case j.kind
    of JString:
      if j.getStr().len == 0: return nil
      try: j = parseJson(j.getStr())
      except CatchableError: return nil
    of JObject:
      if j.hasKey("value") and j.hasKey("success"):
        if not j["success"].getBool(false): return nil
        j = j["value"]
      else: return j
    else: return nil
  nil

proc syncRead(p: RlnProbe, module, meth: string): JsonNode =
  let c = p.client(module)
  if c == nil: return nil
  var res, err: cstring
  let rc = lp_invoke(c, meth.cstring, "[]", SyncMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return nil
  reply($res)

proc fire(p: RlnProbe, r: var AsyncRead, module, meth, argsJson: string, now: float) =
  let c = p.client(module)
  if c == nil: return
  let rc = lp_invoke_async(c, meth.cstring, argsJson.cstring, AsyncMs, onRead, addr r.q)
  if rc == LP_OK:
    r.inFlight = true
    r.sentAt = now

proc drain(r: var AsyncRead, now: float) =
  for raw in r.q.drain():
    r.inFlight = false
    var s = newString(raw.len)
    if raw.len > 0: copyMem(addr s[0], unsafeAddr raw[0], raw.len)
    let j = reply(s)
    if j != nil: r.last = j            # a failed read keeps the last good one, never zero
  if r.inFlight and now - r.sentAt > AsyncMs.float / 1000 + 5: r.inFlight = false

proc read*(p: RlnProbe, preset, node, nodeMessage: string): RlnInputs =
  ## Everything rlnRow needs, now. Off the RLN preset nothing is asked.
  result = RlnInputs(preset: preset, node: node, nodeMessage: nodeMessage)
  if preset != RlnPreset: return
  let now = epochTime()
  if now - p.walletAt > WalletEveryS:
    p.wallet = p.syncRead(LezRlnModule, "wallet_status")
    p.walletAt = now
  p.balance.drain(now)
  p.membership.drain(now)
  let payer = (if p.wallet != nil and p.wallet.kind == JObject and p.wallet{"state"}.getStr() == "ready":
                 p.wallet{"payer"}.getStr() else: "")
  if payer.len > 0 and not p.balance.inFlight and now - p.balance.sentAt > ChainEveryS:
    p.fire(p.balance, LezRlnModule, "get_native_balance", $(%*[payer]), now)
  if node.len > 0 and node != "Disabled" and not p.membership.inFlight and
     now - p.membership.sentAt > ChainEveryS:
    p.fire(p.membership, RlnModule, "get_membership_state", $(%*[LogosTestRegistry, RlnIdentifierHex]), now)
  result.wallet = p.wallet
  result.balance = p.balance.last
  result.membership = p.membership.last
