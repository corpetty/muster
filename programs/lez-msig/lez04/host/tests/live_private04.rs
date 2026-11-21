//! The private posture against a REAL LEZ v0.4 sequencer (exo-05f): a group-owned private PDA,
//! every transaction privacy-preserving and paying its fee inside its proof from the group's fee
//! account (D17), proved without disclosing the program (D18) when it is deployed immutable.
//! Skipped unless MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM (the deployed program's account, hex) are set.
//! Proofs are real unless RISC0_DEV_MODE is set, which only a dev-mode zone accepts (localnet):
//!
//!   MUSTER_LEZ_VERSION=v0.4.0-rc3 infra/lez/localnet.sh && … localnet.sh deploy <msig.bin>
//!   RISC0_DEV_MODE=1 MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> \
//!     cargo test -p msig_host04 --test live_private04 -- --nocapture
//!
//! On the devnet (real proofs): MSIG_LIVE_WAIT_S for its minute-long blocks, and run with
//! --release. In order:
//!   1. a public account tops up the group's fee account; its first fee comes out of the credit;
//!   2. the multisig is created at its private PDA;
//!   3. the public account deposits into the vault;
//!   4. 2 of 3 pay a public payee; below threshold the program refuses while proving and
//!      nothing is sent.
//! Each step prints its proving time and the fee it paid.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use common::transaction::LeeTransaction;
use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey};
use lee_core::{
    account::{Account, AccountId, Actor, ActorState},
    program::{immutable_mirror_commitment, ProgramHeader, PROGRAM_LOADER_ACCOUNT_ID},
    Commitment, MembershipProof,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host04::{fee_inbox, native_state, private_reserve, program, vault_balance, Msig, PrivateFee, Proven};
use sequencer_service_rpc::{RpcClient as _, SequencerClient, SequencerClientBuilder};

fn fund(rpc: &str, to: &AccountId, amount: u128, key: Option<&PublicKey>) {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .env("MUSTER_LEZ_VERSION", "v0.4.0-rc3")
        .args(["--zone", rpc, "fund", &hex::encode(to.as_ref()), &amount.to_string()])
        .args(key.map(|k| hex::encode(k.value())))
        .output()
        .expect("run the zone's funder");
    assert!(out.status.success(), "the funder could not pay: {}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
}

async fn until(what: &str, mut cond: impl AsyncFnMut() -> bool) {
    let wait = std::env::var("MSIG_LIVE_WAIT_S").ok().and_then(|v| v.parse().ok()).unwrap_or(120);
    let deadline = Instant::now() + Duration::from_secs(wait);
    while !cond().await {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

struct Live {
    c: SequencerClient,
    m: Msig,
    note: Option<Account>,
    fee_note: Option<Account>,
}

impl Live {
    async fn proof(&self, id: AccountId, note: &Account) -> Option<MembershipProof> {
        let (proofs, _, _) = self.c.get_proofs_and_root(vec![Commitment::new(&id, note)], vec![]).await.ok()?;
        proofs.into_iter().next().flatten()
    }

    async fn states(&self, ids: &[AccountId]) -> HashMap<Actor, ActorState> {
        let mut out = HashMap::new();
        for id in ids {
            let a = self.c.get_account(*id).await.expect("getAccount").unwrap_or_default();
            out.insert(Actor::native_balance(*id), native_state(&a));
        }
        out
    }

    async fn reserve(&self) -> u128 {
        let q = self.c.get_fee_state().await.expect("getFeeState");
        private_reserve(0, q.next_base_fee_exec_ceiling, q.next_base_fee_stor_ceiling)
    }

    async fn fee(&self) -> PrivateFee {
        let note = self.fee_note.clone().expect("the fee account is funded");
        let proof = self.proof(self.m.fee_account().unwrap(), &note).await.expect("the fee note is on chain");
        PrivateFee { note, proof, amount: self.reserve().await, inbox: fee_inbox() }
    }

    async fn pre(&self) -> Option<(Account, MembershipProof)> {
        match &self.note {
            None => None,
            Some(n) => Some((n.clone(), self.proof(self.m.account(), n).await.expect("the multisig's note is on chain"))),
        }
    }

    /// Sends a proven transaction and waits until the zone holds its new notes.
    async fn land(&mut self, step: &str, secs: f64, p: Proven) {
        let size = borsh::to_vec(&p.tx).unwrap().len();
        let fee = p.tx.message().execution.fee.as_ref().map(|_| "in the proof").unwrap_or("none");
        self.c.send_transaction(LeeTransaction::PrivacyPreserving(p.tx)).await.expect("sendTransaction");
        let fee_id = self.m.fee_account().unwrap();
        let (post, fee_post) = (p.post.clone(), p.fee_post.clone().expect("the fee note decrypts"));
        until(step, async || {
            self.proof(fee_id, &fee_post).await.is_some()
                && match &post {
                    None => true,
                    Some(n) => self.proof(self.m.account(), n).await.is_some(),
                }
        })
        .await;
        let paid = vault_balance(self.fee_note.as_ref().unwrap_or(&fee_post)).saturating_sub(vault_balance(&fee_post));
        eprintln!("{step}: proved in {secs:.1} s, {size} bytes, fee {fee}: the fee account paid {paid}");
        if post.is_some() {
            self.note = post;
        }
        self.fee_note = Some(fee_post);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn private_multisig_on_a_live_v04_zone() {
    let (Ok(rpc), Ok(prog)) = (std::env::var("MSIG_LIVE_RPC"), std::env::var("MSIG_LIVE_PROGRAM")) else {
        eprintln!("skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let c = SequencerClientBuilder::default().build(&rpc).unwrap();
    let program_id = AccountId::new(hex::decode(prog).unwrap().try_into().unwrap());
    let group = GroupKeyHolder::new();
    let mut m = Msig::private(program_id, &program().id(), rand::random(), &group);

    // D18: an immutable program is proved undisclosed
    let loader = c.get_account(program_id).await.expect("getAccount").expect("the program is deployed");
    let header = ProgramHeader::from_loader_actor_state(loader.data.actor_state(PROGRAM_LOADER_ACCOUNT_ID).as_ref())
        .expect("the program's account holds a loader header");
    assert_eq!(header.image_id, program().id(), "the deployed program is this guest");
    if header.immutable {
        let (proofs, _, _) = c.get_proofs_and_root(vec![immutable_mirror_commitment(program_id, &header)], vec![]).await.unwrap();
        m = m.with_undisclosed(header, proofs.into_iter().next().flatten().expect("the mirror commitment"));
        eprintln!("the program is immutable: every proof below names no program (D18)");
    }
    let mut l = Live { c, m, note: None, fee_note: None };

    let depositor = PrivateKey::try_new(rand::random()).unwrap();
    let dep_pk = PublicKey::new_from_private_key(&depositor);
    let dep = AccountId::from(&dep_pk);
    let reserve = l.reserve().await;
    let fund_amount = 6 * reserve + 10_000;
    fund(&rpc, &dep, fund_amount, Some(&dep_pk));
    until("the depositor's funds", async || l.c.get_account_balance(dep).await.unwrap_or(0) >= fund_amount).await;
    let payee_pk = PublicKey::new_from_private_key(&PrivateKey::try_new(rand::random()).unwrap());
    let payee = AccountId::from(&payee_pk);
    fund(&rpc, &payee, 1, Some(&payee_pk));
    until("the payee exists", async || l.c.get_account_balance(payee).await.unwrap_or(0) == 1).await;
    eprintln!("a private fee reserve here: {reserve}");
    let inbox = fee_inbox();

    // 1. top up the group's fee account
    let nonce = l.c.get_accounts_nonces(vec![dep]).await.unwrap()[0].0;
    let states = l.states(&[dep, inbox]).await;
    let t = Instant::now();
    let p = l.m.top_up_fee_tx(&depositor, nonce, 4 * reserve + reserve, None, reserve, inbox, states).expect("top-up proves");
    l.land("1. top-up of the group's fee account", t.elapsed().as_secs_f64(), p).await;

    // 2. create at the private PDA
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let zone: Key = tagged(b"muster-msig/v1/zone", b"lez:local");
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let (fee, states) = (l.fee().await, l.states(&[inbox]).await);
    let t = Instant::now();
    let p = l.m.private_tx(Instruction::Create { zone, config }, None, Some(fee), states).expect("create proves");
    l.land("2. create at the private PDA", t.elapsed().as_secs_f64(), p).await;
    assert_eq!(l.m.state_of(l.note.as_ref().unwrap()).unwrap().config.threshold, 2);

    // 3. a deposit into the vault
    let nonce = l.c.get_accounts_nonces(vec![dep]).await.unwrap()[0].0;
    let (pre, fee, states) = (l.pre().await, l.fee().await, l.states(&[dep, inbox]).await);
    let t = Instant::now();
    let p = l.m.deposit_tx(&depositor, nonce, 5_000, pre, Some(fee), states).expect("deposit proves");
    l.land("3. deposit into the vault", t.elapsed().as_secs_f64(), p).await;
    assert_eq!(vault_balance(l.note.as_ref().unwrap()), 5_000);

    // 4. below threshold refuses while proving; 2 of 3 pays the public payee
    let to: Key = payee.as_ref().try_into().unwrap();
    let pay = Proposal { multisig: l.m.key(), zone, epoch: 0, nonce: 0, action: Action::Transfer { to, amount: 1_200 },
                         expires_ms: 9_000_000_000_000, proposer: s[0].key() };
    let exec = |who: &[usize]| Instruction::Execute { proposal: pay.clone(), approvals: who.iter().map(|&i| s[i].approve(&pay)).collect(), executor: None };
    let (pre, fee, states) = (l.pre().await, l.fee().await, l.states(&[payee, inbox]).await);
    let e = format!("{:?}", l.m.private_tx(exec(&[0]), pre, Some(fee), states).err().expect("refused"));
    assert!(e.contains("below-threshold"), "got: {e}");
    eprintln!("   1 of 2: the program refused while proving; nothing was sent, nothing paid");
    let (pre, fee, states) = (l.pre().await, l.fee().await, l.states(&[payee, inbox]).await);
    let t = Instant::now();
    let p = l.m.private_tx(exec(&[0, 1]), pre, Some(fee), states).expect("2 of 3 proves");
    l.land("4. 2 of 3 pay a public payee", t.elapsed().as_secs_f64(), p).await;
    until("the payee's credit", async || l.c.get_account_balance(payee).await.unwrap_or(0) == 1_201).await;
    assert_eq!(vault_balance(l.note.as_ref().unwrap()), 3_800);
    eprintln!("live_private04: all passed");
}
