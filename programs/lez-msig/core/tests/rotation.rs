//! D19 (docs/design/lez-msig.md §7, "D19 in detail"): rotation on removal, as the core's pure
//! functions. `apply_stored` retires the multisig and hands its configuration to a successor;
//! `adopt` writes that handover once at the successor; a retired multisig refuses everything but
//! `Sweep`, and `forward` sends whatever balance it finds to the successor. v0.3's `apply` refuses
//! rotation. And every byte Muster's port is held to is unchanged (`muster_vectors_unchanged`).

use msig_core::sign::Signer;
use msig_core::*;

const A: Key = [0xaa; 32];
const CK: Key = [0xcc; 32];
const A2: Key = [0xab; 32];
const CK2: Key = [0xcd; 32];
const ZONE: Key = [0x2e; 32];
const PROG: Key = [0x99; 32];
const TO: Key = [0x0e; 32];
const CTX: Ctx = Ctx { multisig: A, create_key: CK };
const CTX2: Ctx = Ctx { multisig: A2, create_key: CK2 };

fn config(s: &[Signer], k: u32) -> Config {
    Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: k,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

struct M {
    s: Vec<Signer>,
    st: Stored,
}

fn create(n: usize, k: u32, tweak: impl FnOnce(&mut Config, &[Signer])) -> M {
    let s: Vec<Signer> = (0..n).map(|_| Signer::random()).collect();
    let mut c = config(&s, k);
    tweak(&mut c, &s);
    let a = apply_stored(None, &Instruction::Create { zone: ZONE, config: c }, &CTX, Some(&PROG)).expect("create");
    M { s, st: a.post }
}

fn active(st: &Stored) -> &State {
    match st {
        Stored::Active(s) => s,
        Stored::Retired(_) => panic!("retired"),
    }
}

fn proposal(multisig: Key, epoch: u64, nonce: u64, action: Action, proposer: &Signer) -> Proposal {
    Proposal { multisig, zone: ZONE, epoch, nonce, action, expires_ms: 1_000_000, proposer: proposer.key() }
}

fn execute(s: &[Signer], p: &Proposal, who: &[usize]) -> Instruction {
    Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| s[i].approve(p)).collect(), executor: None }
}

fn rotate(s: &[Signer], remove: usize) -> Action {
    Action::Rotate { create_key: CK2, successor: A2, changes: vec![ConfigChange::RemoveMember(s[remove].key())] }
}

fn code<T>(r: Result<T, MsigError>) -> &'static str {
    r.err().map(|e| e.code()).unwrap_or("ok")
}

/// A 2-of-3 that removed member 2 by rotation: the retired record and the successor, adopted.
fn rotated() -> (M, State) {
    let mut m = create(3, 2, |_, _| {});
    let p = proposal(A, 0, 0, rotate(&m.s, 2), &m.s[0]);
    let a = apply_stored(Some(&m.st), &execute(&m.s, &p, &[0, 1]), &CTX, Some(&PROG)).expect("the rotation runs");
    let h = a.handover.expect("a handover");
    let next = adopt(None, &CTX2, &h).expect("the successor adopts");
    m.st = a.post;
    (m, next)
}

#[test]
fn an_approved_rotation_retires_the_multisig_and_hands_over_its_configuration() {
    let m = create(3, 2, |_, _| {});
    let before = active(&m.st).clone();
    let p = proposal(A, 0, 0, rotate(&m.s, 2), &m.s[0]);
    let a = apply_stored(Some(&m.st), &execute(&m.s, &p, &[0, 1]), &CTX, Some(&PROG)).expect("the rotation runs");

    assert_eq!(a.post, Stored::Retired(Retired { mark: RETIRED, create_key: CK, epoch: 1, successor: A2 }));
    assert_eq!(a.sweep_to, Some(A2), "the whole balance follows");
    let h = a.handover.expect("a handover");
    assert_eq!(h.to, A2);
    let next = &h.state;
    assert_eq!(next.create_key, CK2, "the successor has its own create key, so its own seed");
    assert_eq!(next.zone, ZONE);
    assert_eq!(next.epoch, 1, "a configuration change: the epoch moves");
    assert_eq!(next.config.members.len(), 2);
    assert!(next.config.members.iter().all(|x| x.key != m.s[2].key()), "the removed member is gone");
    assert_eq!(next.config.threshold, 2);
    assert_eq!((next.nonce_base, next.consumed), (1, [0; 32]), "the rotation's own nonce is spent there too");
    assert_eq!((next.usage.clone(), next.queue.clone()), (before.usage, vec![]));
}

