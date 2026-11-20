//! Ground truth for muster's Nim port of LEZ v0.4.0-rc3 public transactions (module/src/lez/tx.nim
//! `LezMessage4`), from LEZ's own crates: the message's borsh, its signing hash, the signed
//! transaction's bytes and hash, and `LeeTransaction::Public` as `sendTransaction` carries it.
//! Two messages: a lez-msig Create admitted by PDA evidence, and a 2-of-2 payment, each with a fee
//! declaration and the payer's nonce. Fixed keys; the signature comes from LEZ's signer and is
//! written out, so the Nim side checks the encoding around it rather than re-signing.
//!   cargo run -p msig_host04 --bin msig_vectors04 > ../../../module/tests/vectors/lez-msig/v04.json

use std::collections::BTreeMap;

use lee::{fees::FeeDeclaration, PrivateKey, PublicKey, PublicTransaction};
use lee_core::account::{AccountId, Nonce};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::Msig;

fn h(b: &[u8]) -> String {
    hex::encode(b)
}

fn vector(m: &Msig, op: Instruction, payer: &PrivateKey, nonce: u128) -> serde_like::Obj {
    let pk = PublicKey::new_from_private_key(payer);
    let id = AccountId::from(&pk);
    let fee = FeeDeclaration { payer: id, gas_limit: 2_000_000, tip: 7, max_fee: 134_400_000 };
    let msg = m.public_message(op, BTreeMap::from([(id, Nonce(nonce))]), Some(fee));
    let tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[payer]));
    let sig = tx.witness_set().signatures_and_public_keys()[0].0.value;
    let tx_bytes = borsh::to_vec(&tx).unwrap();
    let lee_tx = borsh::to_vec(&common_tx::Public(tx.clone())).unwrap();
    serde_like::Obj(vec![
        ("payer", h(id.as_ref())),
        ("payerKey", h(pk.value())),
        ("nonce", nonce.to_string()),
        ("message", h(&msg.to_bytes())),
        ("hash", h(&msg.hash())),
        ("signature", h(&sig)),
        ("tx", h(&tx_bytes)),
        ("txHash", h(&tx.hash())),
        ("leeTx", h(&lee_tx)),
    ])
}

/// LeeTransaction's borsh, without depending on the sequencer's crate: Public is variant 0.
mod common_tx {
    #[derive(borsh::BorshSerialize)]
    pub enum LeeTx {
        Public(lee::PublicTransaction),
    }
    #[allow(non_snake_case)]
    pub fn Public(t: lee::PublicTransaction) -> LeeTx {
        LeeTx::Public(t)
    }
}

mod serde_like {
    pub struct Obj(pub Vec<(&'static str, String)>);
    impl Obj {
        pub fn render(&self, indent: &str) -> String {
            let body: Vec<String> = self.0.iter().map(|(k, v)| format!("{indent}  \"{k}\": \"{v}\"")).collect();
            format!("{{\n{}\n{indent}}}", body.join(",\n"))
        }
    }
}

fn main() {
    let program = AccountId::new([0xa4; 32]);
    let m = Msig::public(program, [0x22; 32]);
    let s: Vec<Signer> = (1..=2u8).map(|i| Signer::from_secret(&[i; 32])).collect();
    let payer = PrivateKey::try_new([0x5a; 32]).unwrap();
    let zone: Key = [0x2e; 32];
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let create = vector(&m, Instruction::Create { zone, config }, &payer, 0);
    let p = Proposal { multisig: m.key(), zone, epoch: 0, nonce: 0, action: Action::Transfer { to: [0x0e; 32], amount: 1200 },
                       expires_ms: 1_800_000_000_000, proposer: s[0].key() };
    let approvals = s.iter().map(|x| x.sign_with_aux(&approve_msg(&proposal_id(&p)), &[0x11; 32])).collect();
    let pay = vector(&m, Instruction::Execute { proposal: p, approvals, executor: None }, &payer, 1);
    println!("{{\n  \"source\": \"programs/lez-msig/lez04/host/src/bin/msig_vectors04.rs, LEZ v0.4.0-rc3\",");
    println!("  \"program\": \"{}\",\n  \"createKey\": \"{}\",\n  \"multisig\": \"{}\",", h(program.as_ref()), h(&[0x22; 32]), h(m.account().as_ref()));
    println!("  \"create\": {},\n  \"pay\": {}\n}}", create.render("  "), pay.render("  "));
}
