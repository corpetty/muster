## LpLezCore — the REAL LezCore: calls the `lez_core` module (v0.3.0,
## logos-blockchain/logos-execution-zone-module) over the `lp_*` C ABI, so the
## LezAdapter sends assets on the live zone. Slots behind the same seam as FakeLezCore;
## nothing else in the wallet changes. Grounded in the working demo
## (demo/muster-ui/src/{Zone.h,ChatBackendAssets.cpp}) and the labbook
## (docs/labbook/lez-core-error-conventions.md). Design: docs/design/lez-adapter.md.
##
## NOTE: this links `lp_*`, which resolves only at plugin link time — it compiles into
## muster_module but does not `nim r` standalone, and its end-to-end behaviour is
## validated against the running zone, not headlessly (like DeliveryTransport).
##
## v0 caveat: a proving transfer is a SYNCHRONOUS lp_invoke with a 900s timeout, so it
## blocks the module thread for the ~7-minute proof. The demo used the async variant +
## a queued deferral to keep the UI painting; muster's coordinate_execute path already
## frames a coordinated LEZ send as a background job, so the async wallet-direct send is
## a follow-up (see the plan). Reads use the 15s budget.

import std/[json, strutils, os]
import logos_sdk/ffi              # lp_* C-ABI (resolves at plugin link time, like delivery)
import ../transport/inbound_queue # foreign-thread-safe result hand-off (as delivery uses)
import ./types
import ./lez_core
import ./lez_encoding

const
  kReadMs  = cint(15_000)         ## Zone.h: a read that doesn't prove
  kProveMs = cint(900_000)        ## Zone.h: the proving budget (measured 6m41s + headroom)

type
  LpLezCore* = ref object of LezCore
    client: ptr LpClient
    origin: string
    q: InboundQueue          ## a proving transfer's result lands here from lez_core's thread
    inflight: bool           ## single-in-flight: one proving transfer at a time
    lastResult: LezResult    ## the resolved result once drained (module thread)