#[test]
fn a_rotation_needs_the_quorum_like_any_proposal() {
    let m = create(3, 2, |_, _| {});
    let p = proposal(A, 0, 0, rotate(&m.s, 2), &m.s[0]);
    assert_eq!(code(apply_stored(Some(&m.st), &execute(&m.s, &p, &[0]), &CTX, Some(&PROG))), "below-threshold");
    // the removed member's approval counts until the rotation lands, as any member's does
    assert_eq!(code(apply_stored(Some(&m.st), &execute(&m.s, &p, &[0, 2]), &CTX, Some(&PROG))), "ok");
    // a stale epoch and another account are refused as for every proposal
    let stale = proposal(A, 3, 0, rotate(&m.s, 2), &m.s[0]);
    assert_eq!(code(apply_stored(Some(&m.st), &execute(&m.s, &stale, &[0, 1]), &CTX, Some(&PROG))), "stale-epoch");
    let other = proposal([0x01; 32], 0, 0, rotate(&m.s, 2), &m.s[0]);
    assert_eq!(code(apply_stored(Some(&m.st), &execute(&m.s, &other, &[0, 1]), &CTX, Some(&PROG))), "wrong-account");
}

#[test]
fn bad_rotations_are_refused_whole() {
    let m = create(3, 2, |c, s| {
        c.limits.push(SpendingLimit { id: 1, signers: vec![s[1].key()], threshold: 1, amount: 10, period_ms: 100 })
    });
    let run = |action: Action| {
        let p = proposal(A, 0, 0, action, &m.s[0]);
        code(apply_stored(Some(&m.st), &execute(&m.s, &p, &[0, 1]), &CTX, Some(&PROG)))
    };
    let remove = |i: usize| vec![ConfigChange::RemoveMember(m.s[i].key())];
    assert_eq!(run(Action::Rotate { create_key: CK, successor: A2, changes: remove(2) }), "bad-rotation");
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A, changes: remove(2) }), "bad-rotation");
    // the successor's configuration must be valid: two removals leave one member under threshold 2
    let both = vec![ConfigChange::RemoveMember(m.s[1].key()), ConfigChange::RemoveMember(m.s[2].key())];
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A2, changes: both }), "member-in-limit");
    let both = vec![ConfigChange::RemoveMember(m.s[0].key()), ConfigChange::RemoveMember(m.s[2].key())];
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A2, changes: both }), "invalid-config");
    // a limit's signer leaves only with the limit
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A2, changes: remove(1) }), "member-in-limit");
    let with_limit = vec![ConfigChange::RemoveLimit(1), ConfigChange::RemoveMember(m.s[1].key())];
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A2, changes: with_limit }), "ok");
    // a rotation with no change at all (a suspected leak of the group secret) is allowed
    assert_eq!(run(Action::Rotate { create_key: CK2, successor: A2, changes: vec![] }), "ok");
}

