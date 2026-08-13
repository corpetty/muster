// Minimal reproducer: a private→private transfer credits nothing the
// recipient can find, when the recipient identifier is not the account's own.
//
// !! READ THIS FIRST. The premise stated on the line above is wrong, and the
// !! zone's team said so on 2026-08-13. See §6 of
// !! BUG-private-transfer-recipient-identifier.md. In short: a payment landing
// !! at an account the recipient did not create is the design, not a failure —
// !! the recipient publishes a key node and scans for notes under it. Two
// !! things this program does are actively harmful and are kept only because
// !! this file is the artifact that was sent upstream:
// !!
// !!   - step 2 registers the account on-chain, which *initializes* it and
// !!     makes that account id permanently uncreditable by any foreign sender.
// !!   - step 3 prints B's "own identifier", which is always 0 — the field is
// !!     defaulted and never populated. That reading is what sold the whole
// !!     theory below.
// !!
// !! Step 5 remains a genuine reproducer for the panic (§2), which upstream
// !! confirmed. Do not run this against a wallet you care about.
//
// This links wallet-ffi directly. There is no logos-core, no module host, no
// chat, no networking of our own and no second wallet — one process, one
// wallet, two private accounts in it. If the recipient account cannot be
// credited *inside a single wallet*, nothing about messaging or two peers is
// implicated.
//
// What it does, in order:
//
//   1. opens an existing (funded) wallet and syncs to the tip
//   2. creates a second private account B, and registers it on-chain
//   3. reads B's own identifier via wallet_ffi_resolve_private_account
//   4. transfer A -> B using a RANDOM identifier   (what lez_core does today)
//   5. transfer A -> B using B's OWN identifier    (the control)
//
// and prints B's balance after each. The two transfers are otherwise
// identical, so whichever of them credits B isolates the cause to that one
// argument.
//
// Why this matters: lez_core's transfer_private cannot pass the recipient's
// identifier, because get_private_account_keys does not return one. It
// therefore invents one:
//
//     // src/lez_core_module.cpp, transfer_private()
//     // See transfer_shielded above: to_keys_json never carries an identifier,
//     // so always pick a random one for the recipient's wallet to recover via
//     // sync-private.
//     FfiU128 toIdentifier{};
//     if (!jsonExtractIdentifier(to_keys_json, &toIdentifier))
//         toIdentifier = randomFfiU128();
//
// and wallet_ffi_account_id_for_private_pda documents that a private account
// id is derived from (viewing key, identifier). A random identifier therefore
// derives a *different* account, which the recipient never queries.
//
// Build:
//   gcc -O1 -o poc lez-private-transfer-poc.c \
//       -I<wallet-ffi>/include -L<wallet-ffi>/lib -lwallet_ffi -lm -lpthread -ldl
//
// Run:
//   ./poc <wallet-dir>
// where <wallet-dir> holds config.json / storage.json / statistics.json.
// wallet_ffi_open takes no password, so none is needed or accepted here.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "wallet_ffi.h"

static char cfg[1024], sto[1024], sta[1024];

static void hex32(const struct FfiBytes32 *b, char *out)
{
    for (int i = 0; i < 32; ++i)
        sprintf(out + 2 * i, "%02x", b->data[i]);
    out[64] = 0;
}

static unsigned long long lo64(const uint8_t b[16])
{
    unsigned long long v = 0;
    for (int i = 7; i >= 0; --i)
        v = (v << 8) | b[i];
    return v;
}

// Balance of one account, or -1 when the query itself fails — distinguishing
// "zero" from "could not ask" matters here more than anywhere.
static long long balance_of(struct WalletHandle *w, const struct FfiBytes32 *id, bool is_public)
{
    uint8_t bal[16] = {0};
    enum WalletFfiError e = wallet_ffi_get_balance(w, id, is_public, &bal);
    if (e != SUCCESS) {
        fprintf(stderr, "  get_balance failed: %d\n", e);
        return -1;
    }
    return (long long)lo64(bal);
}

static int sync_tip(struct WalletHandle *w)
{
    uint64_t h = 0;
    enum WalletFfiError e = wallet_ffi_get_current_block_height(w, &h);
    if (e != SUCCESS) { fprintf(stderr, "get_current_block_height: %d\n", e); return 0; }
    e = wallet_ffi_sync_to_block(w, h);
    if (e != SUCCESS) { fprintf(stderr, "sync_to_block(%llu): %d\n", (unsigned long long)h, e); return 0; }
    wallet_ffi_save(w);
    printf("  synced to block %llu\n", (unsigned long long)h);
    return 1;
}

