//! msig_host: the lez-msig client on LEZ v0.3 (docs/design/lez-msig.md §6).
//!
//! A `Msig` names one multisig: the program, its create key, and its placement. For the
//! private posture it also holds the PDA's keys, derived from the members' group master secret
//! (`GroupKeyHolder::derive_keys_for_pda`). It builds the program's instruction and the
//! transaction's rows from the core instruction alone, so the host and the guest agree by
//! construction. It also builds either a public transaction or a privacy-preserving one, and
//! decrypts the multisig's new note after a private execution.
//!
//! Nothing here touches a network: `exec` (the private posture's executor) and `public` (the
//! public posture without Muster: state, propose, spend, check, prepare, send) bring the chain.

pub mod exec;
pub mod public;

use std::collections::{HashMap, HashSet};

use key_protocol::key_management::{group_key_holder::GroupKeyHolder, secret_holders::PrivateKeyHolder};
use lee::{
    privacy_preserving_transaction::{
        circuit::ProgramWithDependencies, message::Message as PpMessage, witness_set::WitnessSet as PpWitnessSet,
        PrivacyPreservingTransaction,
    },
    program::Program,
    public_transaction, ProvingInput, PublicTransaction,
};
use lee_core::{
    account::{Account, AccountId, Nonce, ProgramShardSelector},
    native_token::NATIVE_TOKEN_PROGRAM_ID,
    program::ProgramId,
    Commitment, EncryptionScheme, Identifier, MembershipProof, NullifierWitness, PrivacyPreservingCircuitOutput,
    PrivateAction, PrivateWitness, SharedSecretKey, WitnessKind, DUMMY_COMMITMENT_HASH,
};
pub use msig_core;
use msig_core::{Instruction, Key, Outflow, State};
pub use msig_v03::{self, Placement, ProgramInstruction};
use msig_v03::{key_of, multisig_account, seed};

/// The guest program as built from `methods/guest`.
pub fn program() -> Program {
    Program::new(msig_methods::MSIG_ELF.into()).expect("the built guest is a valid program")
}

pub fn image_id() -> ProgramId {
    msig_methods::MSIG_ID
}

/// The embedded program's image id, hex (its words little-endian, as risc0 prints a digest).
pub fn image_id_hex() -> String {
    image_id().iter().flat_map(|w| w.to_le_bytes()).map(|b| format!("{b:02x}")).collect()
}

pub struct Msig {
    pub program: AccountId,
    pub image: ProgramId,
    pub create_key: Key,
    pub placement: Placement,
    /// The private PDA's keys (private posture only).
    pub keys: Option<PrivateKeyHolder>,
}

impl Msig {
    /// A multisig over a public PDA.
    pub fn public(program: AccountId, image: ProgramId, create_key: Key) -> Self {
        Self { program, image, create_key, placement: Placement::Public, keys: None }
    }

    /// A multisig over a group-owned private PDA, its keys derived from the group's secret.
    pub fn private(program: AccountId, image: ProgramId, create_key: Key, group: &GroupKeyHolder) -> Self {
        let keys = group.derive_keys_for_pda(&image, &seed(&create_key));
        let placement = Placement::Private {
            npk: keys.generate_nullifier_public_key(),
            vpk: keys.generate_viewing_public_key(),
            identifier: Identifier::ZERO,
        };
        Self { program, image, create_key, placement, keys: Some(keys) }
    }

    pub fn account(&self) -> AccountId {
        multisig_account(&self.program, &self.create_key, &self.placement)
    }

    /// The multisig's id as proposals name it.
    pub fn key(&self) -> Key {
        key_of(&self.account())
    }

    pub fn envelope(&self, op: Instruction) -> ProgramInstruction {
        ProgramInstruction { create_key: self.create_key, placement: self.placement.clone(), op }
    }

    /// The transaction's rows: the multisig's own shard, then exactly what the outflow selects
    /// (the guest's plan checks the same list).
    pub fn selectors(&self, op: &Instruction) -> Vec<ProgramShardSelector> {
        let a = self.account();
        let mut rows = vec![ProgramShardSelector::new(a, self.program)];
        match msig_core::claims(op).ok().and_then(|c| c.outflow) {
            None => {}
            Some(Outflow::Pay { to, .. }) => {
                rows.push(ProgramShardSelector::native_balance(a));
                rows.push(ProgramShardSelector::native_balance(AccountId::new(to)));
            }
            Some(Outflow::Invoke { rows: call_rows, .. }) => {
                rows.extend(call_rows.iter().map(|r| ProgramShardSelector::new(AccountId::new(r.account), AccountId::new(r.program))));
            }
        }
        rows
    }

