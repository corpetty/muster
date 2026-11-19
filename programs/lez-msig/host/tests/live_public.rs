//! The public posture through the module's key-free operations only (RFP-005 U.1, roadmap M2;
//! docs/design/lez-msig-signing.md), against a REAL LEZ v0.3 sequencer. This is an integrator's
//! journey with no Muster: every key stays outside, and every signature is made by the test the
//! way an HSM or an MPC system would make it, over the bytes the module returns.
//!   1. prepare + send_public: Create a 2-of-3, paid by a throwaway account the funder pays;
//!   2. state: the config as written, at epoch 0;
//!   3. propose a payment; check refuses one approval (below threshold); two approvals pass;
//!      prepare + send_public: Execute; state: the nonce is spent and the payee is paid;
//!   4. a config change adds a spending limit; spend: one of its signers alone, as one Spend;
//!   5. send_public refuses a signature that is not over the message.
//! Skipped unless MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM name a zone and its deployed program:
//!
//!   infra/lez/localnet.sh; infra/lez/localnet.sh deploy <msig.bin>
//!   MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> \
//!     cargo test -p msig_host --test live_public -- --nocapture

use std::time::{Duration, Instant};

use lee::{PrivateKey, PublicKey, Signature};
use lee_core::account::AccountId;
use msig_core::sign::Signer;
use msig_core::*;
use msig_host::exec::exec_request;
use sequencer_service_rpc::{RpcClient as _, SequencerClientBuilder};
use serde_json::{json, Value};

async fn call(req: Value) -> Value {
    let r = exec_request(req.clone()).await;
    assert!(r.get("error").is_none(), "{} refused: {r}", req["mode"]);
    r
}

fn h(b: &[u8]) -> String {
    hex::encode(b)
}

/// Sign a prepared message as its payer, outside the module, and send it.
async fn pay_and_send(rpc: &str, prepared: &Value, payer: &PrivateKey) -> String {
    let hash: [u8; 32] = hex::decode(prepared["sign"].as_str().unwrap()).unwrap().try_into().unwrap();
    let sig = Signature::new(payer, &hash);
    let r = call(json!({"mode": "send_public", "rpc": rpc, "message": prepared["message"],
                        "witnesses": [{"signature": h(&sig.value), "publicKey": h(PublicKey::new_from_private_key(payer).value())}]}))
    .await;
    r["hash"].as_str().unwrap().to_string()
}

