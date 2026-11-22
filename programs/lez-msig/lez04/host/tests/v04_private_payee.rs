//! A private lez-msig paying a PRIVATE payee on LEZ v0.4 (exo-05f). On LEE's own state, dev-mode
//! proofs. The payee shares a `Recipient` (its nullifier and viewing public keys); the multisig's
//! payment names its address. Inside the proof the credit is an async message to an account the
//! transaction does not hold, so it is sealed to the recipient and published:
//! - 2 of 3 pay the payee from the private vault, the fee from the group's fee account; the
//!   transaction's bytes never name the payee's address;
//! - only the payee's keys open the sealed message;
//! - the payee claims it in a transaction of its own, paying that fee out of the credit, and its
//!   new note holds the payment less the fee.
//! Without a recipient, `private_tx` treats a payee as public, as for any public payee.

use std::collections::HashMap;

use key_protocol::key_management::{group_key_holder::GroupKeyHolder, secret_holders::PrivateKeyHolder};
use lee::{
    privacy_preserving_transaction::{circuit::ProgramCatalog, message::Message, witness_set::WitnessSet},
    PrivacyPreservingTransaction, PrivateKey, ProvingInput, PublicExecutionContext, PublicKey, Recipient,
    SenderPresentation, Simulation, TransactionEntry, V03State,
};
use lee_core::{
    account::{Account, AccountId, Actor},
    program::Publication,
    Commitment, DummyOutput, EncryptionScheme, FeeTransfer, MembershipProof, MessageWitness, NullifierWitness,
    PrivateAccountKind, PrivateWitness, RegularKey, SharedSecretKey, WitnessKind, DUMMY_COMMITMENT_HASH,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, program, vault_balance, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const FEE: u128 = 40;

struct Room {
    state: V03State,
    m: Msig,
    note: Option<Account>,
    fee_note: Account,
    block: u64,
}

impl Room {
    fn proof(&self, id: AccountId, note: &Account) -> MembershipProof {
        self.state.get_proof_for_commitment(&Commitment::new(&id, note)).expect("the note is in the set")
    }
    fn fee(&self) -> PrivateFee {
        PrivateFee { note: self.fee_note.clone(), proof: self.proof(self.m.fee_account().unwrap(), &self.fee_note),
                     amount: FEE, inbox: AccountId::new(INBOX) }
    }
    fn pre(&self) -> Option<(Account, MembershipProof)> {
        self.note.clone().map(|n| (n.clone(), self.proof(self.m.account(), &n)))
    }
    fn states(&self, ids: &[AccountId]) -> HashMap<Actor, lee_core::account::ActorState> {
        ids.iter().map(|id| (Actor::native_balance(*id), native_state(&self.state.get_account_by_id(*id)))).collect()
    }
    fn land(&mut self, p: Proven, keys: &[&PrivateKey]) -> PrivacyPreservingTransaction {
        self.block += 1;
        let tx = p.signed(keys);
        self.state.transition_from_privacy_preserving_transaction(&tx, self.block, self.block * 1000).expect("accepted");
        if p.post.is_some() {
            self.note = p.post;
        }
        self.fee_note = p.fee_post.expect("the fee note decrypts");
        tx
    }
}

fn recipient_of(k: &PrivateKeyHolder) -> Recipient {
    Recipient { npk: k.generate_nullifier_public_key(), vpk: k.generate_viewing_public_key(),
                kind: PrivateAccountKind::Regular, opening: None }
}

/// A multisig of 3, 2 to pay, created, its vault holding 5000 and its fee account funded.
fn setup() -> (Room, Vec<Signer>) {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let group = GroupKeyHolder::new();
    let m = Msig::private(AccountId::new([0xa4; 32]), &program().id(), rand::random(), &group);
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let depositor = PrivateKey::try_new([7; 32]).unwrap();
    let dep = AccountId::from(&PublicKey::new_from_private_key(&depositor));
    let inbox = AccountId::new(INBOX);
    let state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(inbox, 1), (dep, 100_000)]);
    let mut r = Room { state, m, note: None, fee_note: Account::default(), block: 0 };
    let p = r.m.top_up_fee_tx(dep, 0, 1_000, None, FEE, inbox, r.states(&[dep, inbox])).unwrap();
    r.land(p, &[&depositor]);
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let p = r.m.private_tx(Instruction::Create { zone: ZONE, config }, None, Some(r.fee()), r.states(&[inbox])).unwrap();
    r.land(p, &[]);
    let p = r.m.deposit_tx(dep, 1, 5_000, r.pre(), Some(r.fee()), r.states(&[dep, inbox])).unwrap();
    r.land(p, &[&depositor]);
    (r, s)
}

