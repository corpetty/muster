//! The v0.4 program on LEE's own state machine (`V03State` at LEZ v0.4.0-rc3; the type kept
//! its name), no sequencer: the public posture end to end (roadmap M3, exo-0d3.9). The rules
//! are msig_core's, tested there; this holds the actor adapter:
//! - Create on a fresh public PDA, admitted by evidence that it is the PDA;
//! - a payment 2 of 3, below threshold nothing moves, a nonce once;
//! - not drainable before initialisation (RFP S.7);
//! - the actor's account check: a state at any account but its PDA is refused (D10);
//! - windows: a time-locked action lands only from its ETA;
//! - a spend under a limit, without the quorum.

use std::collections::BTreeMap;

use lee::{PrivateKey, PublicKey, PublicTransaction, V03State};
use lee_core::account::{AccountId, Actor, Nonce};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{program, vault_balance, Msig, Placement, ProgramInstruction};

const ZONE: Key = [0x2e; 32];
const P: [u8; 32] = [0xa4; 32];

fn config(s: &[Signer], k: u32, timelock_ms: u64) -> Config {
    Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: k,
        timelock_ms,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

fn proposal(m: &Msig, s: &[Signer], epoch: u64, nonce: u64, action: Action) -> Proposal {
    Proposal { multisig: m.key(), zone: ZONE, epoch, nonce, action, expires_ms: 1_000_000, proposer: s[0].key() }
}

fn execute(p: &Proposal, s: &[Signer], who: &[usize]) -> Instruction {
    Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| s[i].approve(p)).collect(), executor: None }
}

/// A fee-exempt public transaction: LEE's own state charges no fee (the sequencer does).
fn tx(m: &Msig, op: Instruction) -> PublicTransaction {
    let msg = m.public_message(op, BTreeMap::new(), None);
    PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[]))
}

fn refused<T: std::fmt::Debug>(r: Result<T, lee::error::LeeError>, code: &str) {
    let e = format!("{:?}", r.expect_err("expected the program to refuse"));
    assert!(e.contains(code), "expected `{code}` in the refusal, got: {e}");
}

struct Pub {
    state: V03State,
    m: Msig,
    s: Vec<Signer>,
}

fn setup(k: u32, timelock_ms: u64, limits: Vec<SpendingLimit>) -> Pub {
    let m = Msig::public(AccountId::new(P), rand::random());
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let recipient = AccountId::new([0x0e; 32]);
    let mut state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(recipient, 1)]);
    let mut c = config(&s, k, timelock_ms);
    c.limits = limits;
    state.transition_from_public_transaction(&tx(&m, Instruction::Create { zone: ZONE, config: c }), 1, 0).expect("create");
    Pub { state, m, s }
}

fn fund(t: &mut Pub, amount: u128) {
    let mut a = t.state.get_account_by_id(t.m.account());
    let had = vault_balance(&a);
    a.data.set_actor_state(lee_core::native_token::NATIVE_TOKEN_PROGRAM_ID, lee_core::native_token::encode_balance(had + amount));
    t.state.force_insert_account(t.m.account(), a);
}

#[test]
fn create_on_a_fresh_pda_then_pay_two_of_three() {
    let mut t = setup(2, 0, vec![]);
    let a = t.state.get_account_by_id(t.m.account());
    let st = t.m.state_of(&a).expect("the multisig's actor state");
    assert_eq!((st.epoch, st.config.threshold, st.create_key), (0, 2, t.m.create_key));
    fund(&mut t, 1000);

    let to = AccountId::new([0x0e; 32]);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: msig_v04::key_of(&to), amount: 300 });
    refused(t.state.transition_from_public_transaction(&tx(&t.m, execute(&p, &t.s, &[0])), 2, 10), "below-threshold");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 1000, "nothing moved");

    t.state.transition_from_public_transaction(&tx(&t.m, execute(&p, &t.s, &[0, 1])), 2, 10).expect("2 of 3");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 700);
    assert_eq!(vault_balance(&t.state.get_account_by_id(to)), 301, "the credit landed in the same transaction");
    refused(t.state.transition_from_public_transaction(&tx(&t.m, execute(&p, &t.s, &[0, 1])), 3, 20), "nonce-spent");
}

