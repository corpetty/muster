//! D19 (docs/design/lez-msig.md §7, "D19 in detail"; exo-3dc): removing a member from a private
//! 2-of-3 rotates it, in the program. On LEE's own v0.4 state, dev-mode proofs, with the NEXT guest
//! (`artifacts/msig-next.bin`, not the deployed one). Every note is decrypted with the group's keys,
//! as a member would, and carried forward with a membership proof:
//! - the old fee account's balance moves to the successor's (a transaction of its own, before the
//!   rotation; the program does not hold the fee account);
//! - the approval that removes carol, in ONE transaction: the vault retires, the successor (a new
//!   create key, a new group secret) adopts the configuration without her, and the whole balance
//!   moves there;
//! - carol, holding only the old group secret, cannot find or read the successor;
//! - the retired vault refuses a payment, whoever approves it;
//! - a late deposit to the retired vault is swept forward;
//! - carol cannot spend, at the old vault or at the new one, and the remaining two can;
//! - an outsider can pay the successor's address publicly: the rotation registered its binding.

use std::collections::{BTreeMap, HashMap};

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, PublicTransaction, V03State};
use lee_core::{
    account::{Account, AccountId, Actor, ActorState, Nonce},
    native_token::Message as NativeMessage,
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, next_program, vault_balance, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const P: [u8; 32] = [0xa4; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const PAYEE: [u8; 32] = [0x0e; 32];
const FEE: u128 = 40;

struct Zone {
    state: V03State,
    block: u64,
}

impl Zone {
    fn proof(&self, id: AccountId, note: &Account) -> MembershipProof {
        self.state.get_proof_for_commitment(&Commitment::new(&id, note)).expect("the note is in the set")
    }
    fn at(&self, id: AccountId, note: &Account) -> (Account, MembershipProof) {
        (note.clone(), self.proof(id, note))
    }
    fn fee(&self, m: &Msig, note: &Account) -> PrivateFee {
        PrivateFee { note: note.clone(), proof: self.proof(m.fee_account().unwrap(), note), amount: FEE, inbox: AccountId::new(INBOX) }
    }
    fn states(&self, ids: &[AccountId]) -> HashMap<Actor, ActorState> {
        ids.iter().map(|id| (Actor::native_balance(*id), native_state(&self.state.get_account_by_id(*id)))).collect()
    }
    fn land(&mut self, p: &Proven, keys: &[&PrivateKey]) {
        self.block += 1;
        self.state.transition_from_privacy_preserving_transaction(&p.signed(keys), self.block, self.block * 1000).expect("the zone accepts it");
    }
    fn balance(&self, id: AccountId) -> u128 {
        vault_balance(&self.state.get_account_by_id(id))
    }
}

fn execute(s: &[Signer], p: &Proposal, who: &[usize]) -> Instruction {
    Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| s[i].approve(p)).collect(), executor: None }
}

fn refused(r: Result<Proven, lee::error::LeeError>) -> String {
    format!("{:?}", r.err().expect("refused while proving"))
}

