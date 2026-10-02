# keystore_module as muster's EVM key backend (epic exo-149)

**Status:** K1 landed (2026-10-01). §4 decided 2026-10-01: C, plus A as a flagged interim; B is the target (exo-149.6).
**Sources:** `keystore_module` = logos-co/logos-evm-keystore-module@2318c679
(`docs/specs.md` §request_approval; `rust-lib/src/approval.rs`, `keystore.rs`). The
platform view of the EVM stack is in the Logos Module Atlas: `stacks/evm-wallet.md` and
`stacks/key-custody.md` (github.com/corpetty/logos-module-atlas).

## 1. What changes

Basecamp 0.3.1's catalog ships `keystore_module`. It is the only module that holds EVM
key material, and every signature it makes is one a human approved, by typing the vault
password into an approver (`evm_signer_ui`, or `evm_signer_cli` headless). Moving
muster's secp256k1 authorization key there:

- puts the key where the platform keeps keys;
- puts the human's approval on a surface the platform owns;
- makes signing **asynchronous**. There is no synchronous sign: a request returns
  `{handle, receipt}` at once, and the signatures arrive only after a human approves.

FileKeystore stays the fallback wherever keystore_module cannot attest muster. That
includes the standalone runner, `make run` and the AppImage. `keystore_status` already
says so (K1, `docs/labbook/keystore-caller-attribution.md`).

## 2. What an in-app EVM approval signs today

`coordination/live.nim` (`liveContribute`, the `SafeDriver`/`PersonalSignDriver` arm)
makes three signatures with the same key in one call:

| # | Signature | Bytes | Why |
|---|---|---|---|
| 1 | the contribution | `mat.bytes`, the `safeTxHash` (EIP-712 hash of the SafeTx) | what the Safe counts |
| 2 | the attestation | `keccak256(P)`, where P is the dCBOR attestation payload (`coordination/attest.nim`) | invariants 2 and 10: environment, account, slot and expiry, plus the provenance of every input |
| 3 | the key binding | `linkDigest`: a `muster.identity-binding.v1` hash-input record over the enc identity and context (`crypto/binding.nim`) | F-14/F-9: this key belongs to the admitted member |

Every member's fold checks #2 (`verifyAttestation`) and #3. A contribution without a
valid attestation is refused (`attestation-mismatch`).

## 3. Mapping to keystore legs

A `request_approval` intent is `{address, purpose, legs}`. A bundle of several legs is
**one human decision**: every leg is signed, or none is.

| # | Leg | What the human sees in the signer | Check on the way back |
|---|---|---|---|
| 1 | `typed_data`: the SafeTx EIP-712 document (domain, `SafeTx` type, message) | the domain, the type and **every SafeTx field**, rendered by the keystore, which computes the hash itself | muster re-derives `safeTxHash` (inv 1) and checks the returned signature recovers to the chosen account **over muster's own hash**. A mismatch is refused: the keystore signed a different document than muster derived |
| 1′ | `message` (PersonalSignDriver, printable text ≤ 8 KiB) | the text | the same recovery check over the EIP-191 hash |
| 2 | see §4 | | `verifyAttestation` as today |
| 3 | see §4 | | the binding check as today |

`digest` legs are signed raw over the 32 bytes, with no prefix (`sign_digest_with` →
`sign_hash_sync`), and returned as 65 bytes `r‖s‖v`. That is the same shape as today's
`Keystore.sign`. The `v` encoding (27/28 versus 0/1) is to be confirmed by K2's first
test; the verifiers must accept either.

## 4. The decision: how do the attestation and binding reach the human?

Signatures #2 and #3 are muster's own protocol commitments over muster's own hashes
(invariant 5: domain-separated hash-input records). They are not EIP-712 documents, so
the keystore cannot render them.

**Option A: `digest` legs, as the commitments stand.**
- Works today. No protocol change: every member verifies exactly what it verifies now.
- Cost: the human sees two opaque 32-byte hashes beside the Safe transaction, each
  labelled with muster's *claimed* purpose. The keystore shows a digest's purpose as
  the requester's claim, never as fact. A compromised or malicious `muster_module`
  could put **any** 32-byte hash in such a leg — another Safe's `safeTxHash`, a permit —
  and get it signed in the same click. The keystore's own design treats `digest` as
  the opaque, least-preferred kind for exactly this reason.

**Option B: typed (EIP-712) forms of the attestation and binding.**
- A Muster EIP-712 domain, with the attestation's and binding's fields as typed
  fields, so the keystore renders them line by line.
- Cost: the signed bytes of #2 and #3 change for keystore-backed keys. Every member's
  verifier must accept the typed form beside the hash-input form. That is a wire- and
  probe-level change (invariant tests are append-only), and an ADR, because EIP-712's
  `hashStruct` under a domain separator is domain-separated but is not muster's
  hash-input record. Old and new builds would disagree on such approvals.

