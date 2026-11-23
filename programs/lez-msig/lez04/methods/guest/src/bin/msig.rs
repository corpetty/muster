//! lez-msig on LEZ v0.4: one actor handler over msig_core (docs/design/lez-msig.md; roadmap M3).
//!
//! Every message is one `ProgramInstruction`, delivered to the multisig's own actor
//! `(A, this program)`. The handler:
//!   1. refuses any sender but the transaction itself (`from` is None). Cross-zone and
//!      program-sent messages are new in v0.4; the approvals would still bind, but the multisig
//!      runs only as a root call (D14);
//!   2. re-derives A from (this program, the create key's seed, the placement) and refuses to
//!      run on any other account: the counterfeit-state defence (§2, D10);
//!   3. takes the window and any outflow from the instruction alone (`msig_core::claims`), and
//!      runs every rule against the stored state (`msig_core::apply`);
//!   4. writes the new state and sends the outflow granted the multisig's own seed and nothing
//!      else. The state is staged and the messages run after the handler returns, and a panic
//!      anywhere fails the whole transaction, so value leaves only when the approvals hold.
//!
//! A `Call` goes to ONE actor in v0.4: `rows[0]` is the target, which must be the call's
//! program; the transaction declares the other rows (D15). A seed grant now reaches the target's
//! whole call tree, so a `Call` hands the vault to everything the target calls (D16).

use lee_core::{
    account::{AccountId, Actor},
    native_token::custody_transfer,
    program::{ReceiveInput, Response, SyncMessage},
};
use msig_core::{Ctx, MsigError, Outflow, State};
use msig_v04::{key_of, multisig_account, seed, ProgramInstruction};

lee_core::actor_entrypoint!(handle);

fn refuse(e: MsigError) -> ! {
    panic!("{e}")
}

fn handle(input: &ReceiveInput, ins: ProgramInstruction) -> Response {
    assert!(input.from.is_none(), "wrong-caller: the multisig runs only as the transaction's own call");
    let program = input.receiver.program_account_id;
    let a = multisig_account(&program, &ins.create_key, &ins.placement);
    assert_eq!(
        input.receiver,
        Actor::new(a, program),
        "wrong-account: the receiver is not this multisig's account at its placement"
    );
    let claims = msig_core::claims(&ins.op).unwrap_or_else(|e| refuse(e));
    let pre: &[u8] = input.pre_state.as_ref();
    let pre = (!pre.is_empty()).then(|| borsh::from_slice::<State>(pre).unwrap_or_else(|_| refuse(MsigError::Decode)));
    let ctx = Ctx { multisig: key_of(&a), create_key: ins.create_key };
    let post = msig_core::apply(pre.as_ref(), &ins.op, &ctx, Some(&key_of(&program))).unwrap_or_else(|e| refuse(e));
    let mut r = Response::set_state(borsh::to_vec(&post).expect("borsh"))
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
    r
}
