//! The program in process: each transaction is plan, then every effect's apply against an
//! in-memory set of shards, all or nothing — what the chain does, without the zkVM. The
//! native transfers a transaction chains are returned and checked as calls; that the zone
//! carries the issuer's grant into them is the local-zone e2e's to show.

use std::{collections::HashMap, panic};

use borsh::BorshDeserialize;
use lee_core::{
    account::{AccountId, ProgramShardSelector},
    native_token::{Instruction as Native, NATIVE_TOKEN_PROGRAM_ID},
    program::{AccountMeta, ChainedCall, PdaSeed, PlanInput},
};
use quest_core::*;

use crate::{apply, plan};

type Shards = HashMap<(AccountId, AccountId), Vec<u8>>;

const Q: [u8; 32] = [7; 32];
const ISSUER: Account = [1; 32]; // a circle's vault, granted by its multisig's Execute
const TAKER: Account = [2; 32];
const CONFIRMER: Account = [3; 32];
const OUTSIDER: Account = [4; 32];
const QID: [u8; 32] = [9; 32];
const TERMS: [u8; 32] = [5; 32];
const BOUNTY: Balance = 250;

fn program() -> AccountId {
    AccountId::new(Q)
}

fn record() -> AccountId {
    record_pda(&program(), &ISSUER, &QID)
}

/// This program's shard of an account.
fn own(id: AccountId, authorized: bool) -> AccountMeta {
    AccountMeta::new(id, authorized, program())
}

/// An account passed only for its authorization: this program's shard of it, no effect.
fn signer(a: Account, signed: bool) -> AccountMeta {
    own(AccountId::new(a), signed)
}

/// The native shard of an account (a transfer's row).
fn native(id: AccountId) -> AccountMeta {
    AccountMeta::new(id, false, NATIVE_TOKEN_PROGRAM_ID)
}

/// Plan, then every apply; the shards change only if every apply passes. Err(the first
/// panic's message) otherwise; Ok(the chained calls) on success.
fn tx(shards: &mut Shards, accounts: Vec<AccountMeta>, ins: Instruction) -> Result<Vec<ChainedCall>, String> {
    let input = PlanInput {
        self_account_id: program(),
        caller_account_id: None,
        accounts,
        instruction_data: borsh::to_vec(&ins).unwrap(),
    };
    let before = shards.clone();
    let out = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        let p = plan(&input, ins);
        let output = p.output().clone();
        let mut next = shards.clone();
        for e in &output.effects {
            let sel: &ProgramShardSelector = &e.selector;
            let key = (sel.account_id, sel.program_account_id);
            let pre = next.get(&key).cloned().unwrap_or_default();
            let effect = Effect::try_from_slice(&e.data).unwrap();
            if let Some(post) = apply(effect, &pre) {
                next.insert(key, post);
            }
        }
        (next, output.chained_calls)
    }));
    match out {
        Ok((next, calls)) => {
            *shards = next;
            Ok(calls)
        }
        Err(e) => {
            *shards = before;
            Err(e.downcast_ref::<String>().cloned()
                .or_else(|| e.downcast_ref::<&str>().map(|s| (*s).to_owned()))
                .unwrap_or_default())
        }
    }
}

fn refused(r: Result<Vec<ChainedCall>, String>, why: &str) {
    match r {
        Ok(_) => panic!("expected a refusal naming '{why}', it passed"),
        Err(m) => assert!(m.contains(why), "expected '{why}', got '{m}'"),
    }
}

fn rec(shards: &Shards) -> QuestRecord {
    QuestRecord::try_from_slice(&shards[&(record(), program())]).unwrap()
}

fn transfer(call: &ChainedCall, from: AccountId, to: AccountId, amount: Balance, seeds: Vec<PdaSeed>) {
    assert_eq!(call.program_account_id, NATIVE_TOKEN_PROGRAM_ID, "a native transfer");
    let sel: Vec<(AccountId, AccountId)> =
        call.shard_selectors.iter().map(|s| (s.account_id, s.program_account_id)).collect();
    assert_eq!(sel, vec![(from, NATIVE_TOKEN_PROGRAM_ID), (to, NATIVE_TOKEN_PROGRAM_ID)]);
    assert_eq!(Native::try_from_slice(&call.instruction_data).unwrap(), Native::Transfer { amount });
    assert_eq!(call.pda_seeds, seeds);
}

fn open_rows(bounty: Balance) -> Vec<AccountMeta> {
    let mut rows = vec![own(record(), false), signer(ISSUER, true)];
    if bounty > 0 {
        rows.extend([native(AccountId::new(ISSUER)), native(record())]);
    }
    rows
}

fn open(shards: &mut Shards, bounty: Balance, taker: Option<Account>) -> Result<Vec<ChainedCall>, String> {
    tx(shards, open_rows(bounty),
       Instruction::Open { quest_id: QID, terms_hash: TERMS, bounty, confirmer: CONFIRMER, taker })
}

