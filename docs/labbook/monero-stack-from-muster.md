# The Monero stack, called from Muster (Basecamp 0.3.2)

**exo-dcc.1 / exo-dcc.11, 2026-10-08. Status: Muster calls `monero_wallet_backend` and is
attested as `muster_module`.** Declaring the backend an optional dependency makes Basecamp
start the Monero stack when Muster opens, and makes the call legal under
`--access-policy enforce`. It is **not** what makes the backend answer: with enforcement off,
an undeclared module answers Muster too. The "silent for five minutes" seen on 2026-10-07 was
readiness, not the module: in Basecamp, `lp_get_methods` always returns `[]`.

## What changed in Muster

- `module/metadata.json`: `"optional_dependencies": ["monero_wallet_backend"]`. Optional, so a
  missing or failing Monero stack never fails Muster's load. Pinned in `module/flake.nix` to
  logos-monero-wallet-backend `7690984` (0.1.0); the forked builder ignores the key (no typed
  wrapper — Muster calls lp_* raw), so the pin only records the contract.
- **The bundler.** At nix-bundle-lgx `b49074a` (the June bundler in basecamp's builder set)
  `bundle.sh` copies only `dependencies` into the `.lgx` manifest. The built manifest
  (manifestVersion 0.3.0) had no `optional_dependencies`; the plugin's embedded metadata (the
  whole `metadata.json`, via `Q_PLUGIN_METADATA`) did. `module/flake.nix` now overrides only
  the bundler, to upstream `c8c4659`; the manifest is then manifestVersion 0.6.0 with
  `"optional_dependencies": ["monero_wallet_backend"]`. The SDK set (the load contract) is
  unchanged, and the build loaded and ran in Basecamp 0.3.2.
- **Which one Basecamp reads.** liblogos takes a module's dependencies from the plugin's
  embedded metadata (`ModuleLib::LogosModule::getModuleOptionalDependencies`), not the
  manifest: the build with the old bundler (no key in the manifest) already loaded the stack
  with Muster. Package Manager reads the manifest, so a catalogue install of Muster needs the
  bundler bump to pre-tick the Monero packages (exo-dcc.3, not yet run).
- **Readiness.** `declaredModules` (now in `coordination/module_registry.nim`) separates
  required from optional dependencies. Only a required one is called when there is no
  registry to ask (the standalone runner, which does not bundle Monero): an optional one may be
  absent, and a call to an absent module blocks for lp's whole deadline. Both get "close and
  reopen Muster" as their remedy. `readiness_test` §16c.
- **The standalone runner does not bundle the Monero stack.** `ui/flake.nix` and
  `ui/metadata.json` are unchanged; the UI builder never reads `muster_module`'s optional
  dependencies. In the runner the module item reads "unknown — no module registry to ask",
  as `scripts/install-self-test.sh` expects.
- `MUSTER_LP_DEBUG` now logs `MUSTER-LP execute <module>.<method> args=… state=… reply=…`.
  Basecamp's log does not carry `muster_ui`'s own `qInfo` lines, so the reply was otherwise
  visible only on the card.

## What was run

Basecamp `0.3.2` (`LogosBasecamp-Desktop-v0.3.2-f2fae6`), a fresh `--user-dir`, Xvfb `:81`,
`QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND=software`, `TMPDIR` a short symlink (Qt's local socket
path must fit 108 bytes). Install order:

1. the 13 default-catalog packages Muster depends on (`infra/basecamp/catalog-0.3.1.tsv`,
   sha256-checked), with portable `lgpm --allow-unsigned install --dir`;
2. `muster_module` and `muster_ui` `.#lgx-portable` from this branch, `lgpm install --file`;
3. **Monero Wallet** from Package Manager (search `monero_wallet_ui`, Install, confirm).
   The catalogue now serves **0.1.1** of every Monero package (published 2026-10-07): the dialog
   installed `monero_node_module`, `monero_wallet_core_module`, `monero_wallet_backend`, and the
   pre-ticked optional `monerod_module`, ~3.5 min. Backend 0.1.1 differs from 0.1.0 only in
   dependency ranges and a monero_c relock (`0.18.5.3-RC1`).

Each run sets, on the Basecamp process: `MUSTER_AUTOJOIN_TOPIC=<fresh topic>`
`MUSTER_AUTOADMIT=1 MUSTER_LP_DEBUG=1 MUSTER_AUTOPOLICY=invoke MUSTER_AUTOAPPROVE=1`
`MUSTER_AUTOPROPOSE='{"effect":"invoke","module":"monero_wallet_backend","method":"<m>","args":[]}'`
`MUSTER_INVOKE_ALLOWLIST='[{"module":"monero_wallet_backend","method":"<m>"}, …]'`. Opening
Muster joins a solo room and proposes and approves the call (threshold 1 of 1); pressing the
card's **Run the action** executes it (`coordinate_execute`).

