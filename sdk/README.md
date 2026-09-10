# logos_sdk — a Nim SDK for Logos modules

The Nim counterpart of [`logos-rust-sdk`](https://github.com/logos-co/logos-rust-sdk):
the runtime behind typed, generated clients a **Nim** Logos module uses to call
other modules, plus the module-side context/emit/token seam its generated surface
delegates to, plus a LIDL→Nim code generator that emits both.

It exists to (1) stop every Nim module from hand-rolling its own `lp_*` binding +
bytes codec + proxy (muster did — `module/src/transport/lp_ffi.nim`,
`delivery.nim`), and (2) give the Logos platform a Nim SDK on par with the Rust and
C++ ones ahead of the LIDL→CDDL / new-core transition, so a Nim module's callable
surface stays generated as that contract layer moves.

## Layout (mirrors logos-rust-sdk)

```
sdk/
  src/logos_sdk.nim            umbrella export
  src/logos_sdk/
    ffi.nim      lp_* C-ABI bindings            (rust src/ffi.rs)
    bytes.nim    {"_bytes":<b64url>} codec       (rust src/bytes.rs)   — pure, tested
    plugin.nim   PluginProxy: shared-per-target client, sync/async call, subscribe
                                                 (rust src/plugin.rs)
    api.nim      protocol version + save_token; module context + emit + cstring seam
                                                 (rust src/api.rs)
  lidl-gen/
    gen.nim      pure JsonNode→Nim: genProvider + genClient    — headless, tested
    lidl_gen.nim CLI: lidl_c.h parse bridge over gen.nim       (rust lidl-gen/)
  tests/
    tbytes.nim   codec vectors + round-trips
    tgen.nim     generator output + naming
```

## The two generated outputs

A `.lidl` contract yields two Nim files, exactly as the Rust generator does:

**Provider surface** (`lidl_gen provider contract.lidl out.nim`) — the module's own
side: the seven `logos_module_*` C exports + the dispatch table + the method
descriptor, delegating context/emit/token/protocol to this runtime. The author
writes one `proc <stem><Method>*(...)` per contract method (`stem` is the module
name without `_module`, e.g. `muster_module` → `musterHealth` — the same convention
muster hand-wrote, now generated, and the prefix namespaces the author's impl away
from system identifiers so a method named `echo` or `add` doesn't collide).

**Consumer client** (`lidl_gen client contract.lidl out.nim [target]`) — a typed
`PluginProxy` wrapper per dependency: each contract method becomes a Nim proc that
encodes its args (a `bstr` via `bytesArg`, scalars as JSON), calls, and decodes the
result into the Nim return type. This is the piece muster's own `tools/lidl_gen.nim`
never had — muster calls `delivery_module` through a hand-written proxy.

## Using it

```nim
import logos_sdk

# hand-written, or use a generated client
let counter = newPluginProxy("counter_module", origin = "my_module")
let r = counter.callSync("increment", args(%1))
if r.ok: echo r.value          # the result JSON

# bytes cross the wire in the shared tagged form
let blob = counter.callSync("store", args(bytesArg(@[byte 1, 2, 3])))
```

## Type mapping (LIDL → Nim)

| LIDL   | consumer arg / return | provider author seam | wire |
|--------|-----------------------|----------------------|------|
| `tstr` | `string`              | `string`             | JSON string |
| `bstr` | `seq[byte]`           | `string` (getStr)    | `{"_bytes":<b64url>}` |
| `int`  | `int`                 | `int`                | JSON int |
| `uint` | `int`                 | `int`                | JSON int |
| `bool` | `bool`                | `bool`               | JSON bool |
| other  | `JsonNode`            | `string`             | JSON |

## Testing

```bash
cd sdk && nimble test          # tbytes + tgen, headless
```

The runtime's FFI (`ffi`/`plugin`/`api`) binds `lp_*` symbols that resolve only at
plugin **link** time, so those modules don't `nim r` standalone; they `nim check`
clean, and the generator's pure core + the codec are fully unit-tested. The repo's
generator tests also `nim check` the *generated* provider and client against this
runtime, so the emitted code is proven to compile.

## Status & next

- **Done:** runtime (ffi/bytes/plugin/api), generator (provider + consumer client),
  20 headless tests, generated-code compile check.
- **Next (follow-ups):** migrate muster to consume `logos_sdk` (replace
  `lp_ffi.nim` + the inlined codegen in `tools/lidl_gen.nim`); a raising client
  variant (`call!`) for methods that should surface errors; extract to a standalone
  `logos-nim-sdk` repo to upstream alongside `logos-rust-sdk`.

Tracked as pebble `exo-2c1`.