fn pay(r: &Room, s: &[Signer], to: AccountId, amount: u128) -> Instruction {
    let p = Proposal { multisig: r.m.key(), zone: ZONE, epoch: 0, nonce: 0,
                       action: Action::Transfer { to: to.as_ref().try_into().unwrap(), amount },
                       expires_ms: 1_000_000, proposer: s[0].key() };
    Instruction::Execute { proposal: p.clone(), approvals: vec![s[0].approve(&p), s[1].approve(&p)], executor: None }
}

#[test]
fn a_private_payee_is_paid_by_a_sealed_message_it_alone_claims() {
    let (mut r, s) = setup();
    let inbox = AccountId::new(INBOX);
    let payee = GroupKeyHolder::new().derive_regular_shared_account_keys(&[9; 32]);
    let to = recipient_of(&payee);
    let address = to.address();

    // 2 of 3 pay the private payee; its credit is sealed to it, not declared
    let p = r.m.private_tx_sealed(pay(&r, &s, address, 1_200), r.pre(), Some(r.fee()), r.states(&[inbox]), &[to.clone()])
        .expect("the payment proves");
    let tx = r.land(p, &[]);
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 3_800, "the vault paid");
    assert!(!borsh::to_vec(&tx).unwrap().windows(32).any(|w| w == address.as_ref()), "the payee's address is nowhere in the transaction");

    // only the payee opens it
    let sealed: Vec<_> = r.state.publications_from(0)
        .filter_map(|(pos, p)| match p { Publication::Sealed(x) => Some((pos, x)), _ => None })
        .collect();
    assert_eq!(sealed.len(), 1, "one sealed message");
    let (position, msg) = &sealed[0];
    let stranger = GroupKeyHolder::new().derive_regular_shared_account_keys(&[1; 32]);
    let vs = &stranger.viewing_secret_key;
    assert!(msg.open(stranger.generate_nullifier_public_key(), &vs.d, &vs.z).is_none(), "nobody else opens it");
    let vk = &payee.viewing_secret_key;
    let (body, opened, rho) = msg.open(payee.generate_nullifier_public_key(), &vk.d, &vk.z).expect("the payee opens it");
    assert_eq!((body.to.account_id, opened.address()), (address, address));

    // the payee claims it, paying that fee out of the credit
    let witness = PrivateWitness {
        vpk: payee.generate_viewing_public_key(),
        random_seed: rand::random(),
        kind: WitnessKind::Regular(RegularKey::Authorized(payee.authorization_secret_key)),
        nullifier: NullifierWitness::Init { commitment_root: DUMMY_COMMITMENT_HASH },
        address_openings: Default::default(),
    };
    let input = ProvingInput {
        claims: vec![],
        root: TransactionEntry::Async(MessageWitness {
            body: body.clone(), rho: Some(rho),
            membership_proof: r.state.get_proof_for_position(*position).expect("the message's leaf"),
            filler: DummyOutput::default(),
        }),
        public_context: PublicExecutionContext::new(vec![Actor::native_balance(inbox)], []),
        private_witnesses: vec![witness],
        dummy_inputs: vec![], ciphertext_padding: None, recoveries: vec![], private_promotions: Default::default(),
        fee: Some(FeeTransfer { payer: address, recipient: inbox, amount: FEE, refund_to: None }),
    };
    let sim = Simulation { public_actor_states: r.states(&[inbox]), admitted_accounts: None };
    let (output, proof) = lee::execute_and_prove(input, &sim, &ProgramCatalog::default(),
        |_| SenderPresentation::Canonical, |_, _| false,
        |b| Err(lee::error::LeeError::InvalidInput(format!("no seal {:?}", b.to)))).expect("the claim proves");
    let note = output.execution.private_actions.iter().find_map(|a| {
        let ss = SharedSecretKey::decapsulate(&a.encrypted_post_state.epk, &vk.d, &vk.z)?;
        let (_, acc) = EncryptionScheme::decrypt(&a.encrypted_post_state.ciphertext, &ss, &a.nullifier)?;
        output.execution.private_actions.iter().any(|x| x.commitment == Commitment::new(&address, &acc)).then_some(acc)
    }).expect("the payee's new note");
    let message = Message::from_circuit_output(Default::default(), output);
    let claim = PrivacyPreservingTransaction::new(message.clone(), WitnessSet::for_message(&message, proof, &[]));
    r.state.transition_from_privacy_preserving_transaction(&claim, r.block + 1, (r.block + 1) * 1000).expect("the claim lands");
    assert_eq!(vault_balance(&note), 1_200 - FEE, "the payee holds the payment less its own fee");
}
