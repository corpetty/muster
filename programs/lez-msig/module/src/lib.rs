//! lez_msig_module: lez-msig as a Logos module: the private posture's prover, and the public
//! posture's key-free operations for integrators without Muster (docs/design/lez-msig.md §6,
//! RFP-005 U.1). The module-impl C ABI, the `LezMsigModule` trait and `emit_job_done` are
//! generated from `lez_msig_module.lidl` by logos-lidl-gen (`tools/regen.sh`; in nix the builder
//! writes its own copy). The work itself is `msig_host::exec::exec_request`, the same function the
//! `msig_exec` CLI runs.
//!
//! It holds no key: a deposit's payer signs in their own keystore and `send` carries the
//! signature back. The group secret arrives with each request and lives only in its job, and a
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
        json!({"ok": true, "busy": jobs::busy(), "prover": "local",
               "devMode": std::env::var("RISC0_DEV_MODE").map(|v| !v.is_empty() && v != "0").unwrap_or(false),
               "programImageId": msig_host::image_id_hex()})
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

    fn scan(&mut self, request_json: String) -> String {
        self.submit("scan", request_json)
    }

    fn send(&mut self, request_json: String) -> String {
        let Ok(mut req) = serde_json::from_str::<Value>(&request_json) else { return err("bad-request", "not JSON") };
        req["mode"] = json!("send");
        jobs::run_now(req).to_string()
    }

    // ── the public posture without Muster (RFP-005 U.1, roadmap M2): no proof, no key ──
    fn state(&mut self, request_json: String) -> String {
        self.now("state", request_json)
    }

    fn propose(&mut self, request_json: String) -> String {
        self.now("propose", request_json)
    }

    fn spend(&mut self, request_json: String) -> String {
        self.now("spend", request_json)
    }

    fn check(&mut self, request_json: String) -> String {
        self.now("check", request_json)
    }

    fn prepare(&mut self, request_json: String) -> String {
        self.now("prepare", request_json)
    }

    fn send_public(&mut self, request_json: String) -> String {
        self.now("send_public", request_json)
    }

    fn job(&mut self, job_id: String) -> String {
        jobs::read(&caller(), &job_id).to_string()
    }

    fn forget(&mut self, job_id: String) -> String {
        jobs::forget(&caller(), &job_id).to_string()
    }
}

impl LezMsigModuleImpl {
    /// A request answered at once: a chain read, an encoding, or a send. Never a proof.
    fn now(&mut self, mode: &str, request_json: String) -> String {
        let Ok(mut req) = serde_json::from_str::<Value>(&request_json) else { return err("bad-request", "not JSON") };
        req["mode"] = json!(mode);
        jobs::run_now(req).to_string()
    }

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
