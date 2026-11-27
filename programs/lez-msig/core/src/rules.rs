//! The rules (docs/design/lez-msig.md §5). Two pure functions:
//!
//! - `claims(instruction)`: what the transaction does as the instruction alone says it, which is
//!   the window it must land in and any outflow. A plan, which sees no data, emits these.
//! - `apply(state, instruction, ctx)`: every check against the stored state, and the new state.
//!   It proves the claims are what the members approved, so a chained call from the plan runs
//!   only if `apply` accepted.
//!
//! `apply` is v0.3's entry, over a bare `State`. An actor adapter (v0.4) calls `apply_stored`,
//! which also knows a retired multisig and returns what else the transaction must send (D19's
//! rotation: a handover and a balance read), then `adopt` at the successor and `forward` on the
//! balance's answer.
//!
//! All are total over their inputs and never panic; adapters turn an `Err` into a refusal.

use crate::digest::{approve_msg, execute_msg, proposal_id, spend_msg};
use crate::error::MsigError;
use crate::types::*;
use k256::schnorr::{Signature, VerifyingKey};

type R<T> = Result<T, MsigError>;

// ── the instruction alone ──────────────────────────────────────────────────────

fn outflow_of(a: &Action) -> Option<Outflow> {
    match a {
        Action::Transfer { to, amount } => Some(Outflow::Pay { to: *to, amount: *amount }),
        Action::Call { program, rows, data } => {
            Some(Outflow::Invoke { program: *program, rows: rows.clone(), data: data.clone() })
        }
        // A rotation's balance is read in the transaction, not claimed by the instruction.
        Action::Config(_) | Action::Cancel(_) | Action::Rotate { .. } => None,
    }
}

/// The window and outflow the instruction claims. Refuses windows that are empty by
/// construction, so a plan never emits one the sequencer would reject for its shape.
pub fn claims(ins: &Instruction) -> R<Claims> {
    let w = |from: Option<u64>, to: Option<u64>| -> R<Window> {
        if let (Some(f), Some(t)) = (from, to) {
            if f >= t {
                return Err(MsigError::Expired { at: f, expires: t });
            }
        }
        Ok(Window { from, to })
    };
    Ok(match ins {
        Instruction::Create { .. } | Instruction::Sweep => Claims::default(),
        Instruction::Execute { proposal, .. } => Claims {
            window: w(None, Some(proposal.expires_ms))?,
            outflow: outflow_of(&proposal.action),
        },
        // Lands no later than at_ms, so an ETA counted from at_ms is never early.
        Instruction::Queue { proposal, at_ms, .. } => Claims {
            window: w(None, Some(at_ms.saturating_add(1).min(proposal.expires_ms)))?,
            outflow: None,
        },
        Instruction::ExecuteQueued { proposal, at_ms, .. } => Claims {
            window: w(Some(*at_ms), Some(proposal.expires_ms))?,
            outflow: outflow_of(&proposal.action),
        },
        Instruction::Spend { spend, period, period_ms, .. } => {
            if *period_ms == 0 {
                return Err(MsigError::WrongPeriod { claimed: 0, actual: 0 });
            }
            let start = period.checked_mul(*period_ms).ok_or(MsigError::Decode)?;
            let end = start.checked_add(*period_ms).ok_or(MsigError::Decode)?;
            Claims {
                window: w(Some(start), Some(end.min(spend.expires_ms)))?,
                outflow: Some(Outflow::Pay { to: spend.to, amount: spend.amount }),
            }
        }
    })
}

// ── checks against the state ───────────────────────────────────────────────────

pub fn member<'a>(c: &'a Config, k: &Key) -> Option<&'a Member> {
    c.members.iter().find(|m| &m.key == k)
}

fn verify(key: &Key, msg: &Key, sig: &Sig) -> R<()> {
    let vk = VerifyingKey::from_bytes(key).map_err(|_| MsigError::BadSignature(*key))?;
    let s = Signature::try_from(&sig[..]).map_err(|_| MsigError::BadSignature(*key))?;
    vk.verify_raw(msg, &s).map_err(|_| MsigError::BadSignature(*key))
}

