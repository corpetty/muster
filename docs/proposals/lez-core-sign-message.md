# Issue: domain-separated message signing in lez_core

Status: **filed 2026-10-24** as
[logos-blockchain/logos-execution-zone-module#73](https://github.com/logos-blockchain/logos-execution-zone-module/issues/73),
after the operator's review. The text below is what was filed. As of 2026-11-26 the issue is
open with no reply, so the questions at its end are still unanswered.

---

**Title:** Sign a domain-separated message with a wallet account (with the person's approval)

**Summary.** `lez_core` signs only transactions it builds itself: the `transfer_*` methods,
`send_generic_public_transaction` and `send_program_deployment_transaction`. A module that needs
an account to sign *something other than a transaction* cannot use a LEZ Wallet account. Examples:
- an approval that a LEZ program verifies at execution;
- proof that an account belongs to a person.

We propose one method, for one domain-separated message per call, approved by the person in the
wallet.

**Why.** [Muster](https://github.com/corpetty/muster) runs M-of-N multisigs on LEZ (RFP-005,
`lez-msig`). Members approve off chain, and the program verifies every approval, a BIP-340
signature, when it executes. Today those approval keys live in Muster's own keystore. People
would rather approve with the LEZ Wallet account they already hold and back up with their
recovery phrase, and a hardware signer would later fit behind the same call. Other programs
that check signatures in the guest have the same need: allowlists, permits, vouchers.

**The safety problem a naive method would create.** A LEZ public transaction is authorized by a
BIP-340 signature over the 32-byte hash `SHA-256("/LEE/v0.3/Message/Public/…" ‖ borsh(message))`.
A method that signs *any* 32 bytes the caller supplies would therefore let any caller obtain a
signature over a transaction hash, that is, a transfer. The method must make that impossible
by construction.

**Proposal.**

```
sign_message(account_id_hex: tstr, domain: tstr, message_hex: tstr) -> tstr
  → { ok, signature, public_key, digest } | { ok: false, error, detail }
```

- **What is signed:** `digest = tagged_hash("LEZ/signed-message/v1", len(domain) ‖ domain ‖ message)`
  (BIP-340's tagged hash, with a length prefix on `domain`). The tag differs from every
  transaction-hash prefix, so a message signature can never be a transaction signature, and
  `domain` separates one use from another (e.g. `muster-msig/v2/approve`).
- **Scheme:** BIP-340 Schnorr with the account's public key, the scheme a guest program can
  already verify with the accelerated `k256`.
- **Approval:** each call asks the person in the wallet UI. The prompt shows the calling module,
  the domain, the account, and the message (hex, plus a decoded summary when the caller
  supplies one; see below). The call returns a handle at once, as `keystore_module`'s
  `request_approval` / `approval_status` / `fetch_result` do. A signature must never wait inside
  one `lp_invoke`.
- **Optional `summary_json`:** a human summary the caller wants shown, displayed as "the app
  says", never as verified.
- **Public accounts only.** A private account's keys never sign this.
- **Never a key getter**, and no raw-digest variant.

**What we'd change on our side.** The program would verify approvals over this digest, a new
version of its signing tags, alongside Muster's own keystore keys for people without a LEZ
Wallet.

**Questions for the maintainers.**
1. Is `LEZ/signed-message/v1` (or another tag) acceptable as the wallet-wide message domain?
2. Should the approval flow live in `lez_core` (as in `keystore_module`), or in the wallet UI
   module calling back into it?
3. Is a capability or allowlist needed so only approved modules may request signatures?
4. Would you take a PR for this once the shape is agreed?
