//! The v0.4 program against a REAL LEZ v0.4 standalone sequencer (roadmap M3, exo-0d3.9), the
//! public posture: Create on a fresh PDA admitted by evidence, a 2-of-3 payment, below threshold
//! refused, every transaction paying its own fee from a throwaway payer the zone's funder pays.
//! Skipped unless MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM (the deployed program's account, hex) are set:
//!
//!   MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh
//!   MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh deploy lez04/target/riscv-guest/…/msig.bin
//!   MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> cargo test -p msig_host04 --test live_public04 -- --nocapture

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use common::transaction::LeeTransaction;
use lee::{fees::FeeDeclaration, PrivateKey, PublicKey, PublicTransaction};
use lee_core::account::{AccountId, Nonce};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{vault_balance, Msig};
use sequencer_service_rpc::{RpcClient as _, SequencerClient, SequencerClientBuilder};

/// Pay `to` from the zone's funder; a public account no one has used yet is admitted by its key.
fn fund(rpc: &str, to: &AccountId, amount: u128, key: Option<&PublicKey>) {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .env("MUSTER_LEZ_DIR", std::env::var("MUSTER_LEZ_DIR").unwrap_or_else(|_| format!("{}/.cache/muster/lez-v0.4.0-rc3", std::env::var("HOME").unwrap())))
        .args(["--zone", rpc, "fund", &hex::encode(to.as_ref()), &amount.to_string()])
        .args(key.map(|k| hex::encode(k.value())))
        .output()
        .expect("run the zone's funder");
    assert!(out.status.success(), "the funder could not pay: {}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
}

async fn until(what: &str, mut cond: impl AsyncFnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(120);
    while !cond().await {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

/// Send `op` from the payer, who declares and pays the fee and is the only signer.
async fn send(c: &SequencerClient, m: &Msig, op: Instruction, payer: &PrivateKey) {
    let pk = PublicKey::new_from_private_key(payer);
    let id = AccountId::from(&pk);
    let nonce = c.get_accounts_nonces(vec![id]).await.expect("getAccountsNonces")[0];
    let fee = FeeDeclaration { payer: id, gas_limit: 4_000_000, tip: 0, max_fee: 500_000_000 };
    let msg = m.public_message(op, BTreeMap::from([(id, nonce)]), Some(fee));
    let tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[payer]));
    c.send_transaction(LeeTransaction::Public(tx)).await.expect("sendTransaction");
}

#[tokio::test(flavor = "multi_thread")]
async fn public_multisig_on_a_live_v04_zone() {
    let (Ok(rpc), Ok(prog)) = (std::env::var("MSIG_LIVE_RPC"), std::env::var("MSIG_LIVE_PROGRAM")) else {
        eprintln!("skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let c = SequencerClientBuilder::default().build(&rpc).unwrap();
    let program = AccountId::new(hex::decode(prog).unwrap().try_into().unwrap());
    let m = Msig::public(program, rand::random());
    let payer = PrivateKey::try_new(rand::random()).unwrap();
    let payer_pk = PublicKey::new_from_private_key(&payer);
    let payer_id = AccountId::from(&payer_pk);
    fund(&rpc, &payer_id, 10_000_000_000, Some(&payer_pk));
    until("the payer's funds", async || c.get_account_balance(payer_id).await.unwrap_or(0) > 0).await;

    // 1. create, on a fresh public PDA
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let zone: Key = tagged(b"muster-msig/v1/zone", b"lez:local");
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    send(&c, &m, Instruction::Create { zone, config }, &payer).await;
    let state = async || c.get_account(m.account()).await.ok().flatten().and_then(|a| m.state_of(&a));
    until("the multisig on chain", async || state().await.is_some()).await;
    assert_eq!(state().await.unwrap().config.threshold, 2);
    eprintln!("1. created at its fresh public PDA, admitted by evidence; the payer paid the fee");

    // 2. fund the vault, pay 2 of 3; below threshold changes nothing
    fund(&rpc, &m.account(), 5_000, None);
    until("the funded vault", async || vault(&c, &m).await == 5_000).await;
    let to_pk = PublicKey::new_from_private_key(&PrivateKey::try_new(rand::random()).unwrap());
    let to = AccountId::from(&to_pk);
    fund(&rpc, &to, 1, Some(&to_pk));
    until("the recipient exists", async || c.get_account_balance(to).await.unwrap_or(0) == 1).await;
    let p = Proposal { multisig: m.key(), zone, epoch: 0, nonce: 0, action: Action::Transfer { to: msig_v04_key(&to), amount: 1_200 },
                       expires_ms: 9_000_000_000_000, proposer: s[0].key() };
    let exec = |who: &[usize]| Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| s[i].approve(&p)).collect(), executor: None };
    send(&c, &m, exec(&[0]), &payer).await;
    tokio::time::sleep(Duration::from_secs(20)).await;
    assert_eq!(vault(&c, &m).await, 5_000, "below threshold, nothing moved");
    send(&c, &m, exec(&[0, 1]), &payer).await;
    until("the payment", async || c.get_account_balance(to).await.unwrap_or(0) == 1_201).await;
    assert_eq!(vault(&c, &m).await, 3_800);
    let _ = Nonce(0);
    eprintln!("2. 1 of 2 changed nothing; 2 of 3 paid 1200 out of the vault, in one transaction");
}

async fn vault(c: &SequencerClient, m: &Msig) -> u128 {
    c.get_account(m.account()).await.ok().flatten().map(|a| vault_balance(&a)).unwrap_or(0)
}

fn msig_v04_key(a: &AccountId) -> Key {
    msig_host04::msig_v04::key_of(a)
}
