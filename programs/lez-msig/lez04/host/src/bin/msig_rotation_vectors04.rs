//! Ground truth for Muster's Nim port of D19's bytes (exo-3dc, docs/design/lez-msig.md §7, "D19 in
//! detail"), from fixed inputs: a `Rotate` proposal, its id, an approval, the Execute envelope, a
//! `Sweep` envelope, the retired record a rotation stores, and the handover it sends. Signatures
//! use fixed auxiliary randomness. Nothing here touches the bytes of anything from before D19.
//!   cargo run -p msig_host04 --bin msig_rotation_vectors04 > ../../../module/tests/vectors/lez-msig/v04-rotation.json

use lee_core::account::AccountId;
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::Msig;

fn h(b: &[u8]) -> String {
    hex::encode(b)
}

fn main() {
    let program = AccountId::new([0xa4; 32]);
    let m = Msig::public(program, [0x22; 32]);
    let s: Vec<Signer> = (1..=3u8).map(|i| Signer::from_secret(&[i; 32])).collect();
    let zone: Key = [0x2e; 32];
    let (ck2, successor): (Key, Key) = ([0x33; 32], [0x44; 32]);
    let p = Proposal {
        multisig: m.key(),
        zone,
        epoch: 4,
        nonce: 7,
        action: Action::Rotate { create_key: ck2, successor, changes: vec![ConfigChange::RemoveMember(s[2].key())] },
        expires_ms: 1_800_000_000_000,
        proposer: s[0].key(),
    };
    let id = proposal_id(&p);
    let aux = [0x11; 32];
    let approvals: Vec<Signed> = s[..2].iter().map(|x| x.sign_with_aux(&approve_msg(&id), &aux)).collect();
    let execute = m.envelope(Instruction::Execute { proposal: p.clone(), approvals: approvals.clone(), executor: None });
    let sweep = m.envelope(Instruction::Sweep);
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let state = State {
        version: VERSION, zone, create_key: m.create_key, epoch: 4, config, usage: vec![], nonce_base: 7,
        consumed: [0; 32], queue: vec![],
    };
    let ctx = Ctx { multisig: m.key(), create_key: m.create_key };
    let applied = apply_stored(Some(&Stored::Active(state)), &Instruction::Execute { proposal: p.clone(), approvals, executor: None }, &ctx, None)
        .expect("the rotation applies");
    let handover = applied.handover.expect("a handover");
    let rows = [
        ("program", h(program.as_ref())),
        ("createKey", h(&m.create_key)),
        ("multisig", h(&m.key())),
        ("successorCreateKey", h(&ck2)),
        ("successor", h(&successor)),
        ("removed", h(&s[2].key())),
        ("proposal", h(&borsh::to_vec(&p).unwrap())),
        ("proposalId", h(&id)),
        ("approveMsg", h(&approve_msg(&id))),
        ("approveSig1", h(&s[0].sign_with_aux(&approve_msg(&id), &aux).sig)),
        ("executeEnvelope", h(&borsh::to_vec(&execute).unwrap())),
        ("sweepEnvelope", h(&borsh::to_vec(&sweep).unwrap())),
        ("retired", h(&applied.post.encode())),
        ("handover", h(&borsh::to_vec(&handover).unwrap())),
    ];
    let body: Vec<String> = rows.iter().map(|(k, v)| format!("  \"{k}\": \"{v}\"")).collect();
    println!(
        "{{\n  \"source\": \"programs/lez-msig/lez04/host/src/bin/msig_rotation_vectors04.rs, D19 (exo-3dc)\",\n{}\n}}",
        body.join(",\n")
    );
}
