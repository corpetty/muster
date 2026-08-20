# module/tests

Most probes/tests run with bare `nim r -d:release tests/<name>.nim` (pure Nim,
no external deps) — this is how the exophial spec oracles under `tests/probes/`
are graded.

**Known-answer vectors — `dcbor_golden_test.nim`:** the `probe_cde_*` oracles
check dCBOR *properties* (shortest-length, re-derived ordering, re-encode
stability); this pins the encoder to EXACT bytes for a hand-computed vector set
(width boundaries, string/array/map shapes, the CDE-vs-length-first ordering
discriminator, order-independence, the hash-input framing, and s4/dup-key
rejections). Different bytes are a different signature, so this guards invariant 5
against byte-order/major-type regressions a property check can miss. `nim r`, no deps.

**Exception — the P2 Safe crypto tests need libsecp256k1 linked:**
`secp256k1_test.nim`, `safe_test.nim`, `safe_collect_test.nim` (and anything
importing `src/crypto/secp256k1.nim` or `src/drivers/safe.nim`). Build the lib
and pass it:

```bash
nix build nixpkgs#secp256k1 --out-link /tmp/secp
nim r -d:release --passC:-I/tmp/secp/include \
  --passL:/tmp/secp/lib/libsecp256k1.so tests/safe_collect_test.nim
```

The module build supplies secp256k1 via `nix.packages` once the Safe driver is
wired into the module surface.

**Exception — the host-return probe needs g++ + secp256k1:**
`probes/probe_return_marshalling_host.nim` builds the module as a Nim staticlib
(the shape the real cdylib build produces) and links it into the C++ host harness
`probes/host_return_harness.cpp`, which reproduces the shipped
Nim->C++->host-client return marshalling and reads what a CLIENT observes. Point
it at secp256k1 the same way — an explicit `MUSTER_SECP256K1_LIB` wins, else
`pkg-config --libs libsecp256k1`, else a bare `-lsecp256k1`:

```bash
MUSTER_SECP256K1_LIB="-L/path/to/secp/lib -lsecp256k1 -Wl,-rpath,/path/to/secp/lib" \
  nim r -d:release tests/probes/probe_return_marshalling_host.nim
```
