//! The private posture's executor on LEZ v0.4 (exo-05f): one JSON request in, one JSON answer out,
//! the same surface as v0.3's (`../../host/src/exec.rs`), so Muster's prover seam and the Logos
//! module carry over. What 0.4 adds:
//! - every transaction pays its fee inside its proof, from the group's fee account (D17). A request
//!   carries that account's current note (`feeNote`) beside the multisig's (`pre`), and an answer
//!   carries both new notes (`post`, `feePost`), which Muster seals into the room;
//! - the fee is priced here from the zone's `getFeeState` (`private_reserve`) and paid to its inbox;
//! - an immutable program is proved without naming it (D18), read from the zone on every request;
//! - `topup`: a member's public account funds the fee account. Like `fund`, it is proved here and
//!   signed in the member's own keystore (`sign` → `send`); no key comes here.
//!
//! Requests (hex lowercase, no 0x; amounts and nonces as decimal strings):
//!   {"mode":"derive","program","gms","createKey"} → {"account","feeAccount"}
//!   {"mode":"exec","rpc","program","gms","createKey","pre"|null,"feeNote","op","recipients"?}
//!       → {"hash","post","feePost","account","root","fee","proveMs"}: proved and sent. recipients
//!         are private payees (lee_core::Recipient, borsh hex): a payment to one of their addresses
//!         is sealed to it and published, for it alone to claim; any other payee is public.
//!   {"mode":"fund","rpc","program","gms","createKey","pre","feeNote","payerKey","payerNonce","amount"}
//!       → {"sign","message","proof","post","feePost","account","root","fee","proveMs"}: not sent.
//!   {"mode":"topup","rpc","program","gms","createKey","feeNote"|null,"payerKey","payerNonce","amount"}
//!       → {"sign","message","proof","feePost","feeAccount","root","fee","proveMs"}: not sent; the fee
//!         comes out of `amount`.
//!   {"mode":"scan","rpc","program","gms","createKey","from"?}
//!       → {"found","post","block","hash","feeFound","feePost","scanned"}: the newest notes on chain.
//!   {"mode":"send","rpc","message","proof","witnesses":[{"signature","publicKey"}]} → {"hash"}
//! Errors: {"error":"refused"|"failed","detail"}; a program refusal names its MsigError code and is
//! found at proving time, before anything is sent or paid (RFP U.7).

use std::collections::HashMap;
use std::time::Instant;

use common::transaction::LeeTransaction;
use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{
    privacy_preserving_transaction::{
        circuit::Proof, message::Message as PpMessage, witness_set::WitnessSet as PpWitnessSet, PrivacyPreservingTransaction,
    },
    PublicKey, Recipient, Signature,
};
use lee_core::{
    account::{Account, AccountId, Actor, ActorState},
    program::{immutable_mirror_commitment, ProgramHeader, PROGRAM_LOADER_ACCOUNT_ID},
    Commitment, MembershipProof,
};
use msig_core::{claims, Instruction, Outflow};
use sequencer_service_rpc::{RpcClient as _, SequencerClient, SequencerClientBuilder};
use serde_json::{json, Value};

use crate::{fee_inbox, native_state, private_reserve, program, Msig, PrivateFee, Proven};

fn h32(v: &Value, k: &str) -> Result<[u8; 32], String> {
    let s = v.get(k).and_then(Value::as_str).ok_or(format!("missing {k}"))?;
    let b = hex::decode(s).map_err(|e| format!("{k}: {e}"))?;
    b.try_into().map_err(|_| format!("{k} is not 32 bytes"))
}

fn bytes(v: &Value, k: &str) -> Result<Option<Vec<u8>>, String> {
    match v.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => hex::decode(s).map(Some).map_err(|e| format!("{k}: {e}")),
        _ => Err(format!("{k} is not hex")),
    }
}

fn account(v: &Value, k: &str) -> Result<Option<Account>, String> {
    bytes(v, k)?.map(|b| borsh::from_slice(&b).map_err(|e| format!("{k}: {e}"))).transpose()
}

fn num(v: &Value, k: &str) -> Result<u128, String> {
    v.get(k).and_then(Value::as_str).ok_or(format!("missing {k}"))?.parse().map_err(|e| format!("{k}: {e}"))
}

fn hexb(a: &impl borsh::BorshSerialize) -> String {
    hex::encode(borsh::to_vec(a).expect("borsh"))
}