#[test]
fn removing_a_member_rotates_the_vault_and_its_fee_account_to_a_successor() {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let guest = next_program();
    let image = guest.id();
    let (inbox, payee) = (AccountId::new(INBOX), AccountId::new(PAYEE));
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect(); // alice, bob, carol
    let carol = 2;
    let g1 = GroupKeyHolder::new();
    let m1 = Msig::private(AccountId::new(P), &image, rand::random(), &g1).with_guest(guest.clone());
    let member = PrivateKey::try_new([7; 32]).unwrap();
    let dep = AccountId::from(&PublicKey::new_from_private_key(&member));
    let outsider = PrivateKey::try_new([9; 32]).unwrap();
    let out = AccountId::from(&PublicKey::new_from_private_key(&outsider));
    let mut z = Zone {
        state: V03State::new()
            .with_named_programs([(m1.program, guest.clone())])
            .with_public_account_balances([(inbox, 1), (payee, 1), (dep, 100_000), (out, 100_000)]),
        block: 0,
    };

    // ── the 2-of-3 as it stands: fee account topped up, created, funded ──
    let p = m1.top_up_fee_tx(dep, 0, 1_000 + FEE, None, FEE, inbox, z.states(&[dep, inbox])).unwrap();
    z.land(&p, &[&member]);
    let mut fee1 = p.fee_post.unwrap();
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let p = m1.private_tx(Instruction::Create { zone: ZONE, config }, None, Some(z.fee(&m1, &fee1)), z.states(&[inbox])).unwrap();
    z.land(&p, &[]);
    let (mut a1, fee) = (p.post.unwrap(), p.fee_post.unwrap());
    fee1 = fee;
    let nonce = z.state.get_account_by_id(dep).nonce.0;
    let p = m1.deposit_tx(dep, nonce, 5_000, Some(z.at(m1.account(), &a1)), Some(z.fee(&m1, &fee1)), z.states(&[dep, inbox])).unwrap();
    z.land(&p, &[&member]);
    (a1, fee1) = (p.post.unwrap(), p.fee_post.unwrap());
    assert_eq!((vault_balance(&a1), vault_balance(&fee1)), (5_000, 1_000 - 2 * FEE));

    // ── alice's client draws the successor: a new create key under a new group secret, which
    //    alice and bob hold and carol never receives ──
    let g2 = GroupKeyHolder::new();
    let ck2: Key = rand::random();
    let m2 = Msig::private(AccountId::new(P), &image, ck2, &g2).with_guest(guest.clone());
    assert_ne!(m2.fee_account(), m1.fee_account(), "a new fee account (D17's id from the new create key, keys from GMS')");

    // the old fee account's balance moves first: the program does not hold it
    let left = vault_balance(&fee1);
    let p = m2.fee_sweep_tx(&m1, z.at(m1.fee_account().unwrap(), &fee1), left, None, FEE, inbox, z.states(&[inbox])).unwrap();
    z.land(&p, &[]);
    let old_fee = p.fee_note_of(&m1).expect("the old fee account's new note");
    let mut fee2 = p.fee_post.expect("the new fee account's first note");
    assert_eq!(vault_balance(&old_fee), 0, "nothing left for carol to drain");
    assert_eq!(vault_balance(&fee2), left - FEE, "the new fee account paid this transaction out of the credit");

    // ── the removal: ONE transaction retires the vault, hands over, and moves the balance ──
    let rotate = Proposal {
        multisig: m1.key(), zone: ZONE, epoch: 0, nonce: 0,
        action: Action::Rotate { create_key: ck2, successor: m2.key(), changes: vec![ConfigChange::RemoveMember(s[carol].key())] },
        expires_ms: 1_000_000, proposer: s[0].key(),
    };
    let lone = refused(m1.rotate_tx(&m2, execute(&s, &rotate, &[0]), z.at(m1.account(), &a1), Some(z.fee(&m2, &fee2)), z.states(&[inbox])));
    assert!(lone.contains("below-threshold"), "a rotation needs the quorum: {lone}");
    let p = m1.rotate_tx(&m2, execute(&s, &rotate, &[0, 1]), z.at(m1.account(), &a1), Some(z.fee(&m2, &fee2)), z.states(&[inbox]))
        .expect("the rotation proves");
    z.land(&p, &[]);
    a1 = p.post.clone().expect("the old vault's last note");
    let mut a2 = p.note_of(&m2).expect("the successor's first note");
    fee2 = p.fee_post.clone().unwrap();
    assert_eq!(
        m1.stored_of(&a1),
        Some(Stored::Retired(Retired { mark: RETIRED, create_key: m1.create_key, epoch: 1, successor: m2.key() })),
        "the old vault is retired, naming its successor"
    );
    assert_eq!(vault_balance(&a1), 0, "the whole balance left");
    let st = m2.state_of(&a2).expect("the successor's state");
    assert_eq!((st.epoch, st.create_key, st.config.threshold), (1, ck2, 2));
    assert_eq!(st.config.members.iter().map(|x| x.key).collect::<Vec<_>>(), vec![s[0].key(), s[1].key()]);
    assert_eq!(vault_balance(&a2), 5_000, "the vault moved to the successor in the same transaction");
    assert_eq!(vault_balance(&fee2), left - 2 * FEE, "the rotation's fee came from the new fee account");

    // carol holds only the old group secret: from it the successor's create key derives another
    // account, and nothing in the rotation decrypts for her
    let carols_guess = Msig::private(AccountId::new(P), &image, ck2, &g1).with_guest(guest.clone());
    assert_ne!(carols_guess.account(), m2.account());
    assert_eq!(p.note_of(&carols_guess), None);
    assert!(p.note_of(&m1).is_some(), "she reads the old vault up to its retirement");

    // ── the retired vault refuses a payment, at either epoch and whoever approves ──
    let old = m1.paying_fees_of(&m2);
    for (epoch, who) in [(1, [0, 1]), (0, [0, 1]), (1, [carol, 0])] {
        let pay = Proposal { multisig: m1.key(), zone: ZONE, epoch, nonce: 1, action: Action::Transfer { to: PAYEE, amount: 100 },
                             expires_ms: 1_000_000, proposer: s[who[0]].key() };
        let e = refused(old.private_tx(execute(&s, &pay, &who), Some(z.at(m1.account(), &a1)), Some(z.fee(&m2, &fee2)), z.states(&[payee, inbox])));
        assert!(e.contains("retired"), "got: {e}");
    }

    // ── a late deposit to the old address, swept forward ──
    let nonce = z.state.get_account_by_id(dep).nonce.0;
    let p = old.deposit_tx(dep, nonce, 700, Some(z.at(m1.account(), &a1)), Some(z.fee(&m2, &fee2)), z.states(&[dep, inbox])).unwrap();
    z.land(&p, &[&member]);
    (a1, fee2) = (p.post.unwrap(), p.fee_post.unwrap());
    assert_eq!(vault_balance(&a1), 700, "the deposit reached the retired vault");
    let p = m1.sweep_tx(&m2, z.at(m1.account(), &a1), z.at(m2.account(), &a2), Some(z.fee(&m2, &fee2)), z.states(&[inbox]))
        .expect("the sweep proves");
    z.land(&p, &[]);
    (a1, a2, fee2) = (p.post.clone().unwrap(), p.note_of(&m2).unwrap(), p.fee_post.unwrap());
    assert_eq!((vault_balance(&a1), vault_balance(&a2)), (0, 5_700), "swept to the successor");
    assert!(matches!(m1.stored_of(&a1), Some(Stored::Retired(_))), "still retired");
    assert_eq!(m2.state_of(&a2), Some(st.clone()), "a sweep leaves the successor's state alone");

    // ── carol cannot spend at the successor, even were she handed its keys ──
    let pay2 = |nonce: u64, proposer: usize, amount: u128| Proposal {
        multisig: m2.key(), zone: ZONE, epoch: 1, nonce, action: Action::Transfer { to: PAYEE, amount },
        expires_ms: 1_000_000, proposer: s[proposer].key(),
    };
    for who in [[carol, 0], [0, carol]] {
        let e = refused(m2.private_tx(execute(&s, &pay2(1, who[0], 100), &who), Some(z.at(m2.account(), &a2)), Some(z.fee(&m2, &fee2)),
                                      z.states(&[payee, inbox])));
        assert!(e.contains("not-a-member"), "got: {e}");
    }
    // ── the remaining two pay out of the successor ──
    let p = m2.private_tx(execute(&s, &pay2(1, 0, 1_200), &[0, 1]), Some(z.at(m2.account(), &a2)), Some(z.fee(&m2, &fee2)),
                          z.states(&[payee, inbox])).expect("2 of the remaining 2 prove");
    z.land(&p, &[]);
    a2 = p.post.unwrap();
    assert_eq!(vault_balance(&a2), 4_500);
    assert_eq!(z.balance(payee), 1 + 1_200);

    // ── an outsider pays the successor's address publicly: the rotation registered its binding ──
    z.block += 1;
    let root = Actor::native_balance(out);
    let msg = lee::public_transaction::Message::try_new(root, vec![root], BTreeMap::from([(out, Nonce(0))]),
                                                       NativeMessage::Transfer { to: m2.account(), amount: 300 }).unwrap();
    let tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[&outsider]));
    z.state.transition_from_public_transaction(&tx, z.block, z.block * 1000).expect("the outsider's payment lands");
    let found = z.state.publications_from(0).filter(|(_, p)| m2.inbound(p).is_some()).count();
    assert_eq!(found, 1, "the group finds the deposit to the successor with its new keys");
    assert_eq!(z.state.publications_from(0).filter(|(_, p)| carols_guess.inbound(p).is_some()).count(), 0);
}
