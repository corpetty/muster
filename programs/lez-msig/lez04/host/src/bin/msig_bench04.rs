//! RFP-005 P.1 / P.2 on LEZ v0.4: the private posture's cost with REAL proving (exo-05f). Refuses
//! RISC0_DEV_MODE. A binary, not a test: LEE refuses its test-utils in a release build, and the
//! tests' dev-dependencies turn them on.
//!
//!   cargo run --release -p msig_host04 --bin msig_bench04 -- [M ...]      (default: 1 3 5 10)
//!
//! For each M, on LEE's own state machine:
//! - a public account tops up the group's fee account, its fee out of the credit;
//! - a multisig of max(M, 3) members with threshold M is created at a private PDA;
//! - the public account deposits into its vault;
//! - it pays a public payee with exactly M approvals.
//!
//! Every step pays its fee inside the proof (D17), as on a zone. Each row: wall time to prove, the
//! transaction's size, and whether the state machine accepted it. The machine comes first, so a
//! figure is never quoted without it.

use std::collections::HashMap;
use std::io::Read;
use std::time::Instant;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, V03State};
use lee_core::{
    account::{Account, AccountId, Actor, ActorState},
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, program, vault_balance, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const PAYEE: [u8; 32] = [0x0e; 32];
const FEE: u128 = 100;

fn random32() -> [u8; 32] {
    let mut b = [0u8; 32];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).expect("/dev/urandom");
    b
}

struct Run {
    state: V03State,
    m: Msig,
    note: Option<Account>,
    fee_note: Option<Account>,
    block: u64,
}

impl Run {
    fn proof(&self, id: AccountId, note: &Account) -> MembershipProof {
        self.state.get_proof_for_commitment(&Commitment::new(&id, note)).expect("the note is in the set")
    }
    fn fee(&self) -> PrivateFee {
        let note = self.fee_note.clone().expect("topped up");
        PrivateFee { proof: self.proof(self.m.fee_account().unwrap(), &note), note, amount: FEE, inbox: AccountId::new(INBOX) }
    }
    fn pre(&self) -> Option<(Account, MembershipProof)> {
        self.note.clone().map(|n| (n.clone(), self.proof(self.m.account(), &n)))
    }
    fn states(&self, ids: &[AccountId]) -> HashMap<Actor, ActorState> {
        ids.iter().map(|id| (Actor::native_balance(*id), native_state(&self.state.get_account_by_id(*id)))).collect()
    }
    fn row(&mut self, m: usize, step: &str, keys: &[&PrivateKey], f: impl FnOnce(&Self) -> Result<Proven, lee::error::LeeError>) {
        let t = Instant::now();
        let p = f(self).unwrap_or_else(|e| panic!("{step}: {e:?}"));
        let secs = t.elapsed().as_secs_f64();
        let tx = p.signed(keys);
        let size = borsh::to_vec(&tx).unwrap().len();
        self.block += 1;
        let ok = self.state.transition_from_privacy_preserving_transaction(&tx, self.block, self.block * 1000).is_ok();
        println!("| {m} | {step} | {secs:.1} | {size} | {} |", if ok { "yes" } else { "NO" });
        assert!(ok, "{step} was not accepted");
        if p.post.is_some() {
            self.note = p.post;
        }
        self.fee_note = Some(p.fee_post.expect("the fee note decrypts"));
    }
}

fn run(m: usize) {
    let n = m.max(3);
    let group = GroupKeyHolder::new();
    let ms = Msig::private(AccountId::new([0xa4; 32]), &program().id(), random32(), &group);
    let s: Vec<Signer> = (0..n).map(|_| Signer::random()).collect();
    let depositor = PrivateKey::try_new(random32()).unwrap();
    let dep = AccountId::from(&PublicKey::new_from_private_key(&depositor));
    let state = V03State::new()
        .with_named_programs([(ms.program, program())])
        .with_public_account_balances([(AccountId::new(INBOX), 1), (AccountId::new(PAYEE), 1), (dep, 1_000_000)]);
    let mut r = Run { state, m: ms, note: None, fee_note: None, block: 0 };
    let (inbox, payee) = (AccountId::new(INBOX), AccountId::new(PAYEE));

    r.row(m, "top-up of the fee account (public → private)", &[&depositor], |r| {
        r.m.top_up_fee_tx(dep, 0, 10_000, None, FEE, inbox, r.states(&[dep, inbox]))
    });
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: m as u32,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    };
    r.row(m, &format!("create ({n} members)"), &[], |r| {
        r.m.private_tx(Instruction::Create { zone: ZONE, config }, None, Some(r.fee()), r.states(&[inbox]))
    });
    r.row(m, "deposit (public → the vault)", &[&depositor], |r| {
        let nonce = r.state.get_account_by_id(dep).nonce.0;
        r.m.deposit_tx(dep, nonce, 50_000, r.pre(), Some(r.fee()), r.states(&[dep, inbox]))
    });
    let p = Proposal {
        multisig: r.m.key(),
        zone: ZONE,
        epoch: 0,
        nonce: 0,
        action: Action::Transfer { to: PAYEE, amount: 1_000 },
        expires_ms: 1_000_000,
        proposer: s[0].key(),
    };
    let ins = Instruction::Execute { proposal: p.clone(), approvals: s[..m].iter().map(|x| x.approve(&p)).collect(), executor: None };
    r.row(m, &format!("**execute: pay, {m} signature{}**", if m == 1 { "" } else { "s" }), &[], |r| {
        r.m.private_tx(ins, r.pre(), Some(r.fee()), r.states(&[payee, inbox]))
    });
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 49_000);
}

fn main() {
    if std::env::var("RISC0_DEV_MODE").map(|v| v != "0" && !v.is_empty()).unwrap_or(false) {
        eprintln!("refusing: RISC0_DEV_MODE is set; benchmarks are real proofs or nothing (RFP P.1)");
        std::process::exit(2);
    }
    let ms: Vec<usize> = std::env::args().skip(1).filter_map(|a| a.parse().ok()).collect();
    let ms = if ms.is_empty() { vec![1, 3, 5, 10] } else { ms };
    println!("# lez-msig private posture on LEZ v0.4.0-rc3 (real proving)");
    println!(
        "host: {} cores; risc0-zkvm 3.0.5; prover: {}",
        std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
        std::env::var("RISC0_PROVER").unwrap_or_else(|_| "default (local CPU)".into())
    );
    println!();
    println!("| M | step | prove (s) | tx size (bytes) | accepted |");
    println!("|---|---|---|---|---|");
    let t = Instant::now();
    for m in ms {
        run(m);
    }
    println!("\nwhole run: {:.0} s", t.elapsed().as_secs_f64());
}
