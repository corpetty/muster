## Module-side runtime — the Nim mirror of logos-rust-sdk `src/api.rs`, plus the
## provider context/emit seam the generated module surface delegates to.
##
## Two halves:
##   • CONSUMER helpers (`protocolVersion`, `saveToken`) forward to the linked
##     protocol library, exactly as rust's api.rs does.
##   • PROVIDER context (`setContext`/`context`, `setEmitCallback`/`emit`) holds
##     the host-supplied instance identity and the event-emit callback, so the
##     generated `logos_module_*` exports stay thin and the author's methods read
##     `context().instancePersistencePath` from one place.

import std/json
from system/ansi_c import c_malloc, c_free
import ./ffi

# ── C-string ownership across the module export seam ─────────────────────────
# A `logos_module_*` export that returns a string hands the host a malloc'd copy
# the host frees via `logos_module_string_free`. These are that pair, so the
# generated surface never open-codes malloc/free.

proc allocCString*(s: string): cstring =
  ## Malloc a NUL-terminated copy of `s` for return across the export boundary.
  let n = s.len
  let buf = cast[ptr UncheckedArray[char]](c_malloc(csize_t(n + 1)))
  if buf == nil: return nil
  if n > 0: copyMem(addr buf[0], unsafeAddr s[0], n)
  buf[n] = '\0'
  cast[cstring](buf)

proc freeCString*(s: cstring) =
  ## Free a string returned by `allocCString` (the host calls this).
  if s != nil: c_free(s)

# ── consumer side ────────────────────────────────────────────────────────────

proc protocolVersion*(): string =
  ## The logos-protocol semver this plugin linked against (same MAJOR ⇔
  ## compatible). Forwarded from the protocol library, never minted here.
  let p = lp_protocol_version()
  if p == nil: "" else: $p

proc protocolAbiMajor*(): int =
  int(lp_protocol_abi_major())

proc saveToken*(moduleName, token: string): bool =
  ## Save a host-issued auth token into THIS plugin's protocol stack so calls to
  ## `moduleName` authenticate. The consumer half of `logos_module_accept_token`:
  ## the module-impl export forwards the host's token here, so the SAME stack the
  ## SDK invokes through holds it (without this, outbound lp_invoke is rejected).
  if moduleName.len == 0 or token.len == 0: return false
  lp_token_save(moduleName.cstring, token.cstring) == LP_OK

# ── provider side: instance context ──────────────────────────────────────────

type
  ModuleContext* = object
    ## What the host tells a module about its own instance at load. The
    ## persistence path is where a module keeps per-instance state (keystores,
    ## settings); two instances of the same module get two paths.
    modulePath*: string
    instanceId*: string
    instancePersistencePath*: string

var gContext {.threadvar.}: ModuleContext
var gContextReady {.threadvar.}: bool

proc setContext*(modulePath, instanceId, instancePersistencePath: string) =
  ## Called once by the generated `logos_module_set_context` export.
  gContext = ModuleContext(modulePath: modulePath, instanceId: instanceId,
                           instancePersistencePath: instancePersistencePath)
  gContextReady = true

proc context*(): ModuleContext = gContext
proc contextReady*(): bool = gContextReady

# ── provider side: event emit ────────────────────────────────────────────────

type EmitCb* = proc (name: cstring, payload: cstring, userData: pointer) {.cdecl.}

var gEmit {.threadvar.}: EmitCb
var gEmitUserData {.threadvar.}: pointer

proc setEmitCallback*(cb: EmitCb, userData: pointer) =
  ## Called by the generated `logos_module_set_emit_callback` export.
  gEmit = cb
  gEmitUserData = userData

proc emit*(name: string, payload: JsonNode) =
  ## Emit an event to the host (subscribers on other modules receive it). No-op if
  ## the host has not installed the callback yet.
  if gEmit != nil:
    let p = $payload
    gEmit(name.cstring, p.cstring, gEmitUserData)

proc emit*(name, payload: string) =
  if gEmit != nil:
    gEmit(name.cstring, payload.cstring, gEmitUserData)
