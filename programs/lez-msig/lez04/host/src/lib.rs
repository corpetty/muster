//! msig_host04: the lez-msig client on LEZ v0.4 (roadmap M3, exo-0d3.9): the public posture, and
//! the private posture (exo-05f): a group-owned private PDA whose keys, and whose fee account's
//! (D17), come from the members' group secret.
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

use std::collections::{BTreeMap, HashMap};

use key_protocol::key_management::{group_key_holder::GroupKeyHolder, secret_holders::PrivateKeyHolder};
use lee::{
    fees::FeeDeclaration,
    privacy_preserving_transaction::{circuit::ProgramCatalog, message::Message as PpMessage, witness_set::WitnessSet as PpWitnessSet},
    program::Program,
    public_transaction, PrivacyPreservingTransaction, PrivateKey, ProgramId, ProvingInput, PublicAccountEvidence,
    PublicExecutionContext, PublicKey, RecipientEncryption, RootCall, SenderPresentation, Simulation, TransactionEntry,
};
use lee_core::{
    account::{Account, AccountId, Actor, ActorState, Nonce},
    native_token::{Message as NativeMessage, NATIVE_TOKEN_PROGRAM_ID},
    program::{MessageBody, ProgramHeader},
    Commitment, EncryptionScheme, FeeTransfer, MembershipProof, NullifierWitness, PrivateAction, PrivateWitness,
    RegularKey, SharedSecretKey, WitnessKind, DUMMY_COMMITMENT_HASH,
};
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
    /// The private PDA's keys and its fee account's, from the group secret; None when public.
    keys: Option<GroupKeys>,
    /// D18: prove private executions without disclosing which program ran, against this
    /// immutable header and a membership proof of its mirror commitment.
    undisclosed: Option<(ProgramHeader, MembershipProof)>,
}

struct GroupKeys {
    pda: PrivateKeyHolder,
    fee: PrivateKeyHolder,
}

/// The fee a private transaction pays inside its proof (D17): from the group's fee account,
/// whose current note and membership proof the caller read, to the zone's fee inbox.
pub struct PrivateFee {
    pub note: Account,
    pub proof: MembershipProof,
    pub amount: u128,
    pub inbox: AccountId,
}

/// A proven private transaction, and the new notes a member decrypts from it: the multisig's
/// and, when it paid, the fee account's.
pub struct Proven {
    pub tx: PrivacyPreservingTransaction,
    pub post: Option<Account>,
    pub fee_post: Option<Account>,
}

/// No durable async message is sealed by these transactions; one would be a bug.
fn no_seal(body: &MessageBody) -> Result<RecipientEncryption, lee::error::LeeError> {
    Err(lee::error::LeeError::InvalidInput(format!("no seal for an async message to {:?}", body.to)))
}

impl Msig {
    /// A multisig over a public PDA.
    pub fn public(program: AccountId, create_key: Key) -> Self {
        Self { program, create_key, placement: Placement::Public, keys: None, undisclosed: None }
    }

    /// A multisig over a group-owned private PDA. Every member derives the same keys from the
    /// group secret: the PDA's from (the program's image, the seed), the fee account's from
    /// `fee_derivation_id` (D17).
    pub fn private(program: AccountId, image: &ProgramId, create_key: Key, group: &GroupKeyHolder) -> Self {
        let pda = group.derive_keys_for_pda(image, &seed(&create_key));
        let fee = group.derive_regular_shared_account_keys(&fee_derivation_id(&create_key));
        let placement = Placement::Private { npk: pda.generate_nullifier_public_key(), vpk: pda.generate_viewing_public_key() };
        Self { program, create_key, placement, keys: Some(GroupKeys { pda, fee }), undisclosed: None }
    }

    /// D18: private executions claim only that SOME immutable program ran (its header's mirror
    /// commitment is in the set), never which. The program must be deployed immutable at
    /// `self.program`; `proof` is the mirror commitment's membership proof, read from the zone.
    pub fn with_undisclosed(mut self, header: ProgramHeader, proof: MembershipProof) -> Self {
        self.undisclosed = Some((header, proof));
        self
    }

