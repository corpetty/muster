# Sending assets via Logos — the LEZ adapter, for real

**Status:** design note / plan (2026-09-14). Reintroduces the Logos Execution Zone
(LEZ) into muster as a real `ChainAdapter`, and as a *coordinated* transfer — a room
deciding to move a shielded asset together. Grounds the earlier mock in the actual
`lez_core` surface and the traps recorded the expensive way.

**Thesis.** "Send assets via Logos" should be two things in muster: (1) a real wallet
capability behind the same `ChainAdapter` seam the EVM adapter uses — public and
*shielded* transfers on the LEZ — and (2) a *coordinated intent*, so a room can
co-authorize a private transfer the way it co-authorizes a Safe payment. The LEZ is
where the education mission has its sharpest example: the asset moves and the amount,
sender, and recipient stay off the public record — the leak other stacks can't close.

---

## 1. What the LEZ actually is (not EVM)

The LEZ is **not EVM-compatible** — no `eth_sendRawTransaction`, no chain id, no
JSON-RPC. It is a note/commitment shielded system (Zcash-lineage), reachable two ways:

- **`lez_core`** — a Logos **module** wrapping `wallet_ffi` (the Rust wallet). This is
  muster's native path: call it over the SDK's `lp_*` / `PluginProxy`, exactly like
  `delivery_module` or any invoke target. Methods below.
- **the `wallet` CLI** — the same `authenticated-transfers` program with a CLI front
  end (`wallet account new`, `wallet auth-transfer send`, `wallet account sync-private`).
  The two user docs describe this surface. Useful for standalone reproduction; muster
  drives `lez_core`.

**The model:**
- Two account forms from one identity: a **public** account and a **private/shielded**
  key-set (an `npk`/`vpk` keypair — nullifier and viewing public keys). A private
  account id is *derived*: `SHA256(prefix ‖ npk ‖ identifier)`, and `identifier` is a
  `u128` so one keypair receives from up to 2¹²⁸ distinct accounts.
- **Receive-by-scan, not receive-by-address.** A private payment lands at an account
  the recipient *did not create*; the recipient publishes its key node and **scans**
  for notes (`sync-private` → `list_accounts`). Polling `get_balance` on a published id
  does **not** work — the sender picks a *random* identifier (`to_keys` carries none),
  so the credited account is one you discover, not one you named. *(This was reported
  upstream as a bug and confirmed as the design — see `demo/poc/BUG-private-transfer-recipient-identifier.md`.)*
- **Proving is slow and settlement is delayed.** A shielded `transfer_*` runs a zk
  proof — **measured 6m41s** for one note on a 13-core desktop. The recipient's balance
  moves only after settlement. This is the "balance read right after a transfer is
  stale" reality the mock models as delayed finality.

## 2. What exists in muster today

- **`MockChain`** (`module/src/wallet/mock_chain.nim`) — the stand-in: dual public +
  shielded accounts, delayed finality, sentinel-failure → raise. Deliberately unlike
  EVM so the `ChainAdapter` seam is proven generic. Registered at
  `muster_module.nim` alongside the EVM adapter. It stays — as the no-infra default and
  the deterministic test double.
- **The `ChainAdapter` seam** (`adapter.nim`) — `describe / accounts / assets / balance
  / estimateFee / prepareTransfer / submit / finality`, every method raising
  `WalletError` on any chain quirk (empty-string / `success:false` / timeout), so a
  failed read is never a false zero. Signing goes through the `Keystore` seam.