#[test]
fn a_retired_multisig_refuses_everything_but_a_sweep() {
    let (m, _) = rotated();
    let s = &m.s;
    // the remaining quorum, at the epoch the successor runs: refused here, it must act there
    for epoch in [0, 1] {
        let pay = proposal(A, epoch, 1, Action::Transfer { to: TO, amount: 5 }, &s[0]);
        let r = apply_stored(Some(&m.st), &execute(s, &pay, &[0, 1]), &CTX, Some(&PROG));
        assert_eq!(r.unwrap_err(), MsigError::Retired(A2));
    }
    let again = proposal(A, 1, 2, rotate(s, 1), &s[0]);
    assert_eq!(code(apply_stored(Some(&m.st), &execute(s, &again, &[0, 1]), &CTX, Some(&PROG))), "retired");
    let sp = Spend { multisig: A, zone: ZONE, epoch: 0, limit: 1, nonce: 3, to: TO, amount: 1, expires_ms: 9 };
    let spend = Instruction::Spend { spend: sp.clone(), approvals: vec![s[0].spend(&sp)], period: 0, period_ms: 1 };
    assert_eq!(code(apply_stored(Some(&m.st), &spend, &CTX, Some(&PROG))), "retired");
    let create = Instruction::Create { zone: ZONE, config: config(&s[..2], 1) };
    assert_eq!(code(apply_stored(Some(&m.st), &create, &CTX, Some(&PROG))), "already-initialised");
    // a sweep: the record is unchanged, and the balance goes to the successor
    let a = apply_stored(Some(&m.st), &Instruction::Sweep, &CTX, Some(&PROG)).expect("a sweep");
    assert_eq!((a.post, a.handover, a.sweep_to), (m.st.clone(), None, Some(A2)));
    // under another create key it is not this multisig
    let other = Ctx { multisig: A, create_key: [0x01; 32] };
    assert_eq!(code(apply_stored(Some(&m.st), &Instruction::Sweep, &other, Some(&PROG))), "wrong-create-key");
}

#[test]
fn only_a_retired_multisig_sweeps_and_forwards() {
    let m = create(2, 1, |_, _| {});
    assert_eq!(code(apply_stored(Some(&m.st), &Instruction::Sweep, &CTX, Some(&PROG))), "not-retired");
    assert_eq!(code(forward(&m.st, 10)), "not-retired");
    let (r, _) = rotated();
    assert_eq!(forward(&r.st, 4_242), Ok(Some(Outflow::Pay { to: A2, amount: 4_242 })));
    assert_eq!(forward(&r.st, 0), Ok(None), "nothing to move");
    assert_eq!(claims(&Instruction::Sweep), Ok(Claims::default()), "a sweep claims no window and no outflow");
}

#[test]
fn the_successor_adopts_once_what_its_predecessor_hands_over() {
    let m = create(3, 2, |_, _| {});
    let p = proposal(A, 0, 0, rotate(&m.s, 2), &m.s[0]);
    let h = apply_stored(Some(&m.st), &execute(&m.s, &p, &[0, 1]), &CTX, Some(&PROG)).unwrap().handover.unwrap();
    let next = adopt(None, &CTX2, &h).expect("adopted");
    assert_eq!(next, h.state);
    assert_eq!(code(adopt(Some(&Stored::Active(next.clone())), &CTX2, &h)), "already-initialised");
    assert_eq!(code(adopt(None, &Ctx { multisig: [0x01; 32], create_key: CK2 }, &h)), "bad-handover");
    assert_eq!(code(adopt(None, &Ctx { multisig: A2, create_key: CK }, &h)), "wrong-create-key");
    let mut queued = h.clone();
    queued.state.queue.push(Queued { nonce: 4, proposal_id: [0; 32], eta_ms: 1, expires_ms: 2 });
    assert_eq!(code(adopt(None, &CTX2, &queued)), "bad-handover");
    let mut invalid = h.clone();
    invalid.state.config.threshold = 9;
    assert_eq!(code(adopt(None, &CTX2, &invalid)), "invalid-config");
    let mut version = h;
    version.state.version = 2;
    assert_eq!(code(adopt(None, &CTX2, &version)), "bad-handover");
}

