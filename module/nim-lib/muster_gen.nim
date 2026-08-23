## GENERATED from muster.lidl by tools/lidl_gen.nim — do not edit.
## Regenerate: see module/tools/README.md. The impl seam is muster_module.nim.
import std/json
import std/strutils
from system/ansi_c import c_malloc, c_free

type MusterModuleContext = object
  modulePath: string
  instanceId: string
  instancePersistencePath: string
var gContext: MusterModuleContext
var gContextReady = false
type EmitCb = proc (name: cstring, payload: cstring, userData: pointer) {.cdecl.}
var gEmitCb: EmitCb = nil
var gEmitUserData: pointer = nil

proc toCString(s: string): cstring =
  let n = s.len
  let buf = cast[ptr UncheckedArray[char]](c_malloc(csize_t(n + 1)))
  if buf == nil: return nil
  if n > 0: copyMem(addr buf[0], unsafeAddr s[0], n)
  buf[n] = '\0'
  cast[cstring](buf)

proc musterHealth(): string
proc musterIdentity(): string
proc musterDescribe(): string
proc musterPropose(effect_json: string): string
proc musterTxhash(intent_id: string): string
proc musterApprove(intent_id: string, signature_hex: string): string
proc musterStatus(intent_id: string): string
proc musterSubmit(intent_id: string): string
proc musterCoordinate_join(topic: string): string
proc musterCoordinate_propose(effect_json: string): string
proc musterCoordinate_contribute(intent_id: string, signature_hex: string): string
proc musterCoordinate_intents(): string
proc musterCoordinate_request_join(): string
proc musterCoordinate_pending(): string
proc musterCoordinate_admit(identity_hex: string): string
proc musterWallet_accounts(): string
proc musterWallet_balances(): string
proc musterWallet_estimate_fee(chain: string, to: string, asset_symbol: string, raw: string): string
proc musterWallet_send(chain: string, from_id: string, to: string, asset_symbol: string, raw: string): string
proc musterWallet_finality(chain: string, tx_id: string): string
proc musterWallet_verified_balance(account_id: string, state_root_hex: string): string

proc dispatch(meth: string, args: JsonNode): JsonNode =
  case meth
  of "health":
    %musterHealth()
  of "identity":
    %musterIdentity()
  of "describe":
    %musterDescribe()
  of "propose":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterPropose(args[0].getStr())
  of "txhash":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterTxhash(args[0].getStr())
  of "approve":
    if args.kind != JArray or args.len < 2: return newJNull()
    %musterApprove(args[0].getStr(), args[1].getStr())
  of "status":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterStatus(args[0].getStr())
  of "submit":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterSubmit(args[0].getStr())
  of "coordinate_join":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterCoordinate_join(args[0].getStr())
  of "coordinate_propose":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterCoordinate_propose(args[0].getStr())
  of "coordinate_contribute":
    if args.kind != JArray or args.len < 2: return newJNull()
    %musterCoordinate_contribute(args[0].getStr(), args[1].getStr())
  of "coordinate_intents":
    %musterCoordinate_intents()
  of "coordinate_request_join":
    %musterCoordinate_request_join()
  of "coordinate_pending":
    %musterCoordinate_pending()
  of "coordinate_admit":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterCoordinate_admit(args[0].getStr())
  of "wallet_accounts":
    %musterWallet_accounts()
  of "wallet_balances":
    %musterWallet_balances()
  of "wallet_estimate_fee":
    if args.kind != JArray or args.len < 4: return newJNull()
    %musterWallet_estimate_fee(args[0].getStr(), args[1].getStr(), args[2].getStr(), args[3].getStr())
  of "wallet_send":
    if args.kind != JArray or args.len < 5: return newJNull()
    %musterWallet_send(args[0].getStr(), args[1].getStr(), args[2].getStr(), args[3].getStr(), args[4].getStr())
  of "wallet_finality":
    if args.kind != JArray or args.len < 2: return newJNull()
    %musterWallet_finality(args[0].getStr(), args[1].getStr())
  of "wallet_verified_balance":
    if args.kind != JArray or args.len < 2: return newJNull()
    %musterWallet_verified_balance(args[0].getStr(), args[1].getStr())
  else:
    nil

