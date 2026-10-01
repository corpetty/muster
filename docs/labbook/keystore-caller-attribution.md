# keystore_module sees muster's calls as `unknown` in the standalone runner

**exo-149.1 (K1), 2026-10-01. Status: RESOLVED.** It is the runner's host. Under logoscore
0.3.1, the runtime released beside Basecamp 0.3.1, keystore_module attributes muster's
calls to `module muster_module`. See "Resolved" at the end.

## What was run

`scripts/keystore-self-test.sh` ran one offscreen standalone runner (`make build` at
`feat/keystore-module`). Its module set was `capability_module`, `keystore_module`
(logos-evm-keystore-module@2318c679, the catalog's 0.1.0), `lez_core`,
`delivery_module`, `muster_module`, and the two RLN modules. `muster_module` read
`keystore_module` over `lp_*` with origin `"muster_module"`
(`module/src/wallet/keystore_probe.nim`) every 2 s for a minute.

## What it saw

Every one of 30 reads, in two runs, came back the same:

```
{"key":"keystore","level":"down",
 "detail":"keystore_module sees muster's calls as unknown, not muster_module: every signing request would be refused",
 "approvers":["evm_signer_ui"],"identity":{"kind":"unknown","identity":""}}
```

- `keystore_module` loaded and answered: the ungated reads work, and it names its
  default approver.
- `caller_identity` is `{kind: "unknown"}`. keystore_module admits `request_approval`
  (Tier B) only from `LogosCaller::Module{name}`, so **in this runner every signing
  request muster makes would be refused with "not authorized"**.

## How attribution is supposed to work (Basecamp 0.3.1)

From the atlas, `guides/calling-official-modules.md` §5:

1. The host seeds the module's anchor token through `logos_module_accept_token`.
   In muster this is `saveToken` → `lp_token_save`.
2. On the first call to a target, the caller's lp client asks
   `capability_module.requestModule`. capability_module takes the caller's name from
   the platform's caller document, not from the `fromModuleName` argument. It then
   mints a token and pushes it to the target, filed under that name.
3. The target's generated glue (protocol ≥ 0.6) resolves the token it is presented
   to that name. It pushes `{"kind":"module","name":…}` through
   `logos_module_set_call_caller` for the dispatch, and the target reads it with
   `current_caller()`.

`unknown` means step 3 found no name for the token muster presented.

## Which side drops the name (the question, as it stood)

- **The runner.** Its host comes from `logos-standalone-app` through the UI's
  basecamp-coherent builder (`4717b9af`, ADR-013). That generation predates the
  caller-document naming in steps 2–3. It does load `capability_module` and handle
  tokens, so it is not simply running with the gate off. Whether its
  capability_module files tokens under a name keystore_module's 0.9 glue can resolve
  is unverified.
- **muster's client.** `muster_module` is protocol-0.2 glue (`c10a94c`, the only
  generation logos-nim-sdk@6077eb7 can define;
  see the atlas `guides/compatibility.md` §2). Its outbound token path is the 0.2
  one. Whether a current host attributes a 0.2 caller's calls is unverified.

**The decisive test** is the same `keystore_status` read under a current host:
`logoscore`/`logosctl` 0.3.x headless, or Basecamp 0.3.1 with muster installed. If
that host says `module muster_module`, this is a runner-generation limit, and K2/K3
are tested in Basecamp, not in the runner. If it also says `unknown`, the gap is
muster's 0.2 client, and the fix is upstream in logos-nim-sdk (the 0.9 export set,
including the token exports).

## Resolved: the current runtime attributes muster correctly (2026-10-01)

`scripts/keystore-logoscore-test.sh` starts one logoscore 0.3.1 daemon
(`github:logos-co/logos-logoscore-cli/0.3.1`, dev build) over the runner's own dev
modules. It leaves out the runner's capability_module, so logoscore's current one
serves the tokens.

| Caller | `keystore_module.caller_identity` |
|---|---|
| the logoscore CLI (control) | `{kind: "host"}` |
| `muster_module`, over lp_* with origin `"muster_module"` | **`{kind: "module", identity: "muster_module"}`** |

`keystore_status` then reads `warn: attested as muster_module; no accounts yet`, which
is correct for a fresh keystore. So muster's protocol-0.2 Nim client works as it is.
The `unknown` comes from the standalone runner: its `logos-standalone-app` host and
its capability_module 1.0.0 predate caller naming.

**Consequences for exo-149:**

- **Signing tests run under a current runtime, never the runner.** That is logoscore
  headless, or Basecamp 0.3.1. In the runner, keystore_module refuses every
  `request_approval` from muster. K2/K3 can be proven end to end headless:
  `evm_keystore_cli` as custodian makes the account, and `evm_signer_cli` as approver
  answers, both enrolled by the test (an operator step, never muster).
- **`make run` and the AppImage demo build on the runner,** so the keystore backend
  will not sign there. FileKeystore stays the fallback where keystore_module cannot
  attest muster. The `keystore_status` row says so in place (`down`, naming what
  keystore_module saw).
- `scripts/keystore-self-test.sh` now checks only the UI path in the runner (the row
  arrives, graded) and prints the runner's attribution. Attribution is gated by
  `scripts/keystore-logoscore-test.sh`.
