//! The public posture without Muster (RFP-005 U.1; roadmap M2; `docs/design/lez-msig-signing.md`):
//! read a multisig's state, build a proposal or a spend for its members to sign, check signatures
//! against the state exactly as the program will (`msig_core::apply`), and prepare an unsigned
//! transaction a payer signs elsewhere. It holds no key and approves nothing: how approvals travel
//! is the caller's, and the program is the only authority.
//!
//! Modes (each `{"mode": …}` JSON in, JSON out): `state`, `propose`, `spend`, `check`, `prepare`,
//! `send_public`. Integers that can exceed 2^53 (amounts, times, nonces) are decimal strings out,
//! and strings or numbers in. Keys, ids and bytes are hex without 0x.

use common::transaction::LeeTransaction;
use lee::{fees::FeeDeclaration, public_transaction, PublicKey, PublicTransaction};
use lee_core::account::{AccountId, Nonce};
use msig_core::{
    approve_msg, execute_msg, proposal_id, spend_msg, Action, Config, ConfigChange, Ctx, Instruction, Member, Proposal,
    Row, Signed, Spend, SpendingLimit, State, NONCE_WINDOW,
};
use sequencer_service_rpc::{RpcClient as _, SequencerClientBuilder};
use serde_json::{json, Value};

use crate::{program, vault_balance, Msig};

/// The LEZ wallet's own default fee declaration (muster's `defaultFee`): gas 2 000 000, tip 0,
/// max fee (gas + 100 000) × 64.
const DEFAULT_GAS: u64 = 2_000_000;
const DEFAULT_MAX_FEE: u128 = (2_000_000 + 100_000) * 64;

// ── JSON in ─────────────────────────────────────────────────────────────────────
fn hx(v: &Value, what: &str) -> Result<Vec<u8>, String> {
    let s = v.as_str().ok_or(format!("{what} is not a hex string"))?;
    hex::decode(s.trim_start_matches("0x")).map_err(|e| format!("{what}: {e}"))
}
fn k32(v: &Value, what: &str) -> Result<[u8; 32], String> {
    hx(v, what)?.try_into().map_err(|_| format!("{what} is not 32 bytes"))
}
fn field<'a>(v: &'a Value, k: &str) -> Result<&'a Value, String> {
    v.get(k).filter(|x| !x.is_null()).ok_or(format!("missing {k}"))
}
fn uint<T: std::str::FromStr + TryFrom<u64>>(v: &Value, what: &str) -> Result<T, String> {
    match v {
        Value::String(s) => s.parse::<T>().map_err(|_| format!("{what} is not a whole number")),
        Value::Number(n) => n.as_u64().and_then(|x| T::try_from(x).ok()).ok_or(format!("{what} is out of range")),
        _ => Err(format!("{what} is not a number")),
    }
}
fn u(v: &Value, k: &str) -> Result<u64, String> {
    uint(field(v, k)?, k)
}

fn member_of(v: &Value) -> Result<Member, String> {
    Ok(Member { key: k32(field(v, "key")?, "key")?, roles: uint(field(v, "roles")?, "roles")?,
                weight: v.get("weight").map(|w| uint(w, "weight")).transpose()?.unwrap_or(1) })
}

fn limit_of(v: &Value) -> Result<SpendingLimit, String> {
    let mut signers = Vec::new();
    for s in field(v, "signers")?.as_array().ok_or("signers is not a list")? {
        signers.push(k32(s, "a signer")?);
    }
    Ok(SpendingLimit { id: uint(field(v, "id")?, "id")?, signers, threshold: uint(field(v, "threshold")?, "threshold")?,
                       amount: uint(field(v, "amount")?, "amount")?, period_ms: u(v, "periodMs")? })
}

fn keys_of(v: &Value, what: &str) -> Result<Vec<[u8; 32]>, String> {
    v.as_array().ok_or(format!("{what} is not a list"))?.iter().map(|x| k32(x, what)).collect()
}

