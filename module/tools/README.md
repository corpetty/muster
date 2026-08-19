# module/tools — build-time codegen

## lidl_gen.nim — the Nim LIDL codegen backend (ADR-008 / B4)

Generates `nim-lib/muster_gen.nim` (the module-impl surface: the seven
`logos_module_*` C exports, the dispatch table, and the get-methods descriptor)
from `src/api/muster.lidl`, so the contract is normative **and** generated rather
than hand-written. It parses the contract through the canonical LIDL frontend over
its C bridge (`lidl_c.h`: `lidl_parse_to_json`) — the same bridge
`logos-rust-sdk/lidl-gen` uses — so the grammar is never reimplemented. The author
impl seam is unchanged: each method forwards to a `muster<Method>` proc defined in
`nim-lib/muster_module.nim`.

### Regenerate

Build the LIDL C library, then build and run the generator against it:

```bash
# 1. build liblogos_lidl(_c).a + lidl_c.h
nix build github:logos-co/logos-lidl#logos-lidl --out-link /tmp/lidl

# 2. build the generator, linking the LIDL C bridge
nim c -d:LIDL_INC:/tmp/lidl/include \
      -d:LIDL_C_A:/tmp/lidl/lib/liblogos_lidl_c.a \
      -d:LIDL_A:/tmp/lidl/lib/liblogos_lidl.a \
      --out:/tmp/lidl_gen module/tools/lidl_gen.nim

# 3. regenerate the surface from the contract
/tmp/lidl_gen module/src/api/muster.lidl module/nim-lib/muster_gen.nim
```

Wiring this into the `codegen.nim` module-builder step (so `nix build .#lgx`
regenerates automatically) is the remaining integration; today the checked-in
`muster_gen.nim` is the generator's committed output and is regenerated manually
when the contract changes.
