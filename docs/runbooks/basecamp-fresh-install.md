# Runbook: Muster in Basecamp, from nothing

**As of 2026-10-03 (exo-d4d, branch `feat/evm-endpoint`).** Two people, each on their own
machine, each with a fresh Logos Basecamp 0.3.1, split a bill on Sepolia. Nothing is seeded:
no environment variables, no anvil, no keys muster made. Every label below was read on
screen in the release on 2026-10-03; the code wins over this page. Steps not yet run by two
people on two machines are marked **first run**.

Muster is pre-release: a split with no chain named settles on a test chain (Sepolia first).
Do not put real money on it.

## 0. Install

1. Install **Logos Basecamp 0.3.1** (the AppImage on Linux).
2. From the default catalog, install: **Keystore** (`evm_keystore_ui`), **Signer**
   (`evm_signer_ui`), **Ethereum RPC** (`eth_rpc_ui`). Their modules come with them
   (`keystore_module`, `eth_rpc_module`, `tx_sender_module`, `fee_module`).
3. Install Muster's two packages, `muster_module` then `muster_ui`, with Package Manager →
   install local. A local install resolves no dependencies, so the catalog modules go first.

A developer can do 0 in one command, into an isolated profile:
`scripts/basecamp-profile.sh <name> --fresh` (add `--xvfb :N` for a machine with no screen).

## 1. Your account and your chains

Open **Muster**. Home says **Set up an Ethereum account** until you have one.

1. **Create or import an account.** Basecamp asks "Muster wants to evm.accounts.manage" →
   Open. In **Keystore**: Create → write the 12 words down → confirm words 1, 5 and 12 → a
   vault password → Create account. Muster never sees the phrase or the password.
2. Back in Muster, Home says **Choose the account Muster approves with** → Open Settings →
   **Use for approvals** on your account.
3. Basecamp asks "Muster wants to evm.signing.approve" → Open. The **Signer** shows
   "Requested by: muster_module · Link this account to your Muster identity". Type the vault
   password → Approve. You are back in Muster; Settings reads "Approvals go through the
   selected account, linked to your Muster identity", and Home's setup card is gone.
4. **Chains.** Settings → Ethereum chains → **Open chain settings** opens Ethereum RPC.
   Sepolia is there by default (on publicnode.com); change the endpoint if you run your own.
   Turning on the light-client verified proxy there makes balances proven, not trusted.
5. Fund your account with a little Sepolia ETH from a faucet (the debtor needs the share plus
   gas; ~0.05 is plenty).

## 2. A room

Alice: **Start something** → **Split a bill** → people → (the invite reaches Bob's inbox).
Bob: Home → the invitation → **Join**. Alice admits him. **first run** across two machines
on the platform build; the same steps ran on one machine over the fleet (`client-tour.md` §1).

## 3. The split

1. Alice proposes: total, who's in, a memo. The chain is Sepolia unless she names another;
   she is paid at her keystore account.
2. Bob opens the card → **Agree to my share** (his room key, no signer prompt).
3. Bob → **Pay my share**. The Signer comes forward: "Requested by: tx_sender_module ·
   Pay my share of '<memo>', agreed in a Muster room [asked by muster_module]", one
   transaction on Sepolia to Alice's address for exactly the share. Vault password → Approve.
4. Muster broadcasts through Basecamp's one sender, Bob's card names the transaction; Alice's
   client reads it through **her** chain settings and confirms. **Final** on both.

What was verified before this ran on two machines: steps 1, 1.1–1.3 on the release's
screen (`docs/labbook/muster-in-basecamp-031.md`), and 3.1–3.4 headless with the real
modules against a local chain, Safe settle and a wallet send included
(`scripts/split-platform-logoscore-test.sh`).

## Known rough edges

- Basecamp's sidebar order of installed apps changes between launches: find an app by its tab.
- A muster restart while a payment waits in the Signer keeps the payment in flight; a
  **tx_sender** restart loses it, and the share reads unpaid (it can be paid again; it cannot
  be paid twice).
- Balances read "attested" even when the verified proxy proved them (exo-d4d.9).
- Approving a Safe intent shows the Signer an opaque digest beside the transaction until the
  typed attestation lands (exo-149.6); that is why approvals route to the keystore only on
  test chains for now.