/// A config as `Create` writes it: {members: [{key, roles, weight}], threshold, timelockMs?,
/// openExecution?, actions?, targets?, limits?}. Roles are bits: PROPOSE 1, APPROVE 2, EXECUTE 4;
/// actions: TRANSFER 1, CALL 2.
pub fn config_of(v: &Value) -> Result<Config, String> {
    let members = field(v, "members")?.as_array().ok_or("members is not a list")?.iter().map(member_of)
        .collect::<Result<Vec<_>, _>>()?;
    let limits = match v.get("limits") {
        None | Some(Value::Null) => Vec::new(),
        Some(l) => l.as_array().ok_or("limits is not a list")?.iter().map(limit_of).collect::<Result<_, _>>()?,
    };
    Ok(Config {
        members,
        threshold: uint(field(v, "threshold")?, "threshold")?,
        timelock_ms: v.get("timelockMs").map(|x| uint(x, "timelockMs")).transpose()?.unwrap_or(0),
        open_execution: v.get("openExecution").and_then(Value::as_bool).unwrap_or(true),
        actions: v.get("actions").map(|x| uint(x, "actions")).transpose()?.unwrap_or(msig_core::action_kind::ALL),
        targets: match v.get("targets") { None | Some(Value::Null) => Vec::new(), Some(t) => keys_of(t, "a target")? },
        limits,
    })
}

fn change_of(v: &Value) -> Result<ConfigChange, String> {
    let kind = field(v, "change")?.as_str().ok_or("change is not a string")?;
    Ok(match kind {
        "add-member" => ConfigChange::AddMember(member_of(field(v, "member")?)?),
        "remove-member" => ConfigChange::RemoveMember(k32(field(v, "key")?, "key")?),
        "set-roles" => ConfigChange::SetRoles { key: k32(field(v, "key")?, "key")?, roles: uint(field(v, "roles")?, "roles")? },
        "set-weight" => ConfigChange::SetWeight { key: k32(field(v, "key")?, "key")?, weight: uint(field(v, "weight")?, "weight")? },
        "set-threshold" => ConfigChange::SetThreshold(uint(field(v, "threshold")?, "threshold")?),
        "set-timelock" => ConfigChange::SetTimelock(u(v, "timelockMs")?),
        "set-open-execution" => ConfigChange::SetOpenExecution(field(v, "open")?.as_bool().ok_or("open is not a bool")?),
        "set-actions" => ConfigChange::SetActions(uint(field(v, "actions")?, "actions")?),
        "set-targets" => ConfigChange::SetTargets(keys_of(field(v, "targets")?, "a target")?),
        "add-limit" => ConfigChange::AddLimit(limit_of(field(v, "limit")?)?),
        "remove-limit" => ConfigChange::RemoveLimit(uint(field(v, "id")?, "id")?),
        other => return Err(format!("unknown change {other}")),
    })
}

/// {kind: transfer, to, amount} | {kind: call, program, rows: [{account, program}], data} |
/// {kind: config, changes: [...]} | {kind: cancel, nonces: [n]}.
pub fn action_of(v: &Value) -> Result<Action, String> {
    let kind = field(v, "kind")?.as_str().ok_or("kind is not a string")?;
    Ok(match kind {
        "transfer" => Action::Transfer { to: k32(field(v, "to")?, "to")?, amount: uint(field(v, "amount")?, "amount")? },
        "call" => {
            let mut rows = Vec::new();
            for r in field(v, "rows")?.as_array().ok_or("rows is not a list")? {
                rows.push(Row { account: k32(field(r, "account")?, "account")?, program: k32(field(r, "program")?, "program")? });
            }
            let data = match v.get("data") { None | Some(Value::Null) => Vec::new(), Some(d) => hx(d, "data")? };
            Action::Call { program: k32(field(v, "program")?, "program")?, rows, data }
        }
        "config" => Action::Config(field(v, "changes")?.as_array().ok_or("changes is not a list")?.iter().map(change_of)
            .collect::<Result<_, _>>()?),
        "cancel" => Action::Cancel(field(v, "nonces")?.as_array().ok_or("nonces is not a list")?.iter()
            .map(|n| uint(n, "a nonce")).collect::<Result<_, _>>()?),
        other => return Err(format!("unknown action {other}")),
    })
}

fn signed_of(v: &Value) -> Result<Signed, String> {
    let sig: [u8; 64] = hx(field(v, "sig")?, "sig")?.try_into().map_err(|_| "a signature is 64 bytes".to_string())?;
    Ok(Signed { key: k32(field(v, "key")?, "key")?, sig })
}
fn signed_list(v: &Value, k: &str) -> Result<Vec<Signed>, String> {
    match v.get(k) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(l) => l.as_array().ok_or(format!("{k} is not a list"))?.iter().map(signed_of).collect(),
    }
}

