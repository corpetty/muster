## Headless tests for the pure LIDL→Nim generator (no lidl_c.h, runs under `nim r`).
## Feeds a hand-built parsed-contract JsonNode — the shape lidl_parse_to_json
## returns — and asserts the generated provider surface and consumer client.

import std/[unittest, json, strutils]
import "../lidl-gen/gen"

# A stand-in for a parsed .lidl contract: three methods spanning the type kinds.
let contract = %*{
  "name": "counter_module",
  "methods": [
    {"name": "increment",
     "params": [{"name": "amount", "type": {"name": "uint"}}],
     "returnType": {"name": "int"}},
    {"name": "echo",
     "params": [{"name": "msg", "type": {"name": "tstr"}}],
     "returnType": {"name": "tstr"}},
    {"name": "store",
     "params": [{"name": "blob", "type": {"name": "bstr"}}],
     "returnType": {"name": "bool"}}
  ]
}

suite "lidl-gen: provider surface":
  let p = genProvider(contract)

  test "imports the SDK runtime (api seam)":
    check "import logos_sdk/api" in p

  test "emits all seven logos_module_* exports":
    for e in ["logos_module_dispatch", "logos_module_set_context",
              "logos_module_set_emit_callback", "logos_module_accept_token",
              "logos_module_get_protocol_version", "logos_module_get_methods",
              "logos_module_string_free"]:
      check (e & "(") in p or (e & "():") in p

  test "accept_token delegates to saveToken (the regression guard)":
    check "saveToken(" in p

  test "dispatch has a case arm per method + arg-count guard":
    check "of \"increment\":" in p
    check "of \"echo\":" in p
    check "of \"store\":" in p
    check "args.len < 1" in p

  test "author forward-decls are module-prefixed (namespaced off system idents)":
    check "proc counterIncrement(amount: int): int" in p
    check "proc counterEcho(msg: string): string" in p   # bstr/tstr → string at author seam
    check "proc counterStore(blob: string): bool" in p

  test "context/emit delegate to the SDK":
    check "setContext(" in p
    check "setEmitCallback(" in p

suite "lidl-gen: consumer client":
  let c = genClient(contract)

  test "client type + constructor target the module":
    check "type CounterClient* = ref object" in c
    check "newPluginProxy(\"counter_module\"" in c

  test "typed method signatures map LIDL → Nim":
    check "proc increment*(c: CounterClient, amount: int): int =" in c
    check "proc echo*(c: CounterClient, msg: string): string =" in c
    check "proc store*(c: CounterClient, blob: seq[byte]): bool =" in c

  test "bstr arg is encoded via bytesArg":
    check "bytesArg(blob)" in c

  test "scalar args are JSON-encoded":
    check "args(%amount)" in c

  test "return decode matches the return type":
    check "r.value.getInt()" in c        # increment -> int
    check "r.value.getStr()" in c        # echo -> string
    check "r.value.getBool()" in c       # store -> bool

  test "bstr return would decode via b64urlDecode":
    let c2 = genClient(%*{"name": "blob_module",
      "methods": [{"name": "fetch", "params": [], "returnType": {"name": "bstr"}}]})
    check "b64urlDecode(" in c2
    check "type BlobClient*" in c2

suite "lidl-gen: naming":
  test "clientTypeName strips _module and camel-cases":
    check clientTypeName("counter_module") == "CounterClient"
    check clientTypeName("delivery_module") == "DeliveryClient"
    check clientTypeName("multi_word_module") == "MultiWordClient"
