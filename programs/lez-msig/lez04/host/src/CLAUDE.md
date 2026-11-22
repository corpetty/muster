# lez04/host/src/

`msig_host04`: one multisig at its placement, `Msig`.
- Public posture: the account, the envelope, the public actors a transaction declares, admission
  evidence for a fresh public PDA, the public message.
- Private posture (exo-05f): `Msig::private` derives the PDA's keys and the fee account's (D17,
  `fee_derivation_id`) from the group secret.
  - `private_tx` proves an instruction over the PDA; `private_tx_sealed` pays private payees, each
    credit to one of the given `Recipient`s sealed to it and published; `deposit_tx` proves a public account's
    deposit into the vault.
  - Each pays its fee in the proof from the fee account, witnessed `FeeOnly` (`PrivateFee`).
  - `top_up_fee_tx` proves a public account's top-up of the fee account, which pays that
    transaction's own fee out of the credit, so a group needs no funds to start.
  - `decrypt` / `decrypt_fee` read the new notes back. A note's commitment is not in the same
    `PrivateAction` as its ciphertext, so a decrypted account is matched against every commitment
    the transaction makes.
- `with_undisclosed(header, proof)` (D18): private executions claim only that some immutable
  program ran, against the header's mirror commitment.
- `Proven` holds a proof unsigned: `hash()` is what a public payer signs in its own keystore,
  `signed(keys)` / `with_signatures(sigs)` make the transaction.
- `fee_inbox`, `private_reserve` (LEZ's private fee at the next block's ceilings),
  `vault_balance`, `native_state`.
- `exec.rs`: `exec_request(json) -> json`, the executor on 0.4. It has v0.3's surface (derive / exec /
  fund / scan / send) plus `feeNote` → `feePost` and a `topup` mode; it prices the fee from
  `getFeeState` and proves undisclosed when the program is immutable. `bin/msig_exec04` is its CLI.
