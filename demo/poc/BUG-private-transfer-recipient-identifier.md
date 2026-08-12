# `transfer_private` credits an account the recipient cannot know about

**Components:** `logos-execution-zone` `wallet-ffi` 0.1.0, `logos-blockchain/logos-execution-zone-module` (`lez_core` 0.4.0)
**Environment:** LEZ testnet, `https://testnet.lez.logos.co`, x86_64-linux
**Date measured:** 2026-08-11
**Severity:** a private payment appears to succeed and the recipient's balance never moves. Funds are recoverable, but not by any client that queries the account it advertised.

---

## Summary

A private→private transfer is credited to an account derived from the **identifier the sender picked**, not to the account whose keys the recipient shared. `lez_core.transfer_private` picks that identifier **at random**, because `get_private_account_keys` does not return one.

The result: the sender is debited, the transaction succeeds, and the recipient — polling `get_balance` on the account id it advertised — sees `0` indefinitely. The funds are in the recipient's wallet, at an account id neither party can predict.

There is a second, separate bug: passing the recipient's *own* identifier, which is what a caller would reach for as the fix, **panics inside the library and aborts the process**.

---

## 1. The primary bug

### What happens

`wallet_ffi_account_id_for_private_pda` documents that a private account id is derived from the viewing public key **and an identifier**:

```c
enum WalletFfiError wallet_ffi_account_id_for_private_pda(struct FfiProgramId program_id,
                                                          FfiPdaSeed pda_seed,
                                                          FfiNullifierPublicKey npk,
                                                          const uint8_t *viewing_public_key,
                                                          uintptr_t viewing_public_key_len,
                                                          struct FfiU128 identifier,
                                                          struct FfiBytes32 *account_id);
```

`wallet_ffi_transfer_private` accordingly takes both the recipient's keys and a `to_identifier`:

```c
enum WalletFfiError wallet_ffi_transfer_private(struct WalletHandle *handle,
                                                const struct FfiBytes32 *from,
                                                const struct FfiPrivateAccountKeys *to_keys,
                                                const struct FfiU128 *to_identifier,
                                                const uint8_t (*amount)[16],
                                                struct FfiTransferResult *out_result);
```

But `FfiPrivateAccountKeys` — the only thing a recipient can hand out — carries **no identifier**:

```c
typedef struct FfiPrivateAccountKeys {
  struct FfiBytes32 nullifier_public_key;
  const uint8_t *viewing_public_key;
  uintptr_t viewing_public_key_len;
} FfiPrivateAccountKeys;
```

So `lez_core` invents one. From `src/lez_core_module.cpp`, `transfer_private()`:

```cpp
// See transfer_shielded above: to_keys_json never carries an identifier, so always pick
// a random one for the recipient's wallet to recover via sync-private.
FfiU128 toIdentifier{};
if (!jsonExtractIdentifier(to_keys_json, &toIdentifier))
    toIdentifier = randomFfiU128();
```

The comment anticipates recovery "via sync-private", and **that part does work** — after syncing, the credited account appears in `wallet_ffi_list_accounts`, because the note is discoverable with the recipient's viewing key. What does not work is the obvious client behaviour: query `get_balance` on the id you published.

### Measured, two independent ways

**(a) Two peers over the real testnet.** Both private accounts created *and registered on-chain* (registration tx hashes captured). Sender pays 10.

| | before | after |
|---|---|---|
| sender, private | 150 | 140 |
| recipient's advertised account | 0 | **0** |

Re-read five times with a full sync to tip each, over several minutes. Then enumerating the recipient's wallet with `list_accounts`:

```
private 021fbfac9e904a3b958c6ddfe5dfe7d683b9c526cb2d803fb3dfb7ba728e4634 balance=0    <-- advertised, registered
private b719ff500c86d29db8d304eb7ac04c4557cd07f2addb374ef3c97f3e7bff259a balance=10   <-- the payment
```

**(b) One process, one wallet, two private accounts in it** — the attached PoC, which removes messaging, a second wallet and the module host entirely:

```
spending from private e4937693…c96c5 (balance 140)
recipient private account: 4c43b9d5…75628e
  register: ffi=0 success=1 tx=2457a2cd…600eaa0
recipient's own identifier: 00000000000000000000000000000000
recipient keys: viewing_public_key_len=1184  (note: no identifier is returned)
recipient balance before anything: 0

=== transfer with a RANDOM identifier (what lez_core does) ===
  identifier: c086365559632963e4e842448c7bc237
  returned after 447s: ffi=0 success=1 tx=15b00461…8b3a8a20

accounts after the transfer:
  private e4937693…c96c5 balance=130   <-- sender
  private 4c43b9d5…75628e balance=0    <-- the account whose keys were shared
  private 86cb3f64429e6583d060d51574d9bd9c34ed7309721619241374baf4e29b2f1c balance=10
total still held by this wallet: 140
```

