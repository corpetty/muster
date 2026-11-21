//! What each lez-msig step meters on LEZ v0.4.0-rc3 (exo-50c), measured on LEE's own state the way
//! the sequencer meters it (`ValidatedStateDiff::from_public_transaction_with_cycle_budget`). On 0.4
//! a refused transaction burns its whole declared gas limit, so Muster declares a limit per step
//! from these (module/src/lez/msig_gas.nim, held to them by msig_gas_test). Each step across
//! member counts N and approval counts M:
//! - Create with N members;
//! - Execute (a transfer, a config change), Queue and ExecuteQueued with M of N;
//! - Spend under a limit with M signers.
//!
//! `MSIG_GAS_OUT=<path>` writes the table as JSON:
//!   MSIG_GAS_OUT=../../../module/tests/vectors/lez-msig/v04-gas.json cargo test -p msig_host04 --test v04_gas

use std::collections::BTreeMap;

use lee::{PublicTransaction, V03State, ValidatedStateDiff};
use lee_core::account::AccountId;
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{program, Msig};

const ZONE: Key = [0x2e; 32];
const P: [u8; 32] = [0xa4; 32];
const TO: [u8; 32] = [0x0e; 32];
const BUDGET: u64 = 100_000_000;

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

fn tx(m: &Msig, op: Instruction) -> PublicTransaction {
    let msg = m.public_message(op, BTreeMap::new(), None);
    PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[]))
}

/// Applies `op` and returns the cycles it metered; it must succeed.
fn metered(state: &mut V03State, m: &Msig, op: Instruction, block: u64, at: u64) -> u64 {
    let t = tx(m, op);
    let (diff, charge) = ValidatedStateDiff::from_public_transaction_with_cycle_budget(&t, state, block, at, BUDGET)
        .expect("the step succeeds");
    state.apply_state_diff(diff).expect("applies");
    charge.cycles
}

/// A multisig of `n` members, threshold `k`, created and funded; returns the Create's cycles.
fn setup(n: usize, k: u32, timelock_ms: u64) -> (V03State, Msig, Vec<Signer>, u64) {
    let m = Msig::public(AccountId::new(P), rand::random());
    let s: Vec<Signer> = (0..n).map(|_| Signer::random()).collect();
    let mut state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(AccountId::new(TO), 1)]);
    let c = metered(&mut state, &m, Instruction::Create { zone: ZONE, config: config(&s, k, timelock_ms) }, 1, 0);
    let mut a = state.get_account_by_id(m.account());
    a.data.set_actor_state(lee_core::native_token::NATIVE_TOKEN_PROGRAM_ID, lee_core::native_token::encode_balance(1_000_000));
    state.force_insert_account(m.account(), a);
    (state, m, s, c)
}

fn proposal(m: &Msig, s: &[Signer], epoch: u64, nonce: u64, action: Action) -> Proposal {
    Proposal { multisig: m.key(), zone: ZONE, epoch, nonce, action, expires_ms: 1_000_000, proposer: s[0].key() }
}

fn approvals(p: &Proposal, s: &[Signer], m: usize) -> Vec<Signed> {
    s[..m].iter().map(|x| x.approve(p)).collect()
}

struct Row {
    step: &'static str,
    n: usize,
    m: usize,
    cycles: u64,
}

#[test]
fn every_step_metered() {
    let mut rows = vec![];
    for n in [1usize, 3, 5, 10] {
        for m in (1..=n).filter(|m| [1, 2, 3, 5, 10].contains(m)) {
            let (mut st, ms, s, create) = setup(n, m as u32, 0);
            if m == 1 {
                rows.push(Row { step: "create", n, m: 0, cycles: create });
            }
            let p = proposal(&ms, &s, 0, 0, Action::Transfer { to: TO, amount: 10 });
            let c = metered(&mut st, &ms, Instruction::Execute { proposal: p.clone(), approvals: approvals(&p, &s, m), executor: None }, 2, 10);
            rows.push(Row { step: "execute-transfer", n, m, cycles: c });

            let p = proposal(&ms, &s, 0, 1, Action::Config(vec![ConfigChange::SetTimelock(0), ConfigChange::SetThreshold(m as u32)]));
            let c = metered(&mut st, &ms, Instruction::Execute { proposal: p.clone(), approvals: approvals(&p, &s, m), executor: None }, 3, 20);
            rows.push(Row { step: "execute-config", n, m, cycles: c });

            // a time lock: queue at epoch 1, then execute from the ETA
            let (mut st, ms, s, _) = setup(n, m as u32, 1_000);
            let p = proposal(&ms, &s, 0, 0, Action::Transfer { to: TO, amount: 10 });
            let c = metered(&mut st, &ms, Instruction::Queue { proposal: p.clone(), approvals: approvals(&p, &s, m), executor: None, at_ms: 500 }, 2, 400);
            rows.push(Row { step: "queue", n, m, cycles: c });
            let c = metered(&mut st, &ms, Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: 1_500 }, 3, 1_500);
            rows.push(Row { step: "execute-queued", n, m, cycles: c });

            // a spend under a limit whose m signers all sign
            let (mut st, ms, s, _) = setup(n, n as u32, 0);
            let limit = SpendingLimit { id: 1, signers: s[..m].iter().map(|x| x.key()).collect(), threshold: m as u8, amount: 1_000, period_ms: 10_000 };
            let add = proposal(&ms, &s, 0, 0, Action::Config(vec![ConfigChange::AddLimit(limit)]));
            metered(&mut st, &ms, Instruction::Execute { proposal: add.clone(), approvals: approvals(&add, &s, n), executor: None }, 2, 10);
            let sp = Spend { multisig: ms.key(), zone: ZONE, epoch: 1, limit: 1, nonce: 1, to: TO, amount: 30, expires_ms: 1_000_000 };
            let c = metered(&mut st, &ms, Instruction::Spend { spend: sp.clone(), approvals: s[..m].iter().map(|x| x.spend(&sp)).collect(), period: 0, period_ms: 10_000 }, 3, 20);
            rows.push(Row { step: "spend", n, m, cycles: c });
        }
    }
    for r in &rows {
        println!("{:<17} n={:<2} m={:<2} {:>9}", r.step, r.n, r.m, r.cycles);
    }
    if let Ok(path) = std::env::var("MSIG_GAS_OUT") {
        let body: Vec<String> = rows
            .iter()
            .map(|r| format!("    {{\"step\": \"{}\", \"n\": {}, \"m\": {}, \"cycles\": {}}}", r.step, r.n, r.m, r.cycles))
            .collect();
        let json = format!(
            "{{\n  \"source\": \"programs/lez-msig/lez04/host/tests/v04_gas.rs on LEZ v0.4.0-rc3\",\n  \"rows\": [\n{}\n  ]\n}}\n",
            body.join(",\n")
        );
        std::fs::write(path, json).expect("write");
    }
}
