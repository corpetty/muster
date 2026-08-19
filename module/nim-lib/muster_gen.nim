## Hand-written stand-in for the Nim module-impl surface a Nim `logos-lidl-gen`
## backend will emit from `muster.lidl` (ADR-008 fallback: hand-write the
## generated surface, keep the contract normative). It is the Nim analog of
## logos-rust-sdk's `provider_gen.rs`: it exports the module-impl C ABI
## (`logos_module_*`) that logos-cpp-generator's plugin glue calls, and forwards
## each dispatch to the author impl in `muster_module.nim`.
##
## The C ABI (verified against provider_gen.rs), all `{.exportc, cdecl.}`:
##   logos_module_dispatch(method, args_json) -> cstring   (JSON result, host-freed)
##   logos_module_get_methods() -> cstring                 (JSON method/event descriptor)
##   logos_module_set_context(module_path, instance_id, persistence_path)
##   logos_module_set_emit_callback(cb, user_data)
##   logos_module_accept_token(module_name, token) -> cint
##   logos_module_get_protocol_version() -> cstring
##   logos_module_string_free(s)
##
## When the B4 Nim lidl-gen lands, this file is regenerated from muster.lidl and
## the dispatch table is emitted from its declared methods rather than written.

import std/json
import std/strutils
from system/ansi_c import c_malloc, c_free

# ── Author impl seam ──────────────────────────────────────────────────────────
# Defined in muster_module.nim, which includes this file (mirrors provider's
# `include!("provider_gen.rs")` + trait impl). Kept as forward decls so the
# generated surface never hard-codes method bodies.
proc musterHealth(): string
proc musterEcho(msg: string): string

# ── Module context stamped by the host (mirrors RustModuleContext) ────────────
type MusterModuleContext = object
  modulePath: string
  instanceId: string
  instancePersistencePath: string

var gContext: MusterModuleContext
var gContextReady = false

# ── Emit plumbing (no events on the P0 surface; wired for parity) ─────────────
type EmitCb = proc (name: cstring, payload: cstring, userData: pointer) {.cdecl.}
var gEmitCb: EmitCb = nil
var gEmitUserData: pointer = nil

# ── C-string helpers: allocate with c_malloc so the host frees with c_free via
# logos_module_string_free (one allocator on both ends). ──────────────────────
proc toCString(s: string): cstring =
  let n = s.len
  let buf = cast[ptr UncheckedArray[char]](c_malloc(csize_t(n + 1)))
  if buf == nil: return nil
  if n > 0:
    copyMem(addr buf[0], unsafeAddr s[0], n)
  buf[n] = '\0'
  cast[cstring](buf)

# ── Dispatch table (the part B4's generator emits from muster.lidl) ───────────
# args_json is a JSON array of positional arguments. The result is JSON-encoded
# and returned as a host-freed C string; an unknown method returns nil (the
# same "not handled" signal provider_gen.rs uses).
proc dispatch(meth: string, args: JsonNode): JsonNode =
  case meth
  of "health":
    %musterHealth()
  of "echo":
    if args.kind != JArray or args.len < 1:
      newJNull()
    else:
      %musterEcho(args[0].getStr())
  else:
    nil

proc logos_module_dispatch(meth: cstring, argsJson: cstring): cstring {.exportc, cdecl.} =
  if meth == nil: return nil
  var args = newJArray()
  if argsJson != nil:
    try:
      let parsed = parseJson($argsJson)
      if parsed.kind == JArray: args = parsed
      else: return nil
    except CatchableError:
      return nil
  let res = dispatch($meth, args)
  if res == nil or res.isNil: return nil
  toCString($res)

proc logos_module_get_methods(): cstring {.exportc, cdecl.} =
  ## Introspection surface for health/echo, in the shape logos-cpp-generator
  ## expects (verified against provider_gen.rs's get_methods output).
  const methods = """[
    {"isInvokable":true,"name":"health","parameters":[],"returnType":"QString","signature":"health()"},
    {"isInvokable":true,"name":"echo","parameters":[{"name":"msg","type":"QString"}],"returnType":"QString","signature":"echo(QString)"}
  ]"""
  # Compact it so the host parser sees a single JSON array line.
  toCString(parseJson(methods).`$`)

proc logos_module_set_context(modulePath: cstring, instanceId: cstring,
                              instancePersistencePath: cstring) {.exportc, cdecl.} =
  proc s(p: cstring): string = (if p == nil: "" else: $p)
  gContext = MusterModuleContext(
    modulePath: s(modulePath),
    instanceId: s(instanceId),
    instancePersistencePath: s(instancePersistencePath))
  gContextReady = true

proc logos_module_set_emit_callback(cb: EmitCb, userData: pointer) {.exportc, cdecl.} =
  gEmitCb = cb
  gEmitUserData = userData

proc logos_module_accept_token(moduleName: cstring, token: cstring): cint {.exportc, cdecl.} =
  ## No outbound calls on the P0 surface; accept and record nothing.
  if moduleName == nil or token == nil: return -1
  0

proc logos_module_get_protocol_version(): cstring {.exportc, cdecl.} =
  ## Stamped statically for the spike. logoscore loads pre-protocol builds
  ## permissively, so an exact match is not required to load and dispatch.
  cstring"0.1.0"

proc logos_module_string_free(s: cstring) {.exportc, cdecl.} =
  if s != nil:
    c_free(s)

# ── Nim runtime init for a --noMain staticlib ─────────────────────────────────
# The host never calls NimMain, so GC/globals must be initialized before the
# first exported entry point runs. A linker constructor runs NimMain once at
# load, the same lazy-before-first-dispatch guarantee provider_gen.rs gets from
# Rust's static init.
{.emit: """
extern void NimMain(void);
static void __attribute__((constructor)) muster_module_ctor(void) {
  NimMain();
}
""".}
