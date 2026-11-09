//! The quest record program on LEZ v0.3.0's plan/apply ABI (muster's
//! `docs/design/lez-quest-program.md`, exo-267.7).
//!
//! `plan` sees the instruction and each row's id, authorization and shard, but no data: it
//! checks who signed and which rows a bounty moves, emits one effect on the record, and
//! chains the native transfer. `apply` sees the record and checks the effect's claim
//! against it: the status, the taker, the confirmer, the bounty. Both run in one
//! transaction, so a transfer goes through only if the record agrees.
//!
//! What the chain refuses, whatever anyone signs: a quest issued without its issuer's
//! authorization; taken by anyone but its named taker (or, when open, by its confirmer);
//! confirmed by anyone but its confirmer, or before it is taken; closed before it is
//! confirmed, or paid to anyone but its taker; cancelled once confirmed; and any change
//! to a closed or cancelled record. So nobody is named in a record without their own
//! signature.

use borsh::BorshDeserialize;
use lee_core::{
    account::{AccountId, ProgramShardSelector},
    native_token::{Instruction as Native, NATIVE_TOKEN_PROGRAM_ID},
    program::{AccountMeta, ChainedCall, PdaSeed, Plan, PlanInput},
};
use quest_core::{Account, Balance, Effect, Instruction, QuestRecord, QuestStatus, record_pda, record_seed};

fn the_record(input: &PlanInput, row: &AccountMeta, issuer: &Account, quest_id: &[u8; 32]) {
    assert_eq!(
        row.account_id,
        record_pda(&input.self_account_id, issuer, quest_id),
        "not this quest's record"
    );
    assert_eq!(row.program_account_id, input.self_account_id, "the record row names another program's shard");
}

fn signer(input: &PlanInput, row: &AccountMeta, what: &str) -> Account {
    assert_eq!(row.program_account_id, input.self_account_id, "the {what} row names another program's shard");
    assert!(row.is_authorized, "the {what} did not sign");
    *row.account_id.value()
}

fn rows_len(input: &PlanInput, bounty: Balance) {
    let want = if bounty > 0 { 4 } else { 2 };
    assert_eq!(input.accounts.len(), want, "{want} rows: the record, the signer{}",
               if bounty > 0 { ", then the bounty's two native rows" } else { "" });
}

/// The native transfer of `bounty` from `from` to `to`, whose rows must be the transaction's
/// third and fourth. `seeds` authorize this program's own PDA (the record) as the sender.
fn pay(plan: &mut Plan, input: &PlanInput, from: AccountId, to: AccountId, bounty: Balance, seeds: Vec<PdaSeed>) {
    let rows = &input.accounts;
    for (row, id) in [(&rows[2], from), (&rows[3], to)] {
        assert!(
            row.account_id == id && row.program_account_id == NATIVE_TOKEN_PROGRAM_ID,
            "the bounty's rows are the sender's and the recipient's native shards"
        );
    }
    let sel = |id| ProgramShardSelector { account_id: id, program_account_id: NATIVE_TOKEN_PROGRAM_ID };
    plan.call(
        ChainedCall::new(NATIVE_TOKEN_PROGRAM_ID, vec![sel(from), sel(to)], &Native::Transfer { amount: bounty })
            .with_pda_seeds(seeds),
    );
}

