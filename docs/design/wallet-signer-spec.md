# What Muster needs from a wallet and signer

**For:** whoever designs the aggregation module for wallets and signers on Logos (a separate session,
started 2026-10-24). Muster is the reference client: it coordinates multi-party actions across EVM,
Bitcoin, LEZ (public and private), FROST groups and Monero. If the module serves Muster, it serves
simpler apps.

**What this is:** Muster's requirements, stated as the interface it wants. It is not a design of
the module.
- §1 lists every key operation Muster performs today and where each one lives.
- §2 gives the rules that hold for all of them.
- §3 is the interface, family by family.
- §4 is the approval contract.
- §5 is what exists today against what is needed.
- §6 is how Muster will test the module.
- §7 is the open questions.

Words: **signer** holds keys and signs. **Wallet** reads chains, builds transactions, sends and tracks
them. **App** is the caller: Muster here. **Person** is the human who approves.

---

## 1. Every key operation Muster performs today

| Operation | Key / scheme | Where it lives today | Platform piece today |
|---|---|---|---|
| Room identity: sign authored events, the founding key | Ed25519 (`edSign`) | Muster's keystore (`FileKeystore`, Argon2id file) | none |
| Room identity: open epoch grants, sealed group secrets and notes | X25519 sealed box (`sealOpen`) | Muster's keystore | none |
| Bind the EVM key to the room identity (F-14) | secp256k1 + Ed25519 link statement (`bindingFor`) | Muster's keystore; `keystore_module` when the EVM key is the platform's | partly (K5) |
| Approve a Safe transaction | ECDSA over the EIP-712 `safeTxHash` | `keystore_module` (approval) or Muster's keystore | yes, as an opaque digest leg; the typed form (ADR-017, K6c–d) is not wired |
| Attest the room's record of an approval (invariants 2 and 10) | same key as the approval, EIP-712 form (ADR-017) | Muster's keystore; builders landed (K6b) | no typed attestation leg |
| Send an EVM transaction (split share, Safe settle, wallet send) | ECDSA tx | `tx_sender_module` (prepare → send → approve → status) | yes |
| Bitcoin multisig input (P2WSH / tapscript) | DER over BIP-143, BIP-340 over BIP-341 | Muster's keystore (`signEcdsaDer`, `signSchnorr`) | none; outside signers through PSBT import |
| Bitcoin split payment from the member's own coins | wpkh, DER over BIP-143 | Muster's keystore (`btcPubKey`) and the user's bitcoind | none |
| LEZ public transaction (fees, multisig votes, lez-msig instructions) | BIP-340 over the LEZ message hash | Muster's keystore, per label (`lezMemberSign`) | `lez_core` signs only the transactions it builds |
| lez-msig approval, verified in the program | BIP-340 over a tagged digest | Muster's keystore, per-multisig or a shared account (`lez-msig/<ck>`, `lez-account/<n>`) | none (`docs/proposals/lez-core-sign-message.md`) |
| Proof that an account is the member's (shared accounts) | BIP-340 over a hash-input record | Muster's keystore | none |
| LEZ private transfer, shield, deshield; receive by scan | the wallet's private keys; proving takes minutes | `lez_core` (`transfer_*`, `sync_to_block`) | yes, but no message signing and no job events |
| Private lez-msig execution and deposit | a group secret derives the PDA's keys; the deposit's payer signs BIP-340 | `lez_msig_module` (proving, no key) + Muster's keystore (payer) | partly |
| FROST (ChillDKG + BIP-445 signing) | host key; nonces consumed before use; shares recovered from public data | Muster's keystore (`frost*`) | none |
| Monero request and send | the creditor's own wallet mints subaddresses and confirms from its history; Muster never spends | `monero_wallet_backend` | yes (read-and-mint) |
| Monero multisig spend | each member's own `monero-wallet-rpc`: describe, sign, submit | the member's wallet over RPC | none in Basecamp |

The pattern: a signature on any chain other than EVM is made in Muster's own keystore today,
because no platform signer can make it.

---

## 2. Rules for every operation

