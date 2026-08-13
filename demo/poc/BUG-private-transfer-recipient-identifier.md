# `transfer_private` credits an account the recipient cannot know about

> **§1 of this report is withdrawn.** The zone's team responded on 2026-08-13: what §1 describes is the intended design, and our proposed fix could not have worked. §2 is confirmed. The response also disclosed four defects we had not found, one of which we were actively triggering. **Read [§6](#6-upstream-response-2026-08-13) before anything above it.** The original text is kept unedited — the sequence of wrong turns is the useful part, and this document is now as much a record of how a plausible misreading survived two independent measurements as it is a bug report.

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

## 6. Upstream response (2026-08-13)

Answered by the LEZ team lead. Recorded here in full effect, because most of it corrects this document rather than agreeing with it.

### §1 is withdrawn — that is the design

A private account id is `sha256(prefix || npk || vpk || identifier)`. **What you publish is the key node — the `(npk, vpk)` pair — not an account id.** Every incoming payment mints a new account under that key node, and you find your money by scanning with your viewing key. That is documented in `docs/LEZ testnet v0.1 tutorials/token-transfer.md`; none of it reaches `wallet_ffi.h`, whose `to_identifier` is described only as *"Identifier for the recipient's private account"* — which reads as *the recipient has one, ask them for it*. Upstream is fixing the header docs.

So the recovery path this report calls a workaround is the client. The scan is not how you cope with the bug; it is how a shielded wallet works.

**Our proposed fix #1 could not work, and would have failed louder than the thing we were trying to fix.** A foreign sender has no nullifier secret key, so it can never take the update path — only initialize a fresh account. The initialization nullifier is a hash of the account id *alone*, so **any given account id can be foreign-initialized exactly once, ever**, and the chain rejects the replay. A fixed published identifier would work for one payment and then be permanently dead. Had we shipped the fix we were reaching for, it would have failed on chain rather than silently — which is the one consolation available.

Proposal #2 — document the model and give recipients a supported way to see the money — is the right ask, and is what the tutorial already describes. The gap was that it never reached the header a C caller reads.

### Registration is not needed to receive, and it did real damage

A sender's transfer creates the account. Registration is not part of receiving.

Worse than unnecessary: **`register_private_account` initializes the account**, so after we registered, that specific `(npk, vpk, identifier)` triple became **permanently uncreditable by any foreign sender**. Only that one account id — the published key node is fine, and every other identifier under it still works and is still discoverable. But we added that call believing it was the cause of the symptom in §1, and it is the one thing in this whole investigation that broke something that had been working.

Removed from the demo in the same change as this note. `ChatBackendWallet.cpp` now says why, at the point where the instinct to add it back would strike.

### §2 stands, with a sharper trigger than we had

Confirmed, and a regression test is going in. The mechanism: the send path hardcodes the destination as foreign with no nullifier secret key, while a separate step fills in a membership proof for any account the wallet recognises. The two are decided independently, can disagree, and the `expect` fires.

It is **not** specific to passing the account's own identifier, which is what §2 guessed. The precise trigger:

> the destination identifier is already in the sending wallet's key chain, with a cached state whose commitment is on chain.

Sending to an identifier the wallet has never seen credited does not panic. After an auth-transfer init or an owned-path transfer — both of which write local state without syncing — **the first foreign-path send already hits it**. No test in their suite covered that combination.

### A measurement in §1 was wrong, and it is what sold us the theory

> `recipient's own identifier: 00000000000000000000000000000000`

**`wallet_ffi_resolve_private_account` returns `identifier: 0` for every wallet-owned private account, regardless of its actual identifier.** It is a defaulted field that never gets populated. So that line was a bug, not a reading.

It is the load-bearing one. It is what let §1 conclude that *"accounts appear to be created with a zero identifier, while transfers are addressed to a random one — so the two derivations can never coincide."* That sentence is false, and it is the sentence the whole report is built on. Two independent measurements agreed with each other because both read the same broken field.

Compounding it: **the doc comment on `wallet_ffi_create_account_private` claims it assigns a random identifier; the code uses 0.** Two contradictory sources of wrong information, both pointing the same wrong way. Both are being fixed.

### A defect we had not hit, and the reason we had not

If a wallet is built by **importing a private key chain** — `wallet_ffi_import_private_account`, or `wallet account import private` — then an incoming transfer at any identifier not already present in that import **makes sync panic**. The panic happens before the synced-block marker is written, so the block replays and every subsequent sync dies the same way. Since identifiers are picked at random, this fires on the first ordinary payment.

Wallets created fresh, and wallets restored from a mnemonic, are unaffected: those derive into the key tree, which handles new identifiers correctly.

We are not exposed. `ChatBackendWallet.cpp` mints peers with `create_new`, and nothing in this build imports a key chain. That is now stated there as a constraint rather than left as an accident — a future "just import the peer's keys" would be a wallet that dies permanently on its first payment.

### §5 stands

`lez_core_module.cpp` is `logos-execution-zone-module`, now `src/logos_execution_zone_wallet_module.cpp`. The JSON envelope and the random-identifier fallback are both their code; the envelope point is accepted and on their list. The stale-balance-after-transfer observation is accepted too.

### What this leaves open on our side

Nothing blocking. The scan and the per-note spend are correct and stay. The one real cost survives — a balance is a sum over notes and a single transfer draws on one of them, so a wallet can show more than it can send at once — and it is disclosed in the `payment` claims rather than smoothed over. Note consolidation, or a multi-note spend, would close it; the zone's client exposes neither today.

---

## Contact

Corey Petty — <corey@status.im>. Happy to run any variant of this against the testnet; the PoC is easy to extend and the wallets used above still exist.