/// A valid configuration (§5 "A valid config").
pub fn validate_config(c: &Config) -> R<()> {
    use MsigError::InvalidConfig as Bad;
    if c.members.is_empty() || c.members.len() > MAX_MEMBERS {
        return Err(Bad("between 1 and 32 members"));
    }
    for (i, m) in c.members.iter().enumerate() {
        if c.members[..i].iter().any(|o| o.key == m.key) {
            return Err(Bad("member keys must be distinct"));
        }
        if m.weight == 0 {
            return Err(Bad("every weight is at least 1"));
        }
        if m.roles == 0 || m.roles & !role::ALL != 0 {
            return Err(Bad("every member holds a known role"));
        }
        if VerifyingKey::from_bytes(&m.key).is_err() {
            return Err(Bad("a member key is not a BIP-340 public key"));
        }
    }
    let approve_weight: u32 =
        c.members.iter().filter(|m| m.roles & role::APPROVE != 0).map(|m| m.weight as u32).sum();
    if c.threshold == 0 || c.threshold > approve_weight {
        return Err(Bad("the threshold is between 1 and the approvers' total weight"));
    }
    if !c.members.iter().any(|m| m.roles & role::PROPOSE != 0) {
        return Err(Bad("someone must be able to propose"));
    }
    if !c.open_execution && !c.members.iter().any(|m| m.roles & role::EXECUTE != 0) {
        return Err(Bad("someone must be able to execute"));
    }
    if c.actions & !action_kind::ALL != 0 {
        return Err(Bad("unknown action kind"));
    }
    if c.targets.len() > MAX_TARGETS {
        return Err(Bad("at most 16 targets"));
    }
    if c.timelock_ms > MAX_TIMELOCK_MS {
        return Err(Bad("a time lock of at most a year"));
    }
    if c.limits.len() > MAX_LIMITS {
        return Err(Bad("at most 8 spending limits"));
    }
    for (i, l) in c.limits.iter().enumerate() {
        if c.limits[..i].iter().any(|o| o.id == l.id) {
            return Err(Bad("spending limit ids must be distinct"));
        }
        if l.signers.is_empty() || l.threshold == 0 || l.threshold as usize > l.signers.len() {
            return Err(Bad("a limit's threshold is between 1 and its signers"));
        }
        for (j, s) in l.signers.iter().enumerate() {
            if l.signers[..j].contains(s) {
                return Err(Bad("a limit's signers must be distinct"));
            }
            if member(c, s).is_none() {
                return Err(Bad("a limit's signers must be members"));
            }
        }
        if l.amount == 0 || l.period_ms == 0 {
            return Err(Bad("a limit has an amount and a period"));
        }
    }
    Ok(())
}

fn nonce_bit(s: &State, n: u64) -> R<(usize, u8)> {
    if n < s.nonce_base {
        return Err(MsigError::NonceSpent(n));
    }
    let off = n - s.nonce_base;
    if off >= NONCE_WINDOW {
        return Err(MsigError::NonceOutOfWindow { nonce: n, base: s.nonce_base });
    }
    Ok(((off / 8) as usize, 1u8 << (off % 8)))
}

pub fn nonce_free(s: &State, n: u64) -> R<()> {
    let (i, b) = nonce_bit(s, n)?;
    if s.consumed[i] & b != 0 {
        return Err(MsigError::NonceSpent(n));
    }
    Ok(())
}

fn consume(s: &mut State, n: u64) -> R<()> {
    nonce_free(s, n)?;
    let (i, b) = nonce_bit(s, n)?;
    s.consumed[i] |= b;
    // Slide the window past every spent nonce at its base.
    while s.consumed[0] & 1 != 0 {
        let mut carry = 0u8;
        for byte in s.consumed.iter_mut().rev() {
            let next = *byte & 1;
            *byte = (*byte >> 1) | (carry << 7);
            carry = next;
        }
        s.nonce_base += 1;
    }
    Ok(())
}

fn require_role<'a>(c: &'a Config, k: &Key, r: u8, name: &'static str) -> R<&'a Member> {
    let m = member(c, k).ok_or(MsigError::NotAMember(*k))?;
    if m.roles & r == 0 {
        return Err(MsigError::MissingRole { key: *k, role: name });
    }
    Ok(m)
}

