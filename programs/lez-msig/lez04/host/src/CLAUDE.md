# lez04/host/src/

`msig_host04`: one multisig at its placement, `Msig`.
- Public posture: the account, the envelope, the public actors a transaction declares, admission
  evidence for a fresh public PDA, the public message.
- Private posture (exo-05f): `Msig::private` derives the PDA's keys and the fee account's (D17,
  `fee_derivation_id`) from the group secret.
  - `private_tx` proves an instruction over the PDA; `deposit_tx` proves a public account's
    deposit into the vault.
  - Each pays its fee in the proof from the fee account, witnessed `FeeOnly` (`PrivateFee`).
  - `decrypt` / `decrypt_fee` read the new notes back. A note's commitment is not in the same
    `PrivateAction` as its ciphertext, so a decrypted account is matched against every commitment
    the transaction makes.
- `vault_balance`, `native_state`.
