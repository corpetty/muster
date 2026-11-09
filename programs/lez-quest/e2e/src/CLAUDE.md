# e2e/src/

`main.rs`: the program on a running LEZ v0.3.0 sequencer, issued by a person and by a LEZ
multisig; judges every step by the state it reads back (a refused call is included on v0.3).
`multisig_wire.rs` mirrors the multisig port's wire types. See ../../CLAUDE.md for how to run it.