fn accept(shards: &mut Shards, who: Account, signed: bool) -> Result<Vec<ChainedCall>, String> {
    tx(shards, vec![own(record(), false), signer(who, signed)], Instruction::Accept { issuer: ISSUER, quest_id: QID })
}

fn confirm(shards: &mut Shards, who: Account, signed: bool) -> Result<Vec<ChainedCall>, String> {
    tx(shards, vec![own(record(), false), signer(who, signed)], Instruction::Confirm { issuer: ISSUER, quest_id: QID })
}

fn close(shards: &mut Shards, taker: Account, bounty: Balance) -> Result<Vec<ChainedCall>, String> {
    let mut rows = vec![own(record(), false), signer(ISSUER, true)];
    if bounty > 0 {
        rows.extend([native(record()), native(AccountId::new(taker))]);
    }
    tx(shards, rows, Instruction::Close { quest_id: QID, taker, bounty })
}

fn cancel(shards: &mut Shards, bounty: Balance) -> Result<Vec<ChainedCall>, String> {
    let mut rows = vec![own(record(), false), signer(ISSUER, true)];
    if bounty > 0 {
        rows.extend([native(record()), native(AccountId::new(ISSUER))]);
    }
    tx(shards, rows, Instruction::Cancel { quest_id: QID, bounty })
}

#[test]
fn a_quest_runs_open_accept_confirm_close_and_pays_its_taker() {
    let mut s = Shards::new();
    let calls = open(&mut s, BOUNTY, None).unwrap();
    assert_eq!(calls.len(), 1, "Open sets the bounty aside");
    transfer(&calls[0], AccountId::new(ISSUER), record(), BOUNTY, vec![]);
    let r = rec(&s);
    assert_eq!((r.issuer, r.quest_id, r.terms_hash, r.bounty, r.confirmer, r.taker, r.status),
               (ISSUER, QID, TERMS, BOUNTY, CONFIRMER, None, QuestStatus::Open));

    assert!(accept(&mut s, TAKER, true).unwrap().is_empty());
    assert_eq!(rec(&s).status, QuestStatus::Accepted { taker: TAKER });
    assert!(confirm(&mut s, CONFIRMER, true).unwrap().is_empty());
    assert_eq!(rec(&s).status, QuestStatus::Confirmed { taker: TAKER });

    let calls = close(&mut s, TAKER, BOUNTY).unwrap();
    assert_eq!(calls.len(), 1, "Close pays the taker");
    transfer(&calls[0], record(), AccountId::new(TAKER), BOUNTY, vec![PdaSeed::new(record_seed(&ISSUER, &QID))]);
    assert_eq!(rec(&s).status, QuestStatus::Closed { taker: TAKER });
}

#[test]
fn no_bounty_no_transfer() {
    let mut s = Shards::new();
    assert!(open(&mut s, 0, Some(TAKER)).unwrap().is_empty());
    accept(&mut s, TAKER, true).unwrap();
    confirm(&mut s, CONFIRMER, true).unwrap();
    assert!(close(&mut s, TAKER, 0).unwrap().is_empty());
    assert_eq!(rec(&s).status, QuestStatus::Closed { taker: TAKER });
}

#[test]
fn open_needs_the_issuer_and_its_own_record() {
    let mut s = Shards::new();
    let mut rows = open_rows(0);
    rows[1] = signer(ISSUER, false);
    refused(tx(&mut s, rows, Instruction::Open { quest_id: QID, terms_hash: TERMS, bounty: 0, confirmer: CONFIRMER, taker: None }),
            "the issuer did not sign");
    // a record row that is not this issuer's record for this quest
    let rows = vec![own(record_pda(&program(), &OUTSIDER, &QID), false), signer(ISSUER, true)];
    refused(tx(&mut s, rows, Instruction::Open { quest_id: QID, terms_hash: TERMS, bounty: 0, confirmer: CONFIRMER, taker: None }),
            "not this quest's record");
    // a bounty whose transfer rows are not the issuer's and the record's
    let rows = vec![own(record(), false), signer(ISSUER, true), native(AccountId::new(OUTSIDER)), native(record())];
    refused(tx(&mut s, rows, Instruction::Open { quest_id: QID, terms_hash: TERMS, bounty: BOUNTY, confirmer: CONFIRMER, taker: None }),
            "the bounty's rows");
    // nobody confirms their own quest's taking
    refused(open(&mut s, 0, Some(CONFIRMER)), "the taker cannot be the confirmer");
    open(&mut s, 0, None).unwrap();
    refused(open(&mut s, 0, None), "a quest already exists here");
}

