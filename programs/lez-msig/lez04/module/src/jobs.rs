//! The job table: one proof at a time, each on its own thread, each readable only by the caller
//! that submitted it. Nothing here is written to disk: a job holds the group secret until its
//! thread takes it, and its answer holds the multisig's decrypted note until `forget`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

struct Job {
    owner: String,
    state: &'static str, // proving | done | failed
    started_ms: u128,
    answer: Option<Value>,
}

static RUNNING: AtomicBool = AtomicBool::new(false);

fn table() -> &'static Mutex<HashMap<String, Job>> {
    static T: OnceLock<Mutex<HashMap<String, Job>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(HashMap::new()))
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

pub fn busy() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

/// A request that proves nothing (derive), answered on the calling thread.
pub fn run_now(req: Value) -> Value {
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt.block_on(msig_host04::exec::exec_request(req)),
        Err(e) => json!({"error": "failed", "detail": e.to_string()}),
    }
}

/// Start a proof for `owner`; None while another one runs.
pub fn spawn(owner: String, req: Value) -> Option<String> {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return None;
    }
    let id = hex::encode(rand::random::<[u8; 16]>());
    table().lock().unwrap().insert(id.clone(), Job { owner, state: "proving", started_ms: now_ms(), answer: None });
    let jid = id.clone();
    let started = std::thread::Builder::new().name("lez-msig-prove".into()).spawn(move || {
        // a prover panic fails this job, never the module
        let answer = std::panic::catch_unwind(|| run_now(req))
            .unwrap_or_else(|_| json!({"error": "failed", "detail": "the prover panicked"}));
        let state = if answer.get("error").is_some() { "failed" } else { "done" };
        if let Some(j) = table().lock().unwrap().get_mut(&jid) {
            j.state = state;
            j.answer = Some(answer);
        }
        RUNNING.store(false, Ordering::SeqCst);
        crate::emit_job_done(&jid, state);
    });
    if started.is_err() {
        RUNNING.store(false, Ordering::SeqCst);
        table().lock().unwrap().remove(&id);
        return None;
    }
    Some(id)
}

pub fn read(caller: &str, id: &str) -> Value {
    let t = table().lock().unwrap();
    match t.get(id) {
        Some(j) if j.owner == caller => {
            let mut v = json!({"job": id, "state": j.state, "startedMs": j.started_ms.to_string()});
            if let Some(a) = &j.answer {
                if let (Some(o), Some(src)) = (v.as_object_mut(), a.as_object()) {
                    for (k, x) in src {
                        o.insert(k.clone(), x.clone());
                    }
                }
            }
            v
        }
        _ => json!({"error": "unknown-job", "detail": "no job by that id for this caller"}),
    }
}

pub fn forget(caller: &str, id: &str) -> Value {
    let mut t = table().lock().unwrap();
    match t.get(id) {
        Some(j) if j.owner == caller && j.state != "proving" => {
            t.remove(id);
            json!({"ok": true})
        }
        Some(j) if j.owner == caller => json!({"error": "busy", "detail": "the job is still proving"}),
        _ => json!({"error": "unknown-job"}),
    }
}
