## Pure LIDL → Nim code generation. Operates on the parsed-contract `JsonNode`
## (the shape `lidl_parse_to_json` returns), so every proc here is headless and
## unit-testable — no `lidl_c.h`, no FFI. The CLI (`lidl_gen.nim`) adds only the
## C parse bridge and file I/O on top.
##
## Two outputs, mirroring logos-rust-sdk's two generators:
##   • genProvider — the module's own surface: the seven `logos_module_*` C
##     exports + the dispatch table + the method descriptor, delegating context /
##     emit / token / protocol to the `logos_sdk` runtime. The author writes one
##     `proc <method>(...)` per contract method; the dispatch forwards to it.
##   • genClient — a typed consumer client per dependency: a `PluginProxy` wrapper
##     exposing each contract method as a Nim proc that encodes args, calls, and
##     decodes the result.

import std/[json, strutils]

# ── contract accessors ───────────────────────────────────────────────────────

proc primName(t: JsonNode): string = t{"name"}.getStr("any")

proc methods(contract: JsonNode): JsonNode =
  result = contract{"methods"}
  if result.isNil: result = newJArray()

proc contractName*(contract: JsonNode): string =
  ## The module name a client targets. LIDL puts it at the top level; fall back to
  ## a neutral default so generation never fails on a nameless contract.
  contract{"name"}.getStr("module")

# ── PROVIDER side (matches the proven muster codegen's type decisions) ─────────

proc argGetter(t: JsonNode, idx: int): string =
  case primName(t)
  of "tstr", "bstr": "args[" & $idx & "].getStr()"
  of "int", "uint": "args[" & $idx & "].getInt()"
  of "bool": "args[" & $idx & "].getBool()"
  else: "args[" & $idx & "]"

proc providerProcRetNim(t: JsonNode): string =
  case primName(t)
  of "int", "uint": "int"
  of "bool": "bool"
  else: "string"          # tstr/bstr and anything else cross the author seam as string

proc qtType(t: JsonNode): string =
  case primName(t)
  of "tstr": "QString"
  of "bstr": "QByteArray"
  of "int": "int"
  of "uint": "uint"
  of "bool": "bool"
  else: "QVariant"

proc moduleStem*(name: string): string =
  ## "counter_module" → "counter"; "multi_word_module" → "multiWord";
  ## "muster_module" → "muster". The camelCase stem (lowercase first) that
  ## namespaces author procs and names the client type.
  var base = name
  if base.endsWith("_module"): base = base[0 ..< base.len - "_module".len]
  var up = false
  for i, ch in base:
    if ch == '_': up = true
    elif up: result.add ch.toUpperAscii(); up = false
    elif i == 0: result.add ch.toLowerAscii()
    else: result.add ch
  if result.len == 0: result = "impl"

proc authorProcName*(stem, name: string): string =
  ## The author-side proc a dispatch arm forwards to: `<stem><Method>`, e.g.
  ## "muster" + "health" → "musterHealth". Prefixing namespaces the author's impl
  ## away from system/imported identifiers — without it a method literally named
  ## `echo` or `add` collides. This reproduces muster's hand convention exactly.
  stem & name[0].toUpperAscii() & name[1..^1]

proc providerParamNim(t: JsonNode): string =
  ## Author-seam Nim type for a param — must agree with `argGetter` (a bool param
  ## reaches the author as `getBool()`, so it is declared `bool`, not `string`).
  case primName(t)
  of "int", "uint": "int"
  of "bool": "bool"
  else: "string"          # tstr/bstr arrive as their getStr() string

proc genForwardDecls(ms: JsonNode, stem: string): string =
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var sig: seq[string]
    if not params.isNil:
      for p in params:
        sig.add p["name"].getStr() & ": " & providerParamNim(p["type"])
    result.add "proc " & authorProcName(stem, name) & "(" & sig.join(", ") & "): " &
      providerProcRetNim(m["returnType"]) & "\n"

proc genDispatch(ms: JsonNode, stem: string): string =
  result = "proc dispatch(meth: string, args: JsonNode): JsonNode =\n  case meth\n"
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    let np = (if params.isNil: 0 else: params.len)
    var parts: seq[string]
    if not params.isNil:
      for i in 0 ..< params.len:
        parts.add argGetter(params[i]["type"], i)
    result.add "  of \"" & name & "\":\n"
    if np > 0:
      result.add "    if args.kind != JArray or args.len < " & $np &
                 ": return newJNull()\n"
    result.add "    %" & authorProcName(stem, name) & "(" & parts.join(", ") & ")\n"
  result.add "  else:\n    nil\n"

proc genGetMethods(ms: JsonNode): string =
  var entries: seq[string]
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var pjson, sigTypes: seq[string]
    if not params.isNil:
      for p in params:
        pjson.add "{\"name\":\"" & p["name"].getStr() & "\",\"type\":\"" &
          qtType(p["type"]) & "\"}"
        sigTypes.add qtType(p["type"])
    entries.add "{\"isInvokable\":true,\"name\":\"" & name & "\"," &
      "\"parameters\":[" & pjson.join(",") & "]," &
      "\"returnType\":\"" & qtType(m["returnType"]) & "\"," &
      "\"signature\":\"" & name & "(" & sigTypes.join(",") & ")\"}"
  "[" & entries.join(",") & "]"

