//! lez-msig on LEZ v0.4: one actor handler over msig_core (docs/design/lez-msig.md; roadmap M3).
//!
//! A message reaches the multisig's actor `(A, this program)` from one of three senders:
//!
//! - **the transaction itself** (`from` is None): a `ProgramInstruction`. Cross-zone and
//!   program-sent instructions are new in v0.4; the approvals would still bind, but the multisig
//!   runs only as a root call (D14). The handler
//!   1. re-derives A from (this program, the create key's seed, the placement) and refuses to run
//!      on any other account: the counterfeit-state defence (§2, D10);
//!   2. takes the window and any outflow from the instruction alone (`msig_core::claims`), and
//!      runs every rule against the stored record (`msig_core::apply_stored`);
//!   3. writes the new record and sends the outflow granted the multisig's own seed and nothing
//!      else. The state is staged and the messages run after the handler returns, and a panic
//!      anywhere fails the whole transaction, so value leaves only when the approvals hold.
//! - **this program** (D19): a predecessor's `Handover`, granting this account's seed. Written
//!   once, onto an empty shard (`msig_core::adopt`).
//! - **its own native balance** (D19): the answer to the `ReadState` a rotation or a sweep sends.
//!   A retired multisig forwards all of it to its successor (`msig_core::forward`).
//!
//! A `Call` goes to ONE actor in v0.4: `rows[0]` is the target, which must be the call's
//! program; the transaction declares the other rows (D15). A seed grant now reaches the target's
//! whole call tree, so a `Call` hands the vault to everything the target calls (D16).
//!
//! A rotation (D19) retires A and, in the same transaction, sends the successor its state (granting
//! the successor's seed, never A's) and reads A's balance, which the answer then moves to the
//! successor under A's seed. LEE binds one account per (program, seed) in a transaction, so the
//! successor's create key, and its seed, are its own.

use lee_core::{
    account::{AccountId, Actor},
    native_token::{custody_transfer, decode_balance, Message as NativeMessage},
    program::{ReceiveInput, Response, StateReply, SyncMessage},
};
use msig_core::{Ctx, Handover, MsigError, Outflow, Stored};
use msig_v04::{key_of, multisig_account, seed, ProgramInstruction};

lee_core::actor_entrypoint!(raw handle);

fn refuse(e: MsigError) -> ! {
    panic!("{e}")
}

fn stored(input: &ReceiveInput) -> Option<Stored> {
    let pre: &[u8] = input.pre_state.as_ref();
    (!pre.is_empty()).then(|| Stored::decode(pre).unwrap_or_else(|| refuse(MsigError::Decode)))
}

fn handle(input: &ReceiveInput) -> Response {
    let a = input.receiver.account_id;
    if input.from == Some(Actor::native_balance(a)) {
        return forward(input);
    }
    if input.from_own_program() {
        return adopt(input);
    }
    assert!(input.from.is_none(), "wrong-caller: the multisig runs only as the transaction's own call");
    let ins: ProgramInstruction = borsh::from_slice(&input.message).unwrap_or_else(|_| refuse(MsigError::Decode));
    let program = input.receiver.program_account_id;
    let expected = multisig_account(&program, &ins.create_key, &ins.placement);
    assert_eq!(
        input.receiver,
        Actor::new(expected, program),
        "wrong-account: the receiver is not this multisig's account at its placement"
    );
    let claims = msig_core::claims(&ins.op).unwrap_or_else(|e| refuse(e));
    let ctx = Ctx { multisig: key_of(&a), create_key: ins.create_key };
    let applied = msig_core::apply_stored(stored(input).as_ref(), &ins.op, &ctx, Some(&key_of(&program)))
        .unwrap_or_else(|e| refuse(e));
    let mut r = Response::set_state(applied.post.encode())
        .try_timestamp_window((claims.window.from, claims.window.to))
        .unwrap_or_else(|_| panic!("expired: the instruction's window is empty"));
    match claims.outflow {
        None => {}
        Some(Outflow::Pay { to, amount }) => {
            r = r.send(custody_transfer(a, seed(&ins.create_key), AccountId::new(to), amount));
        }
        Some(Outflow::Invoke { program: target, rows, data }) => {
            let t = rows
                .first()
                .filter(|r| r.program == target)
                .unwrap_or_else(|| panic!("wrong-rows: a call's first row is its target, an account of the called program"));
            r = r.send(SyncMessage {
                to: Actor::new(AccountId::new(t.account), AccountId::new(target)),
                message: data,
                pda_seeds: [seed(&ins.create_key)].into(),
            });
        }
    }
    if let Some(h) = applied.handover {
        let to = Actor::new(AccountId::new(h.to), program);
        r = r.send(SyncMessage::new(to, &h).with_pda_seeds([seed(&h.state.create_key)]));
    }
    if applied.sweep_to.is_some() {
        r = r.send_sync(Actor::native_balance(a), &NativeMessage::ReadState);
    }
    r
}

/// At a successor: its predecessor's handover. Only this program sends one, and only an
/// authorized one counts: the sender granted this account's seed, which LEE checks is the seed of
/// this account's own witness (a private PDA) or derives it (a public one).
fn adopt(input: &ReceiveInput) -> Response {
    assert!(
        input.is_authorized,
        "bad-handover: only a predecessor granting this multisig's seed hands it over"
    );
    let h: Handover = borsh::from_slice(&input.message).unwrap_or_else(|_| refuse(MsigError::Decode));
    let ctx = Ctx { multisig: key_of(&input.receiver.account_id), create_key: h.state.create_key };
    let post = msig_core::adopt(stored(input).as_ref(), &ctx, &h).unwrap_or_else(|e| refuse(e));
    Response::set_state(Stored::Active(post).encode())
}

/// At a retired multisig: its native balance's answer. All of it goes to the successor, under this
/// account's own seed.
fn forward(input: &ReceiveInput) -> Response {
    let reply: StateReply = borsh::from_slice(&input.message).unwrap_or_else(|_| refuse(MsigError::Decode));
    let balance = decode_balance(&reply.state).unwrap_or_else(|_| refuse(MsigError::Decode));
    let pre = stored(input).unwrap_or_else(|| refuse(MsigError::NotInitialised));
    let Stored::Retired(r) = &pre else { refuse(MsigError::NotRetired) };
    let mut response = Response::keep_state();
    if let Some(Outflow::Pay { to, amount }) = msig_core::forward(&pre, balance).unwrap_or_else(|e| refuse(e)) {
        let a = input.receiver.account_id;
        response = response.send(custody_transfer(a, seed(&r.create_key), AccountId::new(to), amount));
    }
    response
}
