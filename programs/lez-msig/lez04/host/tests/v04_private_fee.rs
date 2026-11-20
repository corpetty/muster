//! D17 (docs/design/lez-msig.md): who pays a private lez-msig step's fee on LEZ v0.4. A private
//! transaction pays its fee inside the proof, from a regular private account whose witness holds
//! its authorization key; a PDA cannot. Option A: a regular account derived from the group's
//! secret (GMS), so every member derives the same fee account, witnessed `FeeOnly` so the proof
//! authorizes it for the fee entry alone. On LEE's own state, no sequencer, dev-mode proofs:
//! - a private Create, its fee paid by the group's fee account: the fee reaches the inbox and
//!   the fee account's note is spent;
//! - the same fee account without its authorization key (a nullifier key only) cannot pay;
//! - the multisig's own PDA cannot pay its fee.

use std::collections::BTreeMap;

use key_protocol::key_management::{group_key_holder::GroupKeyHolder, secret_holders::PrivateKeyHolder};
use lee::{
    privacy_preserving_transaction::{circuit::ProgramCatalog, message::Message, witness_set::WitnessSet},
    test_utils::no_seal,
    PrivacyPreservingTransaction, ProvingInput, PublicExecutionContext, RootCall, SenderPresentation, Simulation,
    TransactionEntry, V03State,
};
use lee_core::{
    account::{Account, AccountId, Actor, Nonce},
    native_token::{encode_balance, NATIVE_TOKEN_PROGRAM_ID},
    Commitment, FeeTransfer, MembershipProof, Nullifier, NullifierWitness, PrivateWitness, RegularKey, WitnessKind,
    DUMMY_COMMITMENT_HASH,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{fee_derivation_id, program, Msig, Placement};

const ZONE: Key = [0x2e; 32];
const P: [u8; 32] = [0xa4; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const FEE: u128 = 40;

struct Group {
    gms: GroupKeyHolder,
    m: Msig,
    pda: PrivateKeyHolder,
}

fn group() -> Group {
    let gms = GroupKeyHolder::new();
    let create_key: Key = rand::random();
    let pda = gms.derive_keys_for_pda(&program().id(), &msig_v04::seed(&create_key));
    let placement = Placement::Private {
        npk: pda.generate_nullifier_public_key(),
        vpk: pda.generate_viewing_public_key(),
    };
    Group { m: Msig { program: AccountId::new(P), create_key, placement }, gms, pda }
}

fn fee_keys(g: &Group) -> PrivateKeyHolder {
    g.gms.derive_regular_shared_account_keys(&fee_derivation_id(&g.m.create_key))
}

fn fee_account_id(k: &PrivateKeyHolder) -> AccountId {
    AccountId::for_regular_private_account(&k.generate_nullifier_public_key(), &k.generate_viewing_public_key())
}

fn funded(balance: u128) -> Account {
    let mut a = Account::default();
    a.data.set_actor_state(NATIVE_TOKEN_PROGRAM_ID, encode_balance(balance));
    a
}

fn config(s: &[Signer]) -> Config {
    Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

/// A zone with the program, the fee inbox, and the group's fee account holding `balance` as a
/// private note (seeded directly; the wallet would shield into it).
fn zone(g: &Group, balance: u128) -> (V03State, Account, MembershipProof) {
    let fee_id = fee_account_id(&fee_keys(g));
    let note = funded(balance);
    let commitment = Commitment::new(&fee_id, &note);
    let unrelated = Nullifier::for_account_update(&Commitment::new(&AccountId::new([1; 32]), &Account::default()), &[3; 32]);
    let state = V03State::new()
        .with_named_programs([(g.m.program, program())])
        .with_public_account_balances([(AccountId::new(INBOX), 1)])
        .with_private_accounts([(commitment.clone(), unrelated)]);
    let proof = state.get_proof_for_commitment(&commitment).expect("the fee note is in the set");
    (state, note, proof)
}

/// The private multisig's Create, initialising its PDA, with `payer` paying the fee.
fn private_create(
    g: &Group,
    s: &[Signer],
    payer: AccountId,
    extra: Vec<PrivateWitness>,
) -> Result<PrivacyPreservingTransaction, lee::error::LeeError> {
    let op = Instruction::Create { zone: ZONE, config: config(s) };
    let message = lee::program::Program::serialize_message(g.m.envelope(op)).expect("borsh");
    let pda = PrivateWitness {
        vpk: g.pda.generate_viewing_public_key(),
        random_seed: rand::random(),
        kind: WitnessKind::Pda { nsk: g.pda.nullifier_secret_key(), binding: (g.m.program, msig_v04::seed(&g.m.create_key)) },
        nullifier: NullifierWitness::Init { commitment_root: DUMMY_COMMITMENT_HASH },
        address_openings: Default::default(),
    };
    let inbox = Actor::native_balance(AccountId::new(INBOX));
    let mut witnesses = vec![pda];
    witnesses.extend(extra);
    let input = ProvingInput {
        claims: vec![],
        root: TransactionEntry::Sync(RootCall { to: g.m.root(), message }),
        public_context: PublicExecutionContext::new(vec![inbox], []),
        private_witnesses: witnesses,
        dummy_inputs: vec![],
        ciphertext_padding: None,
        recoveries: vec![],
        private_promotions: Default::default(),
        fee: Some(FeeTransfer { payer, recipient: inbox.account_id, amount: FEE, refund_to: None }),
    };
    let simulation = Simulation { public_actor_states: [(inbox, encode_balance(1))].into(), admitted_accounts: None };
    let programs = ProgramCatalog::from([(g.m.program, program())]);
    let (output, proof) =
        lee::execute_and_prove(input, &simulation, &programs, |_| SenderPresentation::Canonical, |_, _| false, no_seal)?;
    let message = Message::from_circuit_output(BTreeMap::<AccountId, Nonce>::new(), output);
    let witness_set = WitnessSet::for_message(&message, proof, &[]);
    Ok(PrivacyPreservingTransaction::new(message, witness_set))
}

fn fee_witness(k: &PrivateKeyHolder, kind: RegularKey, note: Account, proof: MembershipProof) -> PrivateWitness {
    PrivateWitness {
        vpk: k.generate_viewing_public_key(),
        random_seed: rand::random(),
        kind: WitnessKind::Regular(kind),
        nullifier: NullifierWitness::Update { account: note, membership_proof: proof },
        address_openings: Default::default(),
    }
}

fn dev_mode() {
    std::env::set_var("RISC0_DEV_MODE", "1");
}

#[test]
fn the_group_fee_account_pays_a_private_create_fee_only() {
    dev_mode();
    let g = group();
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let (mut state, note, proof) = zone(&g, 1_000);
    let k = fee_keys(&g);
    let payer = fee_account_id(&k);

    // Every member derives the same fee account from the GMS alone.
    let again = GroupKeyHolder::from_gms(*g.gms.dangerous_raw_gms());
    assert_eq!(fee_account_id(&again.derive_regular_shared_account_keys(&fee_derivation_id(&g.m.create_key))), payer);

    let w = fee_witness(&k, RegularKey::FeeOnly(k.authorization_secret_key), note.clone(), proof);
    let tx = private_create(&g, &s, payer, vec![w]).expect("proved");
    state.transition_from_privacy_preserving_transaction(&tx, 1, 0).expect("the zone accepts it");

    assert_eq!(state.get_account_by_id(AccountId::new(INBOX)).data.native_balance().unwrap(), 1 + FEE, "the fee reached the inbox");
    let spent = Nullifier::for_account_update(&Commitment::new(&payer, &note), &k.nullifier_secret_key());
    assert!(state.is_spent(&spent), "the fee account's note is spent");
}

#[test]
fn without_its_authorization_key_the_fee_account_cannot_pay() {
    dev_mode();
    let g = group();
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let (_, note, proof) = zone(&g, 1_000);
    let k = fee_keys(&g);
    let w = fee_witness(&k, RegularKey::Nullifying(k.nullifier_secret_key()), note, proof);
    let e = format!("{:?}", private_create(&g, &s, fee_account_id(&k), vec![w]).err().expect("refused"));
    assert!(e.contains("FeePayerWithoutAuthorization"), "got: {e}");
}

#[test]
fn the_multisig_pda_cannot_pay_its_own_fee() {
    dev_mode();
    let g = group();
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let e = format!("{:?}", private_create(&g, &s, g.m.account(), vec![]).err().expect("refused"));
    assert!(e.contains("FeePayer"), "got: {e}");
}