const providerExports = """
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
  allocCString($res)

proc logos_module_set_context(modulePath: cstring, instanceId: cstring,
                              instancePersistencePath: cstring) {.exportc, cdecl.} =
  proc s(p: cstring): string = (if p == nil: "" else: $p)
  setContext(s(modulePath), s(instanceId), s(instancePersistencePath))

proc logos_module_set_emit_callback(cb: EmitCb, userData: pointer) {.exportc, cdecl.} =
  setEmitCallback(cb, userData)

# Save the token in THIS plugin's protocol stack, or every outbound lp_invoke is
# rejected and the target's node never boots. Delegates to the SDK's saveToken so
# a regen can never drop it (the lesson of muster's cross-host regression).
proc logos_module_accept_token(moduleName: cstring, token: cstring): cint {.exportc, cdecl.} =
  if moduleName == nil or token == nil: return -1
  discard saveToken($moduleName, $token)
  0

proc logos_module_get_protocol_version(): cstring {.exportc, cdecl.} =
  cstring"0.1.0"

proc logos_module_string_free(s: cstring) {.exportc, cdecl.} =
  freeCString(s)

{.emit: "extern void NimMain(void); static void __attribute__((constructor)) logos_module_ctor(void) { NimMain(); }".}
"""

proc genProvider*(contract: JsonNode): string =
  ## The module's provider surface. Delegates context/emit/token/cstring to the
  ## `logos_sdk` runtime; the author supplies one proc per contract method.
  let ms = methods(contract)
  let stem = moduleStem(contractName(contract))
  result = "## GENERATED from " & contractName(contract) &
           " by logos_sdk lidl-gen — do not edit.\n" &
           "## The author supplies one `proc " & stem & "<Method>*(...)` per method.\n" &
           "import std/json\nimport logos_sdk\n\n"
  result.add genForwardDecls(ms, stem) & "\n"
  result.add genDispatch(ms, stem) & "\n"
  result.add "proc logos_module_get_methods(): cstring {.exportc, cdecl.} =\n"
  result.add "  allocCString($parseJson(\"\"\"" & genGetMethods(ms) & "\"\"\"))\n\n"
  result.add providerExports

# ── CONSUMER side: a typed client per dependency ──────────────────────────────

proc clientTypeName*(target: string): string =
  ## "counter_module" → "CounterClient"; "delivery_module" → "DeliveryClient".
  let stem = moduleStem(target)
  stem[0].toUpperAscii() & stem[1..^1] & "Client"

proc clientParamType(t: JsonNode): string =
  case primName(t)
  of "tstr": "string"
  of "bstr": "seq[byte]"
  of "int", "uint": "int"
  of "bool": "bool"
  else: "JsonNode"

proc clientArgEncode(pname: string, t: JsonNode): string =
  case primName(t)
  of "bstr": "bytesArg(" & pname & ")"
  else: "%" & pname            # string/int/bool → JSON scalar; JsonNode passes through as %

proc clientRetDecode(t: JsonNode): string =
  ## Decode `r.value` into the Nim return type, with a typed zero-value fallback so
  ## a failed call never raises from the typed surface (callers check via a raising
  ## variant if they want — future work).
  case primName(t)
  of "tstr":
    "(if r.ok and r.value != nil and r.value.kind == JString: r.value.getStr() else: \"\")"
  of "int", "uint":
    "(if r.ok and r.value != nil and r.value.kind == JInt: r.value.getInt() else: 0)"
  of "bool":
    "(if r.ok and r.value != nil and r.value.kind == JBool: r.value.getBool() else: false)"
  of "bstr":
    "(if r.ok and r.value != nil and r.value.kind == JObject and r.value.hasKey(\"_bytes\"): " &
      "b64urlDecode(r.value[\"_bytes\"].getStr()) else: newSeq[byte]())"
  else:
    "(if r.ok and r.value != nil: r.value else: newJNull())"

proc genClient*(contract: JsonNode, target = ""): string =
  ## A typed consumer client for the module described by `contract`. `target` is
  ## the module name to call (defaults to the contract's own name).
  let tgt = (if target.len > 0: target else: contractName(contract))
  let cn = clientTypeName(tgt)
  let ms = methods(contract)
  result = "## GENERATED consumer client for " & tgt &
           " by logos_sdk lidl-gen — do not edit.\n" &
           "import std/json\nimport logos_sdk\n\n"
  result.add "type " & cn & "* = ref object\n  proxy*: PluginProxy\n\n"
  result.add "proc new" & cn & "*(origin = \"core\"): " & cn & " =\n" &
             "  " & cn & "(proxy: newPluginProxy(\"" & tgt & "\", origin))\n\n"
  for m in ms:
    let name = m["name"].getStr()
    let params = m{"params"}
    var sig, enc: seq[string]
    if not params.isNil:
      for p in params:
        let pn = p["name"].getStr()
        sig.add pn & ": " & clientParamType(p["type"])
        enc.add clientArgEncode(pn, p["type"])
    let sigStr = (if sig.len > 0: ", " & sig.join(", ") else: "")
    result.add "proc " & name & "*(c: " & cn & sigStr & "): " &
               clientParamType(m["returnType"]) & " =\n"
    result.add "  let r = c.proxy.callSync(\"" & name & "\", args(" & enc.join(", ") & "))\n"
    result.add "  " & clientRetDecode(m["returnType"]) & "\n\n"