proc logos_module_get_methods(): cstring {.exportc, cdecl.} =
  toCString(parseJson("""[{"isInvokable":true,"name":"health","parameters":[],"returnType":"QString","signature":"health()"},{"isInvokable":true,"name":"identity","parameters":[],"returnType":"QString","signature":"identity()"},{"isInvokable":true,"name":"describe","parameters":[],"returnType":"QString","signature":"describe()"},{"isInvokable":true,"name":"propose","parameters":[{"name":"effect_json","type":"QString"}],"returnType":"QString","signature":"propose(QString)"},{"isInvokable":true,"name":"txhash","parameters":[{"name":"intent_id","type":"QString"}],"returnType":"QString","signature":"txhash(QString)"},{"isInvokable":true,"name":"approve","parameters":[{"name":"intent_id","type":"QString"},{"name":"signature_hex","type":"QString"}],"returnType":"QString","signature":"approve(QString,QString)"},{"isInvokable":true,"name":"status","parameters":[{"name":"intent_id","type":"QString"}],"returnType":"QString","signature":"status(QString)"},{"isInvokable":true,"name":"submit","parameters":[{"name":"intent_id","type":"QString"}],"returnType":"QString","signature":"submit(QString)"},{"isInvokable":true,"name":"coordinate_join","parameters":[{"name":"topic","type":"QString"}],"returnType":"QString","signature":"coordinate_join(QString)"},{"isInvokable":true,"name":"coordinate_propose","parameters":[{"name":"effect_json","type":"QString"}],"returnType":"QString","signature":"coordinate_propose(QString)"},{"isInvokable":true,"name":"coordinate_contribute","parameters":[{"name":"intent_id","type":"QString"},{"name":"signature_hex","type":"QString"}],"returnType":"QString","signature":"coordinate_contribute(QString,QString)"},{"isInvokable":true,"name":"coordinate_intents","parameters":[],"returnType":"QString","signature":"coordinate_intents()"},{"isInvokable":true,"name":"coordinate_request_join","parameters":[],"returnType":"QString","signature":"coordinate_request_join()"},{"isInvokable":true,"name":"coordinate_pending","parameters":[],"returnType":"QString","signature":"coordinate_pending()"},{"isInvokable":true,"name":"coordinate_admit","parameters":[{"name":"identity_hex","type":"QString"}],"returnType":"QString","signature":"coordinate_admit(QString)"},{"isInvokable":true,"name":"wallet_accounts","parameters":[],"returnType":"QString","signature":"wallet_accounts()"},{"isInvokable":true,"name":"wallet_balances","parameters":[],"returnType":"QString","signature":"wallet_balances()"},{"isInvokable":true,"name":"wallet_estimate_fee","parameters":[{"name":"chain","type":"QString"},{"name":"to","type":"QString"},{"name":"asset_symbol","type":"QString"},{"name":"raw","type":"QString"}],"returnType":"QString","signature":"wallet_estimate_fee(QString,QString,QString,QString)"},{"isInvokable":true,"name":"wallet_send","parameters":[{"name":"chain","type":"QString"},{"name":"from_id","type":"QString"},{"name":"to","type":"QString"},{"name":"asset_symbol","type":"QString"},{"name":"raw","type":"QString"}],"returnType":"QString","signature":"wallet_send(QString,QString,QString,QString,QString)"},{"isInvokable":true,"name":"wallet_finality","parameters":[{"name":"chain","type":"QString"},{"name":"tx_id","type":"QString"}],"returnType":"QString","signature":"wallet_finality(QString,QString)"},{"isInvokable":true,"name":"wallet_verified_balance","parameters":[{"name":"account_id","type":"QString"},{"name":"state_root_hex","type":"QString"}],"returnType":"QString","signature":"wallet_verified_balance(QString,QString)"}]""").`$`)

proc logos_module_dispatch(meth: cstring, argsJson: cstring): cstring {.exportc, cdecl.} =
  if meth == nil: return nil
  var args = newJArray()
  if argsJson != nil:
    try:
      let parsed = parseJson($argsJson)
      if parsed.kind == JArray: args = parsed
      else: return nil
    except CatchableError: return nil
  let res = dispatch($meth, args)
  if res == nil or res.isNil: return nil
  toCString($res)

proc logos_module_set_context(modulePath: cstring, instanceId: cstring,
                              instancePersistencePath: cstring) {.exportc, cdecl.} =
  proc s(p: cstring): string = (if p == nil: "" else: $p)
  gContext = MusterModuleContext(modulePath: s(modulePath), instanceId: s(instanceId),
                                 instancePersistencePath: s(instancePersistencePath))
  gContextReady = true

proc logos_module_set_emit_callback(cb: EmitCb, userData: pointer) {.exportc, cdecl.} =
  gEmitCb = cb
  gEmitUserData = userData

proc logos_module_accept_token(moduleName: cstring, token: cstring): cint {.exportc, cdecl.} =
  if moduleName == nil or token == nil: return -1
  0

proc logos_module_get_protocol_version(): cstring {.exportc, cdecl.} =
  cstring"0.1.0"

proc logos_module_string_free(s: cstring) {.exportc, cdecl.} =
  if s != nil: c_free(s)

{.emit: "extern void NimMain(void); static void __attribute__((constructor)) muster_module_ctor(void) { NimMain(); }".}