fn borsh_of<T: borsh::BorshDeserialize>(v: &Value, k: &str) -> Result<T, String> {
    borsh::from_slice(&hx(field(v, k)?, k)?).map_err(|e| format!("{k}: {e}"))
}

/// The instruction a request names: {op: <Instruction borsh hex>}, or {kind: create, zone,
/// config} | {kind: execute | queue | execute-queued, proposal, approvals, executor?, atMs?} |
/// {kind: spend, spend, approvals, period, periodMs}, where proposal and spend are borsh hex.
pub fn instruction_of(v: &Value) -> Result<Instruction, String> {
    if v.get("op").is_some_and(|x| !x.is_null()) {
        return borsh_of(v, "op");
    }
    let kind = field(v, "kind")?.as_str().ok_or("kind is not a string")?;
    let executor = v.get("executor").filter(|x| !x.is_null()).map(signed_of).transpose()?;
    Ok(match kind {
        "create" => Instruction::Create { zone: k32(field(v, "zone")?, "zone")?, config: config_of(field(v, "config")?)? },
        "execute" => Instruction::Execute { proposal: borsh_of(v, "proposal")?, approvals: signed_list(v, "approvals")?, executor },
        "queue" => Instruction::Queue { proposal: borsh_of(v, "proposal")?, approvals: signed_list(v, "approvals")?, executor,
                                         at_ms: u(v, "atMs")? },
        "execute-queued" => Instruction::ExecuteQueued { proposal: borsh_of(v, "proposal")?, executor, at_ms: u(v, "atMs")? },
        "spend" => Instruction::Spend { spend: borsh_of(v, "spend")?, approvals: signed_list(v, "approvals")?,
                                         period: u(v, "period")?, period_ms: u(v, "periodMs")? },
        other => return Err(format!("unknown instruction {other}")),
    })
}

// ── JSON out ────────────────────────────────────────────────────────────────────
fn h(b: &[u8]) -> String {
    hex::encode(b)
}

fn config_json(c: &Config) -> Value {
    json!({"members": c.members.iter().map(|m| json!({"key": h(&m.key), "roles": m.roles, "weight": m.weight})).collect::<Vec<_>>(),
           "threshold": c.threshold, "timelockMs": c.timelock_ms.to_string(), "openExecution": c.open_execution,
           "actions": c.actions, "targets": c.targets.iter().map(|t| h(t)).collect::<Vec<_>>(),
           "limits": c.limits.iter().map(|l| json!({"id": l.id, "signers": l.signers.iter().map(|s| h(s)).collect::<Vec<_>>(),
               "threshold": l.threshold, "amount": l.amount.to_string(), "periodMs": l.period_ms.to_string()})).collect::<Vec<_>>()})
}

fn nonce_free(s: &State, n: u64) -> bool {
    n >= s.nonce_base && n - s.nonce_base < NONCE_WINDOW && {
        let off = n - s.nonce_base;
        s.consumed[(off / 8) as usize] & (1 << (off % 8)) == 0
    }
}

fn free_nonces(s: &State, taken: &[u64], count: usize) -> Vec<u64> {
    (s.nonce_base..s.nonce_base + NONCE_WINDOW).filter(|n| nonce_free(s, *n) && !taken.contains(n)).take(count).collect()
}

fn state_json(m: &Msig, s: &State, balance: u128) -> Value {
    json!({"found": true, "account": h(m.account().as_ref()), "multisig": h(&m.key()), "createKey": h(&s.create_key),
           "zone": h(&s.zone), "epoch": s.epoch.to_string(), "nonceBase": s.nonce_base.to_string(),
           "freeNonces": free_nonces(s, &[], 8).iter().map(u64::to_string).collect::<Vec<_>>(),
           "config": config_json(&s.config), "balance": balance.to_string(),
           "usage": s.usage.iter().map(|x| json!({"id": x.id, "period": x.period.to_string(), "used": x.used.to_string()})).collect::<Vec<_>>(),
           "queue": s.queue.iter().map(|q| json!({"nonce": q.nonce.to_string(), "proposalId": h(&q.proposal_id),
               "etaMs": q.eta_ms.to_string(), "expiresMs": q.expires_ms.to_string()})).collect::<Vec<_>>()})
}

