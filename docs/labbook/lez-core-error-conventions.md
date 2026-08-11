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

## 4. There is a *third* failure convention: a non-empty JSON envelope (2026-08-11)

The table in §1 lists two shapes. There is a third, and it is the most dangerous of the three because the obvious check reads it as success.

`register_private_account`, `register_public_account` and the `transfer_*` family return `tstr`, but the string is a JSON envelope built by `transferResultToJson`:

```json
{"success": false, "tx_hash": "", "error": "register_private_account: wallet FFI error 99"}
```

A failure is therefore **non-empty**, well-formed, and truthy. `if (tx.isEmpty())` passes it straight through. We logged "registered private account … tx {…success:false…}" for a call that had hard-failed — precisely the reasoning error §1 exists to prevent, committed again in a shape §1 did not cover.

**Parse the envelope and read `success`.** Do not infer from emptiness, and do not infer from `CallError` either — both were clear here.

`wallet FFI error 99` is `INTERNAL_ERROR`, the catch-all in `WalletFfiError` (`wallet-ffi/include/wallet_ffi.h`). It carries no information; the reason is in the app's stdout, per §2:

```
[wallet-ffi] Registration failed: TransactionBuildError(ProgramProveFailed("Guest panicked: Account must be uninitialized"))
```

## 5. A private account can only be registered while uninitialized (2026-08-11)

That guest panic is the substantive finding. `register_private_account` must be called on a **freshly created, never-used** account. There is no retro-fit: an account that has already been used is rejected permanently.

Two consequences:

- **Register at creation or never.** Put the call in the branch that just minted the account. A peer created by a build that lacked the call cannot be repaired in place; it has to be re-minted, at the cost of its identity.
- **Do not "just try it on every open" as a repair.** The call runs a **prover before it fails**, so a doomed attempt blocks the wallet long enough for every other `lez_core` call to hit the generated client's 20 s timeout. A draft that did this wedged the second peer entirely: `save`, `get_balance`, `get_current_block_height` and `get_last_synced_block` all returned `callRemoteMethod failed or timed out`. The symptom looked like a dead module and was self-inflicted.

This also constrains the hypothesis the call was added for: since neither existing demo peer can now be registered, testing whether registration is what makes a shielded payment credit its recipient **requires two freshly minted peers**, and re-funding both from the faucet.

## 6. The balance immediately after a transfer is stale (2026-08-11)

`syncToTip` then `get_balance`, run in the transfer's own callback, returns the **pre-transfer** figure. The sender read 150 → 150 straight after a successful 7.4-minute proof, and 150 → 140 on the next refresh a minute later.

This matters more than it sounds: it is almost certainly how the original bug report came to describe a debit that did not match the amount sent. **Never conclude anything from the first post-transfer read.** Refresh again, and treat a single reading as unconfirmed.

## 7. Registration is *not* why a shielded payment fails to credit (2026-08-11)

The result the three findings above were in the way of. With two freshly minted peers, **both private accounts registered on-chain and confirmed by transaction hash**:

| | before | after |
|---|---|---|
| sender, private | 150 | **140** |
| recipient, private | 0 | **0** |

The zone proved for 7.4 minutes and returned success with a transaction id. The recipient's balance was re-read five times, each after a full sync to tip, over several minutes. It never moved.

**The registration hypothesis is refuted.** Remaining suspects, in order: note detection needing a receiving-side scan the wallet does not perform, or `get_private_account_keys` not returning the thing `transfer_private` actually credits. Worth asking whoever owns the zone before spending more time on it — three of the four things that looked like the bug turned out to be reporting artefacts in this module's error conventions, and the fourth may be too.

Reproducer: `demo/muster-ui/doctests/credit/run-credit.mjs`, which drives two instances over the inspector protocol and prints the two numbers that decide it.

## Related

- [[qml-errors-are-invisible-to-nix-build]] — the other "green build, dead app" trap in this stack, from the same afternoon. Same root lesson: in this stack, only C++ and contracts are checked by the build; everything resolved at runtime needs the app actually launched.
