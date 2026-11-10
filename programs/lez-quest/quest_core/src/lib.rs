//! The quest record program's types on LEZ v0.3.0: the record, the instructions, the
//! effects its plan emits, and the PDA a record lives at. Shared by the program
//! (plan/apply) and by anyone who builds its transactions or reads its records.
//!
//! The design is muster's `docs/design/lez-quest-program.md` (exo-267.7). A quest is
//! issued by an account (a circle's multisig vault, granted by the multisig's Execute, or
//! a person's own account), accepted by its taker's own signature, confirmed by its
//! confirmer's, and closed by its issuer. The bounty is held in the record account's own
//! native balance from Open until Close pays it to the taker or Cancel returns it.

use borsh::{BorshDeserialize, BorshSerialize};
use lee_core::{account::AccountId, program::PdaSeed};
use sha2::{Digest as _, Sha256};

/// A public account id.
pub type Account = [u8; 32];

/// The native token's balance unit (LEZ v0.3's `Balance`).
pub type Balance = u128;

const RECORD_DOMAIN: &[u8; 32] = b"/lez-quest/v0.1/Record/\x00\x00\x00\x00\x00\x00\x00\x00\x00";

/// The seed of the record `issuer` keeps under `quest_id`:
/// SHA-256("/lez-quest/v0.1/Record/" padded to 32 ‖ issuer ‖ quest_id).
#[must_use]
pub fn record_seed(issuer: &Account, quest_id: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(RECORD_DOMAIN);
    h.update(issuer);
    h.update(quest_id);
    h.finalize().into()
}

/// Where the record lives: the program's public PDA under the record seed. The same account
/// holds the escrowed bounty in its native shard.
#[must_use]
pub fn record_pda(program: &AccountId, issuer: &Account, quest_id: &[u8; 32]) -> AccountId {
    AccountId::for_public_pda(program, &PdaSeed::new(record_seed(issuer, quest_id)))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum QuestStatus {
    Open,
    Accepted { taker: Account },
    Confirmed { taker: Account },
    Closed { taker: Account },
    Cancelled,
}

/// A quest, in its record PDA's own shard.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct QuestRecord {
    pub issuer: Account,
    pub quest_id: [u8; 32],
    /// The terms, hashed by whoever issues it; the text stays with them until they publish it.
    pub terms_hash: [u8; 32],
    /// Native LEZ held in the record account until Close or Cancel; 0 for none.
    pub bounty: Balance,
    pub confirmer: Account,
    /// The one account that may accept, or None: anyone but the confirmer.
    pub taker: Option<Account>,
    pub status: QuestStatus,
}

/// Rows, in order. Every instruction: the record (this program's shard of it), then the
/// account whose authorization it needs (this program's shard of it, no effect on it). With
/// a bounty, Open, Close and Cancel add the two native rows its transfer moves.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Instruction {
    /// Issue a quest. Rows: [record, issuer] + with a bounty [issuer native, record native].
    Open {
        quest_id: [u8; 32],
        terms_hash: [u8; 32],
        bounty: Balance,
        confirmer: Account,
        taker: Option<Account>,
    },
    /// The taker takes it, with their own signature. Rows: [record, taker].
    Accept { issuer: Account, quest_id: [u8; 32] },
    /// The confirmer says it is done, with their own signature. Rows: [record, confirmer].
    Confirm { issuer: Account, quest_id: [u8; 32] },
    /// The issuer closes it and the bounty goes to the taker. `taker` and `bounty` are what
    /// the record holds (plan cannot read it; apply checks them). Rows: [record, issuer] +
    /// with a bounty [record native, taker native].
    Close { quest_id: [u8; 32], taker: Account, bounty: Balance },
    /// The issuer withdraws it before it is confirmed; the bounty goes back. Rows: [record,
    /// issuer] + with a bounty [record native, issuer native].
    Cancel { quest_id: [u8; 32], bounty: Balance },
}

/// What plan asks of the record's shard; apply checks the claim against the record.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Effect {
    /// The shard is empty; write this.
    Open(QuestRecord),
    /// Open, and `taker` may take it; then Accepted.
    Accept { taker: Account },
    /// Accepted, and `confirmer` is the record's; then Confirmed.
    Confirm { confirmer: Account },
    /// Confirmed, by `issuer`'s quest, for `taker`, holding `bounty`; then Closed.
    Close { issuer: Account, taker: Account, bounty: Balance },
    /// Open or Accepted, `issuer`'s quest, holding `bounty`; then Cancelled.
    Cancel { issuer: Account, bounty: Balance },
}
