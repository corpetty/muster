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
proc musterPropose(effect_json: string): string
proc musterApprove(intent_id: string, contribution_hex: string): string
proc musterStatus(intent_id: string): string

proc dispatch(meth: string, args: JsonNode): JsonNode =
  case meth
  of "health":
    %musterHealth()
  of "propose":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterPropose(args[0].getStr())
  of "approve":
    if args.kind != JArray or args.len < 2: return newJNull()
    %musterApprove(args[0].getStr(), args[1].getStr())
  of "status":
    if args.kind != JArray or args.len < 1: return newJNull()
    %musterStatus(args[0].getStr())
  else:
    nil

proc logos_module_get_methods(): cstring {.exportc, cdecl.} =
  toCString(parseJson("""[{"isInvokable":true,"name":"health","parameters":[],"returnType":"QString","signature":"health()"},{"isInvokable":true,"name":"propose","parameters":[{"name":"effect_json","type":"QString"}],"returnType":"QString","signature":"propose(QString)"},{"isInvokable":true,"name":"approve","parameters":[{"name":"intent_id","type":"QString"},{"name":"contribution_hex","type":"QString"}],"returnType":"QString","signature":"approve(QString,QString)"},{"isInvokable":true,"name":"status","parameters":[{"name":"intent_id","type":"QString"}],"returnType":"QString","signature":"status(QString)"}]""").`$`)

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