// ── the chain ───────────────────────────────────────────────────────────────────
fn public_msig(req: &Value) -> Result<Msig, String> {
    Ok(Msig::public(AccountId::new(k32(field(req, "program")?, "program")?), program().id(),
                    k32(field(req, "createKey")?, "createKey")?))
}

fn rpc_of(req: &Value) -> Result<&str, String> {
    field(req, "rpc")?.as_str().ok_or("rpc is not a string".to_string())
}

async fn read_state(rpc: &str, m: &Msig) -> Result<(State, u128), String> {
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let account = client.get_account(m.account()).await.map_err(|e| format!("getAccount: {e}"))?;
    let state = m.state_of(&account).ok_or("not-on-chain: no multisig at that program and create key")?;
    Ok((state, vault_balance(&account)))
}

fn taken_of(req: &Value) -> Result<Vec<u64>, String> {
    match req.get("taken") {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(t) => t.as_array().ok_or("taken is not a list")?.iter().map(|n| uint(n, "a taken nonce")).collect(),
    }
}

fn pick_nonce(req: &Value, s: &State) -> Result<u64, String> {
    if let Some(n) = req.get("nonce").filter(|x| !x.is_null()) {
        let n = uint(n, "nonce")?;
        return if nonce_free(s, n) { Ok(n) } else { Err(format!("nonce-spent: nonce {n} is used or outside the window")) };
    }
    free_nonces(s, &taken_of(req)?, 1).first().copied().ok_or("the nonce window is full: execute or cancel first".into())
}