- **Prior LEZ work — a WORKING end-to-end driver already exists.** `demo/muster-ui/`
  (the chat-ui fork) drives `lez_core` for real, and it is the primary thing to reuse:
  - **`demo/muster-ui/src/Zone.h`** — the clean wrapper to port: `kSequencer =
    https://testnet.lez.logos.co`, two timeouts (`kReadMs = 15_000`, `kProveMs =
    900_000` — 15 min, from the measured 6m41s proof), `amountLe16Hex(u64)` (the zone
    takes every amount as **16-byte little-endian hex**), `Result{ok,tx,error}` +
    `parse()` (the JSON envelope), and `sequencerPost()` (a curl JSON-RPC POST for the
    public-account reads the wallet can't answer from its own state).
  - **`demo/muster-ui/src/ChatBackendAssets.cpp`** — the four **rails**, each a real
    `lez_core` call, and a `Disclosure{amount, payer, payee}` per rail (the education
    surface, already worked out):

    | Rail | `lez_core` call | from → to | discloses {amt, payer, payee} |
    |---|---|---|---|
    | Public → public | `transfer_publicAsync` | public → account id | {T, T, T} |
    | Public → private (shield) | `transfer_shieldedAsync` | public → shielded keys | {T, T, F} |
    | Private → public (deshield) | `transfer_deshieldedAsync` | private → account id | {T, F, T} |
    | Private → private | `transfer_privateAsync` | private → shielded keys | {F, F, F} |

    plus `get_vault_balance`, `vault_claim_privateAsync`, `get_private_account_keys`
    (the npk/vpk key node). All async with `Timeout(kProveMs)`; all envelope-checked.
  - **Receive-by-scan is confirmed in the working code**: spending *received* private
    money uses `spendFromAccount()` — the **discovered** account, not the published one,
    because "money received from someone else is held by a different, discovered
    account." Exactly the model P-L2 built.
  - Also: `demo/poc/lez-private-transfer-poc.c` (a `wallet_ffi` reproducer + the
    random-identifier finding), the labbook (`lez-core-error-conventions.md`), and the
    connection-lifecycle post. The real adapter was deferred as infra-bound; **this
    un-defers it by porting the demo's proven `Zone.h` + rails into the Nim seam.**
  - The `lez_core` module itself is `github:logos-blockchain/logos-execution-zone-module`
    — already a flake input in `demo/muster-ui/flake.nix` (declared as a `dependencies`
    entry, called dynamically by name). That's the wiring precedent for P-L3.

- **Account activation (the atomic-swaps POC, `docs.logos.co/basecamp/atomic-swaps-poc`).**
  A LEZ account must be **explicitly activated on-chain before it can receive** — the
  sequencer *silently discards* transactions to an uninitialized account, with no error.
  So the adapter must activate a fresh account (and surface "not yet activated" rather
  than a silent black hole). The POC also fixes the config: HTLC program id
  `9eb88f51aae87a58fb74b8d2dc7327b39333585e63280e3f9cf8d86dac0ed702`, explorer
  `https://explorer.testnet.lez.logos.co/transaction/<hash>`, and the LEZ charges **no
  fees** (a buyer can start empty).

## 3. The `lez_core` surface → the `ChainAdapter` seam

| Seam method | `lez_core` call(s) | Notes |
|---|---|---|
| `describe` | — | `chain: "lez:testnet"`, forms `[afPublic, afShielded]`, finality `delayed`. Native asset `LEZ`. |
| `accounts(ks)` | `create_account_public`, `create_account_private` / `list_accounts` | Two forms from one identity. Persisted in the wallet store, not re-derived per call. |
| `assets` | — | Native `LEZ`; tokens as the zone exposes them. |
| `balance(acc)` | `get_balance` (tstr; **empty = fail → raise**) | For a shielded account, only after `sync`; the balance of a *received* note appears against a discovered account, not the published id. |
| `estimateFee` | — | A shielded transfer pays a **proof cost**, not gas — a flat native fee + the honest "this proves (~minutes)" note. |
| `prepareTransfer` | (build the `to_keys` json) | Public→public: a plain transfer. Public→private: `to_keys` = recipient `npk`/`vpk` (+ optional identifier). No submit yet — the effect is reviewable. |
| `submit(tx, ks)` | `transfer_*` **async**, `Timeout(900_000)` | Proves. Returns a tx handle from the JSON envelope's `tx_hash`. **Never the sync wrapper** (20s can't wait; expiring mid-proof discards the result while the zone keeps proving). |
| `finality(txRef)` | `sync_to_block` + envelope / block height | Poll, never assert. Stays `pending` until settlement; for a received private note, "final" means the scan found it. |

