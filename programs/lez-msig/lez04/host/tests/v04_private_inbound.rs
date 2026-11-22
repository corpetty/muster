//! Deposits from outside the group into a private lez-msig on LEZ v0.4 (exo-05f). On LEE's own
//! state, dev-mode proofs. The vault's Create registers its recovery binding, so anyone can pay the
//! vault's address from an ordinary public account: the zone publishes the credit in the clear,
//! the group recovers it with its keys, and its next private transaction collects it.
//! - an outsider pays the vault's address publicly; the group finds the deposit and collects it
//!   while 2 of 3 pay out, and the vault's note holds the deposit less the payment;
//! - the same deposit cannot be collected twice;
//! - a vault whose Create registered no binding cannot be paid from a public account.

use std::collections::{BTreeMap, HashMap};

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, PublicTransaction, V03State};
use lee_core::{
    account::{Account, AccountId, Actor, Nonce},
    native_token::Message as NativeMessage,
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{native_state, program, vault_balance, Extras, Msig, PrivateFee, Proven};

const ZONE: Key = [0x2e; 32];
const INBOX: [u8; 32] = [0xfe; 32];
const PAYEE: [u8; 32] = [0x0e; 32];
const FEE: u128 = 40;

struct Room {
    state: V03State,
    m: Msig,
    s: Vec<Signer>,
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
    fn land(&mut self, p: Proven, keys: &[&PrivateKey]) {
        self.block += 1;
        self.state.transition_from_privacy_preserving_transaction(&p.signed(keys), self.block, self.block * 1000).expect("accepted");
        if p.post.is_some() {
            self.note = p.post;
        }
        self.fee_note = p.fee_post.expect("the fee note decrypts");
    }
    fn pay(&self, nonce: u64, amount: u128) -> Instruction {
        let p = Proposal { multisig: self.m.key(), zone: ZONE, epoch: 0, nonce, action: Action::Transfer { to: PAYEE, amount },
                           expires_ms: 1_000_000, proposer: self.s[0].key() };
        Instruction::Execute { proposal: p.clone(), approvals: vec![self.s[0].approve(&p), self.s[1].approve(&p)], executor: None }
    }
}

/// An outsider's public transfer of `amount` to `to`.
fn outsider_pays(state: &mut V03State, key: &PrivateKey, nonce: u128, to: AccountId, amount: u128, block: u64)
    -> Result<(), lee::error::LeeError> {
    let from = AccountId::from(&PublicKey::new_from_private_key(key));
    let root = Actor::native_balance(from);
    let msg = lee::public_transaction::Message::try_new(root, vec![root], BTreeMap::from([(from, Nonce(nonce))]),
                                                       NativeMessage::Transfer { to, amount }).unwrap();
    let tx = PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[key]));
    state.transition_from_public_transaction(&tx, block, block * 1000).map(|_| ())
}

/// A private multisig of 3, 2 to pay, its fee account topped up; `bound` registers the vault's
/// recovery binding at Create.
fn setup(bound: bool) -> (Room, PrivateKey) {
    std::env::set_var("RISC0_DEV_MODE", "1");
    let m = Msig::private(AccountId::new([0xa4; 32]), &program().id(), rand::random(), &GroupKeyHolder::new());
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let member = PrivateKey::try_new([7; 32]).unwrap();
    let outsider = PrivateKey::try_new([9; 32]).unwrap();
    let ids = [&member, &outsider].map(|k| AccountId::from(&PublicKey::new_from_private_key(k)));
    let inbox = AccountId::new(INBOX);
    let state = V03State::new()
        .with_named_programs([(m.program, program())])
        .with_public_account_balances([(inbox, 1), (AccountId::new(PAYEE), 1), (ids[0], 100_000), (ids[1], 100_000)]);
    let mut r = Room { state, m, s, note: None, fee_note: Account::default(), block: 0 };
    let p = r.m.top_up_fee_tx(ids[0], 0, 1_000, None, FEE, inbox, r.states(&[ids[0], inbox])).unwrap();
    r.land(p, &[&member]);
    let config = Config {
        members: r.s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let extras = Extras { recoveries: if bound { vec![r.m.vault_binding()] } else { vec![] }, ..Default::default() };
    let p = r.m.private_tx_with(Instruction::Create { zone: ZONE, config }, None, Some(r.fee()), r.states(&[inbox]), extras).unwrap();
    r.land(p, &[]);
    (r, outsider)
}

#[test]
fn an_outsider_pays_the_vault_and_the_group_collects_it_once() {
    let (mut r, outsider) = setup(true);
    let (payee, inbox) = (AccountId::new(PAYEE), AccountId::new(INBOX));
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 0, "an empty vault");

    r.block += 1;
    outsider_pays(&mut r.state, &outsider, 0, r.m.account(), 3_000, r.block).expect("the outsider's public payment lands");

    // the group finds it with its keys
    let found: Vec<_> = r.state.publications_from(0).filter_map(|(pos, p)| r.m.inbound(&p).map(|b| (pos, b))).collect();
    assert_eq!(found.len(), 1, "one deposit for the vault");
    let (pos, body) = found[0].clone();
    let claim = r.m.claim(body.clone(), r.state.get_proof_for_position(pos).expect("its leaf"));

    // the next private transaction collects it while 2 of 3 pay out
    let extras = Extras { claims: vec![claim], ..Default::default() };
    let p = r.m.private_tx_with(r.pay(0, 1_000), r.pre(), Some(r.fee()), r.states(&[payee, inbox]), extras).expect("proves");
    r.land(p, &[]);
    assert_eq!(vault_balance(r.note.as_ref().unwrap()), 2_000, "the deposit collected, the payment made");
    assert_eq!(vault_balance(&r.state.get_account_by_id(payee)), 1 + 1_000);

    // collecting it again is refused
    let again = r.m.claim(body, r.state.get_proof_for_position(pos).unwrap());
    let p = r.m.private_tx_with(r.pay(1, 10), r.pre(), Some(r.fee()), r.states(&[payee, inbox]),
                                Extras { claims: vec![again], ..Default::default() });
    let refused = match p {
        Err(_) => true,
        Ok(p) => r.state.transition_from_privacy_preserving_transaction(&p.signed(&[]), r.block + 1, (r.block + 1) * 1000).is_err(),
    };
    assert!(refused, "a deposit is collected once");
}

#[test]
fn an_unbound_vault_cannot_be_paid_publicly() {
    let (mut r, outsider) = setup(false);
    r.block += 1;
    let e = format!("{:?}", outsider_pays(&mut r.state, &outsider, 0, r.m.account(), 3_000, r.block).err().expect("refused"));
    assert!(e.contains("UnboundAsyncDestination"), "got: {e}");
}