/// What the instruction asks of the record, checked as far as no data allows.
#[must_use]
pub fn plan(input: &PlanInput, instruction: Instruction) -> Plan {
    let rows = &input.accounts;
    let mut plan = Plan::new(input);
    match instruction {
        Instruction::Open { quest_id, terms_hash, bounty, confirmer, taker } => {
            rows_len(input, bounty);
            let issuer = signer(input, &rows[1], "issuer");
            the_record(input, &rows[0], &issuer, &quest_id);
            assert!(taker != Some(confirmer), "the taker cannot be the confirmer");
            plan.effect(&rows[0], &Effect::Open(QuestRecord {
                issuer,
                quest_id,
                terms_hash,
                bounty,
                confirmer,
                taker,
                status: QuestStatus::Open,
            }));
            if bounty > 0 {
                // the issuer's own authorization (a vault: granted by its multisig's Execute,
                // carried into this chained call) moves the bounty into the record account
                pay(&mut plan, input, AccountId::new(issuer), rows[0].account_id, bounty, vec![]);
            }
        }
        Instruction::Accept { issuer, quest_id } => {
            assert_eq!(rows.len(), 2, "Accept takes two rows: the record, the taker");
            the_record(input, &rows[0], &issuer, &quest_id);
            let taker = signer(input, &rows[1], "taker");
            plan.effect(&rows[0], &Effect::Accept { taker });
        }
        Instruction::Confirm { issuer, quest_id } => {
            assert_eq!(rows.len(), 2, "Confirm takes two rows: the record, the confirmer");
            the_record(input, &rows[0], &issuer, &quest_id);
            let confirmer = signer(input, &rows[1], "confirmer");
            plan.effect(&rows[0], &Effect::Confirm { confirmer });
        }
        Instruction::Close { quest_id, taker, bounty } => {
            rows_len(input, bounty);
            let issuer = signer(input, &rows[1], "issuer");
            the_record(input, &rows[0], &issuer, &quest_id);
            plan.effect(&rows[0], &Effect::Close { issuer, taker, bounty });
            if bounty > 0 {
                let seed = PdaSeed::new(record_seed(&issuer, &quest_id));
                pay(&mut plan, input, rows[0].account_id, AccountId::new(taker), bounty, vec![seed]);
            }
        }
        Instruction::Cancel { quest_id, bounty } => {
            rows_len(input, bounty);
            let issuer = signer(input, &rows[1], "issuer");
            the_record(input, &rows[0], &issuer, &quest_id);
            plan.effect(&rows[0], &Effect::Cancel { issuer, bounty });
            if bounty > 0 {
                let seed = PdaSeed::new(record_seed(&issuer, &quest_id));
                pay(&mut plan, input, rows[0].account_id, AccountId::new(issuer), bounty, vec![seed]);
            }
        }
    }
    plan
}

fn record_of(pre: &[u8]) -> QuestRecord {
    assert!(!pre.is_empty(), "no quest here");
    QuestRecord::try_from_slice(pre).expect("not a quest record")
}

fn enc(r: &QuestRecord) -> Option<Vec<u8>> {
    Some(borsh::to_vec(r).expect("borsh serialization is infallible"))
}

/// The record's part: check the claim, and return its new data.
#[must_use]
pub fn apply(effect: Effect, pre: &[u8]) -> Option<Vec<u8>> {
    match effect {
        Effect::Open(record) => {
            assert!(pre.is_empty(), "a quest already exists here");
            enc(&record)
        }
        Effect::Accept { taker } => {
            let mut r = record_of(pre);
            assert_eq!(r.status, QuestStatus::Open, "the quest is not open");
            assert!(taker != r.confirmer, "the taker cannot be the confirmer");
            if let Some(named) = r.taker {
                assert_eq!(taker, named, "not the taker this quest names");
            }
            r.status = QuestStatus::Accepted { taker };
            enc(&r)
        }
        Effect::Confirm { confirmer } => {
            let mut r = record_of(pre);
            let QuestStatus::Accepted { taker } = r.status else { panic!("the quest is not accepted") };
            assert_eq!(confirmer, r.confirmer, "not this quest's confirmer");
            r.status = QuestStatus::Confirmed { taker };
            enc(&r)
        }
        Effect::Close { issuer, taker, bounty } => {
            let mut r = record_of(pre);
            let QuestStatus::Confirmed { taker: held } = r.status else { panic!("the quest is not confirmed") };
            assert_eq!(issuer, r.issuer, "not this quest's issuer");
            assert_eq!(taker, held, "not the taker who took it");
            assert_eq!(bounty, r.bounty, "not the bounty the quest holds");
            r.status = QuestStatus::Closed { taker };
            enc(&r)
        }
        Effect::Cancel { issuer, bounty } => {
            let mut r = record_of(pre);
            assert!(
                matches!(r.status, QuestStatus::Open | QuestStatus::Accepted { .. }),
                "the quest cannot be cancelled once confirmed, closed or cancelled"
            );
            assert_eq!(issuer, r.issuer, "not this quest's issuer");
            assert_eq!(bounty, r.bounty, "not the bounty the quest holds");
            r.status = QuestStatus::Cancelled;
            enc(&r)
        }
    }
}

#[cfg(test)]
mod tests;