/// R.1: the proposer signed; distinct APPROVE members' valid signatures weigh at least the
/// threshold. Signatures are checked last, so a cheap refusal costs no curve arithmetic.
fn check_approvals(c: &Config, p: &Proposal, id: &Key, approvals: &[Signed]) -> R<()> {
    require_role(c, &p.proposer, role::PROPOSE, "propose")?;
    let mut weight: u32 = 0;
    let mut proposer_signed = false;
    for (i, a) in approvals.iter().enumerate() {
        if approvals[..i].iter().any(|o| o.key == a.key) {
            return Err(MsigError::DuplicateSigner(a.key));
        }
        let m = member(c, &a.key).ok_or(MsigError::NotAMember(a.key))?;
        if a.key == p.proposer {
            proposer_signed = true;
        }
        if m.roles & role::APPROVE != 0 {
            weight += m.weight as u32;
        } else if a.key != p.proposer {
            return Err(MsigError::MissingRole { key: a.key, role: "approve" });
        }
    }
    if !proposer_signed {
        return Err(MsigError::ProposerDidNotSign);
    }
    if weight < c.threshold {
        return Err(MsigError::BelowThreshold { have: weight, need: c.threshold });
    }
    let msg = approve_msg(id);
    for a in approvals {
        verify(&a.key, &msg, &a.sig)?;
    }
    Ok(())
}

fn check_executor(c: &Config, id: &Key, executor: &Option<Signed>) -> R<()> {
    if c.open_execution {
        return Ok(());
    }
    let e = executor.as_ref().ok_or(MsigError::ExecutorRequired)?;
    require_role(c, &e.key, role::EXECUTE, "execute")?;
    verify(&e.key, &execute_msg(id), &e.sig)
}

