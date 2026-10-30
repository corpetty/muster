## Host client harness for derived-exo-526 (companion to
## probe_return_marshalling_host.nim). It loads the module (the REAL Nim core, no
## mock) as a shared library, the way a host loads a module, and drives it through the
## SAME return-marshalling the shipped host applies. So the value it prints is what a
## host CLIENT observes, not the raw logos_module_dispatch string.
##
## The marshalling reproduced here is exactly the shipped cdylib path:
##   * logos-qt-sdk qt-generator/lidl_gen_cdylib_glue.cpp (the generated
##     <Module>CdylibProvider::callMethod): dispatch -> nlohmann::json::parse
##     -> logos::nlohmannToQVariant(jResult).
##   * logos-cpp-sdk cpp/logos_json_convert.cpp nlohmannToQVariant(): a JSON
##     string becomes QVariant(QString); a JSON bool becomes QVariant(bool);
##     null/discarded becomes an invalid QVariant.
##   * logos-liblogos src/logos_core/proxy_api.cpp (--call): the CLI reads the
##     returned QVariant as `canConvert<QString>() ? toString() : "Result of
##     type: <T>"`. A bool false thus prints the literal "false", the exact
##     symptom this probe exists to catch.
##
## Qt and nlohmann are not on the probe's bare-nim toolchain, so the JSON-scalar ->
## typed-value -> client-string reduction is reimplemented minimally over the
## dispatch output. It is not a re-encode of the module's answer: it parses the
## module's real dispatch bytes and classifies the client-observed type, which is
## where the reported bool-drop would surface.
##
## Emits one JSON observation object per call on stdout. It JUDGES NOTHING: the probe
## (and the spec's `always(client_return_typed)`) own every verdict.
##
## The Nim port (exo-607 T7) of host_return_harness.cpp, observation for observation.
## The C++ harness linked the module's Nim staticlib; a Nim harness cannot, because two
## Nim runtimes in one link collide (and the module's exports are hidden, so a shared
## build of it cannot be loaded either). So this harness and nim-lib/muster_module.nim
## are one program with one runtime: it imports the module, which compiles its
## logos_module_* exports in, and calls them through `importc` declarations, a C-ABI
## call into the module's own exported functions, as the C++ harness made (and, as in the
## plugin, the module's own constructor initializes the runtime). The lp_* ABI
## the module expects from its host is defined here, and the module's `importc`s of it
## link to these definitions.

import std/[json, strutils]
import "../../nim-lib/muster_module"   # the module, compiled in: its exports and its init
import "../../src/audio/opus"          # the libopus this program links: what voice_status must name

# ── the lp_* inter-module ABI (logos_sdk/ffi.nim) ───────────────────────────────
# The shipped plugin statically links its own logos-protocol, which defines these; this
# harness is a host with NO protocol stack: every client/subscription is null, every
# call fails. None of the calls this probe makes (health, propose, status, and the voice
# methods, coordinate_messages and coordinate_proof with no room joined) should reach
# another module, so each stub counts its calls and the harness reports the
# count; a non-zero count is visible in the probe's output rather than hidden behind a
# silent success.
var lpCalls = 0

proc lp_protocol_version(): cstring {.exportc, cdecl.} = inc lpCalls; "0.0.0-harness"
proc lp_protocol_abi_major(): cint {.exportc, cdecl.} = inc lpCalls; 0
proc lp_set_mode(mode: cstring): cint {.exportc, cdecl.} = inc lpCalls; -1
proc lp_get_mode(): cstring {.exportc, cdecl.} = inc lpCalls; "none"
proc lp_set_default_transport(t: cstring): cint {.exportc, cdecl.} = inc lpCalls; -1
proc lp_string_free(s: cstring) {.exportc, cdecl.} = discard
proc lp_client_create(target, origin, tt, ct: cstring): pointer {.exportc, cdecl.} =
  inc lpCalls; nil
proc lp_client_destroy(c: pointer) {.exportc, cdecl.} = discard
proc lp_invoke(c: pointer, meth, args: cstring, timeoutMs: cint,
               outResult, outError: ptr cstring): cint {.exportc, cdecl.} =
  inc lpCalls
  if outResult != nil: outResult[] = nil
  if outError != nil: outError[] = nil
  -1
proc lp_invoke_async(c: pointer, meth, args: cstring, timeoutMs: cint,
                     cb, ud: pointer): cint {.exportc, cdecl.} = inc lpCalls; -1