## Before and after

| | Muster without the declaration | with it |
|---|---|---|
| Opening Muster loads | its required dependencies only; the backend loads when Monero Wallet opens | the required ones, then `monerod_module`, `monero_node_module`, `monero_wallet_core_module`, `monero_wallet_backend`, all before `muster_module` |
| Readiness, first read | `missing` — "installed but not running", until Monero Wallet was opened | `unknown` — "the host reports monero_wallet_backend ready, but it did not answer muster yet" |
| `caller_identity` through Run | **executed**, once the backend ran (opened by the wallet app) | **executed** |
| Under `--access-policy enforce` (`infra/access-policy.json`) | — | the optional dependency is called: **executed** |
| Control: undeclared `monero_node_module.list_networks`, enforcement off | **executed** | |
| Control: the same, under enforce | `access policy denies 'muster_module' -> 'monero_node_module'`; reply `{"code":"unauthorized","message":"call to 'monero_node_module' rejected: token not recognized (re-exchange failed)"}` | |

So, against exo-dcc.11's hypothesis: capability_module mints Muster's token for an undeclared
module too (enforcement off). Declaring is what starts the backend with Muster, and what
`enforce` requires; **optional dependencies count as declared under `enforce`** (the open
question in the atlas guide §5).

## Why readiness never reads "met" in Basecamp

`readiness` grades a module `met` only when `Invoker.methodsOf` (lp_get_methods) returns a
non-empty array. Basecamp runs core modules out of process, and logos-protocol's remote
transport does not implement introspection:

```cpp
// cpp/implementations/qt_remote/remote_transport.cpp (6401e30, and HEAD 9d59f5d)
QJsonArray getMethods() override { return QJsonArray(); }   // "Remote introspection not implemented"
```

So every module item stays `unknown` ("did not answer muster yet") in Basecamp — the same
for `keystore_module`, a required dependency whose `caller_identity` then answered Muster two
seconds later. And the remedy for an undeclared module ("Muster may need an update that
declares it") rests on a cause this run disproved. Neither is fixed here.

## The reply shapes (stagenet default, no wallet open)

lp_invoke's result for a `tstr` method is a JSON **string** whose content is the method's JSON
document: unwrap the string, then parse. This is the `reply=` in the log, verbatim:

```
monero_wallet_backend.caller_identity → "{\"approvers\":[\"monero_wallet_ui\"],\"custodians\":[\"monero_wallet_ui\"],\"identity\":\"muster_module\",\"kind\":\"module\",\"ok\":true}"
monero_wallet_backend.list_networks   → "{\"active\":\"stagenet\",\"networks\":[\"mainnet\",\"stagenet\",\"testnet\",\"regtest\"],\"ok\":true}"
monero_wallet_backend.wallet_status   → "{\"activeNetwork\":\"stagenet\",\"address\":\"\",\"connected\":false,\"daemonHeight\":0,\"lastError\":\"\",\"libraryVersion\":\"0.18.5.3-RC1\",\"network\":\"\",\"ok\":true,\"state\":\"no_wallet\",\"syncPercent\":0,\"synchronized\":false,\"wallet\":\"\",\"walletHeight\":0,\"watchOnly\":false}"
keystore_module.caller_identity       → "{\"approvers\":[\"evm_signer_ui\"],\"custodians\":[\"evm_keystore_ui\"],\"identity\":\"muster_module\",\"kind\":\"module\",\"ok\":true}"
monero_node_module.list_networks      → "{\"networks\":[\"mainnet\",\"regtest\",\"stagenet\",\"testnet\"],\"ok\":true}"
```

- **`caller_identity` attests `muster_module`** as `kind: "module"`: Muster may call
  `prepare_send`, and holds no role.
- No call was made from the context-ready hook; the first was ≥ 10 s after load.
- Not answered here, because they need an open stagenet wallet with funds: whether incoming
  transfers appear in `history()` before they confirm, and how long a first sync takes.

## Surprises

- Under `enforce`, `muster_module -> modules_state` is denied (the registry is not a declared
  dependency), so readiness loses the host's registry and every module reads "no module
  registry to ask". `infra/access-policy.json` names only the `muster_ui -> muster_module` edge.
- Basecamp loads optional dependencies transitively: `monerod_module` (the node module's
  optional dependency, installed by the pre-ticked box) started with Muster.

## Reproduce

The scripts are in the session scratchpad, `monero-declare/`: `install-catalog.sh`,
`install-muster.sh <module.lgx> <ui.lgx>`, `cycle.sh <tag> <method> [module]` (launch, open
Muster, Run, wait for `MUSTER-LP execute`), `summarize.py <log>`; `BCARGS="--access-policy
infra/access-policy.json"` for the enforce runs. Logs `out/{b1,a1,c1,c2,c3,c4,e1,e2,n1}.log`,
screenshots `out/*.png`.