#[test]
fn the_successor_runs_under_the_new_configuration_and_the_removed_member_cannot_spend() {
    let (m, next) = rotated();
    let s = &m.s;
    let st = Stored::Active(next);
    let pay = |epoch: u64, nonce: u64, proposer: usize| proposal(A2, epoch, nonce, Action::Transfer { to: TO, amount: 7 }, &s[proposer]);
    // the remaining two pay
    let a = apply_stored(Some(&st), &execute(s, &pay(1, 1, 0), &[0, 1]), &CTX2, Some(&PROG)).expect("2 of 2 remaining");
    assert_eq!(claims(&execute(s, &pay(1, 1, 0), &[0, 1])).unwrap().outflow, Some(Outflow::Pay { to: TO, amount: 7 }));
    assert!(matches!(a.post, Stored::Active(_)));
    // the removed member neither proposes nor approves
    assert_eq!(code(apply_stored(Some(&st), &execute(s, &pay(1, 1, 2), &[2, 0]), &CTX2, Some(&PROG))), "not-a-member");
    assert_eq!(code(apply_stored(Some(&st), &execute(s, &pay(1, 1, 0), &[0, 2]), &CTX2, Some(&PROG))), "not-a-member");
    // the nonce the rotation spent stays spent; approvals from before the rotation name the old epoch
    assert_eq!(code(apply_stored(Some(&st), &execute(s, &pay(1, 0, 0), &[0, 1]), &CTX2, Some(&PROG))), "nonce-spent");
    assert_eq!(code(apply_stored(Some(&st), &execute(s, &pay(0, 1, 0), &[0, 1]), &CTX2, Some(&PROG))), "stale-epoch");
    // a proposal signed for the old account is worthless at the new one
    let old = proposal(A, 1, 1, Action::Transfer { to: TO, amount: 7 }, &s[0]);
    assert_eq!(code(apply_stored(Some(&st), &execute(s, &old, &[0, 1]), &CTX2, Some(&PROG))), "wrong-account");
}

#[test]
fn a_queued_rotation_runs_at_its_eta_and_cancels_the_rest_of_the_queue() {
    let mut m = create(3, 2, |c, _| c.timelock_ms = 100);
    let s = &m.s;
    let rot = proposal(A, 0, 0, rotate(s, 2), &s[0]);
    let pay = proposal(A, 0, 1, Action::Transfer { to: TO, amount: 3 }, &s[2]);
    let q = |p: &Proposal| Instruction::Queue { proposal: p.clone(), approvals: vec![s[0].approve(p), s[2].approve(p)], executor: None, at_ms: 10 };
    // under a time lock a rotation is queued, like any configuration change
    assert_eq!(code(apply_stored(Some(&m.st), &execute(s, &rot, &[0, 1]), &CTX, Some(&PROG))), "needs-queue");
    m.st = apply_stored(Some(&m.st), &q(&rot), &CTX, Some(&PROG)).unwrap().post;
    m.st = apply_stored(Some(&m.st), &q(&pay), &CTX, Some(&PROG)).unwrap().post;
    assert_eq!(active(&m.st).queue.len(), 2);
    let exq = |p: &Proposal, at: u64| Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: at };
    assert_eq!(code(apply_stored(Some(&m.st), &exq(&rot, 50), &CTX, Some(&PROG))), "too-early");
    let a = apply_stored(Some(&m.st), &exq(&rot, 110), &CTX, Some(&PROG)).expect("the queued rotation runs");
    let h = a.handover.expect("a handover");
    assert!(h.state.queue.is_empty(), "queued actions name the old account: they do not carry over");
    assert_eq!(h.state.nonce_base, 2, "the queued payment's nonce stays spent at the successor");
    // the payment the removed member proposed and queued can never run now
    assert_eq!(code(apply_stored(Some(&a.post), &exq(&pay, 120), &CTX, Some(&PROG))), "retired");
}

#[test]
fn the_successor_keeps_the_period_a_limit_has_spent() {
    let m = create(3, 2, |c, s| {
        c.limits.push(SpendingLimit { id: 7, signers: vec![s[0].key(), s[1].key()], threshold: 1, amount: 100, period_ms: 1000 })
    });
    let s = &m.s;
    let sp = Spend { multisig: A, zone: ZONE, epoch: 0, limit: 7, nonce: 5, to: TO, amount: 90, expires_ms: 9_999 };
    let spend = Instruction::Spend { spend: sp.clone(), approvals: vec![s[0].spend(&sp)], period: 2, period_ms: 1000 };
    let st = apply_stored(Some(&m.st), &spend, &CTX, Some(&PROG)).unwrap().post;
    let p = proposal(A, 0, 0, rotate(s, 2), &s[0]);
    let h = apply_stored(Some(&st), &execute(s, &p, &[0, 1]), &CTX, Some(&PROG)).unwrap().handover.unwrap();
    assert_eq!(h.state.usage, vec![LimitUsage { id: 7, period: 2, used: 90 }]);
    let next = Stored::Active(adopt(None, &CTX2, &h).unwrap());
    let sp2 = Spend { multisig: A2, epoch: 1, nonce: 6, amount: 20, ..sp };
    let over = Instruction::Spend { spend: sp2.clone(), approvals: vec![s[0].spend(&sp2)], period: 2, period_ms: 1000 };
    assert_eq!(code(apply_stored(Some(&next), &over, &CTX2, Some(&PROG))), "over-limit", "a rotation does not refill a limit");
}

