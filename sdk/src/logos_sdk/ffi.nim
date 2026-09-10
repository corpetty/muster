## Nim bindings of the language-neutral `lp_*` C ABI (logos-protocol) — the Nim
## mirror of logos-rust-sdk `src/ffi.rs`. Both SDKs bind the SAME C symbols.
##
## The symbols resolve at final link time, when logos-module-builder links the
## module plugin against the protocol archive (chained through logos-qt-sdk). No
## header is needed — just the extern signatures below. Consequently this module
## does NOT link under a plain `nim r`; it is compiled into a module staticlib and
## resolved in the plugin link. Higher SDK layers keep their pure-Nim logic in
## separate modules (see `bytes.nim`) so those stay unit-testable.

type
  LpClient* {.importc: "struct LpClient", incompleteStruct.} = object
    ## Opaque client handle (`lp_client*`).
  LpSubscription* {.importc: "struct LpSubscription", incompleteStruct.} = object
    ## Opaque subscription handle (`lp_subscription*`).

  LpResultCb* = proc (ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.}
    ## Result callback for `lp_invoke_async`: `ok != 0` → `json` is the result
    ## value; `ok == 0` → a canonical error object. `json` is valid ONLY for the
    ## duration of the callback — copy anything you keep.
  LpEventCb* = proc (eventName: cstring, dataJson: cstring, userData: pointer) {.cdecl, gcsafe.}
    ## Event callback for `lp_subscribe`: `dataJson` is a JSON array payload.

const LP_OK* = cint(0)

proc lp_protocol_version*(): cstring {.importc, cdecl.}
  ## The logos-protocol semver this plugin linked against (same MAJOR ⇔
  ## compatible). Forwarded verbatim from the protocol library, never minted here.
proc lp_protocol_abi_major*(): cint {.importc, cdecl.}

# Process-global mode / transport of THIS plugin's embedded lp copy. Each plugin
# statically links its own logos-protocol, so its lp globals are its own — the
# host configures a different copy. "remote" (IPC, the default) | "local"
# (in-process registry) | "mock". lp_set_default_transport takes a transport JSON
# object, e.g. {"protocol":"local"}.
proc lp_set_mode*(mode: cstring): cint {.importc, cdecl.}
proc lp_get_mode*(): cstring {.importc, cdecl.}
proc lp_set_default_transport*(transportJson: cstring): cint {.importc, cdecl.}

proc lp_string_free*(s: cstring) {.importc, cdecl.}
  ## Free a string the ABI returned (result/error out-params, lp_get_methods).

proc lp_client_create*(targetModule, originModule,
                       targetTransportJson, capabilityTransportJson: cstring): ptr LpClient
  {.importc, cdecl.}
proc lp_client_destroy*(client: ptr LpClient) {.importc, cdecl.}

proc lp_invoke*(client: ptr LpClient, meth, argsJson: cstring, timeoutMs: cint,
                outResultJson, outErrorJson: ptr cstring): cint {.importc, cdecl.}
  ## One synchronous call. `timeoutMs <= 0` selects the ABI default (currently
  ## 20s). On success returns LP_OK and writes `outResultJson`; on failure writes
  ## `outErrorJson`. Free both out-params with `lp_string_free`.

proc lp_invoke_async*(client: ptr LpClient, meth, argsJson: cstring, timeoutMs: cint,
                      cb: LpResultCb, userData: pointer): cint {.importc, cdecl.}
  ## Asynchronous twin. The ABI copies `argsJson` before returning, so the caller
  ## need not keep it alive; the typed result lands on `cb` later.

proc lp_token_save*(moduleName, token: cstring): cint {.importc, cdecl.}
  ## Save a host-issued auth token into THIS plugin's protocol stack, so
  ## subsequent calls to `moduleName` authenticate. The consumer half of the
  ## module-impl handshake `logos_module_accept_token` (see `api.nim`).

proc lp_subscribe*(client: ptr LpClient, eventName: cstring,
                   cb: LpEventCb, userData: pointer): ptr LpSubscription {.importc, cdecl.}
proc lp_unsubscribe*(sub: ptr LpSubscription) {.importc, cdecl.}

proc lp_get_methods*(client: ptr LpClient): cstring {.importc, cdecl.}
  ## The target's method descriptor JSON. Free with `lp_string_free`.
