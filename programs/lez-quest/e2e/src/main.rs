//! The quest program on a running LEZ v0.3.0 sequencer (exo-267.7).
//!
//!   quest_e2e <sequencer url> <quest program (base58)> <multisig program (base58)> <fund command>
//!
//! `<fund command>` is run as `<fund command> <account hex> <amount>` (muster's
//! `infra/lez/localnet.sh fund`: v0.3 has no faucet, so a funder stands in for anyone
//! holding native LEZ). Every signer pays its own fee.
//!
//!   1. a person issues a quest from their own account, the bounty set aside in the record;
//!   2. an outsider's Accept, an outsider's Confirm, and a Close by anyone but the issuer
//!      are refused, and nothing moves; the taker accepts, the confirmer confirms, the
//!      issuer closes, and the taker is paid;
//!   3. a 2-of-3 LEZ multisig issues a quest by vote: its Execute calls the quest program
//!      with the vault's seed, and the vault's grant carries into the quest program's own
//!      transfer of the bounty — the record's issuer is the vault;
//!   4. the multisig closes it by a second vote and the bounty reaches the taker.
//!
//! On v0.3 a refused call is still INCLUDED and pays; every step is judged by the state it
//! reads back (the multisig port's e2e_v03 found this, muster's labbook trap 8).

mod multisig_wire;