proc lp_token_save(m, t: cstring): cint {.exportc, cdecl.} = inc lpCalls; -1
proc lp_token_get(m: cstring): cstring {.exportc, cdecl.} = inc lpCalls; nil
proc lp_inform_module_token(c: pointer, a, m, t: cstring): cint {.exportc, cdecl.} =
  inc lpCalls; -1
proc lp_subscribe(c: pointer, e: cstring, cb, ud: pointer): pointer {.exportc, cdecl.} =
  inc lpCalls; nil
proc lp_unsubscribe(s: pointer) {.exportc, cdecl.} = discard
proc lp_get_methods(c: pointer): cstring {.exportc, cdecl.} = inc lpCalls; nil

# ── the reduction ───────────────────────────────────────────────────────────────

type
  ClientType = enum
    ## The client-observed shapes the reduction can land on. `ctString` is the only
    ## typed-string outcome a QString-returning method should ever produce; `ctBool`
    ## is the reported regression (QVariant(bool) -> CLI "true"/"false"); `ctEmpty`
    ## is a dropped/invalid QVariant (null/parse-failure -> CLI "").
    ctString = "string", ctBool = "bool", ctEmpty = "empty", ctNumber = "number",
    ctOther = "other"
  ClientReturn = object
    kind: ClientType
    value: string   ## the string the CLI would print (QVariant::toString())

proc hostObserve(raw: cstring): ClientReturn =
  ## Reproduce the host: parse the dispatch scalar JSON and classify the QVariant the
  ## client observes, then the string the CLI prints from it. This is the
  ## nlohmannToQVariant + proxy_api.cpp `toString()` reduction, no more.
  if raw == nil: return ClientReturn(kind: ctEmpty)    # null dispatch -> QVariant() -> ""
  let t = ($raw).strip(chars = {' ', '\n', '\t', '\r'})
  if t.len == 0 or t == "null": return ClientReturn(kind: ctEmpty)
  if t == "true": return ClientReturn(kind: ctBool, value: "true")
  if t == "false": return ClientReturn(kind: ctBool, value: "false")
  if t.len >= 2 and t[0] == '"' and t[^1] == '"':
    try: return ClientReturn(kind: ctString, value: parseJson(t).getStr())
    except CatchableError: return ClientReturn(kind: ctOther, value: t)
  if t.allCharsInSet({'-', '+', '.', '0' .. '9'}):     # a bare number token
    return ClientReturn(kind: ctNumber, value: t)
  ClientReturn(kind: ctOther, value: t)

proc logos_module_dispatch(meth, argsJson: cstring): cstring {.importc, cdecl.}
proc logos_module_get_methods(): cstring {.importc, cdecl.}
proc logos_module_string_free(s: cstring) {.importc, cdecl.}

proc listedAsQString(name: string): bool =
  ## Whether the module's method table (what a host builds its typed client from) lists
  ## `name` returning QString. A method missing there is not callable from a typed client.
  let raw = logos_module_get_methods()
  if raw == nil: return false
  try:
    for m in parseJson($raw):
      if m{"name"}.getStr() == name and m{"returnType"}.getStr() == "QString": result = true
  except CatchableError: result = false
  logos_module_string_free(raw)

proc voiceStatusTyped(v: string): bool =
  ## voice_status (docs/design/voice-notes.md §8) is a JSON object: ready.codec is the libopus
  ## this program links (opus_get_version_string), and before any device opened, ready.capture
  ## and ready.playback are "unknown". Reading it must open no device.
  try:
    let j = parseJson(v)
    j.kind == JObject and j{"ready", "codec"}.getStr() == $opus_get_version_string() and
      j{"ready", "capture"}.getStr() == "unknown" and j{"ready", "playback"}.getStr() == "unknown"
  except CatchableError: false

proc callClient(meth, argsJson: string): ClientReturn =
  ## Call one method through the module's C ABI and reduce it to a client return.
  let raw = logos_module_dispatch(meth.cstring, argsJson.cstring)
  result = hostObserve(raw)
  if raw != nil: logos_module_string_free(raw)

const stateTokens = ["draft", "proposed", "collecting", "executable", "final",
                     "expired", "aborted", "unknown-intent"]