#[test]
fn v03_apply_refuses_rotation_and_keeps_migration() {
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let st = apply(None, &Instruction::Create { zone: ZONE, config: config(&s, 2) }, &CTX, Some(&PROG)).unwrap();
    let p = proposal(A, 0, 0, rotate(&s, 2), &s[0]);
    assert_eq!(code(apply(Some(&st), &execute(&s, &p, &[0, 1]), &CTX, Some(&PROG))), "rotation-unsupported");
    let q = Instruction::Queue { proposal: p.clone(), approvals: vec![], executor: None, at_ms: 1 };
    assert_eq!(code(apply(Some(&st), &q, &CTX, Some(&PROG))), "rotation-unsupported");
    assert_eq!(code(apply(Some(&st), &Instruction::Sweep, &CTX, Some(&PROG))), "rotation-unsupported");
    // everything else is what apply_stored does to an active multisig
    let pay = proposal(A, 0, 0, Action::Transfer { to: TO, amount: 1 }, &s[0]);
    let via_apply = apply(Some(&st), &execute(&s, &pay, &[0, 1]), &CTX, Some(&PROG)).unwrap();
    assert_eq!(via_apply.nonce_base, 1);
}

#[test]
fn a_retired_record_and_a_state_are_told_apart_by_their_first_byte() {
    let (m, next) = rotated();
    let state_bytes = borsh::to_vec(&next).unwrap();
    assert_eq!(state_bytes[0], VERSION);
    assert_eq!(Stored::Active(next.clone()).encode(), state_bytes, "an active multisig stores the bare State, as before D19");
    assert_eq!(Stored::decode(&state_bytes), Some(Stored::Active(next)));
    let retired = m.st.encode();
    assert_eq!(retired[0], RETIRED);
    assert_eq!(retired.len(), 1 + 32 + 8 + 32);
    assert_eq!(Stored::decode(&retired), Some(m.st));
    assert_eq!(Stored::decode(&[]), None);
    assert_eq!(Stored::decode(&[7, 1, 2]), None);
    assert_eq!(Stored::decode(&[RETIRED, 1]), None);
}

// ── no existing byte changes ───────────────────────────────────────────────────

const VECTORS: &str = include_str!("../../../../module/tests/vectors/lez-msig/vectors.json");

fn vector(name: &str) -> Vec<u8> {
    let needle = format!("\"{name}\": \"");
    let start = VECTORS.find(&needle).unwrap_or_else(|| panic!("no vector {name}")) + needle.len();
    let hex = &VECTORS[start..start + VECTORS[start..].find('"').unwrap()];
    (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect()
}

/// Muster's Nim port is held to these bytes. D19 appends variants, so every value from before it
/// decodes, re-encodes, and hashes exactly as the vectors say.
#[test]
fn muster_vectors_unchanged() {
    for name in ["transfer", "call", "config", "cancel"] {
        let bytes = vector(&format!("{name}.proposal"));
        let p: Proposal = borsh::from_slice(&bytes).unwrap();
        assert_eq!(borsh::to_vec(&p).unwrap(), bytes, "{name}");
        assert_eq!(proposal_id(&p).to_vec(), vector(&format!("{name}.proposal_id")), "{name}");
        assert_eq!(approve_msg(&proposal_id(&p)).to_vec(), vector(&format!("{name}.approve_msg")), "{name}");
        assert_eq!(execute_msg(&proposal_id(&p)).to_vec(), vector(&format!("{name}.execute_msg")), "{name}");
    }
    let sp: Spend = borsh::from_slice(&vector("spend")).unwrap();
    assert_eq!(spend_msg(&sp).to_vec(), vector("spend_msg"));
    let state = vector("state");
    let stored = Stored::decode(&state).expect("a State decodes as an active multisig");
    assert_eq!(stored.encode(), state);
    assert_eq!(state_seed(&vector("create_key").try_into().unwrap()).to_vec(), vector("state_seed"));
}