**Funding + setup (not seam methods, but the adapter needs them):**
`claim_pinata(id, account, nonce)` (the faucet; sync OK <20s), and — only ever on a
**freshly minted, uninitialized** private account — `register_private_account`
(registering an account you want to *receive* to makes it uncreditable by foreign
senders; §5 of the labbook).

## 4. The two documented flows, mapped

**Native transfer** (`docs.logos.co/lez/.../transfer-native-tokens…`):
CLI `wallet auth-transfer send --from public/A --to public/B --amount N` →
adapter `prepareTransfer(pubA, pubB, N)` then `submit` → `lez_core.transfer` between
two public accounts. Public and resolvable, like an EVM send but on the zone.

**Public ↔ private** (`docs.logos.co/lez/.../transfer-lez-tokens-between-public-private-states`):
CLI `wallet auth-transfer send --from A --to-npk … --to-vpk … --to-identifier … --amount N`,
then recipient `wallet account sync-private` →
adapter `prepareTransfer(A, toKeys={npk,vpk}, N)` + `submit` (`transfer_private`, which
invents a random identifier), then the **recipient** side `sync` + `list_accounts` to
discover the credited note. There is no `shield`/`unshield` precompile — moving public→
private *is* a transfer to a private account; private→public is the reverse.

## 5. The reality that reshapes the surface (from the labbook)

Design the surface for these, not around them:

1. **Three failure conventions, all checked.** tstr methods fail as **empty string**;
   int methods fail as **non-zero** (`SUCCESS=0`); `register_*`/`transfer_*` return a
   **JSON envelope** `{"success":false,"tx_hash":"","error":…}` — non-empty and truthy,
   so `isEmpty()` reads a hard failure as success. The adapter parses `success` and
   raises `WalletError` with the envelope's `error`. `CallError` alone is never enough.
2. **Proving is a job, not an interaction.** Async, `Timeout` budget **900s**; reset any
   stage label on the failure path; make follow-up module calls from inside the callback
   via a **queued deferral** (calling straight back re-enters the transport handler → a
   ~20s stall). A payment that takes ~10 minutes cannot sit behind a button someone
   watches — the coordinated-intent framing (§6) fits this: a proposal the room approves,
   then a settle that runs as a job, is the honest UX.
3. **Don't author the wallet config.** `WalletConfig::from_path_or_initialize_default`
   writes a correct default already pointed at `https://testnet.lez.logos.co`. A flat
   `{"sequencer_addr":…}` (older clients) does **not** deserialize and makes `create_new`
   return null. Only write a config to override the sequencer, matching the real struct.
4. **Register at creation or never**, and only on an uninitialized account; a doomed
   `register` runs a prover *before* it fails, wedging every other call behind the 20s
   timeout.
5. **Read `[lez_core]`/`[wallet-ffi]` in the app log**, not the view log, for the reason
   a call failed.

## 6. The coordination angle — a LEZ send as a room intent

This is the muster half. A LEZ transfer is a **module action**, so it rides the
driver-derivation machinery (epic exo-fa4) rather than a bespoke path:

- **The effect** names the transfer: `{effect:"invoke", module:"lez_core",
  method:"transfer_private", args:[from, toKeys, amountHex]}` — or a typed
  `{effect:"lez-transfer", from, toKeys, amount, shielded:true}` the LEZ adapter
  canonicalizes. Either way the action lives in the effect (invariant 6), and its
  `schemaId` domain-separates it (invariant 5).
- **The room approves** it k-of-n (the invoke/threshold driver), then **the core**
  executes it via `lez_core` over `lp_*` — the same "core does the doing, the driver
  only describes" path as `coordinate_submit` (Safe) and `coordinate_execute` (invoke),
  so **invariant 3 holds**: the plugin/driver never touches the zone; the core does.