// ── the modes ───────────────────────────────────────────────────────────────────
pub async fn run(mode: &str, req: &Value) -> Result<Value, String> {
    if mode == "send_public" {
        return send_public(req).await;
    }
    let m = public_msig(req)?;
    let rpc = rpc_of(req)?;
    match mode {
        "state" => match read_state(rpc, &m).await {
            Ok((s, balance)) => Ok(state_json(&m, &s, balance)),
            Err(e) if e.starts_with("not-on-chain") => Ok(json!({"found": false, "account": h(m.account().as_ref())})),
            Err(e) => Err(e),
        },
        "propose" => {
            // {action, proposer, expiresMs, nonce?, taken?} at the chain's zone and epoch
            let (s, _) = read_state(rpc, &m).await?;
            let p = Proposal { multisig: m.key(), zone: s.zone, epoch: s.epoch, nonce: pick_nonce(req, &s)?,
                               action: action_of(field(req, "action")?)?, expires_ms: u(req, "expiresMs")?,
                               proposer: k32(field(req, "proposer")?, "proposer")? };
            let id = proposal_id(&p);
            Ok(json!({"proposal": h(&borsh::to_vec(&p).map_err(|e| e.to_string())?), "proposalId": h(&id),
                      "approveMsg": h(&approve_msg(&id)), "executeMsg": h(&execute_msg(&id)),
                      "epoch": p.epoch.to_string(), "nonce": p.nonce.to_string()}))
        }
        "spend" => {
            // {limit, to, amount, expiresMs, nonce?, taken?}
            let (s, _) = read_state(rpc, &m).await?;
            let sp = Spend { multisig: m.key(), zone: s.zone, epoch: s.epoch, limit: uint(field(req, "limit")?, "limit")?,
                             nonce: pick_nonce(req, &s)?, to: k32(field(req, "to")?, "to")?,
                             amount: uint(field(req, "amount")?, "amount")?, expires_ms: u(req, "expiresMs")? };
            let limit = s.config.limits.iter().find(|l| l.id == sp.limit).ok_or(format!("unknown-limit: no limit {}", sp.limit))?;
            let period = req.get("nowMs").map(|x| uint::<u64>(x, "nowMs")).transpose()?.map(|now| now / limit.period_ms);
            Ok(json!({"spend": h(&borsh::to_vec(&sp).map_err(|e| e.to_string())?), "spendMsg": h(&spend_msg(&sp)),
                      "periodMs": limit.period_ms.to_string(), "period": period.map(|p| p.to_string()),
                      "epoch": sp.epoch.to_string(), "nonce": sp.nonce.to_string()}))
        }
        "check" => {
            // what the program would do with this instruction against the state now; sends nothing
            let (s, _) = read_state(rpc, &m).await?;
            let ins = instruction_of(req)?;
            let ctx = Ctx { multisig: m.key(), create_key: m.create_key };
            let window = msig_core::claims(&ins).map_err(|e| e.to_string())?.window;
            Ok(match msig_core::apply(Some(&s), &ins, &ctx, Some(&key32(&m.program))) {
                Ok(post) => json!({"ok": true, "epochAfter": post.epoch.to_string(),
                                   "window": {"fromMs": window.from.map(|x| x.to_string()), "toMs": window.to.map(|x| x.to_string())}}),
                Err(e) => json!({"ok": false, "refusal": e.to_string()}),
            })
        }
        "prepare" => {
            // an unsigned public transaction: {…instruction, payerKey, payerNonce?, fee?: {gasLimit, tip, maxFee}}
            let ins = instruction_of(req)?;
            let payer_key = PublicKey::try_new(k32(field(req, "payerKey")?, "payerKey")?).map_err(|e| format!("payerKey: {e:?}"))?;
            let payer = AccountId::from(&payer_key);
            let nonce: u128 = match req.get("payerNonce").filter(|x| !x.is_null()) {
                Some(n) => uint(n, "payerNonce")?,
                None => {
                    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
                    let ns = client.get_accounts_nonces(vec![payer]).await.map_err(|e| format!("getAccountsNonces: {e}"))?;
                    ns.first().map(|n| n.0).ok_or("no nonce for the payer")?
                }
            };
            let fee_v = req.get("fee").cloned().unwrap_or(json!({}));
            let fee = FeeDeclaration {
                payer,
                gas_limit: fee_v.get("gasLimit").map(|x| uint(x, "gasLimit")).transpose()?.unwrap_or(DEFAULT_GAS),
                tip: fee_v.get("tip").map(|x| uint(x, "tip")).transpose()?.unwrap_or(0),
                max_fee: fee_v.get("maxFee").map(|x| uint(x, "maxFee")).transpose()?.unwrap_or(DEFAULT_MAX_FEE),
            };
            let rows = m.selectors(&ins);
            let rows_json: Vec<Value> = rows.iter().map(|r| json!(format!("{r:?}"))).collect();
            let message = public_transaction::Message::try_new_with_fees(m.program, rows, vec![Nonce(nonce)], m.envelope(ins), fee)
                .map_err(|e| format!("building the message: {e:?}"))?;
            Ok(json!({"sign": h(&message.hash()), "message": h(&borsh::to_vec(&message).map_err(|e| e.to_string())?),
                      "payer": h(payer.as_ref()), "payerNonce": nonce.to_string(), "rows": rows_json}))
        }
        other => Err(format!("unknown mode {other}")),
    }
}

fn key32(a: &AccountId) -> [u8; 32] {
    a.as_ref().try_into().expect("an account id is 32 bytes")
}

/// A public message, signed by its payer elsewhere, sent: {rpc, message, witnesses:
/// [{signature, publicKey}]} → {hash}. Every signature is checked against the message first.
async fn send_public(req: &Value) -> Result<Value, String> {
    let rpc = rpc_of(req)?;
    let message: public_transaction::Message = borsh_of(req, "message")?;
    let mut sigs = Vec::new();
    for w in field(req, "witnesses")?.as_array().ok_or("witnesses is not a list")? {
        let value: [u8; 64] = hx(field(w, "signature")?, "signature")?.try_into().map_err(|_| "a signature is 64 bytes".to_string())?;
        let pk = PublicKey::try_new(k32(field(w, "publicKey")?, "publicKey")?).map_err(|e| format!("publicKey: {e:?}"))?;
        sigs.push((lee::Signature { value }, pk));
    }
    let ws = public_transaction::WitnessSet::from_raw_parts(sigs);
    if !ws.is_valid_for(&message) {
        return Err("bad-signature: a witness does not sign this message".into());
    }
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let hash = client.send_transaction(LeeTransaction::Public(PublicTransaction::new(message, ws))).await
        .map_err(|e| format!("sendTransaction: {e}"))?;
    Ok(json!({"hash": h(hash.as_ref())}))
}
