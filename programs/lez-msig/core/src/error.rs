//! Every refusal, with a stable code a client can match and a sentence a person can act on
//! (RFP U.7). The program panics with `Display`, so the code is the first word of the message.

use crate::types::Key;
use core::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MsigError {
    NotInitialised,
    AlreadyInitialised,
    WrongAccount,
    WrongCreateKey,
    WrongZone,
    StaleEpoch { signed: u64, current: u64 },
    NonceSpent(u64),
    NonceOutOfWindow { nonce: u64, base: u64 },
    NotAMember(Key),
    MissingRole { key: Key, role: &'static str },
    ProposerDidNotSign,
    DuplicateSigner(Key),
    BadSignature(Key),
    BelowThreshold { have: u32, need: u32 },
    ExecutorRequired,
    ActionNotAllowed(&'static str),
    TargetNotAllowed(Key),
    CallsOwnProgram,
    NeedsQueue,
    NoTimelock,
    CancelNotQueued,
    QueueFull,
    NotQueued(u64),
    TooEarly { at: u64, eta: u64 },
    Expired { at: u64, expires: u64 },
    UnknownLimit(u32),
    NotALimitSigner(Key),
    WrongPeriod { claimed: u64, actual: u64 },
    StalePeriod { claimed: u64, current: u64 },
    OverLimit { used: u128, amount: u128, limit: u128 },
    InvalidConfig(&'static str),
    MemberInLimit(Key),
    Decode,
    Retired(Key),
    NotRetired,
    BadRotation(&'static str),
    BadHandover(&'static str),
    RotationUnsupported,
}

impl MsigError {
    /// The stable code: what a client matches on.
    pub fn code(&self) -> &'static str {
        use MsigError::*;
        match self {
            NotInitialised => "not-initialised",
            AlreadyInitialised => "already-initialised",
            WrongAccount => "wrong-account",
            WrongCreateKey => "wrong-create-key",
            WrongZone => "wrong-zone",
            StaleEpoch { .. } => "stale-epoch",
            NonceSpent(_) => "nonce-spent",
            NonceOutOfWindow { .. } => "nonce-out-of-window",
            NotAMember(_) => "not-a-member",
            MissingRole { .. } => "missing-role",
            ProposerDidNotSign => "proposer-did-not-sign",
            DuplicateSigner(_) => "duplicate-signer",
            BadSignature(_) => "bad-signature",
            BelowThreshold { .. } => "below-threshold",
            ExecutorRequired => "executor-required",
            ActionNotAllowed(_) => "action-not-allowed",
            TargetNotAllowed(_) => "target-not-allowed",
            CallsOwnProgram => "calls-own-program",
            NeedsQueue => "needs-queue",
            NoTimelock => "no-timelock",
            CancelNotQueued => "cancel-not-queued",
            QueueFull => "queue-full",
            NotQueued(_) => "not-queued",
            TooEarly { .. } => "too-early",
            Expired { .. } => "expired",
            UnknownLimit(_) => "unknown-limit",
            NotALimitSigner(_) => "not-a-limit-signer",
            WrongPeriod { .. } => "wrong-period",
            StalePeriod { .. } => "stale-period",
            OverLimit { .. } => "over-limit",
            InvalidConfig(_) => "invalid-config",
            MemberInLimit(_) => "member-in-limit",
            Decode => "decode",
            Retired(_) => "retired",
            NotRetired => "not-retired",
            BadRotation(_) => "bad-rotation",
            BadHandover(_) => "bad-handover",
            RotationUnsupported => "rotation-unsupported",
        }
    }
}

fn short(k: &Key) -> String {
    k[..4].iter().map(|b| format!("{b:02x}")).collect::<String>() + "…"
}

impl fmt::Display for MsigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use MsigError::*;
        let why = match self {
            NotInitialised => "this account holds no multisig yet: create it first".into(),
            AlreadyInitialised => "this account already holds a multisig".into(),
            WrongAccount => "the proposal was signed for another multisig".into(),
            WrongCreateKey => "the instruction names another create key than the multisig's".into(),
            WrongZone => "the proposal was signed for another zone".into(),
            StaleEpoch { signed, current } => format!(
                "approvals were gathered under epoch {signed}; the configuration changed since (epoch {current}): collect them again"),
            NonceSpent(n) => format!("nonce {n} was already executed, queued or cancelled"),
            NonceOutOfWindow { nonce, base } => format!(
                "nonce {nonce} is outside the window [{base}, {}): use a nonce in it", base + crate::types::NONCE_WINDOW),
            NotAMember(k) => format!("key {} is not a member", short(k)),
            MissingRole { key, role } => format!("member {} may not {role}", short(key)),
            ProposerDidNotSign => "the proposer's own approval signature is missing".into(),
            DuplicateSigner(k) => format!("key {} signed twice", short(k)),
            BadSignature(k) => format!("the signature by {} does not verify for this proposal", short(k)),
            BelowThreshold { have, need } => format!("approvals weigh {have}; the threshold is {need}"),
            ExecutorRequired => "this multisig requires an EXECUTE member to sign the execution".into(),
            ActionNotAllowed(k) => format!("this multisig does not allow {k} actions"),
            TargetNotAllowed(p) => format!("program {} is not on this multisig's list of targets", short(p)),
            CallsOwnProgram => "a call may not target the multisig program itself".into(),
            NeedsQueue => "this multisig has a time lock: queue the action first".into(),
            NoTimelock => "this multisig has no time lock: execute the action directly".into(),
            CancelNotQueued => "a cancel is never time-locked: execute it directly".into(),
            QueueFull => "the queue is full: execute or cancel a queued action first".into(),
            NotQueued(n) => format!("nothing is queued under nonce {n} for this proposal"),
            TooEarly { at, eta } => format!("the time lock ends at {eta}; this execution claims {at}"),
            Expired { at, expires } => format!("the proposal expires at {expires}; this claims {at}"),
            UnknownLimit(id) => format!("no spending limit {id}"),
            NotALimitSigner(k) => format!("key {} may not sign under this limit", short(k)),
            WrongPeriod { claimed, actual } => format!(
                "the spend claims a {claimed} ms period; the limit's is {actual} ms"),
            StalePeriod { claimed, current } => format!(
                "the spend counts against period {claimed}; the limit is already in period {current}"),
            OverLimit { used, amount, limit } => format!(
                "{used} spent this period plus {amount} exceeds the limit of {limit}"),
            InvalidConfig(why) => format!("the configuration would be invalid: {why}"),
            MemberInLimit(k) => format!(
                "member {} signs for a spending limit: remove or change the limit in the same change", short(k)),
            Decode => "the instruction or the state does not decode".into(),
            Retired(k) => format!(
                "this multisig is retired, succeeded by {}: act there; here only a sweep forwards funds", short(k)),
            NotRetired => "only a retired multisig sweeps its balance to a successor".into(),
            BadRotation(why) => format!("the rotation is invalid: {why}"),
            BadHandover(why) => format!("the handover is refused: {why}"),
            RotationUnsupported => "this runtime does not rotate a multisig: migrate it instead (D11)".into(),
        };
        write!(f, "{}: {why}", self.code())
    }
}
