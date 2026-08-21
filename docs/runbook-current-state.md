# Runbook — verify the current state (2026-08-21)

A layered runbook for exercising what the **real `module/`+`ui/` build** does today.
Each layer is independent; run top-to-bottom for a full sweep, or jump to the layer
you care about. Where a layer is blocked, that is called out with the tracking pebble.

**What works today:** P0–P2 and all 11 invariant pebbles (42-probe suite), the Safe
driver end-to-end against anvil (collect off-chain, execute on-chain, no indexer), and
the module loading + dispatching in `logoscore`.
**What's blocked:** the P4 UI acceptance (`exo-c6a`, an SDK-rev skew). Layer E documents
exactly how far it gets and where it stops.

Phase status and the invariant map live in [`02-implementation-plan.md`](02-implementation-plan.md);
the full build log + gotchas are in the session memory.

---

## 0. Prerequisites (one-time)

- **Nix** with flakes. The `module/`/`ui/` flakes pin a **local** `logos-module-builder`
  checkout at `~/Github/logos-co/logos-module-builder` on the `nim-cdylib-authoring`
  branch — the Nim codegen path is not upstream yet ([logos-co/logos-module-builder#202](https://github.com/logos-co/logos-module-builder/pull/202)).
  Confirm it exists and is on that branch before any `nix build`.
- **Logos binary cache.** This box's user is *not* a trusted nix user, and the logos
  cache is not in the global `nix.conf`, so pass it explicitly on every `nix build`:

  ```bash
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
  ```

  (Set these once via an alias if you prefer. Without them most derivations rebuild from source.)
- **Nim** (for the pure-Nim probes and the Safe tests). `nim --version` should resolve.
- **foundry** (`anvil`, `forge`, `cast`) for Layer C. Already installed on this box.
- **`logoscore` + `lgpm`** for Layer D:

  ```bash
  nix build github:logos-co/logos-logoscore-cli --out-link /tmp/logoscore
  nix build github:logos-co/logos-package-manager#cli --out-link /tmp/lgpm
  ```

---

## Layer A — invariant probes (fast smoke test, no host, no deps)

The 42 spec-oracle probes under `module/tests/probes/` are pure Nim — they need no host,
no crypto lib, no network. This is the quickest "is the core still honest" check.

```bash
cd module
for p in tests/probes/probe_*.nim; do nim r -d:release "$p" || echo "FAILED: $p"; done
```

Also the lifecycle unit test (not a probe — F-3 has no pebble):

```bash
nim r -d:release tests/lifecycle_test.nim
```

**Expect:** every probe prints its oracle fields and exits 0; no `FAILED:` line.
These cover invariants 1–10: deterministic CDE encoding, domain-separated hash inputs,
`reduce(log)` convergence under reorder/dup, re-derive-or-refuse materialization,
replay-bound signing payloads, anonymity, membership epochs, provenance, the plugin
sandbox, and no-server/no-telemetry.

> The two probes that are **not** pure Nim (`probe_return_marshalling_host.nim` needs g++
> + secp256k1; the Safe crypto tests) are covered in Layers B/C — the loop above will
> report those as failed if run without the lib, which is expected. Run them per Layer B.

---

## Layer B — P2 Safe crypto tests (need libsecp256k1)

These import `src/crypto/secp256k1.nim` / `src/drivers/safe.nim`, so they link
libsecp256k1. Build it once and pass it:

```bash
nix build nixpkgs#secp256k1 --out-link /tmp/secp
cd module
for t in tests/secp256k1_test.nim tests/safe_test.nim tests/safe_collect_test.nim; do
  nim r -d:release --passC:-I/tmp/secp/include \
    --passL:/tmp/secp/lib/libsecp256k1.so "$t" || echo "FAILED: $t"
done
```

**Expect:**
- `secp256k1_test` — ecrecover + Ethereum address derivation, validated against
  privkey-1 → `0x7E5F…Bdf` and a sign→recover round-trip.
- `safe_test` — EIP-712 `safeTxHash` matches the **published Safe 1.4.1 constants**
  (`DOMAIN_TYPEHASH 47e79534…`, `SAFE_TX_TYPEHASH bb8310d4…`), bound to chainId/safe/nonce.
- `safe_collect_test` — the full lifecycle through the engine: collect 2-of-3 → `executable`,
  with a non-owner sig and a wrong-chainId contribution both **rejected**, no indexer.
  This is the automated proof of `propose → approve → executable`.

The host-return marshalling probe (verifies a *client* observes `health() → "ok"`, not the
`exo-526` untyped-CLI `false` artifact) links a Nim staticlib into a C++ harness:

```bash
MUSTER_SECP256K1_LIB="-L/tmp/secp/lib -lsecp256k1 -Wl,-rpath,/tmp/secp/lib" \
  nim r -d:release tests/probes/probe_return_marshalling_host.nim
```

---

## Layer C — Safe on-chain end-to-end (anvil, no indexer)

Collect 2-of-3 off-chain, execute `execTransaction` on-chain against the `MiniSafe`
fixture (a faithful Safe-1.4.1 subset). Full detail in [`../infra/anvil/README.md`](../infra/anvil/README.md).

```bash
# 1. anvil
anvil --silent &

# 2. deploy MiniSafe with anvil accounts 0/1/2 as owners, threshold 2
cd infra/anvil
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge create --rpc-url http://127.0.0.1:8545 --private-key $K0 --broadcast \
  src/MiniSafe.sol:MiniSafe \
  --constructor-args "[0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC]" 2
cast send --rpc-url http://127.0.0.1:8545 --private-key $K0 --value 5ether <SAFE_ADDR>

# 3. drive it from muster (uses the /tmp/secp from Layer B)
cd ../../module
nim r -d:release --passC:-I/tmp/secp/include --passL:/tmp/secp/lib/libsecp256k1.so \
  tests/safe_anvil_e2e.nim <SAFE_ADDR>
```

**Expect:** `... 2-of-3 collected off-chain, executed on-chain, no indexer: OK`, and the
recipient balance moves `0x0 → 0xde0b6b3a7640000` (1 ETH). A successful `execTransaction`
is itself proof that muster's local `safeTxHash` matched the contract's on-chain
`getTxHash` — the contract reverts otherwise. Tear down anvil with `kill %1` (or `pkill -x anvil`).

---

## Layer D — module builds, loads, and dispatches in `logoscore`

Build the `.lgx` and confirm the hosted coordination surface answers.

```bash
cd module
nix build .#lgx-portable --out-link result-lgx \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
# a modules dir logoscore can load directly:
nix build .#install-portable --out-link result-install-portable \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
```

> **Variant key matters.** Use the `-portable` variants (keyed `linux-amd64`). The dev
> `.#lgx` / `.#install` are keyed `linux-amd64-dev`, which `logoscore`'s default variant
> resolver rejects. (The dev key is what `logos-basecamp`'s dev core wants — see Layer E.)

Single-call checks (each `logoscore` run is a fresh process):

```bash
LGS=/tmp/logoscore/bin/logoscore
$LGS -m result-install-portable/modules -l muster_module -c 'muster_module.health()'  --quit-on-finish
$LGS -m result-install-portable/modules -l muster_module -c 'muster_module.describe()' --quit-on-finish
```

**Expect:** `health()` → `ok` (the module loaded and dispatched over Qt Remote Objects);
`describe()` → the configured coordination account JSON (`{chainId, safe, threshold, owners, environment}`).

The full `propose → txhash → approve → status` lifecycle is **per-process state**, so it
must run inside one interactive `logoscore` session, and `approve` needs a real 65-byte
owner signature over the `txhash`. The reliable, automated proof of that same lifecycle is
`safe_collect_test.nim` (Layer B) and `safe_anvil_e2e.nim` (Layer C). To drive it by hand at
the CLI: `propose` an effect, read the `txhash`, sign it with an owner key
(`cast wallet sign --no-hash --private-key $K0 <txhash>`), and `approve`.

> **Two `logoscore` gotchas:** (1) the CLI **mangles `0x`-prefixed args** (they arrive
> empty) — pass hashes/signatures **without** the `0x` prefix (the module's hex parser
> accepts either). (2) Kill the host with `pkill -x logoscore` (exact name) — `pgrep -f
> logoscore` also matches your shell.

---

## Layer E — UI build + the P4 acceptance (⚠ BLOCKED: `exo-c6a`)

The UI **builds** and the module↔ui↔host chain is proven up to the ui-host handshake, but
the view does not render to acceptance because of an SDK-rev skew. This layer is here to
reproduce the blocker, not to pass.

```bash
cd ui
nix build .#lgx --out-link result-ui \
  --extra-substituters https://cache.nix.logos.co/public \
  --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=
```

**Expect the build to succeed.** But note: `nix build` does **not** evaluate QML, so a green
build proves nothing about the view. Gate every QML change on `qmllint` against the import
path **and** an actual launch (`docs/labbook/qml-errors-are-invisible-to-nix-build.md`).

**Rendering — the working host is `logos-basecamp`, not the standalone runner.**
`logos-standalone-app` renders no `ui_qml` view on this box (its own template blanks too —
not a GL/headless issue). `logos-basecamp` (`~/Github/logos-co/logos-basecamp`) renders its
UI headlessly under `xvfb-run` + `QT_QUICK_BACKEND=software`. Driving `muster_ui` there gets:
sidebar 'M' icon → `logos-qt-mcp` `app.click('muster_ui')` → `muster_module` loads → ui-host
spawns "loaded plugin muster_ui" → **then fails at view instantiation.**

**Root cause (do not re-diagnose from scratch):** rev skew between the module-builder's
Nim-cdylib codegen and basecamp's ui-host —
`logos-view-module-runtime` (basecamp `1fde7d43` vs builder `3c3735c2`) and
`logos-cpp-sdk` (basecamp `4b66dac0` vs builder `e3744fb8`). Pinning view-runtime fixes a
`std::bad_alloc`; aligning cpp-sdk fixes the capability-token handshake **but regresses to
bad_alloc**, because the codegen's view-glue targets `e3744fb8`.

**The fix (upstream):** update the module-builder's Nim-cdylib codegen to `logos-cpp-sdk
4b66dac0` (keep view-runtime `1fde7d43`), rebuild `muster_ui`, then run the designed
acceptance: `logos-qt-mcp` drives basecamp's Package Manager to enable `muster_ui`, clicks
its icon, and asserts the view shows `muster_module.health() → ok`.

Two build-side fixes already proven along the way, keep them in mind if the load path regresses:
- `muster_module_plugin.so` lists `libsecp256k1.so.5` as NEEDED but its RUNPATH omits secp's
  dir → drop `libsecp256k1.so.5` into the module dir (`$ORIGIN` is in RUNPATH), or add
  `-rpath` for the Nim link libs (the real fix).
- Use the **dev** bundler (`installDev`, keyed `linux-amd64-dev`) when baking into basecamp's
  dev core — the opposite of Layer D's logoscore, which wants portable.

Tracking pebbles: `pb show exo-c6a` (the blocker) and `pb show exo-1f8` (P4 env bring-up).

---

## Layer F — the `demo/` speed build (separate track)

Independent of `module/`+`ui/`: the runnable wallet-journey demo (a fork of
`logos-chat-ui`), used for the testnet campaign. Not the specified client.

```bash
cd demo && make app        # build the standalone runner (slow)
make alice                 # launch a peer
make bob                   # second peer (another terminal)
make help                  # every target
```

Known open demo-track bugs (see `demo/poc/BUG-*.md` and `pb list --type bug`): cross-network
chat fails when `muster_ui` runs as `.lgx` in basecamp (`demo/poc/BUG-lgx-in-basecamp-cross-network-chat-fails.md`),
chat-module state not persisted, pay/request ordering, refresh-to-discover a shielded payment.

---

## Quick reference — one-liners

| Check | Command |
|---|---|
| Invariant probes (fast) | `cd module && for p in tests/probes/probe_*.nim; do nim r -d:release "$p"; done` |
| Safe crypto + lifecycle | Layer B (needs `/tmp/secp`) |
| On-chain e2e | Layer C (needs anvil) |
| Module loads + `health()` | Layer D (`nix build .#install-portable`, then `logoscore … -c 'muster_module.health()'`) |
| UI build (renders? no — `exo-c6a`) | `cd ui && nix build .#lgx` |
| Demo app | `cd demo && make app && make alice` |

**Frontier:** the upstream module-builder codegen bump to `logos-cpp-sdk 4b66dac0`
(keeping view-runtime `1fde7d43`) unblocks Layer E and the first real P4 acceptance run.
