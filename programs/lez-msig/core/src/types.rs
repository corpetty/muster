//! What the multisig stores and what its instructions carry (docs/design/lez-msig.md §3–§5).
//! Every type is borsh: the bytes a signature covers and the bytes the program stores.

use borsh::{BorshDeserialize, BorshSerialize};

/// A 32-byte id: an account, a program, a zone tag, a BIP-340 x-only key.
pub type Key = [u8; 32];
/// A BIP-340 signature.
pub type Sig = [u8; 64];

pub const VERSION: u8 = 1;
/// The first byte of a retired multisig's record (D19), where an active one stores `VERSION`.
pub const RETIRED: u8 = 0x52;
pub const MAX_MEMBERS: usize = 32;
pub const MAX_LIMITS: usize = 8;
pub const MAX_TARGETS: usize = 16;
pub const MAX_QUEUE: usize = 16;
pub const MAX_TIMELOCK_MS: u64 = 365 * 24 * 3600 * 1000;
/// Nonces from `nonce_base` up to this many past it may be used, in any order.
pub const NONCE_WINDOW: u64 = 256;

/// A member's roles (RFP F.6): what the program lets their key do.
pub mod role {
    pub const PROPOSE: u8 = 1;
    pub const APPROVE: u8 = 2;
    pub const EXECUTE: u8 = 4;
    pub const ALL: u8 = PROPOSE | APPROVE | EXECUTE;
}

/// The kinds of action a multisig allows (RFP F.1: "the action set").
pub mod action_kind {
    pub const TRANSFER: u8 = 1;
    pub const CALL: u8 = 2;
    /// Configuration changes and cancels are always allowed: refusing them could lock the
    /// multisig out of its own repair.
    pub const ALL: u8 = TRANSFER | CALL;
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Member {
    pub key: Key,
    pub roles: u8,
    pub weight: u16,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct SpendingLimit {
    pub id: u32,
    /// Members' keys who may sign a spend under this limit.
    pub signers: Vec<Key>,
    /// How many of them must.
    pub threshold: u8,
    /// Native base units per period.
    pub amount: u128,
    pub period_ms: u64,
}

/// Everything a member set agrees on, as the creator writes it and config changes edit it.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Config {
    pub members: Vec<Member>,
    /// The total weight of distinct APPROVE signers an action needs.
    pub threshold: u32,
    pub timelock_ms: u64,
    /// Anyone may execute (true), or an EXECUTE member must sign the execution (false).
    pub open_execution: bool,
    /// `action_kind` bits.
    pub actions: u8,
    /// If non-empty, the only programs a `Call` may target.
    pub targets: Vec<Key>,
    pub limits: Vec<SpendingLimit>,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct LimitUsage {
    pub id: u32,
    pub period: u64,
    pub used: u128,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Queued {
    pub nonce: u64,
    pub proposal_id: Key,
    pub eta_ms: u64,
    pub expires_ms: u64,
}

/// The program's shard of the multisig's account.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct State {
    pub version: u8,
    pub zone: Key,
    pub create_key: Key,
    pub epoch: u64,
    pub config: Config,
    pub usage: Vec<LimitUsage>,
    pub nonce_base: u64,
    pub consumed: [u8; 32],
    pub queue: Vec<Queued>,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum ConfigChange {
    AddMember(Member),
    RemoveMember(Key),
    SetRoles { key: Key, roles: u8 },
    SetWeight { key: Key, weight: u16 },
    SetThreshold(u32),
    SetTimelock(u64),
    SetOpenExecution(bool),
    SetActions(u8),
    SetTargets(Vec<Key>),
    AddLimit(SpendingLimit),
    RemoveLimit(u32),
}

/// One row of a call: an account and the program whose shard of it the call selects.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Row {
    pub account: Key,
    pub program: Key,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Action {
    /// Native LEZ out of the vault.
    Transfer { to: Key, amount: u128 },
    /// Any program, granted the multisig's own seed and nothing else.
    Call { program: Key, rows: Vec<Row>, data: Vec<u8> },
    Config(Vec<ConfigChange>),
    /// Unqueue these nonces and spend them. Never time-locked.
    Cancel(Vec<u64>),
    /// D19: apply `changes`, then hand the result to a successor multisig at `successor`, whose
    /// create key is `create_key`, and move the whole balance there. This account retires.
    /// Appended, so every earlier variant keeps its bytes.
    Rotate { create_key: Key, successor: Key, changes: Vec<ConfigChange> },
}

/// What the members sign (§4). `proposal_id` is its tagged hash.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Proposal {
    pub multisig: Key,
    pub zone: Key,
    pub epoch: u64,
    pub nonce: u64,
    pub action: Action,
    pub expires_ms: u64,
    pub proposer: Key,
}

/// A spend under a limit, signed by the limit's own signers.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Spend {
    pub multisig: Key,
    pub zone: Key,
    pub epoch: u64,
    pub limit: u32,
    pub nonce: u64,
    pub to: Key,
    pub amount: u128,
    pub expires_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Signed {
    pub key: Key,
    pub sig: Sig,
}

#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Instruction {
    Create { zone: Key, config: Config },
    Execute { proposal: Proposal, approvals: Vec<Signed>, executor: Option<Signed> },
    /// `at_ms` is the latest time the transaction may land: the queue's ETA counts from it.
    Queue { proposal: Proposal, approvals: Vec<Signed>, executor: Option<Signed>, at_ms: u64 },
    /// `at_ms` is the earliest time the transaction may land; it must be at least the ETA.
    ExecuteQueued { proposal: Proposal, executor: Option<Signed>, at_ms: u64 },
    /// `period` is the limit's period index the spend counts against, `period_ms` the length the
    /// spender read from the limit: the program checks it, the plan turns both into a window.
    Spend { spend: Spend, approvals: Vec<Signed>, period: u64, period_ms: u64 },
    /// D19: at a retired multisig, forward its whole balance to its successor. Unsigned: the
    /// successor is the one the quorum approved, so this only finishes the move.
    Sweep,
}

/// A retired multisig's record (D19), stored in place of its `State`. `mark` is `RETIRED`.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Retired {
    pub mark: u8,
    pub create_key: Key,
    /// The epoch the successor started at.
    pub epoch: u64,
    /// The successor's account: every balance found here goes there.
    pub successor: Key,
}

