//! The private posture's executor (docs/design/lez-msig.md §6): one JSON request on stdin, one
//! JSON answer on stdout. Muster builds and signs everything it can (the proposal, the
//! approvals, the instruction's bytes); this proves the program's execution over the
//! multisig's private note and sends it, because proving needs LEZ's own Rust prover.
//!
//! Requests (every hex string lowercase, no 0x):
//!   {"mode":"derive","program","gms","createKey"}
//!       → {"account"}: the multisig's private PDA, which only a holder of the group secret can
//!         derive (its keys are part of the address).
//!   {"mode":"exec","rpc","program","gms","createKey","pre":<Account borsh> | null,"op":<msig_core::Instruction borsh>}
//!       → {"hash","post":<Account borsh>,"account","proveMs"}: proved against the chain's
//!         membership proof for `pre` (null for Create, an Init) and sent. `post` is the new
//!         note in plaintext, as a member decrypts it. Muster carries it, sealed, in the room,
//!         so every member can execute next without scanning the chain.
//!   {"mode":"fund","rpc","program","gms","createKey","pre","payerKey","payerNonce","amount"}
//!       → {"sign","payer","message","proof","post","account","root","proveMs"}: a deposit from
//!         the payer's public account, proved but not sent. The payer signs `sign` (BIP-340 over
//!         the message's hash) in their own keystore; nothing here holds a key.
//!   {"mode":"scan","rpc","program","gms","createKey","from"?} → {"found","post","block","hash","scanned"}:
//!         the multisig's newest note, read from the chain with the group's viewing key.
//!   {"mode":"send","rpc","message","proof","witnesses":[{"signature","publicKey"}]} → {"hash"}:
//!         a proved message sent with its signatures, each checked first.
//!
//! The public posture, key-free, for integrators without Muster (`msig_host::public`,
//! docs/design/lez-msig-signing.md; README "Use it without Muster"):
//!   {"mode":"state","rpc","program","createKey"} → the multisig's state, decoded
//!   {"mode":"propose",…,"action","proposer","expiresMs"} → {"proposal","proposalId","approveMsg",…}
//!   {"mode":"spend",…,"limit","to","amount","expiresMs"} → {"spend","spendMsg",…}
//!   {"mode":"check",…,instruction} → {"ok"} or {"ok":false,"refusal"}: the program's own verdict
//!   {"mode":"prepare",…,instruction,"payerKey"} → {"sign","message"}: unsigned, for the payer
//!   {"mode":"send_public","rpc","message","witnesses"} → {"hash"}
//! Errors: {"error","detail"}. A refusal the program makes surfaces as its MsigError code at
//! proving time, before anything is sent (RFP U.7).
//!
//! `RISC0_DEV_MODE` decides whether proofs are real; a dev-mode zone accepts dev receipts only.

use std::io::Read;

use serde_json::{json, Value};

#[tokio::main]
async fn main() {
    let mut input = String::new();
    let answer = match std::io::stdin().read_to_string(&mut input) {
        Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
        Ok(_) => match serde_json::from_str::<Value>(&input) {
            Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
            Ok(req) => msig_host::exec::exec_request(req).await,
        },
    };
    println!("{answer}");
}