- **Finality is the proof job.** `coordinate_execute` publishes `submit`, and `final`
  only when `sync` confirms — the room converges on the real settled state, not an
  optimistic one. The ~7-minute proof is a background job the whole room watches
  reach `final`, which is exactly what the "job not interaction" constraint wants.
- **Provenance + privacy (F-20, FS-10, spec `derived-exo-3a1`).** The lineage records
  that a transfer effect was proposed and approved, scoped to the room's epoch — while
  the *shielded* amounts/recipients stay off the public record. The room is the
  disclosure boundary; the chain learns nothing. This is the education payoff: show the
  same transfer on EVM (amount, from, to public) beside the LEZ (a commitment, a
  nullifier, nothing else) — where Logos closes the leak.

## 7. Invariants preserved

- **Inv 3** — the LEZ driver/adapter *describes and verifies*; the core does the
  `lez_core` `lp_invoke`, as it already does the Safe `execTransaction`.
- **Inv 1 / 5** — a coordinated LEZ transfer re-derives its canonicalization before
  execution; the effect's `schemaId` domain-separates it.
- **Inv 8** — the sequencer (`testnet.lez.logos.co`) is untrusted, user-configurable
  infra, surfaced in Settings, never assumed.
- **The wallet contract** — every `lez_core` quirk becomes a `WalletError` raise; a
  failed/timed-out/`success:false` call is never a false zero or a false receipt.

## 8. Plan

- **P-L1 — the `LezAdapter` skeleton + seam mapping.** Implement `ChainAdapter` over a
  small `LezCore` seam (the `lez_core` calls, so tests use a fake and real runs use the
  `lp_*` client). Public accounts + `get_balance` + a public transfer, with the three
  error conventions → raise. No proving path yet. Unit-tested against a fake `LezCore`.
- **P-L2 — shielded transfer + receive-by-scan.** `transfer_private` (async, 900s),
  `sync` + `list_accounts` discovery, delayed finality. The public↔private flow end to
  end against a fake, and against the real testnet once infra is wired.
- **P-L3 — the real `lp_*` `LezCore`.** Consume `lez_core` as a `metadata.json`
  dependency; the real client over `PluginProxy`, async + queued deferral. Wire funding
  (`claim_pinata`) + register-at-creation. Register the adapter in the wallet
  (`gLez = newLezAdapter(...)`).
- **P-L4 — coordinate a LEZ send.** A LEZ transfer as a room intent (§6) — reuse the
  invoke driver + `coordinate_execute`, or a typed `lez-transfer` effect. The room
  approves; the core settles via `lez_core`; the fold reaches `final` when the proof
  settles. UI: the transfer card + the shielded/public disclosure.
- **P-L5 — the education surface.** The side-by-side (EVM leaks vs LEZ shields) the
  vision doc promises, driven from the two real adapters.

## 9. Infra needed to run it real (the "point me at it" list)

To move past the fake `LezCore` and run against the zone:
- the **`lez_core` module** — repo + rev to add to `module/metadata.json` (owner/repo/
  hash), or a prebuilt `.lgx` + how the runner loads it;
- the **sequencer** endpoint (default `https://testnet.lez.logos.co` — confirm, or the
  override);
- the **pinata faucet** id + nonce for `claim_pinata` (the lifecycle post used
  `kPinataB58 = EfQhKQAkX2FJiwNii2WFQsGndjvF1Mzd7RuVe7QdPLw7`);
- `wallet_ffi` headers/lib if the adapter links it directly instead of via `lez_core`;
- confirmation of the **LEZ testnet version** (labbook is v0.2.1/0.2.2; docs say v0.2.1).

Related: [[muster-wallet-interface]], [[muster-driver-derivation]], the mock
(`module/src/wallet/mock_chain.nim`), the labbook, and the two user docs linked above.
