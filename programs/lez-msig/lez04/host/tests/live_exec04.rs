//! The 0.4 executor's JSON surface (`exec::exec_request`, the contract Muster's prover seam and the
//! Logos module depend on) against a REAL LEZ v0.4 sequencer, exo-05f. Skipped unless MSIG_LIVE_RPC
//! and MSIG_LIVE_PROGRAM are set (see live_private04.rs). Each signature the payer makes is made
//! here, as Muster's keystore makes it, from the `sign` the executor answered; no key goes in:
//!   derive → topup (sign, send) → exec Create (the vault's recovery binding) → fund (sign, send) →
//!   an outsider pays the vault publicly; inbound lists it → exec 1 of 2 (refused) →
//!   exec 2 of 3, collecting the outsider's deposit → exec 2 of 3 to a PRIVATE payee (recipients): its credit sealed, found and opened
//!   by the payee alone, and claimed in its own transaction, the fee out of the credit → scan
//!   finds both newest notes.

use std::time::{Duration, Instant};

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, Recipient, Signature};
use lee_core::{program::Publication, PrivateAccountKind};
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
    fund(&rpc, &payer_id, 80_000_000, &payer_pk);
    let deadline = Instant::now() + Duration::from_secs(wait);
    while c.get_account_balance(payer_id).await.unwrap_or(0) < 80_000_000 {
        assert!(Instant::now() < deadline, "timed out funding the payer");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    let nonce = async || c.get_accounts_nonces(vec![payer_id]).await.unwrap()[0].0.to_string();
    let pk = hex::encode(payer_pk.value());

    // top up the fee account; the payer signs
    let t = ok(req("topup", json!({"feeNote": null, "payerKey": pk, "payerNonce": nonce().await, "amount": "40000000"}))).await;
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
    let f = ok(req("fund", json!({"pre": note, "feeNote": fee_note, "payerKey": pk, "payerNonce": nonce().await, "amount": "15000000"}))).await;
    sign_and_send(&rpc, &f, &payer).await;
    note = f["post"].as_str().unwrap().to_string();
    fee_note = f["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    eprintln!("fund: proved in {} ms", f["proveMs"]);

    // anyone pays the vault's address from a public account (here the test's own funded account):
    // Create registered the vault's recovery binding, so the credit is published for the group. The
    // vault is left undeclared: it is no public account. LEZ's wallet CLI cannot send this (it
    // declares a `--to` public), so the transaction is built here.
    {
        let vault = AccountId::new(hex::decode(&account).unwrap().try_into().unwrap());
        let root = lee_core::account::Actor::native_balance(payer_id);
        let q = c.get_fee_state().await.unwrap();
        let gas = 200_000u64;
        let fee = lee::fees::FeeDeclaration { payer: payer_id, gas_limit: gas, tip: 0,
                                              max_fee: (gas as u128 + 2_000) * q.next_base_fee_exec_ceiling.max(q.next_base_fee_stor_ceiling) as u128 * 2 };
        let message = lee::program::Program::serialize_message(lee_core::native_token::Message::Transfer { to: vault, amount: 3_000 }).unwrap();
        let n = c.get_accounts_nonces(vec![payer_id]).await.unwrap()[0];
        let msg = lee::public_transaction::Message::new(root, message, [root], std::collections::BTreeMap::from([(payer_id, n)]), Some(fee), vec![]);
        let tx = lee::PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[&payer]));
        c.send_transaction(common::transaction::LeeTransaction::Public(tx)).await.expect("the outsider's payment is sent");
    }
    let deadline = Instant::now() + Duration::from_secs(wait);
    let deposit = loop {
        let d = ok(req("inbound", json!({}))).await;
        if let Some(x) = d["deposits"].as_array().and_then(|a| a.first()).cloned() {
            break x;
        }
        assert!(Instant::now() < deadline, "timed out waiting for the outsider's deposit");
        tokio::time::sleep(Duration::from_secs(3)).await;
    };
    assert_eq!(deposit["amount"], "3000");
    eprintln!("inbound: {deposit}");

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
    let e = ok(req("exec", json!({"pre": note, "feeNote": fee_note, "op": op(&exec(&[0, 1])),
                                  "collect": [deposit["position"].clone()]}))).await;
    assert_eq!(e["collected"], json!([deposit["position"].clone()]));
    let vault: lee_core::account::Account = borsh::from_slice(&hex::decode(e["post"].as_str().unwrap()).unwrap()).unwrap();
    assert_eq!(msig_host04::vault_balance(&vault), 15_000_000 + 3_000 - 1_200, "the outsider's deposit collected, the payment made");
    note = e["post"].as_str().unwrap().to_string();
    fee_note = e["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    let deadline = Instant::now() + Duration::from_secs(wait);
    while c.get_account_balance(payee).await.unwrap_or(0) != 1_201 {
        assert!(Instant::now() < deadline, "timed out waiting for the payee's credit");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    eprintln!("pay 2 of 3: proved in {} ms", e["proveMs"]);

    // a private payee: the credit is sealed to it, and it alone opens and claims it
    let payee = GroupKeyHolder::new().derive_regular_shared_account_keys(&rand::random());
    let to = Recipient { npk: payee.generate_nullifier_public_key(), vpk: payee.generate_viewing_public_key(),
                         kind: PrivateAccountKind::Regular, opening: None };
    let address = to.address();
    let pay2 = Proposal { multisig: msig, zone, epoch: 0, nonce: 1, action: Action::Transfer { to: address.as_ref().try_into().unwrap(), amount: 7_000_000 },
                          expires_ms: 9_000_000_000_000, proposer: s[0].key() };
    let exec2 = Instruction::Execute { proposal: pay2.clone(), approvals: vec![s[0].approve(&pay2), s[1].approve(&pay2)], executor: None };
    let e = ok(req("exec", json!({"pre": note, "feeNote": fee_note, "op": op(&exec2),
                                  "recipients": [hex::encode(borsh::to_vec(&to).unwrap())]}))).await;
    note = e["post"].as_str().unwrap().to_string();
    fee_note = e["feePost"].as_str().unwrap().to_string();
    landed(&account, &note).await;
    let vk = &payee.viewing_secret_key;
    let (position, body, rho) = c.get_publications(0, 256).await.unwrap().into_iter().find_map(|(pos, p)| match p {
        Publication::Sealed(m) => m.open(payee.generate_nullifier_public_key(), &vk.d, &vk.z).map(|(b, _, rho)| (pos, b, rho)),
        _ => None,
    }).expect("the payee finds a message sealed to it");
    assert_eq!(body.to.account_id, address);
    let q = c.get_fee_state().await.unwrap();
    let claim_fee = msig_host04::private_reserve(0, q.next_base_fee_exec_ceiling, q.next_base_fee_stor_ceiling);
    let inbox = msig_host04::fee_inbox();
    let inbox_state = msig_host04::native_state(&c.get_account(inbox).await.unwrap().unwrap_or_default());
    let input = lee::ProvingInput {
        claims: vec![],
        root: lee::TransactionEntry::Async(lee_core::MessageWitness {
            body, rho: Some(rho),
            membership_proof: c.get_message_path(position).await.unwrap().expect("the message's path"),
            filler: lee_core::DummyOutput::default(),
        }),
        public_context: lee::PublicExecutionContext::new(vec![lee_core::account::Actor::native_balance(inbox)], []),
        private_witnesses: vec![lee_core::PrivateWitness {
            vpk: payee.generate_viewing_public_key(), random_seed: rand::random(),
            kind: lee_core::WitnessKind::Regular(lee_core::RegularKey::Authorized(payee.authorization_secret_key)),
            nullifier: lee_core::NullifierWitness::Init { commitment_root: lee_core::DUMMY_COMMITMENT_HASH },
            address_openings: Default::default(),
        }],
        dummy_inputs: vec![], ciphertext_padding: None, recoveries: vec![], private_promotions: Default::default(),
        fee: Some(lee_core::FeeTransfer { payer: address, recipient: inbox, amount: claim_fee, refund_to: None }),
    };
    let sim = lee::Simulation { public_actor_states: [(lee_core::account::Actor::native_balance(inbox), inbox_state)].into(), admitted_accounts: None };
    let (output, proof) = lee::execute_and_prove(input, &sim, &lee::privacy_preserving_transaction::circuit::ProgramCatalog::default(),
        |_| lee::SenderPresentation::Canonical, |_, _| false,
        |b| Err(lee::error::LeeError::InvalidInput(format!("no seal {:?}", b.to)))).expect("the claim proves");
    let claimed = output.execution.private_actions.iter().find_map(|a| {
        let ss = lee_core::SharedSecretKey::decapsulate(&a.encrypted_post_state.epk, &vk.d, &vk.z)?;
        let (_, acc) = lee_core::EncryptionScheme::decrypt(&a.encrypted_post_state.ciphertext, &ss, &a.nullifier)?;
        output.execution.private_actions.iter().any(|x| x.commitment == lee_core::Commitment::new(&address, &acc)).then_some(acc)
    }).expect("the payee's new note");
    let msg = lee::privacy_preserving_transaction::message::Message::from_circuit_output(Default::default(), output);
    let claim = lee::PrivacyPreservingTransaction::new(msg.clone(), lee::privacy_preserving_transaction::witness_set::WitnessSet::for_message(&msg, proof, &[]));
    c.send_transaction(common::transaction::LeeTransaction::PrivacyPreserving(claim)).await.expect("the claim is sent");
    landed(&hex::encode(address.as_ref() as &[u8]), &hex::encode(borsh::to_vec(&claimed).unwrap())).await;
    assert_eq!(msig_host04::vault_balance(&claimed), 7_000_000 - claim_fee, "the payee holds the payment less its claim's fee");
    eprintln!("private payee: paid 7000000 sealed, claimed by the payee alone (fee {claim_fee})");

    // a member who lost both notes reads them back from the chain
    let sc = ok(req("scan", json!({}))).await;
    assert_eq!((sc["found"].as_bool(), sc["feeFound"].as_bool()), (Some(true), Some(true)));
    assert_eq!((sc["post"].as_str().unwrap(), sc["feePost"].as_str().unwrap()), (note.as_str(), fee_note.as_str()), "the newest notes");
    eprintln!("live_exec04: all passed");
}
