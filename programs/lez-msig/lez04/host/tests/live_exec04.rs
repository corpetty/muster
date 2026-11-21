//! The 0.4 executor's JSON surface (`exec::exec_request`, the contract Muster's prover seam and the
//! Logos module depend on) against a REAL LEZ v0.4 sequencer, exo-05f. Skipped unless MSIG_LIVE_RPC
//! and MSIG_LIVE_PROGRAM are set (see live_private04.rs). Each signature the payer makes is made
//! here, as Muster's keystore makes it, from the `sign` the executor answered; no key goes in:
//!   derive → topup (sign, send) → exec Create → fund (sign, send) → exec 1 of 2 (refused) →
//!   exec 2 of 3 → scan finds both newest notes.

use std::time::{Duration, Instant};

use lee::{PrivateKey, PublicKey, Signature};
use lee_core::account::AccountId;
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::exec::exec_request;
use sequencer_service_rpc::{RpcClient as _, SequencerClientBuilder};
use serde_json::{json, Value};

fn fund(rpc: &str, to: &AccountId, amount: u128, key: &PublicKey) {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .env("MUSTER_LEZ_VERSION", "v0.4.0-rc3")
        .args(["--zone", rpc, "fund", &hex::encode(to.as_ref()), &amount.to_string(), &hex::encode(key.value())])
        .output()
        .expect("run the zone's funder");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}

async fn ok(req: Value) -> Value {
    let a = exec_request(req).await;
    assert!(a.get("error").is_none(), "{a}");
    a
}