Note `recipient's own identifier: 000…0`. Accounts appear to be created with a zero identifier, while transfers are addressed to a random one — so the two derivations can never coincide.

### Why this is easy to hit

`transfer_private` returns `success: true` with a transaction hash. Nothing anywhere reports a problem. The only symptom is a balance that stays at zero on an account the recipient has every reason to think is correct — it is the account it created, registered, and published the keys of.

---

## 2. The secondary bug: a panic when using the account's own identifier

Passing the identifier that `wallet_ffi_resolve_private_account` reports for the recipient — the value a caller would use once they discover the first bug — aborts the process:

```
thread '<unnamed>' panicked at lez/wallet/src/account_manager.rs:385:42:
update variant must have nsk
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
fatal runtime error: failed to initiate panic, error 5, aborting
```

Reproduce with `./poc <wallet-dir> panic`. In our case sender and recipient were in the same wallet, so this may be specific to crediting an account the wallet already owns — worth checking, but either way a library that aborts the host process is a problem for anything embedding it.

---

## 3. Reproducer

`lez-private-transfer-poc.c` — one file, links `wallet-ffi` directly. No logos-core, no module host, no chat, no second wallet.

```bash
gcc -O1 -o poc lez-private-transfer-poc.c \
    -I<wallet-ffi>/include -L<wallet-ffi>/lib -lwallet_ffi -lm -lpthread -ldl

# needs a wallet dir holding config.json / storage.json / statistics.json,
# with a private account holding >= 25 units
LD_LIBRARY_PATH=<wallet-ffi>/lib ./poc <wallet-dir>

# read-only: sync and print every account with its balance
LD_LIBRARY_PATH=<wallet-ffi>/lib ./poc <wallet-dir> list

# the panic in §2
LD_LIBRARY_PATH=<wallet-ffi>/lib ./poc <wallet-dir> panic
```

It opens the wallet, creates and registers a second private account, transfers to it with a random identifier, then enumerates every account and prints where the money went. Expect the advertised account at 0 and the amount at an account that did not exist before.

Each proving step takes **6–8 minutes** (measured 447 s for one transfer, ~7 min for a registration) at ~1300% CPU on a 13-core desktop, so a full run is roughly 15 minutes.

---

## 4. What we would like

Any one of these would resolve it; the first is what we assumed the API already did.

1. **Make the recipient's identifier part of what they publish.** Have `get_private_account_keys` return the identifier alongside the keys, and have `lez_core.transfer_private` use it instead of a random value. The recipient is then credited at the account it advertised, and `get_balance` on that id is correct.
2. **Or, if a fresh identifier per note is deliberate** (it is a reasonable unlinkability property, and we would rather keep it than lose it), document that clearly and give recipients a supported way to see the money: a "total private balance across all derived accounts" call, or a documented contract that clients must `list_accounts` after syncing and treat newly appearing private accounts as received notes. Right now the recovery path exists but nothing points at it, and the natural client behaviour silently reports zero.
3. **Fix the panic** in §2 regardless.

We would also value a note on whether **registration matters at all** for a private account. We added `register_private_account` believing it was the cause of this and it made no difference; it is also easy to get wrong, since it proves (so it needs the async path, not the 20 s sync client) and it rejects any account that is not freshly created (`Guest panicked: Account must be uninitialized`).

---

## 5. Two API notes that cost us time

Not the bug, but they made it much harder to see, and both would be cheap to change.

- **`transfer_*`, `claim_pinata`, `register_*` and 12 other methods return a JSON envelope**, not a bare transaction id: `{"success": false, "tx_hash": "", "error": "…"}`. A failure is therefore non-empty and truthy, so the `if (result.empty())` check that is correct for the rest of the module reads a hard failure as success. This silently swallowed a failed shielding step for us, and could have let a client post a receipt for a transfer the zone rejected. Returning an empty string on failure, or documenting the envelope prominently, would prevent that.
- **The balance read immediately after a transfer is stale.** `sync_to_block(current_height)` then `get_balance` returns the pre-transfer figure; a second refresh a minute later is correct. We initially mis-reported our own sender balance because of this.

---

## Contact

Corey Petty — <corey@status.im>. Happy to run any variant of this against the testnet; the PoC is easy to extend and the wallets used above still exist.
