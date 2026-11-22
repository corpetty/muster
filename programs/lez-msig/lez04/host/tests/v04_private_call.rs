//! A private lez-msig's CALL on LEZ v0.4 (exo-05f): the vault invoking a program from its private
//! PDA, granted the multisig's own seed (D15, D16). On LEE's own state, dev-mode proofs. The target
//! is the native token program at the vault's own balance, carrying a transfer to a public payee, so
//! the call path runs without a second program: `rows[0]` is the target, the payee is a declared
//! public row, and the seed authorizes the vault's account inside the proof.
//! - 2 of 3 call; the payee is credited publicly and the vault's note shows the debit;
//! - a multisig whose targets list does not name the native program has the same call refused
//!   while proving, by its code: nothing is sent.

use std::collections::HashMap;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, V03State};
use lee_core::{
    account::{Account, AccountId, Actor},
    native_token::{Message as NativeMessage, NATIVE_TOKEN_PROGRAM_ID},
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, program, vault_balance, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const PAYEE: [u8; 32] = [0x0e; 32];
const FEE: u128 = 40;

struct Room {
    state: V03State,
    m: Msig,
    s: Vec<Signer>,
    note: Option<Account>,
    fee_note: Account,
    block: u64,
}

impl Room {
    fn proof(&self, id: AccountId, note: &Account) -> MembershipProof {
        self.state.get_proof_for_commitment(&Commitment::new(&id, note)).expect("the note is in the set")
    }
    fn fee(&self) -> PrivateFee {
        PrivateFee { note: self.fee_note.clone(), proof: self.proof(self.m.fee_account().unwrap(), &self.fee_note),
                     amount: FEE, inbox: AccountId::new(INBOX) }
    }
    fn pre(&self) -> Option<(Account, MembershipProof)> {
        self.note.clone().map(|n| (n.clone(), self.proof(self.m.account(), &n)))
    }
    fn states(&self, ids: &[AccountId]) -> HashMap<Actor, lee_core::account::ActorState> {
        ids.iter().map(|id| (Actor::native_balance(*id), native_state(&self.state.get_account_by_id(*id)))).collect()
    }
    fn land(&mut self, p: Proven, keys: &[&PrivateKey]) {
        self.block += 1;
        self.state.transition_from_privacy_preserving_transaction(&p.signed(keys), self.block, self.block * 1000).expect("accepted");
        if p.post.is_some() {
            self.note = p.post;
        }
        self.fee_note = p.fee_post.expect("the fee note decrypts");
    }
}

/// A private multisig of 3, 2 to act, `targets` its call allowlist, the vault holding 5000.
fn setup(targets: Vec<Key>) -> Room {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let m = Msig::private(AccountId::new([0xa4; 32]), &program().id(), rand::random(), &GroupKeyHolder::new());
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let depositor = PrivateKey::try_new([7; 32]).unwrap();
    let dep = AccountId::from(&PublicKey::new_from_private_key(&depositor));
    let inbox = AccountId::new(INBOX);
    let state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(inbox, 1), (AccountId::new(PAYEE), 1), (dep, 100_000)]);
    let mut r = Room { state, m, s, note: None, fee_note: Account::default(), block: 0 };
    let p = r.m.top_up_fee_tx(dep, 0, 1_000, None, FEE, inbox, r.states(&[dep, inbox])).unwrap();
    r.land(p, &[&depositor]);
    let config = Config {
        members: r.s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets, limits: vec![],
    };
    let p = r.m.private_tx(Instruction::Create { zone: ZONE, config }, None, Some(r.fee()), r.states(&[inbox])).unwrap();
    r.land(p, &[]);
    let p = r.m.deposit_tx(dep, 1, 5_000, r.pre(), Some(r.fee()), r.states(&[dep, inbox])).unwrap();
    r.land(p, &[&depositor]);
    r
}

/// The call: the native program at the vault's own balance, transferring `amount` to the payee.
fn call(r: &Room, amount: u128) -> Instruction {
    let native: Key = NATIVE_TOKEN_PROGRAM_ID.as_ref().try_into().unwrap();
    let a: Key = r.m.account().as_ref().try_into().unwrap();
    let data = borsh::to_vec(&NativeMessage::Transfer { to: AccountId::new(PAYEE), amount }).unwrap();
    let action = Action::Call {
        program: native,
        rows: vec![Row { account: a, program: native }, Row { account: PAYEE, program: native }],
        data,
    };
    let p = Proposal { multisig: r.m.key(), zone: ZONE, epoch: 0, nonce: 0, action, expires_ms: 1_000_000, proposer: r.s[0].key() };
    Instruction::Execute { proposal: p.clone(), approvals: vec![r.s[0].approve(&p), r.s[1].approve(&p)], executor: None }
}

#[test]
fn a_private_call_runs_with_the_vaults_seed() {
    let mut r = setup(vec![]);
    let (payee, inbox) = (AccountId::new(PAYEE), AccountId::new(INBOX));
    let p = r.m.private_tx(call(&r, 900), r.pre(), Some(r.fee()), r.states(&[payee, inbox])).expect("the call proves");
    r.land(p, &[]);
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 4_100, "the vault's note shows the debit");
    assert_eq!(vault_balance(&r.state.get_account_by_id(payee)), 1 + 900, "the payee was credited publicly");
}

#[test]
fn a_call_outside_the_targets_list_is_refused_while_proving() {
    let r = setup(vec![[0x77; 32]]);
    let (payee, inbox) = (AccountId::new(PAYEE), AccountId::new(INBOX));
    let e = format!("{:?}", r.m.private_tx(call(&r, 900), r.pre(), Some(r.fee()), r.states(&[payee, inbox])).err().expect("refused"));
    assert!(e.contains("not on this multisig's list of targets"), "got: {e}");
}
