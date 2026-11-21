//! The private posture on LEZ v0.4 (exo-05f): a group-owned private PDA, every step paying its fee
//! inside the proof from the group's fee account (D17). On LEE's own state, dev-mode proofs. Each
//! step's new notes are decrypted with the group's keys, as any member would, and carried into the
//! next step with a membership proof from the state:
//! - the group's fee account topped up from a public account, paying its own first fee out of
//!   the credit (no funds in the group needed);
//! - a private Create;
//! - a deposit into the vault from a public account;
//! - a 2-of-3 payment out to a public payee;
//! - below threshold, the program refuses while proving and nothing is sent;
//! - a spent nonce is refused the same way.

use std::collections::HashMap;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, V03State};
use lee_core::{
    account::{Account, AccountId, Actor},
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, program, vault_balance, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const P: [u8; 32] = [0xa4; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const PAYEE: [u8; 32] = [0x0e; 32];
const FEE: u128 = 40;

fn config(s: &[Signer]) -> Config {
    Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

/// A member's view of the zone: the state, the multisig's and the fee account's current notes.
struct Room {
    state: V03State,
    m: Msig,
    s: Vec<Signer>,
    note: Option<Account>,
    fee_note: Account,
    depositor: PrivateKey,
    block: u64,
}

impl Room {
    fn proof(&self, id: AccountId, note: &Account) -> MembershipProof {
        self.state.get_proof_for_commitment(&Commitment::new(&id, note)).expect("the note is in the set")
    }

    fn fee(&self) -> PrivateFee {
        PrivateFee {
            note: self.fee_note.clone(),
            proof: self.proof(self.m.fee_account().unwrap(), &self.fee_note),
            amount: FEE,
            inbox: AccountId::new(INBOX),
        }
    }

    fn pre(&self) -> Option<(Account, MembershipProof)> {
        self.note.clone().map(|n| (n.clone(), self.proof(self.m.account(), &n)))
    }

    fn states(&self, actors: &[AccountId]) -> HashMap<Actor, lee_core::account::ActorState> {
        actors
            .iter()
            .map(|id| (Actor::native_balance(*id), native_state(&self.state.get_account_by_id(*id))))
            .collect()
    }

    /// Applies a proven transaction and carries its notes forward.
    fn land(&mut self, p: Proven) {
        self.block += 1;
        self.state.transition_from_privacy_preserving_transaction(&p.tx, self.block, self.block * 1000).expect("the zone accepts it");
        if p.post.is_some() {
            self.note = p.post;
        }
        self.fee_note = p.fee_post.expect("the fee account's new note decrypts");
    }

    fn st(&self) -> State {
        self.m.state_of(self.note.as_ref().unwrap()).expect("the multisig's state")
    }
}

fn setup() -> Room {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let group = GroupKeyHolder::new();
    let m = Msig::private(AccountId::new(P), &program().id(), rand::random(), &group);
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let depositor = PrivateKey::try_new([7; 32]).unwrap();
    let dep_id = AccountId::from(&PublicKey::new_from_private_key(&depositor));
    let state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(AccountId::new(INBOX), 1), (AccountId::new(PAYEE), 1), (dep_id, 10_000)]);
    Room { state, m, s, note: None, fee_note: Account::default(), depositor, block: 0 }
}

fn proposal(r: &Room, nonce: u64, amount: u128) -> Proposal {
    Proposal {
        multisig: r.m.key(),
        zone: ZONE,
        epoch: 0,
        nonce,
        action: Action::Transfer { to: PAYEE, amount },
        expires_ms: 1_000_000,
        proposer: r.s[0].key(),
    }
}

fn execute(r: &Room, p: &Proposal, who: &[usize]) -> Instruction {
    Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| r.s[i].approve(p)).collect(), executor: None }
}

#[test]
fn the_private_vault_end_to_end_each_step_paying_its_fee() {
    let mut r = setup();
    let inbox = AccountId::new(INBOX);
    let payee = AccountId::new(PAYEE);

    // the group's fee account, topped up from a public account: its first fee comes out of the credit
    let dep = AccountId::from(&PublicKey::new_from_private_key(&r.depositor));
    let depositor = PrivateKey::try_new([7; 32]).unwrap();
    let p = r.m.top_up_fee_tx(&depositor, 0, 1_000 + FEE, None, FEE, inbox, r.states(&[dep, inbox])).expect("top-up proves");
    r.land(p);
    assert_eq!(vault_balance(&r.fee_note), 1_000, "the fee account holds the top-up less its own fee");
    assert_eq!(vault_balance(&r.state.get_account_by_id(dep)), 10_000 - 1_000 - FEE);

    // Create
    let create = Instruction::Create { zone: ZONE, config: config(&r.s) };
    let p = r.m.private_tx(create, None, Some(r.fee()), r.states(&[inbox])).expect("create proves");
    r.land(p);
    assert_eq!((r.st().epoch, r.st().config.threshold), (0, 2));
    assert_eq!(vault_balance(&r.fee_note), 1_000 - FEE, "the fee left the group's fee account");

    // a deposit from a public account
    let nonce = r.state.get_account_by_id(dep).nonce.0;
    let p = r.m.deposit_tx(&depositor, nonce, 5_000, r.pre(), Some(r.fee()), r.states(&[dep, inbox])).expect("deposit proves");
    r.land(p);
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 5_000, "the vault's note holds the deposit");
    assert_eq!(vault_balance(&r.state.get_account_by_id(dep)), 10_000 - 1_000 - FEE - 5_000);

    // 2 of 3 pays a public payee
    let pay = proposal(&r, 0, 1_200);
    let p = r.m.private_tx(execute(&r, &pay, &[0, 1]), r.pre(), Some(r.fee()), r.states(&[payee, inbox])).expect("2 of 3 proves");
    r.land(p);
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 3_800);
    assert_eq!(vault_balance(&r.state.get_account_by_id(payee)), 1 + 1_200, "the payee was credited publicly");
    assert_eq!(vault_balance(&r.state.get_account_by_id(inbox)), 1 + 4 * FEE, "four fees reached the inbox");
    assert_eq!(vault_balance(&r.fee_note), 1_000 - 3 * FEE);

    // below threshold: refused while proving, so nothing is sent and nothing is paid
    let lone = proposal(&r, 1, 10);
    let e = format!("{:?}", r.m.private_tx(execute(&r, &lone, &[0]), r.pre(), Some(r.fee()), r.states(&[payee, inbox])).err().expect("refused"));
    assert!(e.contains("below-threshold"), "got: {e}");

    // a spent nonce
    let e = format!("{:?}", r.m.private_tx(execute(&r, &pay, &[0, 1]), r.pre(), Some(r.fee()), r.states(&[payee, inbox])).err().expect("refused"));
    assert!(e.contains("nonce-spent"), "got: {e}");
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 3_800, "nothing moved");
}