/// What the program's shard of a multisig's account holds: an active multisig, or a retired one.
/// Encoded as the bare `State` or `Retired`, told apart by the first byte, so `State`'s layout is
/// the one every multisig created before D19 stores.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Stored {
    Active(State),
    Retired(Retired),
}

impl Stored {
    pub fn encode(&self) -> Vec<u8> {
        match self {
            Stored::Active(s) => borsh::to_vec(s),
            Stored::Retired(r) => borsh::to_vec(r),
        }
        .expect("borsh")
    }

    /// `None` when the bytes are neither record.
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        match *bytes.first()? {
            VERSION => borsh::from_slice(bytes).ok().map(Stored::Active),
            RETIRED => borsh::from_slice(bytes).ok().map(Stored::Retired),
            _ => None,
        }
    }
}

/// What a rotating multisig sends its successor (D19): the state the successor starts with. A
/// message from the program to itself, never signed.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Handover {
    pub to: Key,
    pub state: State,
}

/// Everything an instruction does to a stored multisig: its new record, and what an actor adapter
/// must also send. `handover`: the successor's state, delivered to `to` granting the seed of
/// `state.create_key`. `sweep_to`: read this account's balance and move all of it there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Applied {
    pub post: Stored,
    pub handover: Option<Handover>,
    pub sweep_to: Option<Key>,
}

/// Where value leaves the multisig, as the plan must route it: the adapter turns this into a
/// chained call carrying the multisig's own seed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outflow {
    Pay { to: Key, amount: u128 },
    Invoke { program: Key, rows: Vec<Row>, data: Vec<u8> },
}

/// A half-open time window `[from, to)` in milliseconds; `None` is unbounded.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Window {
    pub from: Option<u64>,
    pub to: Option<u64>,
}

/// What the instruction alone says the transaction does: the window it must land in, and any
/// outflow. The plan emits these; `apply` proves they are the ones the members approved.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Claims {
    pub window: Window,
    pub outflow: Option<Outflow>,
}

/// Who `apply` acts as: the multisig's account (the plan checked it is the PDA of
/// `create_key`'s seed), and that create key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ctx {
    pub multisig: Key,
    pub create_key: Key,
}