    /// A public transaction (public posture). `signers` pay the fee and sign; the multisig
    /// itself needs no signature: its authority is its members' approvals.
    pub fn public_tx(&self, op: Instruction, signers: &[(&lee::PrivateKey, u128)]) -> PublicTransaction {
        let rows = self.selectors(&op);
        let nonces = signers.iter().map(|(_, n)| Nonce(*n)).collect();
        let message = public_transaction::Message::try_new(self.program, rows, nonces, self.envelope(op))
            .expect("a well-formed message");
        let keys: Vec<&lee::PrivateKey> = signers.iter().map(|(k, _)| *k).collect();
        let witness = public_transaction::WitnessSet::for_message(&message, &keys);
        PublicTransaction::new(message, witness)
    }

    /// The private PDA's witness: an Init when the multisig's account does not exist yet,
    /// else an Update over its current plaintext and membership proof.
    pub fn witness(&self, pre: Option<(Account, MembershipProof)>) -> PrivateWitness {
        let keys = self.keys.as_ref().expect("a private multisig holds its keys");
        let Placement::Private { npk, vpk, identifier } = &self.placement else { unreachable!() };
        PrivateWitness {
            vpk: vpk.clone(),
            random_seed: random32(),
            identifier: *identifier,
            kind: WitnessKind::Pda { binding: (self.program, seed(&self.create_key)) },
            nullifier: match pre {
                None => NullifierWitness::Init { npk: npk.clone(), commitment_root: DUMMY_COMMITMENT_HASH },
                Some((account, membership_proof)) => NullifierWitness::Update {
                    account,
                    view_tag: 0,
                    nsk: keys.nullifier_secret_key(),
                    membership_proof,
                },
            },
        }
    }

    /// A privacy-preserving transaction (private posture): proves the program's execution over
    /// the multisig's note, plus any `extra` private witnesses (a private recipient's Init).
    /// `RISC0_DEV_MODE` decides whether the proof is real. Returns the transaction and the
    /// multisig's new plaintext account (decrypted from its note, as any member would).
    pub fn private_tx(
        &self,
        op: Instruction,
        pre: Option<(Account, MembershipProof)>,
        extra: Vec<PrivateWitness>,
        deps: HashMap<AccountId, Program>,
    ) -> Result<(PrivacyPreservingTransaction, Option<Account>), lee::error::LeeError> {
        let rows = self.selectors(&op);
        let mut witnesses = vec![self.witness(pre)];
        witnesses.extend(extra);
        let input = ProvingInput {
            shard_selectors: rows,
            signers: HashSet::new(),
            private_witnesses: witnesses,
            instruction_data: Program::serialize_instruction(self.envelope(op))?,
            dummy_inputs: vec![],
            ciphertext_padding: Some(1024),
        };
        let pwd = ProgramWithDependencies::new(program(), self.program, deps);
        let (output, proof) = lee::execute_and_prove(input, &pwd)?;
        let post = self.decrypt_post(&output);
        let message = PpMessage::from_circuit_output(vec![], output);
        let witness = PpWitnessSet::for_message(&message, proof, &[]);
        Ok((PrivacyPreservingTransaction::new(message, witness), post))
    }

    /// The multisig's new plaintext account from a private execution's output, found by
    /// decrypting each note with the PDA's viewing key and matching its commitment.
    pub fn decrypt_post(&self, output: &PrivacyPreservingCircuitOutput) -> Option<Account> {
        self.decrypt_actions(&output.private_actions)
    }

    /// The multisig's account among a transaction's private actions, as a member decrypts it;
    /// None when none of them is the multisig's. This is how a member reads a note from the
    /// chain when no one carried it into the room (exo-abc).
    pub fn decrypt_actions(&self, actions: &[PrivateAction]) -> Option<Account> {
        let keys = self.keys.as_ref()?;
        let vsk = &keys.viewing_secret_key;
        let a = self.account();
        actions.iter().find_map(|action| {
            let ss = SharedSecretKey::decapsulate(&action.encrypted_post_state.epk, &vsk.d, &vsk.z)?;
            let (_, account) = EncryptionScheme::decrypt(&action.encrypted_post_state.ciphertext, &ss, &action.nullifier)?;
            (action.commitment == Commitment::new(&a, &account)).then_some(account)
        })
    }

    /// The multisig's state from its account: the program's own shard.
    pub fn state_of(&self, account: &Account) -> Option<State> {
        let shard = account.data.shard(self.program);
        if shard.is_empty() {
            return None;
        }
        borsh::from_slice(shard.as_ref()).ok()
    }
}

/// The vault's balance: the native shard of the multisig's account.
pub fn vault_balance(account: &Account) -> u128 {
    account.data.native_balance().unwrap_or(0)
}

pub fn native() -> AccountId {
    NATIVE_TOKEN_PROGRAM_ID
}

fn random32() -> [u8; 32] {
    use std::time::{SystemTime, UNIX_EPOCH};
    // The random seed only blinds the note; any unpredictable value does.
    let mut b = [0u8; 32];
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos().to_le_bytes();
    b[..16].copy_from_slice(&t);
    let id = std::process::id().to_le_bytes();
    b[16..20].copy_from_slice(&id);
    msig_core::tagged(b"muster-msig/v1/blind", &b)
}