**Option C (complements either): move the binding out of the approval.**
- The binding (#3) depends only on the key and the context (account, slot, expiry),
  not on the intent. It can be requested once, when the member selects the keystore
  account (K5), and reused. Each approval then carries one extra leg (#2), not two.

**Decided (2026-10-01):** C, plus A as an interim labelled as such: behind a setting, off
by default outside testnet, with the risk stated on the card. Then B as the target, via
its own ADR (exo-149.6). K2's mechanics (§5) are the same under A and B, so they land
first.

## 5. The asynchronous seam (K2)

The same shape as the LEZ proving pump and the RLN probe's async reads:

1. `coordinate_contribute` with a key ref that names a keystore_module account does
   the checks it does today (refusals, expiry, accountable inputs, P). It then sends
   `request_approval` and returns at once with `{pending: true, handle}`. Nothing is
   published.
2. A pending table, in memory only, keyed by `handle`, holds the receipt, the intent
   id, P, the expected hashes, and a deadline.
   - **The receipt is never logged, emitted, or persisted.** A restart drops the
     table. The record expires in the keystore (60 s if unclaimed), and the member
     approves again.
3. The intents tick pumps each pending request:
   - `approval_status`: while it is `offered` or `rendered`, wait.
   - When settled and approved: `fetch_result`, run the §3 checks, publish the
     contribution, attestation and binding exactly as `liveContribute` does now, then
     `ack_result`.
   - When rejected, expired or cancelled: drop it and say why (the card's status
     line).
4. `cancel_approval` runs when the intent expires, is declined, or the member backs
   out. At most 4 can be pending per requester; a 5th request is refused before
   anything is sent.
5. K3 raises `evm.signing.approve {handle}` from `muster_ui` (Basecamp). Headless,
   `evm_signer_cli` approves.

## 6. Test plan

- **Pure:** the pending-table state machine (`keystore_requests.nim`), and the leg
  builders (SafeTx → `typed_data` JSON, checked against `safeTxHash` vectors).
- **Headless end to end under logoscore 0.3.1** (never the runner; see the K1
  labbook):
  - `evm_keystore_cli`, enrolled as custodian by the test (an operator step, never
    muster), imports anvil owner key 1.
  - Muster proposes on the anvil Safe and contributes with that key ref → `pending`.
  - `evm_signer_cli` approves `<handle> <bundle_id> @pwfile`.
  - The pump folds the contribution, the attestation verifies, and two owners reach
    executable.

## 7. Verified end to end (2026-10-01)

`scripts/keystore-approval-logoscore-test.sh` passes under logoscore 0.3.1, against
anvil and the real Safe v1.4.1. muster contributed with `keystore_module`'s owner 0 and
got `awaiting-approval`. `evm_signer_cli`, acting as the human, rendered the request as
below and approved it (`signed_count: 2`). muster's tick then fetched both signatures,
checked each recovers to owner 0 over muster's own hashes (so the keystore's signing
hash equals muster's `safeTxHash`), and published the approval: `collecting`, with 1
approval by `0xf39f…2266`.

```
2 item(s) to sign:
  [1] Sign EIP-712 typed data
      Domain: chainId=31337, verifyingContract=0xeb4520e32862d2adfa2af042f0b5ea2041dee841
      Type: SafeTx
      Message:  baseGas: 0 · data: 0x · gasPrice: 0 · gasToken: 0x0…0 · nonce: 0 ·
                operation: 0 · refundReceiver: 0x0…0 · safeTxGas: 0 ·
                to: 0x70997970c51812dc3a010c7d01b50e0d17dc79c8 · value: 1
      Signing hash: 0xbddffaa9dbd6811dd56fd4c8be1c5191ddd4273a5991873ea279b7bf5d311156
  [2] Sign an OPAQUE 32-byte digest
      Purpose (claimed by the requester): Muster attestation (interim): …
      Digest: 0xa530324e94cc3be517314746c99f2c72c360efad54128d49c80a077f26807712
      This signer cannot show you what this authorises.
```

Leg 2 is the interim cost of §4, stated in the signer's own words; exo-149.6 removes it.
**Seen here, for K5:** the intents view marks the approval `mine: false`. muster's "is
this me" check knows only its own keystore's keys, not the `keystore_module` account
the member chose.

## 8. K5: the member's keystore_module account (2026-10-02)

- **Selecting.** `keystore_select(address)` makes a `keystore_module` account the one
  that approves this member's Safe intents. It is persisted (`keystoreAccount`), and it
  needs `keystore-backend = interim`.
- **The binding, signed once.** Selecting asks, once, for the account's F-14 binding:
  one digest leg over `linkDigest(enc identity, {account, slot "keystore_module",
  30 days})` (`wallet/keystore_identity.nim`). It is kept only if it recovers to the
  account, and is stored as `keystoreBinding`. `keystore_status` reports it as
  none / valid / expiring / expired / invalid.
- **Routing.** A Safe approval with no key ref goes through the selected account, and
  publishes the stored binding beside it. Readers check what a binding names
  (`approvedByMe`), not its context or expiry, so the one binding serves every room.
  Every member's view then counts the approval as this member's
  (`keystore_approval_test` §4).
- **"Mine" locally.** `myNames()` adds the selected account to the names this member's
  approvals carry. That covers `mine` and `approvedByMe`, readiness's authority check,
  and home's needs-you.
- **Settings.** Settings shows "Use for approvals" on each account, and the selected
  account's binding state.

**Verified end to end** by `scripts/keystore-approval-logoscore-test.sh` (logoscore
0.3.1, anvil, the real Safe):
1. Muster selects owner 0, and a person approves the binding in the signer
   (`binding: valid`).
2. A contribution with no key ref → `awaiting-approval`.
3. The person approves in the signer.
4. Muster publishes it as `collecting`. The approval reads `name: you, mine: true`.

**Found on the way:**
- `set_setting` before anything has loaded the module's settings saves the defaults
  over them. This is existing behaviour. The test now reads `settings` first, and
  `keystore_select` loads them before it saves.
- A self-call I had introduced in `myNames()` blew the stack. A SIGSEGV with no Nim
  traceback came from logos_host; `coredumpctl` showed the recursing frame.
