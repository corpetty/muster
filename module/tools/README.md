# module/tools — build-time codegen

## The Nim LIDL codegen now lives in the shared SDK (`../sdk/lidl-gen`)

`nim-lib/muster_gen.nim` (the module-impl surface: the seven `logos_module_*` C
exports, the dispatch table, and the get-methods descriptor) is generated from
`src/api/muster.lidl` by the **shared Nim SDK generator**, `logos_sdk` under
`sdk/` — muster consumes the SDK rather than carrying its own codegen copy (the
old `tools/lidl_gen.nim` was retired when muster migrated onto `logos_sdk`). The
generator parses the contract through the canonical LIDL frontend over its C bridge
(`lidl_c.h`: `lidl_parse_to_json`) — the same bridge `logos-rust-sdk/lidl-gen`
uses. The generated surface delegates context / emit / token / cstring to
`logos_sdk/api`, and each method forwards to a `muster<Method>` proc defined in
`nim-lib/muster_module.nim`.

### Regenerate

One command wraps the whole recipe:

```bash
module/tools/regen.sh
```

Which is equivalent to: build the LIDL C library, build the SDK generator against
it, then run it in `provider` mode:

```bash
nix build github:logos-co/logos-lidl#logos-lidl --out-link /tmp/lidl
nim c -d:LIDL_INC:/tmp/lidl/include/lidl \
      -d:LIDL_C_A:/tmp/lidl/lib/liblogos_lidl_c.a \
      -d:LIDL_A:/tmp/lidl/lib/liblogos_lidl.a \
      --out:/tmp/lidl_gen sdk/lidl-gen/lidl_gen.nim
/tmp/lidl_gen provider module/src/api/muster.lidl module/nim-lib/muster_gen.nim
```

(The same generator emits a typed consumer client in `client` mode — see
`sdk/README.md`.) Wiring this into the `codegen.nim` module-builder step (so
`nix build .#lgx` regenerates automatically) is the remaining integration; today
the checked-in `muster_gen.nim` is the generator's committed output, regenerated
manually when the contract changes.
