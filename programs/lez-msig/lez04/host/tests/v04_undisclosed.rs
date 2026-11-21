//! D18 (docs/design/lez-msig.md): a private lez-msig execution on LEZ v0.4 discloses which program
//! ran unless it is proved against an immutable header. On LEE's own state, dev-mode proofs, the
//! program deployed through the loader as on a zone: segments, then an immutable header, whose
//! account is the program's.
//! - proved the default way, the transaction names the program (`ProgramImageClaim::Disclosed`);
//! - proved undisclosed, it carries only a commitment-set root (`Undisclosed`), names no program,
//!   and the zone accepts it;
//! - an undisclosed claim against a header that was never deployed is refused.

use std::collections::BTreeMap;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, PublicTransaction, V03State};
use lee_core::{
    account::{Account, AccountId, ActorState, Nonce},
    program::{immutable_mirror_commitment, ProgramHeader, ProgramSegment, PROGRAM_LOADER_ACCOUNT_ID},
    ProgramImageClaim,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{program, Msig};
use program_loader_core::{Message as LoaderMessage, MAX_SEGMENT_DATA_LEN};

const ZONE: Key = [0x2e; 32];

/// Deploys the guest as a zone does: its user ELF in segments, then an immutable header naming
/// the first. The segments are written directly (their content is what the loader checks); the
/// header is a real loader transaction, which computes the image id and lands the mirror
/// commitment.
fn deploy(state: &mut V03State) -> (AccountId, ProgramHeader) {
    let elf = risc0_binfmt::ProgramBinary::decode(msig_methods04::MSIG_ELF).expect("a program binary").user_elf.to_vec();
    let chunks: Vec<&[u8]> = elf.chunks(MAX_SEGMENT_DATA_LEN).collect();
    let ids: Vec<AccountId> = (0..chunks.len()).map(|i| AccountId::new([0x40 + i as u8; 32])).collect();
    for i in (0..chunks.len()).rev() {
        let seg = ProgramSegment { bytecode: chunks[i].to_vec(), next_segment: ids.get(i + 1).copied() };
        state.force_insert_account(
            ids[i],
            Account::default().with_actor_state(PROGRAM_LOADER_ACCOUNT_ID, ActorState::from(seg.to_loader_actor_state())),
        );
    }
    let key = PrivateKey::try_new([0x11; 32]).unwrap();
    let header = AccountId::from(&PublicKey::new_from_private_key(&key));
    let actor = lee_core::account::Actor::new(header, PROGRAM_LOADER_ACCOUNT_ID);
    let msg = lee::public_transaction::Message::try_new(
        actor,
        vec![actor],
        BTreeMap::from([(header, Nonce(0))]),
        LoaderMessage::CreateHeader { first_segment: ids[0], immutable: true },
    )
    .unwrap();
    let tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[&key]));
    state.transition_from_public_transaction(&tx, 1, 0).expect("the immutable header deploys");
    (header, ProgramHeader { image_id: program().id(), program_first_segment: ids[0], immutable: true })
}

fn create(m: &Msig) -> lee::PrivacyPreservingTransaction {
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    };
    m.private_tx(Instruction::Create { zone: ZONE, config }, None, None, Default::default()).expect("proves").tx
}

fn claims(tx: &lee::PrivacyPreservingTransaction) -> Vec<ProgramImageClaim> {
    tx.message().execution.program_image_claims.clone()
}

#[test]
fn an_undisclosed_execution_names_no_program_and_lands() {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let mut state = V03State::new();
    let (header, ph) = deploy(&mut state);
    let group = GroupKeyHolder::new();

    // the default: the transaction names the program
    let disclosed = create(&Msig::private(header, &ph.image_id, rand::random(), &group));
    assert!(
        claims(&disclosed).iter().any(|c| matches!(c, ProgramImageClaim::Disclosed { account_id, .. } if *account_id == header)),
        "a default proof discloses the program"
    );
    state.transition_from_privacy_preserving_transaction(&disclosed, 2, 0).expect("the disclosed Create lands");

    // D18: proved against the immutable header, it names none
    let proof = state.get_proof_for_commitment(&immutable_mirror_commitment(header, &ph)).expect("the mirror commitment");
    let m = Msig::private(header, &ph.image_id, rand::random(), &group).with_undisclosed(ph, proof);
    let tx = create(&m);
    let c = claims(&tx);
    assert!(!c.is_empty() && c.iter().all(|c| matches!(c, ProgramImageClaim::Undisclosed { .. })), "only a root: {c:?}");
    let bytes = borsh::to_vec(&tx).unwrap();
    assert!(!bytes.windows(32).any(|w| w == header.as_ref()), "the program's account appears nowhere in the transaction");
    state.transition_from_privacy_preserving_transaction(&tx, 3, 0).expect("the zone accepts the undisclosed Create");
}

#[test]
fn an_undisclosed_claim_against_no_deployed_header_is_refused() {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let mut deployed = V03State::new();
    let (header, ph) = deploy(&mut deployed);
    let proof = deployed.get_proof_for_commitment(&immutable_mirror_commitment(header, &ph)).unwrap();
    // a zone that never saw the header: the claim's root is not one of its roots
    let mut other = V03State::new();
    let m = Msig::private(header, &ph.image_id, rand::random(), &GroupKeyHolder::new()).with_undisclosed(ph, proof);
    assert!(other.transition_from_privacy_preserving_transaction(&create(&m), 1, 0).is_err(), "refused");
}
