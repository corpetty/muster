# keystore_module sees muster's calls as `unknown` in the standalone runner

**exo-149.1 (K1), 2026-10-01. Status: OPEN.** The cause is not yet separated from the host.

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

## Not yet known: which side drops the name

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
