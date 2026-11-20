//! msig_host04: the lez-msig client on LEZ v0.4 (roadmap M3, exo-0d3.9). The public posture
//! first; the private posture (fees inside the proof, async deposits) follows its design rows.
//!
//! A `Msig` names one multisig: the program's account, its create key and its placement. It
//! builds the program's message and the transaction's public actors from the core instruction
//! alone, so the host and the guest agree by construction.
//!
//! What the transaction must declare in v0.4, where v0.3 listed rows:
//! - the multisig's own actor `(A, P)`, the root call's receiver;
//! - for a payment, the vault's native balance and the recipient's (its credit is an async
//!   message, run in the same transaction only when the recipient is a declared public actor);
//! - for a call, every row as an actor (the target is `rows[0]`);
//! - for a Create of a public A that does not exist yet, admission evidence that A is the PDA of
//!   (P, seed), since a fresh public account is otherwise refused.

use std::collections::BTreeMap;

use lee::{fees::FeeDeclaration, program::Program, public_transaction, PublicAccountEvidence};
use lee_core::account::{Account, AccountId, Actor, Nonce};
pub use msig_core;
use msig_core::{Instruction, Key, Outflow, State};
pub use msig_v04::{self, Placement, ProgramInstruction};
use msig_v04::{key_of, multisig_account, seed};
use sha2::{Digest, Sha256};

/// The derivation id of a private multisig's fee account (D17): a regular private account the
/// members derive from their group secret with LEE's `derive_regular_shared_account_keys(id)`,
/// and witness `FeeOnly`, since the multisig's PDA cannot pay a fee. One per multisig, so two
/// multisigs of one group never share a fee account.
pub fn fee_derivation_id(create_key: &Key) -> [u8; 32] {
    Sha256::new().chain_update(b"lez-msig/v1/fee-account").chain_update(create_key).finalize().into()
}

/// The guest program as built from `methods/guest`.
pub fn program() -> Program {
    Program::new(msig_methods04::MSIG_ELF.into()).expect("a valid program")
}

pub struct Msig {
    pub program: AccountId,
    pub create_key: Key,
    pub placement: Placement,
}

impl Msig {
    /// A multisig over a public PDA.
    pub fn public(program: AccountId, create_key: Key) -> Self {
        Self { program, create_key, placement: Placement::Public }
    }

    pub fn account(&self) -> AccountId {
        multisig_account(&self.program, &self.create_key, &self.placement)
    }

    /// The multisig's id as proposals name it.
    pub fn key(&self) -> Key {
        key_of(&self.account())
    }

    /// The actor every instruction is delivered to.
    pub fn root(&self) -> Actor {
        Actor::new(self.account(), self.program)
    }

    pub fn envelope(&self, op: Instruction) -> ProgramInstruction {
        ProgramInstruction { create_key: self.create_key, placement: self.placement.clone(), op }
    }

    /// The public actors the transaction declares: the root, then what the outflow touches.
    pub fn public_actors(&self, op: &Instruction) -> Vec<Actor> {
        let a = self.account();
        let mut actors = vec![self.root()];
        match msig_core::claims(op).ok().and_then(|c| c.outflow) {
            None => {}
            Some(Outflow::Pay { to, .. }) => {
                actors.push(Actor::native_balance(a));
                actors.push(Actor::native_balance(AccountId::new(to)));
            }
            Some(Outflow::Invoke { rows, .. }) => {
                actors.extend(rows.iter().map(|r| Actor::new(AccountId::new(r.account), AccountId::new(r.program))));
            }
        }
        actors
    }

    /// A public A is admitted on Create by evidence that it is the PDA of (P, seed).
    pub fn admission(&self, op: &Instruction) -> Vec<PublicAccountEvidence> {
        match (op, &self.placement) {
            (Instruction::Create { .. }, Placement::Public) => {
                vec![PublicAccountEvidence::Pda { program: self.program, seed: seed(&self.create_key) }]
            }
            _ => vec![],
        }
    }

    /// The public message for `op`. `nonces` are the signers' (a fee payer's), `fee` its
    /// declaration (None only for a fee-exempt system transaction or LEE's own test state).
    pub fn public_message(
        &self,
        op: Instruction,
        nonces: BTreeMap<AccountId, Nonce>,
        fee: Option<FeeDeclaration>,
    ) -> public_transaction::Message {
        let actors = self.public_actors(&op);
        let admission = self.admission(&op);
        let message = Program::serialize_message(self.envelope(op)).expect("borsh");
        public_transaction::Message::new(self.root(), message, actors, nonces, fee, admission)
    }

    /// The multisig's state from its account: the program's own actor state.
    pub fn state_of(&self, account: &Account) -> Option<State> {
        let data: &[u8] = account.data.actor_state(self.program).as_ref();
        if data.is_empty() {
            return None;
        }
        borsh::from_slice(data).ok()
    }
}

/// The vault's balance: the native balance of the multisig's account.
pub fn vault_balance(account: &Account) -> u128 {
    account.data.native_balance().unwrap_or(0)
}