fn check_action_allowed(c: &Config, a: &Action, ctx_program: Option<&Key>) -> R<()> {
    match a {
        Action::Transfer { .. } if c.actions & action_kind::TRANSFER == 0 => {
            Err(MsigError::ActionNotAllowed("transfer"))
        }
        Action::Call { .. } if c.actions & action_kind::CALL == 0 => Err(MsigError::ActionNotAllowed("call")),
        Action::Call { program, .. } => {
            if Some(program) == ctx_program {
                return Err(MsigError::CallsOwnProgram);
            }
            if !c.targets.is_empty() && !c.targets.contains(program) {
                return Err(MsigError::TargetNotAllowed(*program));
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// The checks shared by Execute and Queue: the proposal is for this multisig, zone and epoch,
/// its nonce is free, its action allowed, its approvals and executor sufficient.
fn check_proposal(
    s: &State,
    p: &Proposal,
    approvals: &[Signed],
    executor: &Option<Signed>,
    ctx: &Ctx,
    program: Option<&Key>,
) -> R<Key> {
    if p.multisig != ctx.multisig {
        return Err(MsigError::WrongAccount);
    }
    if p.zone != s.zone {
        return Err(MsigError::WrongZone);
    }
    if p.epoch != s.epoch {
        return Err(MsigError::StaleEpoch { signed: p.epoch, current: s.epoch });
    }
    nonce_free(s, p.nonce)?;
    check_action_allowed(&s.config, &p.action, program)?;
    let id = proposal_id(p);
    check_approvals(&s.config, p, &id, approvals)?;
    check_executor(&s.config, &id, executor)?;
    Ok(id)
}

fn apply_changes(s: &mut State, changes: &[ConfigChange]) -> R<()> {
    let mut c = s.config.clone();
    for ch in changes {
        match ch {
            ConfigChange::AddMember(m) => {
                if member(&c, &m.key).is_some() {
                    return Err(MsigError::InvalidConfig("member keys must be distinct"));
                }
                c.members.push(m.clone());
            }
            ConfigChange::RemoveMember(k) => {
                if member(&c, k).is_none() {
                    return Err(MsigError::NotAMember(*k));
                }
                if c.limits.iter().any(|l| l.signers.contains(k)) {
                    return Err(MsigError::MemberInLimit(*k));
                }
                c.members.retain(|m| &m.key != k);
            }
            ConfigChange::SetRoles { key, roles } => {
                c.members.iter_mut().find(|m| &m.key == key).ok_or(MsigError::NotAMember(*key))?.roles = *roles
            }
            ConfigChange::SetWeight { key, weight } => {
                c.members.iter_mut().find(|m| &m.key == key).ok_or(MsigError::NotAMember(*key))?.weight = *weight
            }
            ConfigChange::SetThreshold(t) => c.threshold = *t,
            ConfigChange::SetTimelock(t) => c.timelock_ms = *t,
            ConfigChange::SetOpenExecution(o) => c.open_execution = *o,
            ConfigChange::SetActions(a) => c.actions = *a,
            ConfigChange::SetTargets(t) => c.targets = t.clone(),
            ConfigChange::AddLimit(l) => c.limits.push(l.clone()),
            ConfigChange::RemoveLimit(id) => {
                let before = c.limits.len();
                c.limits.retain(|l| l.id != *id);
                if c.limits.len() == before {
                    return Err(MsigError::UnknownLimit(*id));
                }
                s.usage.retain(|u| u.id != *id);
            }
        }
    }
    validate_config(&c)?;
    s.config = c;
    // R.2: every approval gathered before this change stops counting.
    s.epoch += 1;
    Ok(())
}

/// Runs the action on the state. A rotation returns the successor's state instead (D19): the
/// changes applied as `Config` applies them, its own create key, the limits' usage and the nonce
/// window carried over, and an empty queue.
fn run_action(s: &mut State, a: &Action, ctx: &Ctx) -> R<Option<Handover>> {
    match a {
        Action::Rotate { create_key, successor, changes } => {
            if *create_key == s.create_key {
                return Err(MsigError::BadRotation("the successor needs a create key of its own"));
            }
            if *successor == ctx.multisig {
                return Err(MsigError::BadRotation("the successor must be another account"));
            }
            let mut next = s.clone();
            apply_changes(&mut next, changes)?;
            next.create_key = *create_key;
            // Queued actions name this account: they do not carry over (a rotation cancels them).
            next.queue.clear();
            Ok(Some(Handover { to: *successor, state: next }))
        }
        a => run_plain(s, a).map(|()| None),
    }
}

fn run_plain(s: &mut State, a: &Action) -> R<()> {
    match a {
        Action::Config(changes) => apply_changes(s, changes),
        Action::Cancel(nonces) => {
            for n in nonces {
                s.queue.retain(|q| q.nonce != *n);
                // A nonce still free is spent so the proposal can never run; one already spent
                // (executed, or queued and now unqueued) stays spent.
                if nonce_free(s, *n).is_ok() {
                    consume(s, *n)?;
                }
            }
            Ok(())
        }
        Action::Transfer { .. } | Action::Call { .. } | Action::Rotate { .. } => Ok(()),
    }
}

/// v0.3's entry: every check against the stored state, and the new state. `pre` is the program's
/// shard as stored (`None` or empty when the account holds no multisig yet). `program` is the
/// multisig program's own id, when the adapter knows it, so a `Call` cannot target it.
///
/// v0.3 has no actor messages, so it cannot rotate: a `Rotate` and a `Sweep` are refused here
/// (`rotation-unsupported`), and v0.3 migrates (D11).
pub fn apply(pre: Option<&State>, ins: &Instruction, ctx: &Ctx, program: Option<&Key>) -> R<State> {
    let rotates = |p: &Proposal| matches!(p.action, Action::Rotate { .. });
    match ins {
        Instruction::Sweep => return Err(MsigError::RotationUnsupported),
        Instruction::Execute { proposal, .. }
        | Instruction::Queue { proposal, .. }
        | Instruction::ExecuteQueued { proposal, .. }
            if rotates(proposal) =>
        {
            return Err(MsigError::RotationUnsupported)
        }
        _ => {}
    }
    if let Instruction::Create { .. } = ins {
        return create(pre.is_some(), ins, ctx);
    }
    let s0 = pre.ok_or(MsigError::NotInitialised)?;
    step(s0, ins, ctx, program).map(|(s, _)| s)
}

/// The actor adapter's entry (v0.4): `apply` over what the shard stores, active or retired, and what
/// the transaction must also send. A retired multisig refuses everything but `Sweep`.
pub fn apply_stored(pre: Option<&Stored>, ins: &Instruction, ctx: &Ctx, program: Option<&Key>) -> R<Applied> {
    if let Instruction::Create { .. } = ins {
        let s = create(pre.is_some(), ins, ctx)?;
        return Ok(Applied { post: Stored::Active(s), handover: None, sweep_to: None });
    }
    match pre.ok_or(MsigError::NotInitialised)? {
        Stored::Retired(r) => {
            if r.create_key != ctx.create_key {
                return Err(MsigError::WrongCreateKey);
            }
            match ins {
                Instruction::Sweep => {
                    Ok(Applied { post: Stored::Retired(r.clone()), handover: None, sweep_to: Some(r.successor) })
                }
                _ => Err(MsigError::Retired(r.successor)),
            }
        }
        Stored::Active(s0) => {
            if let Instruction::Sweep = ins {
                return Err(MsigError::NotRetired);
            }
            let (s, handover) = step(s0, ins, ctx, program)?;
            Ok(match handover {
                None => Applied { post: Stored::Active(s), handover: None, sweep_to: None },
                Some(h) => Applied {
                    post: Stored::Retired(Retired {
                        mark: RETIRED,
                        create_key: s.create_key,
                        epoch: h.state.epoch,
                        successor: h.to,
                    }),
                    sweep_to: Some(h.to),
                    handover: Some(h),
                },
            })
        }
    }
}

/// At a successor, its predecessor's handover (D19): written once, onto an empty shard, naming this
/// account and its create key, with a valid configuration and an empty queue. The adapter has
/// already checked that the program sent it granting this account's seed.
pub fn adopt(pre: Option<&Stored>, ctx: &Ctx, h: &Handover) -> R<State> {
    if pre.is_some() {
        return Err(MsigError::AlreadyInitialised);
    }
    if h.to != ctx.multisig {
        return Err(MsigError::BadHandover("it names another account"));
    }
    let s = &h.state;
    if s.version != VERSION {
        return Err(MsigError::BadHandover("an unknown state version"));
    }
    if s.create_key != ctx.create_key {
        return Err(MsigError::WrongCreateKey);
    }
    if !s.queue.is_empty() {
        return Err(MsigError::BadHandover("a successor starts with an empty queue"));
    }
    validate_config(&s.config)?;
    Ok(s.clone())
}

/// On the balance's answer to a rotation or a sweep (D19): where it goes. Only a retired multisig
/// reads its balance, and all of it goes to the successor.
pub fn forward(pre: &Stored, balance: u128) -> R<Option<Outflow>> {
    match pre {
        Stored::Active(_) => Err(MsigError::NotRetired),
        Stored::Retired(r) => Ok((balance > 0).then_some(Outflow::Pay { to: r.successor, amount: balance })),
    }
}

fn create(exists: bool, ins: &Instruction, ctx: &Ctx) -> R<State> {
    let Instruction::Create { zone, config } = ins else { return Err(MsigError::Decode) };
    if exists {
        return Err(MsigError::AlreadyInitialised);
    }
    validate_config(config)?;
    Ok(State {
        version: VERSION,
        zone: *zone,
        create_key: ctx.create_key,
        epoch: 0,
        config: config.clone(),
        usage: Vec::new(),
        nonce_base: 0,
        consumed: [0; 32],
        queue: Vec::new(),
    })
}

/// Every instruction but Create and Sweep, against an active multisig: its new state, and the
/// successor's when the action rotates.
fn step(s0: &State, ins: &Instruction, ctx: &Ctx, program: Option<&Key>) -> R<(State, Option<Handover>)> {
    if s0.create_key != ctx.create_key {
        return Err(MsigError::WrongCreateKey);
    }
    let mut s = s0.clone();
    let mut handover = None;
    match ins {
        Instruction::Create { .. } | Instruction::Sweep => return Err(MsigError::Decode), // the callers handle both
        Instruction::Execute { proposal: p, approvals, executor } => {
            check_proposal(&s, p, approvals, executor, ctx, program)?;
            if s.config.timelock_ms > 0 && !matches!(p.action, Action::Cancel(_)) {
                return Err(MsigError::NeedsQueue);
            }
            consume(&mut s, p.nonce)?;
            handover = run_action(&mut s, &p.action, ctx)?;
        }
        Instruction::Queue { proposal: p, approvals, executor, at_ms } => {
            if s.config.timelock_ms == 0 {
                return Err(MsigError::NoTimelock);
            }
            if matches!(p.action, Action::Cancel(_)) {
                return Err(MsigError::CancelNotQueued);
            }
            let id = check_proposal(&s, p, approvals, executor, ctx, program)?;
            if s.queue.len() >= MAX_QUEUE {
                return Err(MsigError::QueueFull);
            }
            let eta = at_ms.saturating_add(s.config.timelock_ms);
            if eta >= p.expires_ms {
                return Err(MsigError::Expired { at: eta, expires: p.expires_ms });
            }
            consume(&mut s, p.nonce)?;
            s.queue.push(Queued { nonce: p.nonce, proposal_id: id, eta_ms: eta, expires_ms: p.expires_ms });
        }
        Instruction::ExecuteQueued { proposal: p, executor, at_ms } => {
            if p.multisig != ctx.multisig {
                return Err(MsigError::WrongAccount);
            }
            let id = proposal_id(p);
            let pos = s
                .queue
                .iter()
                .position(|q| q.nonce == p.nonce && q.proposal_id == id)
                .ok_or(MsigError::NotQueued(p.nonce))?;
            let q = s.queue[pos].clone();
            if *at_ms < q.eta_ms {
                return Err(MsigError::TooEarly { at: *at_ms, eta: q.eta_ms });
            }
            if *at_ms >= q.expires_ms {
                return Err(MsigError::Expired { at: *at_ms, expires: q.expires_ms });
            }
            // The epoch is NOT re-checked: the R.2 cutoff is the queue. The executor and the
            // action set are the current configuration's.
            check_executor(&s.config, &id, executor)?;
            check_action_allowed(&s.config, &p.action, program)?;
            s.queue.remove(pos);
            handover = run_action(&mut s, &p.action, ctx)?;
        }
        Instruction::Spend { spend: sp, approvals, period, period_ms } => {
            if sp.multisig != ctx.multisig {
                return Err(MsigError::WrongAccount);
            }
            if sp.zone != s.zone {
                return Err(MsigError::WrongZone);
            }
            if sp.epoch != s.epoch {
                return Err(MsigError::StaleEpoch { signed: sp.epoch, current: s.epoch });
            }
            let limit = s.config.limits.iter().find(|l| l.id == sp.limit).cloned().ok_or(MsigError::UnknownLimit(sp.limit))?;
            if *period_ms != limit.period_ms {
                return Err(MsigError::WrongPeriod { claimed: *period_ms, actual: limit.period_ms });
            }
            nonce_free(&s, sp.nonce)?;
            let mut n = 0usize;
            for (i, a) in approvals.iter().enumerate() {
                if approvals[..i].iter().any(|o| o.key == a.key) {
                    return Err(MsigError::DuplicateSigner(a.key));
                }
                if !limit.signers.contains(&a.key) {
                    return Err(MsigError::NotALimitSigner(a.key));
                }
                n += 1;
            }
            if n < limit.threshold as usize {
                return Err(MsigError::BelowThreshold { have: n as u32, need: limit.threshold as u32 });
            }
            let used_before = match s.usage.iter().find(|u| u.id == sp.limit) {
                Some(u) if u.period > *period => {
                    return Err(MsigError::StalePeriod { claimed: *period, current: u.period })
                }
                Some(u) if u.period == *period => u.used,
                _ => 0,
            };
            let used = used_before.checked_add(sp.amount).ok_or(MsigError::OverLimit {
                used: used_before,
                amount: sp.amount,
                limit: limit.amount,
            })?;
            if used > limit.amount {
                return Err(MsigError::OverLimit { used: used_before, amount: sp.amount, limit: limit.amount });
            }
            let msg = spend_msg(sp);
            for a in approvals {
                verify(&a.key, &msg, &a.sig)?;
            }
            consume(&mut s, sp.nonce)?;
            s.usage.retain(|u| u.id != sp.limit);
            s.usage.push(LimitUsage { id: sp.limit, period: *period, used });
        }
    }
    Ok((s, handover))
}