fn id_hex(a: &AccountId) -> String {
    hex::encode(a.as_ref() as &[u8])
}

fn msig_of(req: &Value) -> Result<Msig, String> {
    let group = GroupKeyHolder::from_gms(h32(req, "gms")?);
    Ok(Msig::private(AccountId::new(h32(req, "program")?), &program().id(), h32(req, "createKey")?, &group))
}

fn client(req: &Value) -> Result<SequencerClient, String> {
    let rpc = req.get("rpc").and_then(Value::as_str).ok_or("missing rpc")?;
    SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())
}

/// D18: an immutable program is proved without naming it, against its header's mirror commitment.
async fn undisclosed(c: &SequencerClient, m: Msig) -> Result<Msig, String> {
    let loader = c.get_account(m.program).await.map_err(|e| format!("getAccount(program): {e}"))?
        .ok_or("the program is not deployed on this zone")?;
    let header = ProgramHeader::from_loader_actor_state(loader.data.actor_state(PROGRAM_LOADER_ACCOUNT_ID).as_ref())
        .ok_or("the program's account holds no loader header")?;
    if header.image_id != program().id() {
        return Err("wrong-program: the deployed image is not this prover's guest".into());
    }
    if !header.immutable {
        return Ok(m);
    }
    let (proofs, _, _) = c.get_proofs_and_root(vec![immutable_mirror_commitment(m.program, &header)], vec![]).await
        .map_err(|e| format!("getProofsAndRoot(mirror): {e}"))?;
    let proof = proofs.into_iter().next().flatten().ok_or("the zone holds no mirror commitment for the program")?;
    Ok(m.with_undisclosed(header, proof))
}

/// Membership proofs for the notes, all under one root; the root is an external read Muster
/// records (invariant 10).
async fn proofs(c: &SequencerClient, notes: &[(AccountId, &Account)]) -> Result<(Vec<MembershipProof>, String), String> {
    let commitments = notes.iter().map(|(id, a)| Commitment::new(id, a)).collect();
    let (proofs, _, root) = c.get_proofs_and_root(commitments, vec![]).await.map_err(|e| format!("getProofsAndRoot: {e}"))?;
    let proofs = proofs.into_iter().collect::<Option<Vec<_>>>()
        .ok_or("stale-note: the chain holds no commitment for a note; it is stale or was never sent")?;
    Ok((proofs, hexb(&root)))
}

async fn states(c: &SequencerClient, ids: &[AccountId]) -> Result<HashMap<Actor, ActorState>, String> {
    let mut out = HashMap::new();
    for id in ids {
        let a = c.get_account(*id).await.map_err(|e| format!("getAccount: {e}"))?.unwrap_or_default();
        out.insert(Actor::native_balance(*id), native_state(&a));
    }
    Ok(out)
}

async fn reserve(c: &SequencerClient) -> Result<u128, String> {
    let q = c.get_fee_state().await.map_err(|e| format!("getFeeState: {e}"))?;
    Ok(private_reserve(0, q.next_base_fee_exec_ceiling, q.next_base_fee_stor_ceiling))
}

async fn send(c: &SequencerClient, tx: PrivacyPreservingTransaction) -> Result<String, String> {
    let h = c.send_transaction(LeeTransaction::PrivacyPreserving(tx)).await.map_err(|e| format!("sendTransaction: {e}"))?;
    Ok(hex::encode(h.as_ref() as &[u8]))
}

fn proved(e: lee::error::LeeError) -> String {
    format!("the program refused it while proving: {e:?}")
}

/// The unsigned answer of a deposit or top-up: what the payer signs, and what `send` carries back.
fn unsigned(p: &Proven) -> Value {
    json!({"sign": hex::encode(p.hash()), "message": hexb(&p.message), "proof": hexb(&p.proof)})
}

