//! lez_msig_module on LEZ v0.4 (0.2.0; exo-cc7): lez-msig's private posture as a Logos module
//! (docs/design/lez-msig.md §6, RFP-005 U.1). The module-impl C ABI, the `LezMsigModule` trait and
//! `emit_job_done` are generated from `lez_msig_module.lidl` by logos-lidl-gen (`tools/regen.sh`; in
//! nix the builder writes its own copy). The work itself is `msig_host04::exec::exec_request`, the
//! same function the `msig_exec04` CLI runs. The v0.3 module (0.1.0) is `../../module`; the two
//! lines cannot share a dependency graph, so each is its own build of the same contract, and this
//! one adds `topup` and the fee account's notes (D17).
//!
//! It holds no key: a deposit's or a top-up's payer signs in their own keystore and `send` carries
//! the signature back. The group secret arrives with each request and lives only in its job, and a
//! job's answer (the multisig's decrypted note) is readable only by the caller that submitted it
//! and dropped by `forget`. A proof takes minutes, so `exec` answers at once with a job id; one
//! proof runs at a time, on its own thread, and `job_done` wakes the caller.

mod jobs;

mod generated {
    #![allow(warnings)]
    #![allow(clippy::all)]
    include!(concat!(env!("CARGO_MANIFEST_DIR"), "/../generated/provider_gen.rs"));
}
pub use generated::*;

use serde_json::{json, Value};

fn err(code: &str, detail: impl ToString) -> String {
    json!({"error": code, "detail": detail.to_string()}).to_string()
}

/// Who is asking, as the host's token names them: a job is bound to it.
fn caller() -> String {
    logos_rust_sdk::current_caller().identity()
}

#[derive(Default)]
pub struct LezMsigModuleImpl;

impl LezMsigModule for LezMsigModuleImpl {
    fn health(&mut self) -> String {
        json!({"ok": true, "busy": jobs::busy(), "prover": "local", "line": "v0.4",
               "devMode": std::env::var("RISC0_DEV_MODE").map(|v| !v.is_empty() && v != "0").unwrap_or(false),
               "programImageId": msig_host04::image_id_hex()})
        .to_string()
    }

    fn derive(&mut self, request_json: String) -> String {
        let Ok(mut req) = serde_json::from_str::<Value>(&request_json) else { return err("bad-request", "not JSON") };
        req["mode"] = json!("derive");
        jobs::run_now(req).to_string()
    }

    fn exec(&mut self, request_json: String) -> String {
        self.submit("exec", request_json)
    }

    fn fund(&mut self, request_json: String) -> String {
        self.submit("fund", request_json)
    }

    fn topup(&mut self, request_json: String) -> String {
        self.submit("topup", request_json)
    }

    fn scan(&mut self, request_json: String) -> String {
        self.submit("scan", request_json)
    }

    fn send(&mut self, request_json: String) -> String {
        let Ok(mut req) = serde_json::from_str::<Value>(&request_json) else { return err("bad-request", "not JSON") };
        req["mode"] = json!("send");
        jobs::run_now(req).to_string()
    }

    fn job(&mut self, job_id: String) -> String {
        jobs::read(&caller(), &job_id).to_string()
    }

    fn forget(&mut self, job_id: String) -> String {
        jobs::forget(&caller(), &job_id).to_string()
    }
}

impl LezMsigModuleImpl {
    fn submit(&mut self, mode: &str, request_json: String) -> String {
        let Ok(mut req) = serde_json::from_str::<Value>(&request_json) else { return err("bad-request", "not JSON") };
        for k in ["rpc", "program", "gms", "createKey"] {
            if req.get(k).and_then(Value::as_str).is_none() {
                return err("bad-request", format!("missing {k}"));
            }
        }
        req["mode"] = json!(mode);
        match jobs::spawn(caller(), req) {
            Some(id) => json!({"job": id}).to_string(),
            None => err("busy", "a proof is already running: try again when it is done"),
        }
    }
}

#[no_mangle]
pub extern "Rust" fn logos_module_install() {
    install::<LezMsigModuleImpl>();
}