async fn until(what: &str, mut cond: impl AsyncFnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(90);
    while !cond().await {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn public_multisig_through_the_module_only() {
    let (Ok(rpc), Ok(program)) = (std::env::var("MSIG_LIVE_RPC"), std::env::var("MSIG_LIVE_PROGRAM")) else {
        eprintln!("skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let c = SequencerClientBuilder::default().build(&rpc).unwrap();
    let ck: Key = rand::random();
    let base = json!({"rpc": rpc, "program": program, "createKey": h(&ck)});
    let with = |extra: Value| {
        let mut v = base.clone();
        for (k, x) in extra.as_object().unwrap() {
            v[k] = x.clone();
        }
        v
    };

    // the payer: a throwaway public account the zone's funder pays
    let payer = PrivateKey::try_new(rand::random()).unwrap();
    let payer_pk = PublicKey::new_from_private_key(&payer);
    let payer_id = AccountId::from(&payer_pk);
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .args(["--zone", &rpc, "fund", &h(payer_id.as_ref()), "10000000000"])
        .output()
        .expect("run the zone's funder");
    assert!(out.status.success(), "the funder could not pay: {}", String::from_utf8_lossy(&out.stderr));
    until("the payer's funds", async || c.get_account_balance(payer_id).await.unwrap() > 0).await;

    // 1. create, through prepare + send_public
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let zone = h(&tagged(b"muster-msig/v1/zone", b"lez:local"));
    let config = json!({"members": s.iter().map(|x| json!({"key": h(&x.key()), "roles": role::ALL, "weight": 1})).collect::<Vec<_>>(),
                        "threshold": 2});
    let prepared = call(with(json!({"mode": "prepare", "kind": "create", "zone": zone, "config": config,
                                    "payerKey": h(payer_pk.value())}))).await;
    pay_and_send(&rpc, &prepared, &payer).await;
    let st = async || exec_request(with(json!({"mode": "state"}))).await;
    until("the multisig on chain", async || st().await["found"] == json!(true)).await;
    eprintln!("1. created through prepare + send_public; the payer signed outside the module");

    // 2. state
    let s0 = st().await;
    assert_eq!(s0["epoch"], "0");
    assert_eq!(s0["config"]["threshold"], 2);
    assert_eq!(s0["config"]["members"].as_array().unwrap().len(), 3);
    let vault = s0["account"].as_str().unwrap().to_string();
    let out = std::process::Command::new(script).args(["--zone", &rpc, "fund", &vault, "5000"]).output().unwrap();
    assert!(out.status.success());
    until("the funded vault", async || st().await["balance"] == "5000").await;
    eprintln!("2. state reads the config at epoch 0, and the funded vault");

    // 3. propose, check, execute
    let payee: Key = rand::random();
    let p = call(with(json!({"mode": "propose", "action": {"kind": "transfer", "to": h(&payee), "amount": "1200"},
                             "proposer": h(&s[0].key()), "expiresMs": "9000000000000"}))).await;
    let approve: Key = hex::decode(p["approveMsg"].as_str().unwrap()).unwrap().try_into().unwrap();
    let sig = |i: usize| { let x = s[i].sign(&approve); json!({"key": h(&x.key), "sig": h(&x.sig)}) };
    let one = call(with(json!({"mode": "check", "kind": "execute", "proposal": p["proposal"], "approvals": [sig(0)]}))).await;
    assert_eq!(one["ok"], false);
    assert!(one["refusal"].as_str().unwrap().starts_with("below-threshold"), "{one}");
    let two = json!([sig(0), sig(1)]);
    let ok = call(with(json!({"mode": "check", "kind": "execute", "proposal": p["proposal"], "approvals": two}))).await;
    assert_eq!(ok["ok"], true, "{ok}");
    let prepared = call(with(json!({"mode": "prepare", "kind": "execute", "proposal": p["proposal"], "approvals": two,
                                    "payerKey": h(payer_pk.value())}))).await;
    pay_and_send(&rpc, &prepared, &payer).await;
    let payee_id = AccountId::new(payee);
    until("the payment", async || c.get_account_balance(payee_id).await.unwrap() == 1200).await;
    let s1 = st().await;
    assert!(!s1["freeNonces"].as_array().unwrap().contains(&json!(p["nonce"])), "the nonce is spent");
    eprintln!("3. propose → check (1 of 2 refused, 2 of 3 pass) → prepare + send_public: the program paid");

    // 4. a spending limit, then a spend by one of its signers alone
    let limit = json!({"id": 1, "signers": [h(&s[2].key())], "threshold": 1, "amount": "1000", "periodMs": "3600000"});
    let p2 = call(with(json!({"mode": "propose", "action": {"kind": "config", "changes": [{"change": "add-limit", "limit": limit}]},
                              "proposer": h(&s[1].key()), "expiresMs": "9000000000000"}))).await;
    let approve2: Key = hex::decode(p2["approveMsg"].as_str().unwrap()).unwrap().try_into().unwrap();
    let a2: Vec<Value> = [1, 2].iter().map(|&i| { let x = s[i].sign(&approve2); json!({"key": h(&x.key), "sig": h(&x.sig)}) }).collect();
    let prepared = call(with(json!({"mode": "prepare", "kind": "execute", "proposal": p2["proposal"], "approvals": a2,
                                    "payerKey": h(payer_pk.value())}))).await;
    pay_and_send(&rpc, &prepared, &payer).await;
    until("the limit", async || st().await["epoch"] == "1").await;
    let now_ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    let sp = call(with(json!({"mode": "spend", "limit": 1, "to": h(&payee), "amount": "400", "expiresMs": "9000000000000",
                              "nowMs": now_ms.to_string()}))).await;
    let spend_msg: Key = hex::decode(sp["spendMsg"].as_str().unwrap()).unwrap().try_into().unwrap();
    let x = s[2].sign(&spend_msg);
    let spend_req = json!({"kind": "spend", "spend": sp["spend"], "approvals": [{"key": h(&x.key), "sig": h(&x.sig)}],
                           "period": sp["period"], "periodMs": sp["periodMs"]});
    let mut chk = with(spend_req.clone());
    chk["mode"] = json!("check");
    assert_eq!(call(chk).await["ok"], true);
    let mut prep = with(spend_req);
    prep["mode"] = json!("prepare");
    prep["payerKey"] = json!(h(payer_pk.value()));
    let prepared = call(prep).await;
    pay_and_send(&rpc, &prepared, &payer).await;
    until("the spend", async || c.get_account_balance(payee_id).await.unwrap() == 1600).await;
    eprintln!("4. a limit added by the quorum; one of its signers spent under it alone");

    // 5. a signature over something else is refused before sending
    let bad = Signature::new(&payer, &[7u8; 32]);
    let r = exec_request(json!({"mode": "send_public", "rpc": rpc, "message": prepared["message"],
                                "witnesses": [{"signature": h(&bad.value), "publicKey": h(payer_pk.value())}]})).await;
    assert!(r["detail"].as_str().unwrap_or("").starts_with("bad-signature"), "{r}");
    eprintln!("5. send_public refuses a signature that is not over the message");
}