    fn keys(&self) -> &GroupKeys {
        self.keys.as_ref().expect("a private multisig holds its group's keys")
    }

    /// The group's fee account (D17), for a private multisig.
    pub fn fee_account(&self) -> Option<AccountId> {
        self.keys.as_ref().map(|k| {
            AccountId::for_regular_private_account(&k.fee.generate_nullifier_public_key(), &k.fee.generate_viewing_public_key())
        })
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

    /// The private PDA's witness: an Init before Create, else an Update over its current note.
    pub fn pda_witness(&self, pre: Option<(Account, MembershipProof)>) -> PrivateWitness {
        let k = &self.keys().pda;
        PrivateWitness {
            vpk: k.generate_viewing_public_key(),
            random_seed: random32(),
            kind: WitnessKind::Pda { nsk: k.nullifier_secret_key(), binding: (self.program, seed(&self.create_key)) },
            nullifier: match pre {
                None => NullifierWitness::Init { commitment_root: DUMMY_COMMITMENT_HASH },
                Some((account, membership_proof)) => NullifierWitness::Update { account, membership_proof },
            },
            address_openings: Default::default(),
        }
    }

    /// The fee account's witness: `FeeOnly`, so the proof authorizes it for the fee entry and
    /// nothing else (D17).
    pub fn fee_witness(&self, note: Account, proof: MembershipProof) -> PrivateWitness {
        let k = &self.keys().fee;
        PrivateWitness {
            vpk: k.generate_viewing_public_key(),
            random_seed: random32(),
            kind: WitnessKind::Regular(RegularKey::FeeOnly(k.authorization_secret_key)),
            nullifier: NullifierWitness::Update { account: note, membership_proof: proof },
            address_openings: Default::default(),
        }
    }

    /// The public actors a private execution declares: what `public_actors` lists, less the
    /// multisig's own account, which is private here.
    pub fn private_public_actors(&self, op: &Instruction) -> Vec<Actor> {
        let a = self.account();
        self.public_actors(op).into_iter().filter(|x| x.account_id != a).collect()
    }

    /// Proves `op` over the private PDA. `public_states` holds the current state of every public
    /// actor the transaction declares (the payee's balance, the fee inbox's), as the zone holds it.
    /// `RISC0_DEV_MODE` decides whether the proof is real.
    pub fn private_tx(
        &self,
        op: Instruction,
        pre: Option<(Account, MembershipProof)>,
        fee: Option<PrivateFee>,
        public_states: HashMap<Actor, ActorState>,
    ) -> Result<Proven, lee::error::LeeError> {
        let mut actors = self.private_public_actors(&op);
        let message = Program::serialize_message(self.envelope(op))?;
        let root = TransactionEntry::Sync(RootCall { to: self.root(), message });
        self.prove(root, &mut actors, vec![], vec![self.pda_witness(pre)], fee, public_states, &[], BTreeMap::new())
    }

    /// A deposit into the private vault: a native transfer from `payer`'s public account, which
    /// signs; the vault's credit is promoted into its note in the same proof.
    pub fn deposit_tx(
        &self,
        payer: &PrivateKey,
        payer_nonce: u128,
        amount: u128,
        pre: Option<(Account, MembershipProof)>,
        fee: Option<PrivateFee>,
        public_states: HashMap<Actor, ActorState>,
    ) -> Result<Proven, lee::error::LeeError> {
        let from = AccountId::from(&PublicKey::new_from_private_key(payer));
        let sender = Actor::native_balance(from);
        let message = borsh::to_vec(&NativeMessage::Transfer { to: self.account(), amount }).expect("borsh");
        let root = TransactionEntry::Sync(RootCall { to: sender, message });
        self.prove(root, &mut vec![sender], vec![from], vec![self.pda_witness(pre)], fee, public_states, &[payer],
                   BTreeMap::from([(from, Nonce(payer_nonce))]))
    }

    #[allow(clippy::too_many_arguments)]
    fn prove(
        &self,
        root: TransactionEntry<lee_core::MessageWitness>,
        actors: &mut Vec<Actor>,
        authorized: Vec<AccountId>,
        mut witnesses: Vec<PrivateWitness>,
        fee: Option<PrivateFee>,
        public_states: HashMap<Actor, ActorState>,
        signers: &[&PrivateKey],
        nonces: BTreeMap<AccountId, Nonce>,
    ) -> Result<Proven, lee::error::LeeError> {
        let a = self.account();
        let transfer = fee.map(|f| {
            actors.push(Actor::native_balance(f.inbox));
            witnesses.push(self.fee_witness(f.note, f.proof));
            FeeTransfer { payer: self.fee_account().expect("private"), recipient: f.inbox, amount: f.amount, refund_to: None }
        });
        let input = ProvingInput {
            claims: vec![],
            root,
            public_context: PublicExecutionContext::new(actors.clone(), authorized),
            private_witnesses: witnesses,
            dummy_inputs: vec![],
            ciphertext_padding: Some(1024),
            recoveries: vec![],
            private_promotions: Default::default(),
            fee: transfer,
        };
        let simulation = Simulation { public_actor_states: public_states, admitted_accounts: None };
        let mut programs = ProgramCatalog::from([(self.program, program())]);
        if let Some((header, proof)) = &self.undisclosed {
            programs = programs.with_undisclosed(self.program, *header, proof.clone());
        }
        let (output, proof) = lee::execute_and_prove(
            input,
            &simulation,
            &programs,
            |_| SenderPresentation::Canonical,
            |_, body: &MessageBody| body.to.account_id == a,
            no_seal,
        )?;
        let actions = &output.execution.private_actions;
        let post = self.decrypt(actions);
        let fee_post = self.decrypt_fee(actions);
        let message = PpMessage::from_circuit_output(nonces, output);
        let witness = PpWitnessSet::for_message(&message, proof, signers);
        Ok(Proven { tx: PrivacyPreservingTransaction::new(message, witness), post, fee_post })
    }

    /// The multisig's note among a transaction's private actions, as a member decrypts it.
    pub fn decrypt(&self, actions: &[PrivateAction]) -> Option<Account> {
        decrypt_with(&self.keys.as_ref()?.pda, self.account(), actions)
    }

    /// The fee account's note among a transaction's private actions.
    pub fn decrypt_fee(&self, actions: &[PrivateAction]) -> Option<Account> {
        decrypt_with(&self.keys.as_ref()?.fee, self.fee_account()?, actions)
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

/// An account's new note among a transaction's private actions. A note is keyed by its action's
/// nullifier, but the commitments are not kept in the same action as the note they commit to
/// (`PrivateAction`'s own comment), so the decrypted account is checked against every commitment
/// the transaction makes.
fn decrypt_with(k: &PrivateKeyHolder, id: AccountId, actions: &[PrivateAction]) -> Option<Account> {
    let vsk = &k.viewing_secret_key;
    actions.iter().find_map(|action| {
        let ss = SharedSecretKey::decapsulate(&action.encrypted_post_state.epk, &vsk.d, &vsk.z)?;
        let (_, account) = EncryptionScheme::decrypt(&action.encrypted_post_state.ciphertext, &ss, &action.nullifier)?;
        let c = Commitment::new(&id, &account);
        actions.iter().any(|x| x.commitment == c).then_some(account)
    })
}

fn random32() -> [u8; 32] {
    // The seed only blinds the note; any unpredictable value does.
    let mut b = [0u8; 32];
    getrandom(&mut b);
    b
}

fn getrandom(b: &mut [u8; 32]) {
    use std::io::Read;
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(b)).expect("/dev/urandom");
}

/// The native balance's actor state as a public account holds it (a payee's, the fee inbox's).
pub fn native_state(account: &Account) -> ActorState {
    account.data.actor_state(NATIVE_TOKEN_PROGRAM_ID).clone()
}

/// The vault's balance: the native balance of the multisig's account.
pub fn vault_balance(account: &Account) -> u128 {
    account.data.native_balance().unwrap_or(0)
}