#[test]
fn only_the_taker_accepts_with_their_own_signature() {
    let mut s = Shards::new();
    open(&mut s, BOUNTY, Some(TAKER)).unwrap();
    refused(accept(&mut s, TAKER, false), "the taker did not sign");
    refused(accept(&mut s, OUTSIDER, true), "not the taker this quest names");
    accept(&mut s, TAKER, true).unwrap();
    refused(accept(&mut s, TAKER, true), "not open");

    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    refused(accept(&mut s, CONFIRMER, true), "the taker cannot be the confirmer");
    accept(&mut s, OUTSIDER, true).unwrap();
    assert_eq!(rec(&s).status, QuestStatus::Accepted { taker: OUTSIDER }, "an open quest: anyone else may take it");
}

#[test]
fn only_the_confirmer_confirms_and_only_once_taken() {
    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    refused(confirm(&mut s, CONFIRMER, true), "not accepted");
    accept(&mut s, TAKER, true).unwrap();
    refused(confirm(&mut s, CONFIRMER, false), "the confirmer did not sign");
    refused(confirm(&mut s, TAKER, true), "not this quest's confirmer");
    refused(confirm(&mut s, ISSUER, true), "not this quest's confirmer");
    confirm(&mut s, CONFIRMER, true).unwrap();
    refused(confirm(&mut s, CONFIRMER, true), "not accepted");
}

#[test]
fn close_only_after_confirm_for_the_recorded_taker_and_bounty() {
    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    accept(&mut s, TAKER, true).unwrap();
    refused(close(&mut s, TAKER, BOUNTY), "not confirmed");
    confirm(&mut s, CONFIRMER, true).unwrap();
    refused(close(&mut s, OUTSIDER, BOUNTY), "not the taker");
    refused(close(&mut s, TAKER, BOUNTY + 1), "not the bounty");
    refused(close(&mut s, TAKER, 0), "not the bounty");
    // the issuer must sign
    let rows = vec![own(record(), false), signer(ISSUER, false), native(record()), native(AccountId::new(TAKER))];
    refused(tx(&mut s, rows, Instruction::Close { quest_id: QID, taker: TAKER, bounty: BOUNTY }), "the issuer did not sign");
    // a payee row that is not the taker's
    let rows = vec![own(record(), false), signer(ISSUER, true), native(record()), native(AccountId::new(OUTSIDER))];
    refused(tx(&mut s, rows, Instruction::Close { quest_id: QID, taker: TAKER, bounty: BOUNTY }), "the bounty's rows");
    close(&mut s, TAKER, BOUNTY).unwrap();
}

#[test]
fn a_closed_or_cancelled_record_never_changes() {
    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    accept(&mut s, TAKER, true).unwrap();
    confirm(&mut s, CONFIRMER, true).unwrap();
    close(&mut s, TAKER, BOUNTY).unwrap();
    let closed = rec(&s);
    refused(accept(&mut s, OUTSIDER, true), "not open");
    refused(confirm(&mut s, CONFIRMER, true), "not accepted");
    refused(close(&mut s, TAKER, BOUNTY), "not confirmed");
    refused(cancel(&mut s, BOUNTY), "cannot be cancelled");
    refused(open(&mut s, BOUNTY, None), "a quest already exists here");
    assert_eq!(rec(&s), closed);

    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    cancel(&mut s, BOUNTY).unwrap();
    refused(accept(&mut s, TAKER, true), "not open");
    refused(cancel(&mut s, BOUNTY), "cannot be cancelled");
    assert_eq!(rec(&s).status, QuestStatus::Cancelled);
}

#[test]
fn cancel_returns_the_bounty_until_confirmed() {
    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    accept(&mut s, TAKER, true).unwrap();
    refused(cancel(&mut s, BOUNTY + 1), "not the bounty");
    let calls = cancel(&mut s, BOUNTY).unwrap();
    transfer(&calls[0], record(), AccountId::new(ISSUER), BOUNTY, vec![PdaSeed::new(record_seed(&ISSUER, &QID))]);
    assert_eq!(rec(&s).status, QuestStatus::Cancelled);

    let mut s = Shards::new();
    open(&mut s, BOUNTY, None).unwrap();
    accept(&mut s, TAKER, true).unwrap();
    confirm(&mut s, CONFIRMER, true).unwrap();
    refused(cancel(&mut s, BOUNTY), "cannot be cancelled");
}

#[test]
fn the_record_seed_is_domain_separated_and_binds_issuer_and_quest() {
    assert_ne!(record_seed(&ISSUER, &QID), record_seed(&OUTSIDER, &QID));
    assert_ne!(record_seed(&ISSUER, &QID), record_seed(&ISSUER, &[8; 32]));
    let mut swapped = [0_u8; 32];
    swapped.copy_from_slice(&QID);
    assert_ne!(record_seed(&ISSUER, &QID), record_seed(&swapped, &ISSUER));
}