These follow from Muster's invariants (`CLAUDE.md`). A module that breaks one cannot carry
Muster's signatures.

1. **Operations, never key getters.** The interface signs, derives a public key, opens a sealed
   box, or proves. It never returns a secret, and a backend without exportable keys (a Keycard,
   a hardware signer) works behind it unchanged.
2. **Every signature is domain-separated by the signer.** The signer signs typed payloads it can
   name: a transaction, an EIP-712 document, a PSBT input, a domain-tagged message. It refuses a
   bare 32-byte digest from an app. On LEZ, the reason is concrete: a raw signer would sign a
   transaction hash for anyone.
3. **What the person sees is what is signed.** The signer re-derives the digest from the
   structured payload it shows, and refuses on mismatch. This is Muster's invariant 1, held at
   the signer too. The app may add a summary; it is shown as "the app says".
4. **A signature commits to where it is valid.** Environment (chain, CAIP-2), account (CAIP-10),
   and an expiry or nonce are part of every payload the signer builds or shows (invariant 2). The
   signer displays them.
5. **The caller is known and limited.** Every request carries the calling module's attested
   identity (`caller_identity()`, as `keystore_module` has). A policy says which modules may
   request which kinds of signature, per account.
6. **Nothing blocks the caller.** Approvals take minutes and proofs take minutes. Every request
   answers at once with a handle. Progress comes through events and a status call. Requests
   survive a restart, and a request can be cancelled. A long call inside one `lp_invoke` froze
   Muster's module thread before (`rpc_budget`).
7. **State is recoverable from one secret.** Every key derives deterministically from the
   person's recovery phrase and a derivation context (§3.1). Muster's own state is
   `reduce(log) + keys` (invariant 4), and it depends on re-deriving the same keys after a
   reinstall.
8. **Fresh keys per context by default.** Muster derives a new key per room membership and per
   multisig, so memberships cannot be linked on chain. The signer must make "a new key for this
   context" cheap, and keep reuse a deliberate choice whose consequence it states (as shared
   accounts do).
9. **No server, no telemetry** (invariant 8). RPC endpoints are the person's choice, and every
   read says how it was obtained: verified (a proof checked) or attested (an RPC's word). That
   is F-10.
10. **A failure is an error, never a zero.** A failed read raises. A refused signature names why
    with a stable code. Every network call has a deadline.
11. **Every platform Logos ships:** linux-amd64, linux-arm64, darwin-arm64, then windows-x86_64.
    A signer that exists on one platform splits the app (as `lez_msig_module` does today).

---

## 3. The interface Muster wants

Grouped by what it does. Names are illustrative; the shapes are the requirement.

### 3.1 Accounts and derived keys

- **`list_accounts(chain?) → [{account (CAIP-10), chain, kind, label, publicKey, origin}]`.**
  `origin` is `phrase:<group>/<index>` or `imported`, never the path.
- **`derive_key(purpose, context, scheme) → {keyRef, publicKey, address?}`.** A deterministic key
  for a purpose and a context:
  - **`purpose`:** `room-identity`, `lez-member`, `lez-msig-approval`, `frost-host`, `btc-payer`,
    and so on;
  - **`context`:** for example the room topic and the multisig's create key.

  The same inputs give the same key on any device restored from the phrase. `keyRef` is opaque.
  The derivation path is never disclosed to the app or to the room. This replaces Muster's labels
  (`lez-msig/<ck>`, `lez-account/<n>`, `lez-member/0`).
- **`prove_possession(keyRef, domain, context_record) → signature`.** One key's signature over a
  domain-separated record binding it to a person and a place. Muster's shared accounts (room,
  member, chain, kind, key) and its F-14 binding are two cases.
- **Create, import, label, delete** belong to the person's custodian UI. An app never calls them.

### 3.2 The room identity (encryption and authorship)

- **`ed25519_sign(keyRef, domain, message)`.** Authored room events. Domain-separated: Muster
  signs hash-input records (`muster.event.author.v1`).
- **`x25519_open(keyRef, sealed)`.** Opens a libsodium sealed box addressed to the identity: epoch
  grants, a private multisig's group secret, its notes.