async fn run(req: Value) -> Result<Value, String> {
    let mode = req.get("mode").and_then(Value::as_str).unwrap_or("exec");
    if mode == "send" {
        return send_signed(&req).await;
    }
    let m = msig_of(&req)?;
    let a = m.account();
    let fee_id = m.fee_account().expect("private");
    if mode == "derive" {
        return Ok(json!({"account": id_hex(&a), "feeAccount": id_hex(&fee_id)}));
    }
    let c = client(&req)?;
    if mode == "scan" {
        return scan(&req, &c, &m).await;
    }
    let m = undisclosed(&c, m).await?;
    let fee_note = account(&req, "feeNote")?;
    let inbox = fee_inbox();
    let amount_fee = reserve(&c).await?;
    if mode == "topup" {
        let payer = AccountId::from(&PublicKey::try_new(h32(&req, "payerKey")?).map_err(|e| format!("payerKey: {e:?}"))?);
        let (pre, root) = match &fee_note {
            None => (None, String::new()),
            Some(n) => {
                let (p, root) = proofs(&c, &[(fee_id, n)]).await?;
                (Some((n.clone(), p.into_iter().next().unwrap())), root)
            }
        };
        let st = states(&c, &[payer, inbox]).await?;
        let t = Instant::now();
        let p = m.top_up_fee_tx(payer, num(&req, "payerNonce")?, num(&req, "amount")?, pre, amount_fee, inbox, st).map_err(proved)?;
        let mut out = unsigned(&p);
        out["feePost"] = json!(hexb(p.fee_post.as_ref().ok_or("the fee account's new note does not decrypt")?));
        out["feeAccount"] = json!(id_hex(&fee_id));
        out["root"] = json!(root);
        out["fee"] = json!(amount_fee.to_string());
        out["proveMs"] = json!(t.elapsed().as_millis());
        return Ok(out);
    }
    let fee_note = fee_note.ok_or("missing feeNote: the group's fee account has no funds yet (topup)")?;
    let pre = account(&req, "pre")?;
    let mut notes = vec![(fee_id, &fee_note)];
    if let Some(n) = &pre {
        notes.push((a, n));
    }
    let (mut ps, root) = proofs(&c, &notes).await?;
    let pre = pre.map(|n| (n, ps.pop().unwrap()));
    let fee = PrivateFee { note: fee_note.clone(), proof: ps.pop().unwrap(), amount: amount_fee, inbox };
    let t = Instant::now();
    match mode {
        "exec" => {
            let op: Instruction = borsh::from_slice(&bytes(&req, "op")?.ok_or("missing op")?).map_err(|e| format!("op: {e}"))?;
            // private payees: each credit to one of their addresses is sealed to it, not declared
            let mut seals: Vec<Recipient> = vec![];
            for r in req.get("recipients").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]) {
                let b = hex::decode(r.as_str().ok_or("a recipient is hex")?).map_err(|e| format!("recipient: {e}"))?;
                seals.push(borsh::from_slice(&b).map_err(|e| format!("recipient: {e}"))?);
            }
            let mut ids = vec![inbox];
            if let Some(Outflow::Pay { to, .. }) = claims(&op).ok().and_then(|cl| cl.outflow) {
                let to = AccountId::new(to);
                if !seals.iter().any(|r| r.address() == to) {
                    ids.push(to);
                }
            }
            let st = states(&c, &ids).await?;
            let p = m.private_tx_sealed(op, pre, Some(fee), st, &seals).map_err(proved)?;
            let prove_ms = t.elapsed().as_millis();
            let post = p.post.clone().ok_or("the proof's notes do not decrypt to the multisig's account")?;
            let fee_post = p.fee_post.clone().ok_or("the fee account's new note does not decrypt")?;
            let hash = send(&c, p.signed(&[])).await?;
            Ok(json!({"hash": hash, "post": hexb(&post), "feePost": hexb(&fee_post), "account": id_hex(&a),
                      "root": root, "fee": amount_fee.to_string(), "proveMs": prove_ms}))
        }
        "fund" => {
            let pre = pre.ok_or("fund needs the multisig's current note")?;
            let payer = AccountId::from(&PublicKey::try_new(h32(&req, "payerKey")?).map_err(|e| format!("payerKey: {e:?}"))?);
            let st = states(&c, &[payer, inbox]).await?;
            let p = m.deposit_tx(payer, num(&req, "payerNonce")?, num(&req, "amount")?, Some(pre), Some(fee), st).map_err(proved)?;
            let mut out = unsigned(&p);
            out["post"] = json!(hexb(p.post.as_ref().ok_or("the deposit's notes do not decrypt to the multisig's account")?));
            out["feePost"] = json!(hexb(p.fee_post.as_ref().ok_or("the fee account's new note does not decrypt")?));
            out["account"] = json!(id_hex(&a));
            out["root"] = json!(root);
            out["fee"] = json!(amount_fee.to_string());
            out["proveMs"] = json!(t.elapsed().as_millis());
            Ok(out)
        }
        other => Err(format!("unknown mode {other}")),
    }
}

