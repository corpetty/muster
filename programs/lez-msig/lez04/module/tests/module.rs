//! lez_msig_v04_module 0.2.0 (LEZ v0.4) through its own trait, with no host: health and derive at
//! once, and (when MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM name a v0.4 zone) a fee-account top-up as a
//! job: topup answers with a job id at once, a second one meanwhile is "busy", and the job ends
//! with what the payer signs and the fee account's new note. The payer is funded by the zone's
//! funder (infra/lez/funder.sh), and nothing is signed or sent here.
//!
//!   MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> RISC0_DEV_MODE=1 \
//!     cargo test -p lez_msig_v04_module -- --nocapture

use lez_msig_v04_module::{LezMsigModuleImpl, LezMsigV04Module};
use serde_json::{json, Value};

fn j(s: String) -> Value {
    serde_json::from_str(&s).unwrap()
}

#[test]
fn health_derive_and_a_fee_top_up_as_a_job() {
    let mut m = LezMsigModuleImpl::default();
    let h = j(m.health());
    assert_eq!(h["ok"], true);
    assert_eq!(h["programImageId"].as_str().unwrap(), msig_host04::image_id_hex());

    let program = std::env::var("MSIG_LIVE_PROGRAM").unwrap_or_else(|_| "11".repeat(32));
    let gms = hex::encode(rand::random::<[u8; 32]>());
    let ck = hex::encode(rand::random::<[u8; 32]>());
    let d = j(m.derive(json!({"program": program, "gms": gms, "createKey": ck}).to_string()));
    assert_eq!(d["account"].as_str().unwrap().len(), 64, "{d}");
    assert_eq!(d["feeAccount"].as_str().unwrap().len(), 64, "the group's fee account: {d}");
    assert_eq!(h["line"], "v0.4");
    assert_eq!(j(m.derive("nope".into()))["error"], "bad-request");
    assert_eq!(j(m.exec(json!({"program": program}).to_string()))["error"], "bad-request");
    assert_eq!(j(m.fund(json!({}).to_string()))["error"], "bad-request");
    assert_eq!(j(m.send(json!({"rpc": "http://127.0.0.1:1", "message": "00", "proof": "00", "witnesses": []}).to_string()))["error"],
               "failed", "an unreadable message is refused before anything is sent");

    let Ok(rpc) = std::env::var("MSIG_LIVE_RPC") else {
        eprintln!("live part skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let payer = lee::PrivateKey::try_new(rand::random()).unwrap();
    let pk = lee::PublicKey::new_from_private_key(&payer);
    let payer_id = lee_core::account::AccountId::from(&pk);
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .env("MUSTER_LEZ_VERSION", "v0.4.0-rc3")
        .args(["--zone", &rpc, "fund", &hex::encode(payer_id.as_ref()), "20000000", &hex::encode(pk.value())])
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let c = sequencer_service_rpc::SequencerClientBuilder::default().build(&rpc).unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    use sequencer_service_rpc::RpcClient as _;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
    while rt.block_on(c.get_account_balance(payer_id)).unwrap_or(0) == 0 {
        assert!(std::time::Instant::now() < deadline, "the payer was never funded");
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    let req = json!({"rpc": rpc, "program": program, "gms": gms, "createKey": ck, "feeNote": null,
                     "payerKey": hex::encode(pk.value()), "payerNonce": "0", "amount": "10000000"});
    let started = std::time::Instant::now();
    let r = j(m.topup(req.to_string()));
    let id = r["job"].as_str().expect("a job id at once").to_string();
    assert!(started.elapsed().as_secs() < 2, "topup answers at once");
    assert_eq!(j(m.topup(req.to_string()))["error"], "busy", "one proof at a time");
    let done = loop {
        let v = j(m.job(id.clone()));
        if v["state"] != "proving" { break v; }
        std::thread::sleep(std::time::Duration::from_millis(500));
    };
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(done["feeAccount"], d["feeAccount"], "the note is the derived fee account's");
    assert_eq!(done["sign"].as_str().unwrap().len(), 64, "a hash for the payer to sign");
    assert!(done["feePost"].as_str().unwrap().len() > 64 && done["message"].as_str().is_some() && done["proof"].as_str().is_some());
    assert_eq!(j(m.job("ab".repeat(16)))["error"], "unknown-job");
    assert_eq!(j(m.forget(id.clone()))["ok"], true);
    assert_eq!(j(m.job(id))["error"], "unknown-job", "forgotten, the note with it");
    eprintln!("a fee-account top-up as a job: {:?}", started.elapsed());
}