- **`identity(keyRef) → {ed25519, x25519}`,** with X25519 derived from Ed25519. This is the
  identity Muster's rooms already use (F-14).
- **No approval prompt per event.** Authorship signatures happen on every message. The person
  grants the app this key's use once per room (or per app), and the policy (rule 5) holds the
  grant.

### 3.3 EVM

- **EIP-712 typed data,** shown field by field: the Safe transaction (all SafeTx fields, the Safe,
  the chain) and Muster's typed attestation and binding (ADR-017). **One prompt for related
  legs:** an approval and its attestation are one decision for the person.
- **EIP-191 personal messages,** for the `eip191` driver.
- **Transactions only through the wallet's sender:** one nonce ledger per account and chain, as
  `tx_sender_module` does. `prepare` answers the exact calls it will send, Muster compares them
  with what the room agreed and refuses a mismatch, then `send` asks the person.
- **A raw-digest leg must not exist.** Today the attestation reaches the person as one (K6 gap).

### 3.4 Bitcoin

- **Sign a PSBT.** The signer computes every input's sighash from the PSBT itself (BIP-143 for
  segwit v0, BIP-341/342 for taproot) and shows inputs, outputs, fee and change. It signs only
  inputs whose keys it holds, and returns partial signatures.
  - **Canonical form.** Muster's canonical form is dCBOR, never PSBT bytes; the PSBT is the
    exchange format.
- **Keys:** a per-context wpkh payer key, multisig member keys (compressed and x-only), and a
  BIP-340 key for tapscript.
- **The person's own node** is the wallet's chain backend (`scantxoutset`,
  `sendrawtransaction`).

### 3.5 LEZ

- **Public transactions,** built or checked by the signer: program, accounts, shards,
  instruction, fee declaration, nonces. The signer computes the message hash itself. Any
  program call (`send_generic_public_transaction`), not only transfers, with the payer chosen
  per call.
- **Domain-separated messages** (`docs/proposals/lez-core-sign-message.md`), BIP-340, for
  approvals a program verifies (lez-msig) and for possession proofs.
- **Private rails:** shield, deshield, private transfer, receive by scan. Proving runs as a job
  with progress events; it takes minutes per proof.
