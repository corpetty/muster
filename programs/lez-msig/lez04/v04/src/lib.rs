//! The lez-msig program on LEZ v0.4 (docs/design/lez-msig.md §2, roadmap M3): what the guest
//! reads and writes, shared with the host so both derive the same bytes and the same account.
//!
//! What changed from v0.3 (`../../v03`): a private PDA's address no longer takes an identifier,
//! so `Placement::Private` drops it; and there is no plan/apply split, so the v0.3 `Effect` is
//! gone (the actor sees its state and its receiver together).

use borsh::{BorshDeserialize, BorshSerialize};
use lee_core::{account::AccountId, encryption::ViewingPublicKey, program::PdaSeed, NullifierPublicKey};
pub use msig_core;
use msig_core::{Instruction, Key};

/// Where the multisig's account lives. The actor re-derives the account from it and refuses
/// to run on any other, so a state written anywhere else is never granted the seed (§2, D10).
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Placement {
    /// A public PDA: the public posture.
    Public,
    /// A group-owned private PDA: the private posture. Its keys come from the members' group
    /// secret; inside a privacy-preserving transaction this stays in the proof.
    Private { npk: NullifierPublicKey, vpk: ViewingPublicKey },
}

/// The program's message: which multisig, where it lives, and the core instruction.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct ProgramInstruction {
    pub create_key: Key,
    pub placement: Placement,
    pub op: Instruction,
}

/// The multisig account's PDA seed.
pub fn seed(create_key: &Key) -> PdaSeed {
    PdaSeed::new(msig_core::state_seed(create_key))
}

/// The multisig's account: the PDA of (program, seed) at its placement.
pub fn multisig_account(program: &AccountId, create_key: &Key, placement: &Placement) -> AccountId {
    let s = seed(create_key);
    match placement {
        Placement::Public => AccountId::for_public_pda(program, &s),
        Placement::Private { npk, vpk } => AccountId::for_private_pda(program, &s, npk, vpk),
    }
}

pub fn key_of(a: &AccountId) -> Key {
    let mut k = [0u8; 32];
    k.copy_from_slice(a.as_ref());
    k
}