/// What the payer's keystore does with a `fund`/`topup` answer, then `send`.
async fn sign_and_send(rpc: &str, a: &Value, key: &PrivateKey) -> String {
    let hash: [u8; 32] = hex::decode(a["sign"].as_str().unwrap()).unwrap().try_into().unwrap();
    let sig = Signature::new(key, &hash);
    let pk = PublicKey::new_from_private_key(key);
    let sent = ok(json!({"mode": "send", "rpc": rpc, "message": a["message"], "proof": a["proof"],
                         "witnesses": [{"signature": hex::encode(sig.value), "publicKey": hex::encode(pk.value())}]})).await;
    sent["hash"].as_str().unwrap().to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn the_executor_drives_a_private_multisig_on_a_live_v04_zone() {
    let (Ok(rpc), Ok(program)) = (std::env::var("MSIG_LIVE_RPC"), std::env::var("MSIG_LIVE_PROGRAM")) else {
        eprintln!("skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let c = SequencerClientBuilder::default().build(&rpc).unwrap();
    let wait = std::env::var("MSIG_LIVE_WAIT_S").ok().and_then(|v| v.parse().ok()).unwrap_or(120u64);
    let base = json!({"rpc": rpc, "program": program, "gms": hex::encode(rand::random::<[u8; 32]>()),
                      "createKey": hex::encode(rand::random::<[u8; 32]>())});
    let req = |mode: &str, extra: Value| {
        let mut r = base.clone();
        r["mode"] = json!(mode);
        for (k, v) in extra.as_object().unwrap() {
            r[k] = v.clone();
        }
        r
    };
    // a note is on chain once the executor can prove over it again: poll with a derive-free read
    let landed = async |note_owner: &str, note: &str| {
        let deadline = Instant::now() + Duration::from_secs(wait);
        let owner: [u8; 32] = hex::decode(note_owner).unwrap().try_into().unwrap();
        let acc: lee_core::account::Account = borsh::from_slice(&hex::decode(note).unwrap()).unwrap();
        loop {
            let (p, _, _) = c.get_proofs_and_root(vec![lee_core::Commitment::new(&AccountId::new(owner), &acc)], vec![]).await.unwrap();
            if p[0].is_some() {
                return;
            }
            assert!(Instant::now() < deadline, "timed out waiting for a note");
            tokio::time::sleep(Duration::from_secs(3)).await;
        }
    };

    let d = ok(req("derive", json!({}))).await;
    let (account, fee_account) = (d["account"].as_str().unwrap().to_string(), d["feeAccount"].as_str().unwrap().to_string());
    let payer = PrivateKey::try_new(rand::random()).unwrap();
    let payer_pk = PublicKey::new_from_private_key(&payer);
    let payer_id = AccountId::from(&payer_pk);
    fund(&rpc, &payer_id, 40_000_000, &payer_pk);
    let deadline = Instant::now() + Duration::from_secs(wait);
    while c.get_account_balance(payer_id).await.unwrap_or(0) < 40_000_000 {
        assert!(Instant::now() < deadline, "timed out funding the payer");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    let nonce = async || c.get_accounts_nonces(vec![payer_id]).await.unwrap()[0].0.to_string();
    let pk = hex::encode(payer_pk.value());

    // top up the fee account; the payer signs
    let t = ok(req("topup", json!({"feeNote": null, "payerKey": pk, "payerNonce": nonce().await, "amount": "25000000"}))).await;
    sign_and_send(&rpc, &t, &payer).await;
    let mut fee_note = t["feePost"].as_str().unwrap().to_string();
    landed(&fee_account, &fee_note).await;
    eprintln!("topup: fee {} proved in {} ms", t["fee"], t["proveMs"]);

    // create
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let zone: Key = tagged(b"muster-msig/v1/zone", b"lez:local");
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let op = |i: &Instruction| hex::encode(borsh::to_vec(i).unwrap());
    let e = ok(req("exec", json!({"pre": null, "feeNote": fee_note, "op": op(&Instruction::Create { zone, config })}))).await;
    let mut note = e["post"].as_str().unwrap().to_string();
    fee_note = e["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    eprintln!("create: {} proved in {} ms", e["hash"], e["proveMs"]);

    // a deposit; the payer signs
    let f = ok(req("fund", json!({"pre": note, "feeNote": fee_note, "payerKey": pk, "payerNonce": nonce().await, "amount": "5000"}))).await;
    sign_and_send(&rpc, &f, &payer).await;
    note = f["post"].as_str().unwrap().to_string();
    fee_note = f["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    eprintln!("fund: proved in {} ms", f["proveMs"]);

    // a public payee; 1 of 2 is refused while proving, 2 of 3 pays
    let payee_pk = PublicKey::new_from_private_key(&PrivateKey::try_new(rand::random()).unwrap());
    let payee = AccountId::from(&payee_pk);
    fund(&rpc, &payee, 1, &payee_pk);
    let deadline = Instant::now() + Duration::from_secs(wait);
    while c.get_account_balance(payee).await.unwrap_or(0) != 1 {
        assert!(Instant::now() < deadline, "timed out funding the payee");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    let msig: Key = hex::decode(&account).unwrap().try_into().unwrap();
    let pay = Proposal { multisig: msig, zone, epoch: 0, nonce: 0, action: Action::Transfer { to: payee.as_ref().try_into().unwrap(), amount: 1_200 },
                         expires_ms: 9_000_000_000_000, proposer: s[0].key() };
    let exec = |who: &[usize]| Instruction::Execute { proposal: pay.clone(), approvals: who.iter().map(|&i| s[i].approve(&pay)).collect(), executor: None };
    let r = exec_request(req("exec", json!({"pre": note, "feeNote": fee_note, "op": op(&exec(&[0]))}))).await;
    assert_eq!(r["error"], "refused", "{r}");
    assert!(r["detail"].as_str().unwrap().contains("below-threshold"), "{r}");
    let e = ok(req("exec", json!({"pre": note, "feeNote": fee_note, "op": op(&exec(&[0, 1]))}))).await;
    note = e["post"].as_str().unwrap().to_string();
    fee_note = e["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    let deadline = Instant::now() + Duration::from_secs(wait);
    while c.get_account_balance(payee).await.unwrap_or(0) != 1_201 {
        assert!(Instant::now() < deadline, "timed out waiting for the payee's credit");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    eprintln!("pay 2 of 3: proved in {} ms", e["proveMs"]);

    // a member who lost both notes reads them back from the chain
    let sc = ok(req("scan", json!({}))).await;
    assert_eq!((sc["found"].as_bool(), sc["feeFound"].as_bool()), (Some(true), Some(true)));
    assert_eq!((sc["post"].as_str().unwrap(), sc["feePost"].as_str().unwrap()), (note.as_str(), fee_note.as_str()), "the newest notes");
    eprintln!("live_exec04: all passed");
}
