# How `lez_core` reports failure, and where it says why (2026-08-11)

Two conventions that cost a debugging cycle each. Both matter for anyone calling the execution-zone module from a Logos view.

## 1. Failure is in the return value, not in `CallError`

The generated typed client hands you a `logos::CallError` out-parameter, which is the obvious thing to check. It is not sufficient. `lez_core`'s methods are thin wrappers over `wallet_ffi`, and they signal failure the C way:

| Return type | Failure looks like |
|---|---|
| `tstr` (`create_new`, `create_account_private`, `transfer_*`, `get_balance`, …) | **empty string**, `CallError` still clear |
| `int` (`open`, `save`, `sync_to_block`, `add_label`) | **non-zero** (`SUCCESS` is 0; the FFI's `INTERNAL_ERROR` is 1) |

From `src/lez_core_module.cpp`:

```cpp
FfiCreateWalletOutput out = wallet_ffi_create_new(...);
if (!out.wallet) {
    fprintf(stderr, "create_new: wallet_ffi_create_new returned null\n");
    return {};                 // <-- empty string, and that is the only signal
}
```

So `if (!err.ok())` alone treats a wallet that was never created as open. The failure then surfaces one or two calls later, somewhere unrelated — for us, as "Could not create a private account", which named the wrong thing entirely.

**Check both**: `CallError` *and* an empty/non-zero return, on every call.

## 2. The reason is logged by the module, in a different log than the view's

Three logs are in play, and they carry different truths:

| Log | Holds |
|---|---|
| the app's stdout (what `nix run … > log` captures) | `[lez_core] …` lines — **the real reason** |
| `<user-dir>/module_data/chat_module/<id>/chat_ui_*.log` | the view's own calls and its downstream symptom |
| `<user-dir>/module_data/chat_module/<id>/chat_module_*.log` | the chat module |

The failure that stopped us read, in the *app* log only:

```
[lez_core] [wallet-ffi] Failed to create wallet: Failed to deserialize wallet config at .../config.json
[lez_core] create_new: wallet_ffi_create_new returned null
```

while the view log showed only `chat_ui: Could not create a private account`. Reading the view log alone would never find the cause. **Grep the app log for `[lez_core]` first.**

## 3. Do not write the wallet config

`WalletConfig` (LEZ v0.2.2, `lez/wallet/src/config.rs`) is:

```rust
pub struct WalletConfig {
    pub sequencers: Vec<SequencerConnectionData>,   // NOT a flat `sequencer_addr`
    pub seq_poll_timeout: Duration,                 // humantime, e.g. "12s"
    pub seq_tx_poll_max_blocks: usize,
    pub seq_poll_max_retries: u64,
    pub seq_block_poll_max_amount: u64,
    pub multi_sequencer_client_config: MultiSequencerClientConfig,  // serde default
}
```

Older clients (including `hackyguru/persona`, which is otherwise the best worked example for driving this module) write a flat `{"sequencer_addr": "..."}`. That shape **does not deserialize** here, and an unparseable config makes `create_new` return null.

The fix is to write nothing: `WalletConfig::from_path_or_initialize_default` writes a correct default — already pointing at `https://testnet.lez.logos.co` — when the file is absent. A config we do not author cannot drift from the schema the linked `wallet_ffi` expects.

Only write one to override the sequencer, and then match the struct above.

## 4. Long calls need the *async* wrapper — the sync one cannot wait

The generated sync wrapper takes no timeout and uses the SDK default, **20 000 ms** (`Timeout`'s default ctor, `logos-protocol/include/cpp/logos_mode.h`):

```cpp
QString LezCore::transfer_shielded_owned(const QString&, const QString&, const QString&,
                                         logos::CallError*);   // 4 args. No timeout.
```

A zk proof does not fit in 20 s. What happens instead is worse than a clean failure: the call returns an error while **the zone keeps proving**, so the next blocking call queues behind that work and the view sits on a stale stage looking hung. We watched a shield "fail" at 20 s and the module carry on for minutes afterwards.

The raw client *does* take one (`invokeRemoteMethod(..., Timeout, CallError*)`), which is how `hackyguru/persona` passes 300 s — but Persona is a **core** module with a `logosAPI` handle. A UI backend has only `LogosUiPluginContext`, which deliberately exposes `modules()` and nothing else, so that route is closed.

The way through is the generated **async** variant, which does accept a `Timeout`:

```cpp
modules().lez_core.transfer_privateAsync(from, toKeys, amountLe16Hex(v),
    [this](QString tx) { /* empty tx == failure */ },
    Timeout(300000));
```

It also fixes a second problem for free: the sync form blocks the UI thread for the whole proof, so the window stops painting and looks crashed. Use async for anything that proves — `transfer_*` above all. `claim_pinata` and `register_public_account` complete well inside 20 s and can stay sync.

**How long is "proves"? Measured: 6m41s.** One `transfer_shielded_owned` of a single note, LEZ testnet, 2026-08-11, on a 13-core desktop, running at ~1300% CPU throughout. Timed from the start of proving to the module's next storage write.

Two consequences, both learned the hard way:

- **300 s is not enough**, and expiring mid-proof is worse than useless: the client discards the result *while the zone keeps computing it*, so the work completes and is thrown away. We watched the balance stay put while the prover ran for another 100 s after the client had given up. The budget here is now 900 s.
- **Anything queued behind a proof waits for it.** After the timeout fired, the follow-up `syncToTip` sat blocked for the remaining ~100 s until the prover finished. A stage label that is not reset on the failure path therefore reads as a permanent hang. Reset it, and return.

A number this large is a product fact, not just a tuning constant: a payment that takes the better part of ten minutes cannot sit behind a button someone is watching. Design the surface for a job, not an interaction — or find out from the zone's authors whether this is expected.

**Do module calls from inside the callback via a queued deferral**, not directly — calling straight back into the transport re-enters its handler while the notifier is disabled, which is the ~20 s stall `logos-chat-ui` documents.

## Related

- [[qml-errors-are-invisible-to-nix-build]] — the other "green build, dead app" trap in this stack, from the same afternoon. Same root lesson: in this stack, only C++ and contracts are checked by the build; everything resolved at runtime needs the app actually launched.
