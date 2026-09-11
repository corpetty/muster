# module/tools — build-time codegen

## The Nim LIDL codegen lives in the shared SDK ([logos-nim-sdk](https://github.com/corpetty/logos-nim-sdk))

`nim-lib/muster_gen.nim` (the module-impl surface: the seven `logos_module_*` C
exports, the dispatch table, and the get-methods descriptor) is generated from
`src/api/muster.lidl` by the **shared Nim SDK generator**, `logos_sdk` — muster
consumes the SDK as a dependency (`metadata.json` → `codegen.nim.packages` →
`corpetty/logos-nim-sdk`) rather than carrying its own codegen copy (the old
`tools/lidl_gen.nim` was retired when muster migrated onto `logos_sdk`). The
generator parses the contract through the canonical LIDL frontend over its C bridge
(`lidl_c.h`: `lidl_parse_to_json`) — the same bridge `logos-rust-sdk/lidl-gen`
uses. The generated surface delegates context / emit / token / cstring to
`logos_sdk/api`, and each method forwards to a `muster<Method>` proc defined in
`nim-lib/muster_module.nim`.

### Regenerate

One command wraps the whole recipe — it fetches the SDK at the **same rev the
build pins** (from `metadata.json`), builds its `lidl-gen`, and runs it:

```bash
module/tools/regen.sh
```

Equivalent to: build the LIDL C library, clone `logos-nim-sdk` at that rev, build
its generator against the C bridge, then run it in `provider` mode:

```bash
nix build github:logos-co/logos-lidl#logos-lidl --out-link /tmp/lidl
git clone https://github.com/corpetty/logos-nim-sdk /tmp/logos-nim-sdk   # checkout the pinned rev
nim c -d:LIDL_INC:/tmp/lidl/include/lidl \
      -d:LIDL_C_A:/tmp/lidl/lib/liblogos_lidl_c.a \
      -d:LIDL_A:/tmp/lidl/lib/liblogos_lidl.a \
      --out:/tmp/lidl_gen /tmp/logos-nim-sdk/lidl-gen/lidl_gen.nim
/tmp/lidl_gen provider module/src/api/muster.lidl module/nim-lib/muster_gen.nim
```

(The same generator emits a typed consumer client in `client` mode — see the SDK's
own README.) Wiring this into the `codegen.nim` module-builder step (so
`nix build .#lgx` regenerates automatically) is the remaining integration; today
the checked-in `muster_gen.nim` is the generator's committed output, regenerated
manually when the contract changes.
