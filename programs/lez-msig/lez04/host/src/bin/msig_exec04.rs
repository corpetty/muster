//! The private posture's executor on LEZ v0.4 as a CLI: one JSON request on stdin, one JSON answer
//! on stdout, through `msig_host04::exec::exec_request` (the requests are documented there). Muster's
//! `CliMsigProver` runs it in tests without a Logos host; the Logos module calls the same function.
//! `RISC0_DEV_MODE` decides whether proofs are real; only a dev-mode zone accepts dev receipts.

use std::io::Read;

use serde_json::{json, Value};

#[tokio::main]
async fn main() {
    let mut input = String::new();
    let answer = match std::io::stdin().read_to_string(&mut input) {
        Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
        Ok(_) => match serde_json::from_str::<Value>(&input) {
            Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
            Ok(req) => msig_host04::exec::exec_request(req).await,
        },
    };
    println!("{answer}");
}