proc rawCall(c: LpLezCore, meth, argsJson: string, timeoutMs: cint): string =
  ## One lp_invoke → the method's result as a bare string ("" on failure/empty, the
  ## older sentinel convention). A JSON-string result is unwrapped; an object/number is
  ## returned as its JSON text (for the envelope + int methods to parse).
  var res, err: cstring
  let rc = lp_invoke(c.client, meth.cstring, argsJson.cstring, timeoutMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil:
    stderr.writeLine("MUSTER-LEZ " & meth & " FAILED rc=" & $rc &
                     " err=" & (if err != nil: $err else: "<none>"))
    return ""
  let s = $res
  try:
    let j = parseJson(s)
    if j.kind == JString: return j.getStr()
    return s
  except CatchableError:
    return s

proc args(parts: varargs[JsonNode]): string =
  var a = newJArray()
  for p in parts: a.add p
  $a

proc newLpLezCore*(instancePath: string, origin = "muster_module"): LpLezCore =
  ## Create the lp client for lez_core and open (or create) the wallet under the
  ## host-provided instance path. Per the labbook: DON'T author the wallet config — pass
  ## a config path that does not exist and let the wallet write its own default (already
  ## pointed at https://testnet.lez.logos.co). Raises if lez_core can't be reached.
  let client = lp_client_create("lez_core", origin.cstring, nil, nil)
  if client == nil:
    raise newException(WalletError, "lez_core: lp_client_create returned null (module not loaded?)")
  result = LpLezCore(client: client, origin: origin)
  initInboundQueue(result.q)
  # The async transfer callback holds `addr result.q` as C user_data; keep the object
  # alive for its (bounded, ≤900s) lifetime, exactly as delivery GC_refs its transport.
  GC_ref(result)
  let cfg = instancePath / "lez" / "config.json"      # absent → wallet writes the default
  let sto = instancePath / "lez" / "storage.json"
  let sta = instancePath / "lez" / "statistics.json"
  # open() returns int 0 on success; if it fails (no wallet yet), create_new().
  let opened = result.rawCall("open", args(%cfg, %sto, %sta), kReadMs)
  var openOk = false
  try: openOk = parseJson(opened).getInt(1) == 0
  except CatchableError: openOk = false
  if not openOk:
    discard result.rawCall("create_new", args(%cfg, %sto, %sta, %""), kReadMs)

# ── the seam ───────────────────────────────────────────────────────────────────

method createAccount*(c: LpLezCore, kind: LezAccountKind): LezAccount =
  if kind == lakPublic:
    let id = c.rawCall("create_account_public", "[]", kReadMs)
    if id.len == 0: raise newException(WalletError, "lez_core create_account_public failed")
    # ACTIVATE a fresh public account on-chain, or the sequencer silently drops txns
    # to it (labbook §9 / the atomic-swap POC). Registering is safe for public accounts.
    discard c.rawCall("register_public_account", args(%id), kReadMs)
    LezAccount(id: id, kind: lakPublic)
  else:
    let id = c.rawCall("create_account_private", "[]", kReadMs)
    if id.len == 0: raise newException(WalletError, "lez_core create_account_private failed")
    # Read the key node to publish (npk/vpk). Do NOT register a private RECEIVE
    # account — initializing it makes it permanently uncreditable by foreign senders.
    let kn = parseKeyNode(c.rawCall("get_private_account_keys", args(%id), kReadMs))
    LezAccount(id: id, kind: lakPrivate, npk: kn.npk, vpk: kn.vpk)

method listAccounts*(c: LpLezCore): seq[LezAccount] =
  let raw = c.rawCall("list_accounts", "[]", kReadMs)
  if raw.len == 0: return
  try:
    for e in parseJson(raw):
      let isPub = e{"is_public"}.getBool(false)
      var a = LezAccount(id: e{"account_id"}.getStr(""),
                         kind: (if isPub: lakPublic else: lakPrivate))
      if not isPub:
        let kn = parseKeyNode(c.rawCall("get_private_account_keys", args(%a.id), kReadMs))
        a.npk = kn.npk; a.vpk = kn.vpk
      if a.id.len > 0: result.add a
  except CatchableError: discard

method getBalanceRaw*(c: LpLezCore, accountId: string, isPublic: bool): string =
  ## get_balance(id, is_public) → a DECIMAL string; "" on an unanswerable read.
  c.rawCall("get_balance", args(%accountId, %isPublic), kReadMs)

proc onTransferResult(ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## Runs on lez_core's thread when a proving transfer settles. Copies the result into
  ## the queue (malloc/copy, no Nim GC) and returns; pollTransfer parses it later on the
  ## module thread. An empty enqueue marks a transport-level failure (ok == 0 / no json).
  if userData == nil: return
  let q = cast[ptr InboundQueue](userData)
  if json != nil: q[].enqueue(json)
  else: q[].enqueue("")

proc transferMethodArgs(form: TransferForm, frm, to, amt: string): (string, string) =
  ## The lez_core method + positional args for a rail; amount already LE-hex.
  case form
  of tfPublic:   ("transfer_public",     args(%frm, %to, %amt))
  of tfDeshield: ("transfer_deshielded", args(%frm, %to, %amt))
  of tfShield, tfPrivate:
    let parts = to.split(':')
    let keys = keyNodeJson((if parts.len > 0: parts[0] else: to),
                           (if parts.len > 1: parts[1] else: ""))
    ((if form == tfShield: "transfer_shielded" else: "transfer_private"),
     args(%frm, %keys, %amt))

method transfer*(c: LpLezCore, form: TransferForm, frm, to, amountRaw: string): LezResult =
  ## Fire the proving transfer in the BACKGROUND (lp_invoke_async), so the ~7-minute
  ## proof NEVER blocks the module's dispatch thread — chat and coordination keep
  ## running. Returns a "pending" marker at once; the adapter's finality() polls
  ## pollTransfer() for the real result. Single-in-flight (one proof at a time).
  if c.inflight:
    return LezResult(success: false, error: "a LEZ transfer is already proving — wait for it")
  let (meth, argsJson) = transferMethodArgs(form, frm, to, amountLe16Hex(amountRaw))
  c.inflight = true
  c.lastResult = LezResult()
  let rc = lp_invoke_async(c.client, meth.cstring, argsJson.cstring, kProveMs,
                           onTransferResult, addr c.q)
  if rc != LP_OK:
    c.inflight = false
    return LezResult(success: false, error: "lez_core " & meth & " lp_invoke_async rc=" & $rc)
  LezResult(success: true, txHash: "pending")     # accepted; proving in the background

proc toStr(b: seq[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

method pollTransfer*(c: LpLezCore): tuple[done: bool, result: LezResult] =
  ## Drain lez_core's async transfer result (on the module thread) and parse it. Until
  ## it arrives, (done: false) — the shielded proof genuinely takes minutes.
  if not c.inflight: return (true, c.lastResult)
  let drained = c.q.drain()
  if drained.len == 0: return (false, LezResult())   # still proving
  c.inflight = false
  let raw = toStr(drained[^1])                        # single in-flight → the one result
  if raw.len == 0:
    c.lastResult = LezResult(success: false, error: "transfer failed (no result)")
  else:
    # the async result may be the bare envelope, or a JSON-string-wrapped one
    var s = raw
    try:
      let j = parseJson(raw)
      if j.kind == JString: s = j.getStr()
    except CatchableError: discard
    c.lastResult = parseEnvelope(s)
  (true, c.lastResult)

method sync*(c: LpLezCore): int =
  ## Scan to the tip so received private notes become discoverable. sync_to_block +
  ## get_current_block_height are int methods (non-zero == failure).
  var height = 0
  try: height = parseJson(c.rawCall("get_current_block_height", "[]", kReadMs)).getInt(0)
  except CatchableError: return 1
  try: return parseJson(c.rawCall("sync_to_block", args(%height), kReadMs)).getInt(1)
  except CatchableError: return 1

method claimPinata*(c: LpLezCore, pinataId, account: string): LezResult =
  ## Faucet: read the pinata challenge (its 33-byte data = [difficulty, seed[0..32]]),
  ## solve the PoW ourselves (the module takes a pre-solved solution), and claim. The
  ## claim is accepted on send; the credit lands only when a block commits (minutes).
  let acct = c.rawCall("get_account_public", args(%pinataId), kReadMs)
  if acct.len == 0: return LezResult(success: false, error: "pinata account unreadable")
  var dataHex = ""
  try: dataHex = parseJson(acct){"data"}.getStr("")
  except CatchableError: discard
  if dataHex.len < 2: return LezResult(success: false, error: "pinata challenge missing")
  let difficulty = parseHexInt(dataHex[0 .. 1])          # first byte = difficulty
  let seedHex = dataHex[2 .. ^1]                          # remaining bytes = seed
  var solution = ""
  try: solution = pinataSolve(seedHex, difficulty)
  except CatchableError as e: return LezResult(success: false, error: "PoW: " & e.msg)
  parseEnvelope(c.rawCall("claim_pinata", args(%pinataId, %account, %solution), kReadMs))
