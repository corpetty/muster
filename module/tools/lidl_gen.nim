## Nim LIDL codegen backend (ADR-008 / B4).
##
## Generates the module-impl surface (`muster_gen.nim` — the seven `logos_module_*`
## C exports + the dispatch table + the get-methods descriptor) from a `.lidl`
## contract, so `muster.lidl` is normative AND generated rather than hand-written.
## The contract is parsed through the canonical LIDL frontend over its C bridge
## (`lidl_c.h`: `lidl_parse_to_json`), exactly as `logos-rust-sdk/lidl-gen` does —
## this is the Nim SDK gap the plan names, filled without reimplementing the grammar.
##
## Usage: lidl_gen <contract.lidl> <out.nim>
## The impl seam is unchanged: the generated file forwards each method to a
## `muster<Method>` proc the author defines (see muster_module.nim).

import std/[json, os, strutils]

const LIDL_INC {.strdefine.} = ""
const LIDL_C_A {.strdefine.} = ""
const LIDL_A {.strdefine.} = ""
{.passC: "-I" & LIDL_INC.}
{.passL: LIDL_C_A & " " & LIDL_A & " -lstdc++".}
proc lidl_parse_to_json(lidl: cstring, err: ptr cstring): cstring {.importc, cdecl.}
proc lidl_free_string(s: cstring) {.importc, cdecl.}

proc parseLidl(src: string): JsonNode =
  var err: cstring = nil
  let js = lidl_parse_to_json(src.cstring, addr err)
  if js == nil:
    let msg = (if err != nil: $err else: "unknown error")
    if err != nil: lidl_free_string(err)
    raise newException(ValueError, "lidl parse failed: " & msg)
  result = parseJson($js)
  lidl_free_string(js)

# ── LIDL primitive → (Nim getter for a JSON arg, JSON-result ctor, Qt type name) ─
proc primName(t: JsonNode): string = t{"name"}.getStr("any")

proc argGetter(t: JsonNode, idx: int): string =
  ## Nim expression reading positional arg `idx` as the LIDL type.
  case primName(t)
  of "tstr": "args[" & $idx & "].getStr()"
  of "bstr": "args[" & $idx & "].getStr()"
  of "int": "args[" & $idx & "].getInt()"
  of "uint": "args[" & $idx & "].getInt()"
  of "bool": "args[" & $idx & "].getBool()"
  else: "args[" & $idx & "]"

proc qtType(t: JsonNode): string =
  case primName(t)
  of "tstr": "QString"
  of "bstr": "QByteArray"
  of "int": "int"
  of "uint": "uint"
  of "bool": "bool"
  else: "QVariant"

proc methodProcName(name: string): string =
  ## LIDL method "echo" -> author proc "musterEcho".
  "muster" & name[0].toUpperAscii() & name[1..^1]

proc genDispatch(methods: JsonNode): string =
  result = "proc dispatch(meth: string, args: JsonNode): JsonNode =\n  case meth\n"
  for m in methods:
    let name = m["name"].getStr()
    let params = m{"params"}
    let np = (if params.isNil: 0 else: params.len)
    var call = methodProcName(name) & "("
    var parts: seq[string]
    if not params.isNil:
      for i in 0 ..< params.len:
        parts.add argGetter(params[i]["type"], i)
    call.add parts.join(", ") & ")"
    result.add "  of \"" & name & "\":\n"
    if np > 0:
      result.add "    if args.kind != JArray or args.len < " & $np & ": return newJNull()\n"
    result.add "    %" & call & "\n"
  result.add "  else:\n    nil\n"

proc genGetMethods(methods: JsonNode): string =
  var entries: seq[string]
  for m in methods:
    let name = m["name"].getStr()
    let params = m{"params"}
    var pjson: seq[string]
    var sigTypes: seq[string]
    if not params.isNil:
      for p in params:
        pjson.add "{\"name\":\"" & p["name"].getStr() & "\",\"type\":\"" & qtType(p["type"]) & "\"}"
        sigTypes.add qtType(p["type"])
    let ret = qtType(m["returnType"])
    entries.add "{\"isInvokable\":true,\"name\":\"" & name & "\"," &
      "\"parameters\":[" & pjson.join(",") & "]," &
      "\"returnType\":\"" & ret & "\",\"signature\":\"" & name & "(" & sigTypes.join(",") & ")\"}"
  "[" & entries.join(",") & "]"

proc genForwardDecls(methods: JsonNode): string =
  for m in methods:
    let name = m["name"].getStr()
    let params = m{"params"}
    var sig: seq[string]
    if not params.isNil:
      for p in params:
        let nimT = (if primName(p["type"]) in ["int", "uint"]: "int" else: "string")
        sig.add p["name"].getStr() & ": " & nimT
    let retNim = (if primName(m["returnType"]) in ["int", "uint"]: "int" else: "string")
    result.add "proc " & methodProcName(name) & "(" & sig.join(", ") & "): " & retNim & "\n"

const header = """## GENERATED from muster.lidl by tools/lidl_gen.nim — do not edit.
## Regenerate: see module/tools/README.md. The impl seam is muster_module.nim.
import std/json
import std/strutils
from system/ansi_c import c_malloc, c_free

"""

const prelude = """
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
"""

const exportsTail = """
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
"""

proc generate(contract: JsonNode): string =
  let methods = contract{"methods"}
  result = header
  result.add prelude & "\n"
  result.add genForwardDecls(methods) & "\n"
  result.add genDispatch(methods) & "\n"
  result.add "proc logos_module_get_methods(): cstring {.exportc, cdecl.} =\n"
  result.add "  toCString(parseJson(\"\"\"" & genGetMethods(methods) & "\"\"\").`$`)\n\n"
  result.add exportsTail

when isMainModule:
  if paramCount() < 2:
    quit("usage: lidl_gen <contract.lidl> <out.nim>", 1)
  let contract = parseLidl(readFile(paramStr(1)))
  writeFile(paramStr(2), generate(contract))
  echo "generated ", paramStr(2), " from ", paramStr(1),
       " (", contract{"methods"}.len, " methods)"