/// The newest notes of the multisig and of its fee account, read from the chain with the group's
/// viewing keys: every privacy-preserving transaction from `from` (default 1) to the tip. A later
/// note supersedes an earlier, since each spends the one before.
async fn scan(req: &Value, c: &SequencerClient, m: &Msig) -> Result<Value, String> {
    const STEP: u64 = 100;
    let tip = c.get_last_block_id().await.map_err(|e| format!("getLastBlockId: {e}"))?;
    let mut at: u64 = req.get("from").and_then(Value::as_str).and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let (mut found, mut fee): (Option<(Account, u64, String)>, Option<Account>) = (None, None);
    while at <= tip {
        let end = (at + STEP - 1).min(tip);
        let blocks = c.get_block_range(at, end).await.map_err(|e| format!("getBlockRange {at}..{end}: {e}"))?;
        for b in blocks {
            for tx in &b.body.transactions {
                if let LeeTransaction::PrivacyPreserving(pp) = tx {
                    let actions = &pp.message().execution.private_actions;
                    if let Some(a) = m.decrypt(actions) {
                        found = Some((a, b.header.block_id, hex::encode(tx.hash().as_ref() as &[u8])));
                    }
                    if let Some(f) = m.decrypt_fee(actions) {
                        fee = Some(f);
                    }
                }
            }
        }
        at = end + 1;
    }
    let mut out = json!({"found": found.is_some(), "feeFound": fee.is_some(), "scanned": tip.to_string()});
    if let Some((a, block, hash)) = found {
        out["post"] = json!(hexb(&a));
        out["block"] = json!(block.to_string());
        out["hash"] = json!(hash);
    }
    if let Some(f) = fee {
        out["feePost"] = json!(hexb(&f));
    }
    Ok(out)
}

/// A proved deposit or top-up, signed by its payer elsewhere, sent. Every signature is checked
/// against the message first.
async fn send_signed(req: &Value) -> Result<Value, String> {
    let c = client(req)?;
    let msg: PpMessage = borsh::from_slice(&bytes(req, "message")?.ok_or("missing message")?).map_err(|e| format!("message: {e}"))?;
    let proof: Proof = borsh::from_slice(&bytes(req, "proof")?.ok_or("missing proof")?).map_err(|e| format!("proof: {e}"))?;
    let mut sigs = Vec::new();
    for w in req.get("witnesses").and_then(Value::as_array).ok_or("missing witnesses")? {
        let sig = bytes(w, "signature")?.ok_or("missing signature")?;
        let value: [u8; 64] = sig.try_into().map_err(|_| "a signature is 64 bytes".to_string())?;
        let pk = PublicKey::try_new(h32(w, "publicKey")?).map_err(|e| format!("publicKey: {e:?}"))?;
        sigs.push((Signature { value }, pk));
    }
    let ws = PpWitnessSet::from_raw_parts(sigs, proof);
    if !ws.signatures_are_valid_for(&msg) {
        return Err("bad-signature: a witness does not sign this message".into());
    }
    Ok(json!({"hash": send(&c, PrivacyPreservingTransaction::new(msg, ws)).await?}))
}

/// Run one request; never panics on input: a bad request or a refusal is {"error","detail"}.
pub async fn exec_request(req: Value) -> Value {
    match run(req).await {
        Ok(v) => v,
        Err(e) => {
            let refused = REFUSALS.iter().any(|c| e.contains(c));
            json!({"error": if refused { "refused" } else { "failed" }, "detail": e})
        }
    }
}

/// The program's refusal codes (msig_core::MsigError), and the prover's own: a request refused,
/// as opposed to one that failed to reach the chain.
const REFUSALS: &[&str] = &["below-threshold", "stale-epoch", "nonce-spent", "bad-signature", "wrong-account",
    "not-initialised", "needs-queue", "too-early", "expired", "invalid-config", "proposer-did-not-sign", "over-limit",
    "duplicate-signer", "not-a-member", "missing-role", "executor-required", "action-not-allowed", "wrong-rows",
    "wrong-caller", "wrong-program", "stale-note"];