use std::{process::Command, thread::sleep, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use common::transaction::LeeTransaction;
use lee::{
    FeeDeclaration, PrivateKey, PublicKey, PublicTransaction,
    public_transaction::{Message, WitnessSet},
};
use lee_core::account::{AccountId, Nonce, ProgramShardSelector};
use quest_core::{Instruction, QuestRecord, QuestStatus, record_pda};
use serde_json::{Value, json};

use multisig_wire as ms;

const NATIVE: [u8; 32] = [0; 32];
const GAS: u64 = 2_000_000;
const MAX_FEE: u128 = (GAS as u128 + 100_000) * 64;

struct Chain {
    url: String,
    fund_cmd: String,
}

impl Chain {
    fn rpc(&self, method: &str, params: Value) -> Value {
        ureq::post(&self.url)
            .send_json(json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
            .expect("the sequencer answers")
            .into_json()
            .expect("JSON")
    }

    fn account(&self, id: &AccountId) -> (u128, serde_json::Map<String, Value>) {
        let r = self.rpc("getAccount", json!([id.to_string()]));
        let a = &r["result"];
        let nonce = a["nonce"].as_u64().map(u128::from)
            .or_else(|| a["nonce"].as_str().and_then(|s| s.parse().ok())).unwrap_or(0);
        (nonce, a["data"]["shards"].as_object().cloned().unwrap_or_default())
    }

    fn shard(&self, id: &AccountId, program: &AccountId) -> Vec<u8> {
        let (_, shards) = self.account(id);
        shards.get(&program.to_string()).and_then(Value::as_array)
            .map(|v| v.iter().map(|b| b.as_u64().unwrap() as u8).collect()).unwrap_or_default()
    }

    fn balance(&self, id: &AccountId) -> u128 {
        let d = self.shard(id, &AccountId::new(NATIVE));
        if d.is_empty() { 0 } else { u128::from_le_bytes(d.try_into().unwrap()) }
    }

    fn fund(&self, id: &AccountId, amount: u128) {
        let hex: String = id.value().iter().map(|b| format!("{b:02x}")).collect();
        let ok = Command::new("sh").arg("-c").arg(format!("{} {hex} {amount}", self.fund_cmd))
            .status().expect("the fund command runs").success();
        assert!(ok, "funding {id} failed");
    }

    fn wait<F: Fn() -> bool>(&self, what: &str, cond: F) {
        for _ in 0..90 {
            if cond() { return; }
            sleep(Duration::from_secs(1));
        }
        panic!("not within 90 s: {what}");
    }

    /// A transaction to `program`, signed by `signers` (the first pays). Returns whether it was
    /// included — not whether it took effect: a refused call is included too, and pays.
    fn send(&self, program: AccountId, signers: &[&PrivateKey], rows: Vec<ProgramShardSelector>, data: Vec<u8>) -> bool {
        let ids: Vec<AccountId> = signers.iter().map(|k| id(k)).collect();
        let payer = ids[0];
        let nonces: Vec<Nonce> = ids.iter().map(|i| Nonce(self.account(i).0)).collect();
        let before = nonces[0].0;
        let msg = Message::new_preserialized(program, rows, nonces, data,
                                             Some(FeeDeclaration::new(payer, GAS, 0, MAX_FEE)));
        let ws = WitnessSet::for_message(&msg, signers);
        let tx = LeeTransaction::Public(PublicTransaction::new(msg, ws));
        let r = self.rpc("sendTransaction", json!([STANDARD.encode(borsh::to_vec(&tx).unwrap())]));
        if r.get("error").is_some() {
            println!("   (sequencer refused at the door: {})", r["error"]);
            return false;
        }
        for _ in 0..45 {
            if self.account(&payer).0 > before { return true; }
            sleep(Duration::from_secs(1));
        }
        false
    }
}

fn key() -> PrivateKey {
    PrivateKey::try_new(rand::random::<[u8; 32]>()).unwrap()
}

fn id(k: &PrivateKey) -> AccountId {
    AccountId::from(&PublicKey::new_from_private_key(k))
}

fn sel(a: &AccountId, p: &AccountId) -> ProgramShardSelector {
    ProgramShardSelector { account_id: *a, program_account_id: *p }
}

fn rec(c: &Chain, q: &AccountId, r: &AccountId) -> QuestRecord {
    borsh::from_slice(&c.shard(r, q)).expect("a quest record")
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args.len(), 5, "usage: quest_e2e <sequencer url> <quest program> <multisig program> <fund command>");
    let c = Chain { url: args[1].clone(), fund_cmd: args[4].clone() };
    let q: AccountId = args[2].parse().expect("the quest program, base58");
    let pm: AccountId = args[3].parse().expect("the multisig program, base58");
    let nat = AccountId::new(NATIVE);

    let (ki, kt, kc, ko) = (key(), key(), key(), key());
    let (issuer, taker, confirmer, outsider) = (id(&ki), id(&kt), id(&kc), id(&ko));
    let (ka, kb) = (key(), key());
    let (a, b) = (id(&ka), id(&kb));
    let ck: [u8; 32] = rand::random();
    let vault = ms::vault_pda(&pm, &ck);
    for who in [&issuer, &taker, &confirmer, &outsider, &a, &b] { c.fund(who, 1_000_000_000); }
    c.fund(&vault, 1_000);
    c.wait("funding lands", || [&issuer, &taker, &confirmer, &outsider, &a, &b].iter().all(|w| c.balance(w) > 0)
                               && c.balance(&vault) == 1_000);

    // ── 1. a person issues a quest ────────────────────────────────────────────
    let qid: [u8; 32] = rand::random();
    let terms: [u8; 32] = rand::random();
    let r1 = record_pda(&q, issuer.value(), &qid);
    let open = Instruction::Open { quest_id: qid, terms_hash: terms, bounty: 300, confirmer: *confirmer.value(), taker: Some(*taker.value()) };
    assert!(c.send(q, &[&ki], vec![sel(&r1, &q), sel(&issuer, &q), sel(&issuer, &nat), sel(&r1, &nat)], borsh::to_vec(&open).unwrap()));
    let r = rec(&c, &q, &r1);
    assert_eq!((r.issuer, r.bounty, r.status), (*issuer.value(), 300, QuestStatus::Open));
    assert_eq!(c.balance(&r1), 300, "the bounty is set aside in the record account");
    println!("1. a person issued a quest at {r1}; the record holds its 300 bounty OK");

    // ── 2. refusals, then accept → confirm → close ────────────────────────────
    let accept = borsh::to_vec(&Instruction::Accept { issuer: *issuer.value(), quest_id: qid }).unwrap();
    let confirm = borsh::to_vec(&Instruction::Confirm { issuer: *issuer.value(), quest_id: qid }).unwrap();
    let inc = c.send(q, &[&ko], vec![sel(&r1, &q), sel(&outsider, &q)], accept.clone());
    assert_eq!(rec(&c, &q, &r1).status, QuestStatus::Open, "only the named taker accepts");
    println!("2a. an outsider's Accept refused (included: {inc}; the record unchanged) OK");
    assert!(c.send(q, &[&kt], vec![sel(&r1, &q), sel(&taker, &q)], accept));
    assert_eq!(rec(&c, &q, &r1).status, QuestStatus::Accepted { taker: *taker.value() });
    let inc = c.send(q, &[&ko], vec![sel(&r1, &q), sel(&outsider, &q)], confirm.clone());
    assert_eq!(rec(&c, &q, &r1).status, QuestStatus::Accepted { taker: *taker.value() }, "only the confirmer confirms");
    println!("2b. the taker accepted; an outsider's Confirm refused (included: {inc}) OK");
    assert!(c.send(q, &[&kc], vec![sel(&r1, &q), sel(&confirmer, &q)], confirm));
    assert_eq!(rec(&c, &q, &r1).status, QuestStatus::Confirmed { taker: *taker.value() });
    // the outsider closing names their own (empty) record; the issuer's never moves
    let close = |t: &AccountId| borsh::to_vec(&Instruction::Close { quest_id: qid, taker: *t.value(), bounty: 300 }).unwrap();
    let inc = c.send(q, &[&ko], vec![sel(&r1, &q), sel(&outsider, &q), sel(&r1, &nat), sel(&outsider, &nat)], close(&outsider));
    assert_eq!((c.balance(&r1), rec(&c, &q, &r1).status), (300, QuestStatus::Confirmed { taker: *taker.value() }));
    println!("2c. the confirmer confirmed; an outsider's Close refused (included: {inc}; nothing moved) OK");
    let t_before = c.balance(&taker);
    assert!(c.send(q, &[&ki], vec![sel(&r1, &q), sel(&issuer, &q), sel(&r1, &nat), sel(&taker, &nat)], close(&taker)));
    assert_eq!(rec(&c, &q, &r1).status, QuestStatus::Closed { taker: *taker.value() });
    assert_eq!((c.balance(&r1), c.balance(&taker) - t_before), (0, 300), "Close paid the taker the bounty");
    println!("2d. the issuer closed it: the taker holds the 300, the record none OK");

    // ── 3. a 2-of-3 multisig issues a quest by vote ───────────────────────────
    let state = ms::state_pda(&pm, &ck);
    let mine = |x: &AccountId| sel(x, &pm);
    let create = ms::Instruction::CreateMultisig { create_key: ck, threshold: 2,
                                                   members: vec![*a.value(), *b.value(), rand::random::<[u8; 32]>()] };
    assert!(c.send(pm, &[&ka], vec![mine(&state)], borsh::to_vec(&create).unwrap()));
    let qid2: [u8; 32] = rand::random();
    let r2 = record_pda(&q, vault.value(), &qid2);
    let open2 = Instruction::Open { quest_id: qid2, terms_hash: terms, bounty: 200, confirmer: *confirmer.value(), taker: None };
    let call = ms::TargetCall {
        program_account_id: *q.value(),
        shard_selectors: vec![(*r2.value(), *q.value()), (*vault.value(), *q.value()),
                              (*vault.value(), NATIVE), (*r2.value(), NATIVE)],
        instruction_data: borsh::to_vec(&open2).unwrap(),
        pda_seeds: vec![ms::vault_seed(&ck)],
    };
    let vote = |index: u64, call: &ms::TargetCall| {
        let prop = ms::proposal_pda(&pm, &ck, index);
        assert!(c.send(pm, &[&ka], vec![mine(&state), mine(&prop), mine(&a)],
                       borsh::to_vec(&ms::Instruction::Propose { create_key: ck, index, target: call.clone() }).unwrap()));
        assert!(c.send(pm, &[&kb], vec![mine(&state), mine(&prop), mine(&b)],
                       borsh::to_vec(&ms::Instruction::Approve { create_key: ck, index }).unwrap()));
        let mut rows = vec![mine(&state), mine(&prop)];
        rows.extend(call.shard_selectors.iter().map(|(x, y)| sel(&AccountId::new(*x), &AccountId::new(*y))));
        c.send(pm, &[&ka], rows, borsh::to_vec(&ms::Instruction::Execute {
            create_key: ck, index, approvers: vec![*a.value(), *b.value()], call: call.clone() }).unwrap())
    };
    let inc = vote(1, &call);
    let shard = c.shard(&r2, &q);
    assert!(!shard.is_empty(), "the multisig's Execute opened no quest (included: {inc})");
    let r = rec(&c, &q, &r2);
    assert_eq!((r.issuer, r.bounty, r.status), (*vault.value(), 200, QuestStatus::Open));
    assert_eq!((c.balance(&vault), c.balance(&r2)), (800, 200),
               "the vault's grant carried into the quest program's transfer of the bounty");
    println!("3. a 2-of-3 issued a quest by vote: the record's issuer is the vault {vault}, \
              and the vault's 200 moved into the record in the same transaction OK");

    // ── 4. taken, confirmed, closed by a second vote ──────────────────────────
    assert!(c.send(q, &[&kt], vec![sel(&r2, &q), sel(&taker, &q)],
                   borsh::to_vec(&Instruction::Accept { issuer: *vault.value(), quest_id: qid2 }).unwrap()));
    assert!(c.send(q, &[&kc], vec![sel(&r2, &q), sel(&confirmer, &q)],
                   borsh::to_vec(&Instruction::Confirm { issuer: *vault.value(), quest_id: qid2 }).unwrap()));
    assert_eq!(rec(&c, &q, &r2).status, QuestStatus::Confirmed { taker: *taker.value() });
    let close2 = ms::TargetCall {
        program_account_id: *q.value(),
        shard_selectors: vec![(*r2.value(), *q.value()), (*vault.value(), *q.value()),
                              (*r2.value(), NATIVE), (*taker.value(), NATIVE)],
        instruction_data: borsh::to_vec(&Instruction::Close { quest_id: qid2, taker: *taker.value(), bounty: 200 }).unwrap(),
        pda_seeds: vec![ms::vault_seed(&ck)],
    };
    let t_before = c.balance(&taker);
    assert!(vote(2, &close2));
    assert_eq!(rec(&c, &q, &r2).status, QuestStatus::Closed { taker: *taker.value() });
    assert_eq!((c.balance(&r2), c.balance(&taker) - t_before, c.balance(&vault)), (0, 200, 800));
    println!("4. taken, confirmed, and closed by a second vote: the taker holds the 200 OK");
    println!("quest_e2e: the quest program on a real LEZ v0.3.0 chain — all OK");
}