// One transfer, with the recipient identifier supplied by the caller. This is
// the only thing that differs between the two runs.
static void transfer(struct WalletHandle *w,
                     const struct FfiBytes32 *from,
                     const struct FfiPrivateAccountKeys *to_keys,
                     const struct FfiU128 *to_identifier,
                     unsigned amount_units,
                     const char *label)
{
    uint8_t amount[16] = {0};
    amount[0] = (uint8_t)amount_units;

    printf("\n=== %s ===\n", label);
    printf("  identifier: ");
    for (int i = 0; i < 16; ++i) printf("%02x", to_identifier->data[i]);
    printf("\n  proving (this takes minutes)...\n");
    fflush(stdout);

    time_t t0 = time(NULL);
    struct FfiTransferResult res = {0};
    enum WalletFfiError e =
        wallet_ffi_transfer_private(w, from, to_keys, to_identifier, &amount, &res);
    printf("  returned after %lds: ffi=%d success=%d tx=%s\n",
           (long)(time(NULL) - t0), e, res.success ? 1 : 0,
           res.tx_hash ? res.tx_hash : "(null)");
    wallet_ffi_free_transfer_result(&res);
    wallet_ffi_save(w);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <wallet-dir>\n", argv[0]);
        return 2;
    }
    snprintf(cfg, sizeof cfg, "%s/config.json", argv[1]);
    snprintf(sto, sizeof sto, "%s/storage.json", argv[1]);
    snprintf(sta, sizeof sta, "%s/statistics.json", argv[1]);

    const int list_only = (argc > 2 && strcmp(argv[2], "list") == 0);

    struct WalletHandle *w = wallet_ffi_open(cfg, sto, sta);
    if (!w) { fprintf(stderr, "wallet_ffi_open failed\n"); return 1; }
    printf("wallet opened\n");
    if (!sync_tip(w)) return 1;

    // `list` mode: sync and print every account this wallet knows, with its
    // balance, and stop. This is how you check whether a transfer that
    // reported success actually landed anywhere the recipient can see — the
    // thing that distinguishes "credited elsewhere in my wallet" from "gone".
    if (list_only) {
        struct FfiAccountList l = {0};
        if (wallet_ffi_list_accounts(w, &l) != SUCCESS) {
            fprintf(stderr, "list_accounts failed\n"); return 1;
        }
        printf("\naccounts (%zu):\n", (size_t)l.count);
        long long total = 0;
        for (size_t i = 0; i < l.count; ++i) {
            char h[65];
            hex32(&l.entries[i].account_id, h);
            long long b = balance_of(w, &l.entries[i].account_id, l.entries[i].is_public);
            printf("  %s %s balance=%lld\n",
                   l.entries[i].is_public ? "public " : "private", h, b);
            if (b > 0) total += b;
        }
        printf("total across all known accounts: %lld\n", total);
        wallet_ffi_free_account_list(&l);
        wallet_ffi_destroy(w);
        return 0;
    }

    // ── find a funded private account to spend from ────────────────────────
    struct FfiAccountList list = {0};
    if (wallet_ffi_list_accounts(w, &list) != SUCCESS) {
        fprintf(stderr, "list_accounts failed\n"); return 1;
    }
    printf("\naccounts (%zu):\n", (size_t)list.count);
    struct FfiBytes32 from = {0};
    long long from_bal = -1;
    for (size_t i = 0; i < list.count; ++i) {
        char h[65];
        hex32(&list.entries[i].account_id, h);
        long long b = balance_of(w, &list.entries[i].account_id, list.entries[i].is_public);
        printf("  %s %s balance=%lld\n", list.entries[i].is_public ? "public " : "private", h, b);
        if (!list.entries[i].is_public && b > from_bal) {
            from_bal = b;
            from = list.entries[i].account_id;
        }
    }
    wallet_ffi_free_account_list(&list);

    if (from_bal < 25) {
        fprintf(stderr, "\nneed a private account with >= 25 units to run both transfers; "
                        "best found was %lld\n", from_bal);
        return 1;
    }
    { char h[65]; hex32(&from, h); printf("\nspending from private %s (balance %lld)\n", h, from_bal); }

    // ── create the recipient, in this same wallet ──────────────────────────
    struct FfiBytes32 to = {0};
    if (wallet_ffi_create_account_private(w, &to) != SUCCESS) {
        fprintf(stderr, "create_account_private failed\n"); return 1;
    }
    wallet_ffi_save(w);
    { char h[65]; hex32(&to, h); printf("recipient private account: %s\n", h); }

    // Registration proves, so it is slow; it is included because the demo does
    // it and we want the recipient in exactly the state a real one is in.
    printf("registering recipient (proving)...\n"); fflush(stdout);
    { struct FfiTransferResult r = {0};
      enum WalletFfiError e = wallet_ffi_register_private_account(w, &to, &r);
      printf("  register: ffi=%d success=%d tx=%s\n", e, r.success ? 1 : 0,
             r.tx_hash ? r.tx_hash : "(null)");
      wallet_ffi_free_transfer_result(&r); }
    wallet_ffi_save(w);
    sync_tip(w);

    // ── the recipient's real identifier, and its keys ──────────────────────
    struct FfiAccountIdentity ident = {0};
    if (wallet_ffi_resolve_private_account(w, to, &ident) != SUCCESS) {
        fprintf(stderr, "resolve_private_account failed\n"); return 1;
    }
    printf("recipient's own identifier: ");
    for (int i = 0; i < 16; ++i) printf("%02x", ident.identifier.data[i]);
    printf("\n");

    struct FfiPrivateAccountKeys keys = {0};
    if (wallet_ffi_get_private_account_keys(w, &to, &keys) != SUCCESS) {
        fprintf(stderr, "get_private_account_keys failed\n"); return 1;
    }
    printf("recipient keys: viewing_public_key_len=%zu  (note: no identifier is returned)\n",
           (size_t)keys.viewing_public_key_len);

    printf("\nrecipient balance before anything: %lld\n", balance_of(w, &to, false));

    // ── the transfer, with a random identifier, as lez_core sends it ───────
    struct FfiU128 rnd = {0};
    srand((unsigned)time(NULL));
    for (int i = 0; i < 16; ++i) rnd.data[i] = (uint8_t)(rand() & 0xff);
    transfer(w, &from, &keys, &rnd, 10, "transfer with a RANDOM identifier (what lez_core does)");
    sync_tip(w);

    const long long after_to = balance_of(w, &to, false);
    const long long after_from = balance_of(w, &from, false);

    // Enumerate afterwards. This is the step that turns "the money vanished"
    // into what actually happened, and it is the step a client is unlikely to
    // think of: the credited account is not the one whose keys were shared.
    printf("\naccounts after the transfer:\n");
    struct FfiAccountList l2 = {0};
    long long total = 0, stranded = 0;
    char stranded_hex[65] = {0};
    if (wallet_ffi_list_accounts(w, &l2) == SUCCESS) {
        for (size_t i = 0; i < l2.count; ++i) {
            char h[65];
            hex32(&l2.entries[i].account_id, h);
            long long b = balance_of(w, &l2.entries[i].account_id, l2.entries[i].is_public);
            const int is_to = memcmp(l2.entries[i].account_id.data, to.data, 32) == 0;
            const int is_from = memcmp(l2.entries[i].account_id.data, from.data, 32) == 0;
            printf("  %s %s balance=%lld%s\n",
                   l2.entries[i].is_public ? "public " : "private", h, b,
                   is_to ? "   <-- the account whose keys were shared"
                         : is_from ? "   <-- sender" : "");
            if (b > 0) total += b;
            if (b > 0 && !is_to && !is_from && !l2.entries[i].is_public) {
                stranded = b;
                memcpy(stranded_hex, h, 65);
            }
        }
        wallet_ffi_free_account_list(&l2);
    }

    printf("\n============================================================\n");
    printf("sender    %lld -> %lld\n", from_bal, after_from);
    printf("recipient (the id whose keys were shared) : %lld\n", after_to);
    if (stranded > 0)
        printf("but %lld turned up at a DIFFERENT account: %s\n", stranded, stranded_hex);
    printf("total still held by this wallet: %lld\n", total);
    if (after_to == 0 && stranded > 0)
        printf(
            "\nVERDICT: the funds are not lost — they are credited to an account derived\n"
            "         from (viewing key, the RANDOM identifier the sender chose), not to\n"
            "         the account whose keys the recipient shared. A recipient that polls\n"
            "         get_balance on the id it advertised sees 0 forever.\n");
    else if (after_to > 0)
        printf("\nVERDICT: credited to the advertised account — not reproduced here.\n");
    else
        printf("\nVERDICT: nothing credited anywhere in this wallet; see the numbers.\n");
    printf("============================================================\n");

    // The other bug, opt-in because it aborts the process: passing the
    // recipient's *own* identifier — the value resolve_private_account
    // returns, and the one that ought to be correct — panics inside the
    // library at lez/wallet/src/account_manager.rs:385, "update variant must
    // have nsk". Run with `panic` as the second argument to see it.
    if (argc > 2 && strcmp(argv[2], "panic") == 0) {
        printf("\nnow sending to the recipient's OWN identifier (expect a panic)...\n");
        fflush(stdout);
        transfer(w, &from, &keys, &ident.identifier, 10,
                 "transfer with the RECIPIENT'S OWN identifier");
        printf("  (did not panic — balance now %lld)\n", balance_of(w, &to, false));
    }

    wallet_ffi_free_private_account_keys(&keys);
    wallet_ffi_free_account_identity(&ident);
    wallet_ffi_destroy(w);
    return 0;
}