- **Group-owned private accounts** (lez-msig's private posture). The signer holds a group secret
  that several people share:
  - it derives the PDA's keys (`GroupKeyHolder::derive_keys_for_pda`);
  - it proves a program execution over the account's note;
  - it scans for the account's notes with the group's viewing key;
  - it seals and opens the secret for members.

  Today this is `lez_msig_module` plus Muster's keystore.
- **Nonces and fees read from the chain** at the signed moment; on v0.3 a refused public
  transaction is still included and pays, so the wallet reports outcomes by state read back.

### 3.6 FROST (threshold Schnorr)

- **Host key per ceremony** (`derive_key(frost-host, ceremony)`).
- **ChillDKG steps inside the signer:** step 1, step 2 and finalize. The signer holds the
  ceremony state between steps.
- **No stored share.** A share is recovered from the ceremony's public recovery data plus the host
  key ("log + keys").
- **Signing rounds:** a nonce commitment, then a partial signature for a named signer set. A
  nonce is consumed before it is used, and a restart aborts its session: no nonce is ever used
  twice.
- **Constant time.** Muster's implementation is demo-grade, not constant time. A platform
  signer must be.

### 3.7 Monero

Muster never spends XMR. It needs, from the person's own wallet:
- mint a subaddress for a request;
- read history (confirmations, amount, subaddress);
- open the wallet's own send screen pre-filled (the person confirms there);
- for a multisig, the person's wallet runs the key exchange rounds, then for each spend
  describes it before signing, signs and submits.

`monero_wallet_backend` covers the first three. The multisig rounds have no platform module.

### 3.8 Reads

- **Balances** per account and asset, with a route: verified (with height) or attested.
- **Nonces, accounts and program state** (LEZ shards, Safe owners, threshold, modules, guard).
- **Proofs** (`eth_getProof`, LEZ membership proofs) where the app verifies.
- **Every read has a deadline,** and a null answer is an error.

---

## 4. The approval contract

One request shape for every family, so the person's approval experience is the same everywhere.

```
request {
  caller        attested module identity (never self-reported)
  account       CAIP-10
  environment   CAIP-2, plus the slot / nonce / expiry the payload commits to
  kind          tx | eip712 | psbt | lez-tx | lez-message | ed25519-message | frost-round | …
  payload       the structured payload the signer will hash and sign
  summary       the app's words (shown as "the app says")
  purpose       one line the room agreed ("Pay my share of 'dinner' to Devon")
  refs          opaque ids the app joins back on (room, intent, part)
  legs          several payloads approved as one decision (approval + attestation)
}
→ { handle, receipt }      at once
status(handle, receipt)    proving | awaiting-person | approved | rejected | failed | expired
fetch(handle, receipt)     the signatures, once; ack erases them
cancel(handle, receipt)
events                     approval_offered, approval_settled, job_progress
```

`keystore_module` already has most of this (`request_approval`, `approval_status`,
`fetch_result`, `ack_result`, `cancel_approval`, receipts). It should become the shape for every
family, with typed payload kinds instead of opaque digests.

**Standing grants** (rule 5) sit beside per-request approvals. Example: "Muster may make Ed25519
authorship signatures with this room identity", without asking each time.

---

## 5. What exists against what Muster needs

Updated 2026-10-25. The platform already has the aggregator this spec asks for:
- `logos.signer/1` (logos-co/logos-signer-interface);
- `signer_manager_module`, which has `keystore_module`'s approval contract and unlock terms,
  "without asking" included;
- signers behind them: the keystore, Keycard, Keycard Shell, QR, Ledger and Trezor.

What Muster lacked is built on three branches under corpetty, proposed upstream and not yet merged
(epic exo-833; drafts in corpetty/logos-signer-module `docs/upstream/`).

| Need | Upstream today | On the branches | Gap |
|---|---|---|---|
| EVM tx through one sender | `tx_sender_module` | — | — |
| EIP-712 typed approval and attestation | the manager renders typed data field by field | — | the attestation's typed form (K6c–d) |
| Bitcoin PSBT signing | keystore (BIP84/86) and the manager read PSBTs | — | multisig inputs (P2WSH, tapscript), FROST key path |
| Ed25519 room identity | none | keystore identity groups; manager `record` legs | merge upstream |
| X25519 open, derived secret | none | keystore `identity_open` / `identity_secret`; manager `open` / `secret` legs | decision: where decryption lives |
| Context-derived fresh keys | fixed BIP-44/84/86 paths | `m/7432'/0'/c0'…c7'` per purpose and context, from the kept phrase | who may ask for one (custodian only today); the purpose number |
| Standing grants | manager unlock terms (`ttlMs`, `count`, `apps`, `confirm: false`) | used as is for identities | — |
| One phrase, kept once | keystore kept phrases (#28) | identity groups use them | — |
| LEZ public tx for any program, chosen payer | `lez_core` (`payer_account_id_hex`) | — | callers supply the call; the signer shows it |
| LEZ domain-separated message | none | — | `sign_message` (drafted upstream ask) |
| LEZ private rails | `lez_core` (synchronous calls) | — | jobs and progress events |
| Group-owned private accounts | `lez_msig_module` + Muster's keystore | — | a signer that holds and shares group secrets |
| FROST | Muster's keystore (demo-grade) | — | constant-time, signer-held ceremony state |
| Monero request / send | `monero_wallet_backend` | — | — |
| Monero multisig rounds | the member's `monero-wallet-rpc` | — | a platform module |
| Possession proofs | Muster's keystore | — | a record leg covers an Ed25519 proof; BIP-340 waits on LEZ messages |
| Every platform | mixed (`lez_msig_module` linux-amd64) | the branches are pure Rust | — |

Muster's side so far (exo-833.3):
- `Keystore.edSignRecord` passes the routine signatures (authorship, after-claims, join requests)
  as records, so the manager can show what it signs.
- `PlatformIdentityKeystore` (`module/src/crypto/platform_identity.nim`) holds the room identity
  in the person's keystore_module, through the manager. It signs records, opens sealed grants and
  derives the founding key with `record`, `open` and `secret` legs, inside the unlock the person
  granted muster, and refuses a locked identity with its remedy. The authorization key and
  everything else stay with muster's own keystore. Held byte for byte to a local keystore with the
  same key (`platform_identity_test`).
- `identity_platform_request` / `identity_platform_status` ask the manager's `request_identity`
  for a key derived for `muster_module/default`, and set `identity-backend` once the person
  approves, only while no room is joined.
- Live under logoscore 0.3.1 (`scripts/platform-identity-logoscore-test.sh`, 2026-10-26): with
  the forked keystore and manager, and the manager's probe as the keys app, muster asks, the keys
  app approves, and muster founds a room and posts a message under a key derived for
  `muster_module/default`, with no prompt; after the keys app locks it, the next post is refused
  at once with its remedy, and nothing is left pending.
- Not yet: a key per room (the seam is not room-scoped), the approval-bearing Ed25519 signatures
  (live, vote, Monero multisig rounds, still raw bytes), and the UI that raises the keys app.

## 6. How Muster will test the module

- **Muster's suite against the module,** behind its existing seams: the `Keystore` operations, the
  `ChainAdapter`, the settlement seam and the `MsigProver`. Every driver's conformance
  (`checkConformance`) passes with the module as the key backend. The live end-to-end tests
  (anvil Safe, Bitcoin regtest, a LEZ v0.3 zone, FROST on regtest and LEZ, lez-msig public and
  private) pass unchanged.
- **Refusals the module must make,** each a test:
  - a raw 32-byte digest;
  - a LEZ message whose digest equals a transaction hash;
  - a payload that differs from its display;
  - a request from a module the policy does not allow;
  - a FROST nonce used twice;
  - a read that answers null.
- **Recovery:** wipe the device, restore from the phrase, and Muster rejoins its rooms and signs
  with the same derived keys (`relaunch-self-test`, `room-copy`).
- **Approval UX:** one prompt for an approval and its attestation; the prompt names the caller,
  the account, the chain and the expiry; a cancelled request leaves nothing behind.

---

## 7. Open questions for the module's design

1. **One module or a family?** One aggregation module routing to per-chain signers (keystore,
   lez, btc, frost), or one signer with plug-in schemes. Muster needs one approval contract and one
   derivation scheme either way.
2. **Where do group secrets live?** A private multisig's secret is shared by its members, so it is
   neither one person's key nor public. The signer must hold it, seal it to members, and recover
   it after a restore. Muster does that over the room today.
3. **Standing grants.** How a person grants an app routine signatures (authorship, a room's epoch
   keys) without a prompt per message, and revokes them.
4. **Hardware signers.** Which schemes a Keycard can do (secp256k1 ECDSA and BIP-340 yes; Ed25519
   and FROST state?), and how the module degrades when a scheme is missing.
5. **Proving location.** LEZ proofs take minutes on a CPU prover (lez-msig on a 64-core AMD EPYC:
   about 111 s + 12.0 s per approval on LEZ v0.3, and 182 s + 11.5 s per approval on v0.4,
   `programs/lez-msig/BENCHMARKS.md`). Is a remote prover in scope, and how would it
   avoid seeing the witness?
6. **Wallet history.** Which app reference a send carries back (`refs`), so the wallet's history
   joins Muster's rooms without the wallet learning what the room is.

---

Sources: Muster's `Keystore` seam (`module/src/crypto/keystore.nim`), its drivers and settlement
(`module/src/drivers/`, `module/src/settlement/`), `docs/design/real-use-basecamp.md`,
`docs/design/keystore-module-backend.md`, `docs/design/lez-msig.md`, ADR-017, and the
platform contracts of `keystore_module`, `tx_sender_module`, `lez_core` 0.5.0 and
`monero_wallet_backend` (Logos module atlas, 2026-10-07 catalogue).
