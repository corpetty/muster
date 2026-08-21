# module/tests

Most probes/tests run with bare `nim r -d:release tests/<name>.nim` (pure Nim,
no external deps) — this is how the exophial spec oracles under `tests/probes/`
are graded.

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

**Exception — `ecdh_test.nim` needs libsecp256k1; `epoch_crypto_test.nim` (F-16)
needs libsecp256k1 + libsodium:**

```bash
nix build nixpkgs#secp256k1 --out-link /tmp/secp
SODIUM=$(nix build nixpkgs#libsodium --no-link --print-out-paths)
nim r -d:release --passC:-I/tmp/secp/include --passL:/tmp/secp/lib/libsecp256k1.so \
  --passL:"$SODIUM/lib/libsodium.so" tests/epoch_crypto_test.nim
```

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