#[test]
fn nothing_moves_before_create() {
    let m = Msig::public(AccountId::new(P), rand::random());
    let s: Vec<Signer> = (0..1).map(|_| Signer::random()).collect();
    let mut state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(m.account(), 500), (AccountId::new([0x0e; 32]), 1)]);
    let p = proposal(&m, &s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 500 });
    refused(state.transition_from_public_transaction(&tx(&m, execute(&p, &s, &[0])), 1, 0), "not-initialised");
    assert_eq!(vault_balance(&state.get_account_by_id(m.account())), 500);
}

#[test]
fn a_state_anywhere_but_its_pda_is_refused() {
    let mut t = setup(1, 0, vec![]);
    fund(&mut t, 1000);
    // the real multisig's actor, around an instruction naming another create key: the actor
    // derives another account and refuses
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 1 });
    let forged = ProgramInstruction { create_key: [9; 32], placement: Placement::Public, op: execute(&p, &t.s, &[0]) };
    let actors = t.m.public_actors(&execute(&p, &t.s, &[0]));
    let msg = lee::public_transaction::Message::new(
        t.m.root(), lee::program::Program::serialize_message(forged).unwrap(), actors, BTreeMap::new(), None, vec![]);
    let forged_tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[]));
    refused(t.state.transition_from_public_transaction(&forged_tx, 2, 0), "wrong-account");

    // a counterfeit multisig: a member's own public account, sent a Create naming the real
    // create key; the account is not the PDA, so the actor refuses
    let key = PrivateKey::try_new([7; 32]).unwrap();
    let own = AccountId::from(&PublicKey::new_from_private_key(&key));
    t.state.force_insert_account(own, lee_core::account::Account::default());
    let ins = ProgramInstruction {
        create_key: t.m.create_key,
        placement: Placement::Public,
        op: Instruction::Create { zone: ZONE, config: config(&t.s, 1, 0) },
    };
    let msg = lee::public_transaction::Message::new(
        Actor::new(own, t.m.program), lee::program::Program::serialize_message(ins).unwrap(),
        [Actor::new(own, t.m.program)], BTreeMap::from([(own, Nonce(0))]), None, vec![]);
    let tx2 = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[&key]));
    refused(t.state.transition_from_public_transaction(&tx2, 2, 0), "wrong-account");
}

#[test]
fn a_time_locked_action_lands_from_its_eta() {
    let mut t = setup(1, 1_000, vec![]);
    fund(&mut t, 100);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 40 });
    refused(t.state.transition_from_public_transaction(&tx(&t.m, execute(&p, &t.s, &[0])), 2, 10), "needs-queue");
    let q = Instruction::Queue { proposal: p.clone(), approvals: vec![t.s[0].approve(&p)], executor: None, at_ms: 500 };
    t.state.transition_from_public_transaction(&tx(&t.m, q), 2, 400).expect("queued, landing before its claimed time");
    let x = || Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: 1_500 };
    refused(t.state.transition_from_public_transaction(&tx(&t.m, x()), 3, 1_499), "");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 100, "not before the ETA");
    t.state.transition_from_public_transaction(&tx(&t.m, x()), 3, 1_500).expect("from the ETA");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 60);
}

#[test]
fn a_spend_under_a_limit_skips_the_quorum() {
    let signers_of = |s: &[Signer]| vec![s[2].key()];
    let s0: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let _ = signers_of(&s0);
    let mut t = setup(3, 0, vec![]);
    let limit = SpendingLimit { id: 1, signers: vec![t.s[2].key()], threshold: 1, amount: 50, period_ms: 10_000 };
    let add = proposal(&t.m, &t.s, 0, 0, Action::Config(vec![ConfigChange::AddLimit(limit)]));
    t.state.transition_from_public_transaction(&tx(&t.m, execute(&add, &t.s, &[0, 1, 2])), 2, 10).expect("the quorum adds a limit");
    fund(&mut t, 100);
    let sp = Spend { multisig: t.m.key(), zone: ZONE, epoch: 1, limit: 1, nonce: 1, to: [0x0e; 32], amount: 30, expires_ms: 1_000_000 };
    let spend = |sp: &Spend| Instruction::Spend { spend: sp.clone(), approvals: vec![t.s[2].spend(sp)], period: 0, period_ms: 10_000 };
    t.state.transition_from_public_transaction(&tx(&t.m, spend(&sp)), 3, 20).expect("one signer of the limit, no quorum");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 70);
    let more = Spend { nonce: 2, amount: 30, ..sp };
    refused(t.state.transition_from_public_transaction(&tx(&t.m, spend(&more)), 4, 30), "over-limit");
}
