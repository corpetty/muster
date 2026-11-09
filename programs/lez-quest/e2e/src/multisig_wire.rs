//! The LEZ multisig v0.3 port's wire types, as a client needs them: its instructions and
//! the PDAs it owns. Mirrors `multisig_core` of logos-co/lez-multisig, branch
//! feat/lee-v0.3.0 (c3a35e9, not yet upstream: exo-eb6.4.4.5) — borsh variant order matters.

use borsh::{BorshDeserialize, BorshSerialize};
use lee_core::{account::AccountId, program::PdaSeed};
use sha2::{Digest as _, Sha256};

pub type Member = [u8; 32];

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct TargetCall {
    pub program_account_id: [u8; 32],
    pub shard_selectors: Vec<([u8; 32], [u8; 32])>,
    pub instruction_data: Vec<u8>,
    pub pda_seeds: Vec<[u8; 32]>,
}

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum ConfigAction {
    AddMember { new_member: Member },
    RemoveMember { member: Member },
    ChangeThreshold { new_threshold: u8 },
}

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Instruction {
    CreateMultisig { create_key: [u8; 32], threshold: u8, members: Vec<Member> },
    Propose { create_key: [u8; 32], index: u64, target: TargetCall },
    ProposeConfig { create_key: [u8; 32], index: u64, action: ConfigAction },
    Approve { create_key: [u8; 32], index: u64 },
    Reject { create_key: [u8; 32], index: u64 },
    Execute { create_key: [u8; 32], index: u64, approvers: Vec<Member>, call: TargetCall },
    ExecuteConfig { create_key: [u8; 32], index: u64, approvers: Vec<Member>, action: ConfigAction },
}

fn seed_from_str(s: &str) -> [u8; 32] {
    let mut out = [0_u8; 32];
    out[..s.len()].copy_from_slice(s.as_bytes());
    out
}

fn combine(seeds: &[[u8; 32]]) -> [u8; 32] {
    if seeds.len() == 1 {
        return seeds[0];
    }
    let mut h = Sha256::new();
    for s in seeds {
        h.update(s);
    }
    h.finalize().into()
}

pub fn vault_seed(ck: &[u8; 32]) -> [u8; 32] {
    combine(&[seed_from_str("multisig_vault__"), *ck])
}

pub fn state_pda(p: &AccountId, ck: &[u8; 32]) -> AccountId {
    AccountId::for_public_pda(p, &PdaSeed::new(combine(&[*ck])))
}

pub fn proposal_pda(p: &AccountId, ck: &[u8; 32], index: u64) -> AccountId {
    let mut i = [0_u8; 32];
    i[..8].copy_from_slice(&index.to_le_bytes());
    AccountId::for_public_pda(p, &PdaSeed::new(combine(&[seed_from_str("multisig_prop___"), *ck, i])))
}

pub fn vault_pda(p: &AccountId, ck: &[u8; 32]) -> AccountId {
    AccountId::for_public_pda(p, &PdaSeed::new(vault_seed(ck)))
}
