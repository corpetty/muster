//! msig_core: the rules of an M-of-N multisig on LEZ (docs/design/lez-msig.md), as pure
//! functions with no LEZ dependency. Adapters map them onto a runtime: v0.3's
//! `run_program(plan, apply)` (`programs/lez-msig/methods/guest`) and, later, `dev`'s actors.

pub mod digest;
pub mod error;
pub mod rules;
pub mod types;

#[cfg(feature = "signing")]
pub mod sign;

pub use digest::*;
pub use error::MsigError;
pub use rules::{adopt, apply, apply_stored, claims, forward, validate_config};
pub use types::*;