proc emit(call, expect: string, cr: ClientReturn) =
  ## One observation line. `expect` is the declared-typed contract for this call:
  ## "ok" for health, "nonempty_id" for propose, "state_token" for status, "voice_status"
  ## for voice_status. A QString-returning method is typed iff the client observed a
  ## non-empty STRING (never bool, never empty/default); status() must also be a known
  ## lifecycle token, propose() a non-empty id, and voice_status() listed in the method
  ## table as QString and the JSON voiceStatusTyped reads.
  var typed = cr.kind == ctString and cr.value.len > 0
  if typed and expect == "ok": typed = cr.value == "ok"
  if typed and expect == "state_token": typed = cr.value in stateTokens
  if typed and expect == "voice_status":
    typed = listedAsQString("voice_status") and voiceStatusTyped(cr.value)
  echo $(%*{"call": call, "expect": expect, "client_type": $cr.kind,
            "client_value": cr.value, "client_return_typed": typed})

proc emitExact(call, want: string, cr: ClientReturn) =
  ## One observation of a call whose reply in this state is known to the byte (the voice
  ## methods with no room joined): typed iff the client observed exactly `want` as a STRING,
  ## and the method table lists `call` returning QString.
  let typed = cr.kind == ctString and cr.value == want and listedAsQString(call)
  echo $(%*{"call": call, "expect": "exact", "want": want, "client_type": $cr.kind,
            "client_value": cr.value, "client_return_typed": typed})

proc quoteArg(s: string): string = $(%*[s])   ## the JSON args array ["<s>"]

proc harnessMain() =
  # health(): the canonical liveness return; must be exactly "ok".
  emit("health", "ok", callClient("health", "[]"))

  # propose() across a family of valid/edge effect JSONs, then status() of each
  # resulting id. The edge cases exercise the impl's JSON tolerance without ever being
  # allowed to collapse the typed string return to a bool/empty default.
  const effects = [
    """{"to":"0xabc","value":1000,"nonce":0}""",                        # canonical transfer
    """{"to":"0x0","value":0,"nonce":0}""",                              # zero value/addr
    """{"to":"0xffffffffffffffffffffffffffffffffffffffff","value":1,"nonce":7}""",
    """{}""",                                                            # empty object
    """{"value":42}""",                                                  # partial object
    "not json at all",                                                   # malformed effect
    """{"to":"0xabc","value":1000,"nonce":0,"extra":"ignored"}""",
  ]
  for eff in effects:
    let pr = callClient("propose", quoteArg(eff))
    emit("propose", "nonempty_id", pr)
    # status(<the id>): reuse the client-observed id string as the argument.
    emit("status", "state_token", callClient("status", quoteArg(pr.value)))
  # voice_status() (voice notes, docs/design/voice-notes.md §8): the module links libopus and
  # miniaudio, and says which libopus, with no device opened.
  emit("voice_status", "voice_status", callClient("voice_status", "[]"))
  # The six other voice methods through the generated dispatch, with no room joined (§8):
  # each reply is the typed string that state gives, and none opens a device, so voice_status
  # still reads both devices "unknown" after them. coordinate_messages, now voice.threadRows'
  # rows, and coordinate_proof, which refuses a room holding a voice note, answer as before.
  let noRoom = [
    ("voice_record_start", "[]", """{"error":"not-joined"}"""),
    ("voice_record_stop", "[]", """{"error":"not-recording"}"""),
    ("voice_draft_send", "[]", """{"error":"no-draft"}"""),
    ("voice_draft_discard", "[]", "ok"),
    ("voice_play", quoteArg("draft"), """{"error":"no-draft"}"""),
    ("voice_play", quoteArg("0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f"), """{"error":"not-joined"}"""),
    ("voice_play_stop", "[]", "ok"),
    ("coordinate_messages", "[]", "[]"),
    ("coordinate_proof", "[]", """{"error":"not-joined"}""")]
  for (meth, args, want) in noRoom:
    emitExact(meth, want, callClient(meth, args))
  emit("voice_status", "voice_status", callClient("voice_status", "[]"))
  # Not an observation (no client_return_typed key): the probe ignores it; a reader of
  # the log sees whether any of the above reached the lp_* stubs.
  echo $(%*{"lp_stub_calls": lpCalls})

# Built with --noMain: the runtime, the module's and this harness's, is initialized
# once, by the constructor the generated surface installs (muster_gen.nim calls NimMain
# at load, as in the shipped plugin). A Nim main would run NimMain a second time, and
# with it every module's top-level code. So the work is in the program's C main.
# argv is char** (cstringArray): clang refuses a main whose second parameter is
# anything else; gcc, which the suite uses on Linux, accepts it.
proc main(argc: cint, argv: cstringArray): cint {.exportc: "main", cdecl.} =
  harnessMain()
  0
