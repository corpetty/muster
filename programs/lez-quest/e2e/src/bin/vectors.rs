//! Ground truth for clients of the quest program (muster's lez/quest.nim): the record PDA,
//! a record's borsh in every status, and every instruction's borsh, as quest_core makes them.
//!
//!   vectors > module/tests/vectors/lez-quest-v010/vectors.json

use lee_core::account::AccountId;
use quest_core::*;
use serde_json::json;

fn hx(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn main() {
    let program = AccountId::new([0x11; 32]);
    let (issuer, taker, confirmer) = ([0x01; 32], [0x02; 32], [0x03; 32]);
    let (quest_id, terms_hash) = ([0x09; 32], [0x05; 32]);
    let bounty: Balance = 250;
    let record = |taker_named: Option<Account>, status: QuestStatus| {
        hx(&borsh::to_vec(&QuestRecord { issuer, quest_id, terms_hash, bounty, confirmer, taker: taker_named, status }).unwrap())
    };
    let ins = |i: Instruction| hx(&borsh::to_vec(&i).unwrap());
    let out = json!({
        "source": "programs/lez-quest quest_core 0.1.0 (exo-267.7)",
        "program": hx(program.value()), "issuer": hx(&issuer), "taker": hx(&taker), "confirmer": hx(&confirmer),
        "quest_id": hx(&quest_id), "terms_hash": hx(&terms_hash), "bounty": bounty.to_string(),
        "record_seed": hx(&record_seed(&issuer, &quest_id)),
        "record_pda": hx(record_pda(&program, &issuer, &quest_id).value()),
        "records": {
            "open": record(None, QuestStatus::Open),
            "open_named": record(Some(taker), QuestStatus::Open),
            "accepted": record(None, QuestStatus::Accepted { taker }),
            "confirmed": record(None, QuestStatus::Confirmed { taker }),
            "closed": record(None, QuestStatus::Closed { taker }),
            "cancelled": record(None, QuestStatus::Cancelled),
        },
        "instructions": {
            "open": ins(Instruction::Open { quest_id, terms_hash, bounty, confirmer, taker: None }),
            "open_named": ins(Instruction::Open { quest_id, terms_hash, bounty, confirmer, taker: Some(taker) }),
            "accept": ins(Instruction::Accept { issuer, quest_id }),
            "confirm": ins(Instruction::Confirm { issuer, quest_id }),
            "close": ins(Instruction::Close { quest_id, taker, bounty }),
            "cancel": ins(Instruction::Cancel { quest_id, bounty }),
        },
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}
