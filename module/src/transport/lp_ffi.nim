## Nim binding of the language-neutral `lp_*` C ABI (logos-protocol) — the
## outbound inter-module call runtime. This is the Nim mirror of the rust-sdk's
## `src/ffi.rs`: the SAME C symbols both SDKs bind. They resolve at final link
## time when logos-module-builder links the plugin against the protocol archive
## (Muster's module already links logos-protocol), so no header is needed here —
## just the extern signatures.
##
## Not for pure-Nim `nim r` (the symbols are undefined without the host); it is
## compiled into the module staticlib and linked in the plugin build.


type
  LpClient* {.importc: "struct LpClient", incompleteStruct.} = object
  LpSubscription* {.importc: "struct LpSubscription", incompleteStruct.} = object

  ## Result callback for `lp_invoke_async`: ok != 0 → `json` is the result value;
  ## ok == 0 → canonical error object. `json` is valid only during the callback.
  LpResultCb* = proc (ok: cint, json: cstring, userData: pointer) {.cdecl, gcsafe.}
  ## Event callback for `lp_subscribe`: `dataJson` is a JSON array payload.
  LpEventCb* = proc (eventName: cstring, dataJson: cstring, userData: pointer) {.cdecl, gcsafe.}

const LP_OK* = cint(0)

proc lp_protocol_version*(): cstring {.importc, cdecl.}
proc lp_protocol_abi_major*(): cint {.importc, cdecl.}

# Process-global mode / transport of THIS module's embedded lp copy. Each plugin
# statically links its own logos-protocol, so its lp globals are its own — the host
# configures a different copy. These let muster configure its own: "remote" (IPC,
# the default) | "local" (in-process registry) | "mock". lp_set_default_transport
# takes a transport JSON object, e.g. {"protocol":"local"}.
proc lp_set_mode*(mode: cstring): cint {.importc, cdecl.}
proc lp_get_mode*(): cstring {.importc, cdecl.}
proc lp_set_default_transport*(transportJson: cstring): cint {.importc, cdecl.}

proc lp_string_free*(s: cstring) {.importc, cdecl.}

proc lp_client_create*(targetModule, originModule,
                       targetTransportJson, capabilityTransportJson: cstring): ptr LpClient
  {.importc, cdecl.}
proc lp_client_destroy*(client: ptr LpClient) {.importc, cdecl.}

proc lp_invoke*(client: ptr LpClient, meth, argsJson: cstring, timeoutMs: cint,
                outResultJson, outErrorJson: ptr cstring): cint {.importc, cdecl.}

proc lp_invoke_async*(client: ptr LpClient, meth, argsJson: cstring, timeoutMs: cint,
                      cb: LpResultCb, userData: pointer): cint {.importc, cdecl.}

proc lp_token_save*(moduleName, token: cstring): cint {.importc, cdecl.}

proc lp_subscribe*(client: ptr LpClient, eventName: cstring,
                   cb: LpEventCb, userData: pointer): ptr LpSubscription {.importc, cdecl.}
proc lp_unsubscribe*(sub: ptr LpSubscription) {.importc, cdecl.}

proc lp_get_methods*(client: ptr LpClient): cstring {.importc, cdecl.}

# ── canonical C-ABI bytes codec: {"_bytes": "<base64url, unpadded>"} ──────────
# A `bstr` argument/field rides this tagged form on the lp_* wire (rust-sdk
# `src/bytes.rs`). We match it byte-for-byte so delivery decodes our payloads.

const b64urlAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc b64urlEncode*(data: openArray[byte]): string =
  ## URL-safe base64, UNPADDED.
  var i = 0
  while i + 3 <= data.len:
    let n = (int(data[i]) shl 16) or (int(data[i+1]) shl 8) or int(data[i+2])
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
    result.add b64urlAlphabet[(n shr 6) and 63]
    result.add b64urlAlphabet[n and 63]
    i += 3
  let rem = data.len - i
  if rem == 1:
    let n = int(data[i]) shl 16
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
  elif rem == 2:
    let n = (int(data[i]) shl 16) or (int(data[i+1]) shl 8)
    result.add b64urlAlphabet[(n shr 18) and 63]
    result.add b64urlAlphabet[(n shr 12) and 63]
    result.add b64urlAlphabet[(n shr 6) and 63]

proc b64urlDecodeChar(c: char): int =
  case c
  of 'A'..'Z': int(c) - int('A')
  of 'a'..'z': int(c) - int('a') + 26
  of '0'..'9': int(c) - int('0') + 52
  of '-': 62
  of '_': 63
  else: -1

proc b64urlDecode*(s: string): seq[byte] =
  ## Lenient: accepts padding (`=`) and standard `+`/`/` as well as url-safe.
  var bits = 0
  var acc = 0
  for ch in s:
    if ch == '=': break
    var v = b64urlDecodeChar(ch)
    if v < 0:
      if ch == '+': v = 62
      elif ch == '/': v = 63
      else: continue    # skip whitespace/newlines
    acc = (acc shl 6) or v
    bits += 6
    if bits >= 8:
      bits -= 8
      result.add byte((acc shr bits) and 0xFF)

proc bytesTag*(data: openArray[byte]): string =
  ## The JSON value for a bstr argument: {"_bytes":"<b64url>"}.
  "{\"_bytes\":\"" & b64urlEncode(data) & "\"}"
