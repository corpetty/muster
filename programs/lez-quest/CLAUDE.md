# programs/lez-quest/

The quest record program (exo-267.7): a LEZ v0.3.0 program, `run_program(plan, apply)`, that
keeps one record per quest. A quest is issued by an account (a circle's LEZ multisig vault,
granted by its Execute, or a person's own), accepted by its taker's own signature,
confirmed by its confirmer's, and closed by its issuer. The bounty sits in the record
account's native shard from Open until Close pays the taker or Cancel returns it. Design:
`docs/design/lez-quest-program.md`. Muster reads and writes it in `module/src/lez/quest.nim`.

It is built like the LEZ multisig's v0.3 port (`docs/design/lez-multisig-v03.md`):

- `quest_core`: the record, the instructions, the effects, the record's PDA.
- `quest_program`: `plan` and `apply`, with every rule tested in process
  (`src/tests.rs`).
- `methods`, `methods/guest`: the risc0 guest the zone runs.
- `e2e`: the program on a running sequencer (`quest_e2e`), and the client vectors
  (`src/bin/vectors.rs` → `module/tests/vectors/lez-quest-v010`). `src/multisig_wire.rs`
  mirrors the multisig port's wire types; keep its borsh variant order in step with the port.

```bash
# every rule, in process (no zkVM, no chain)
cargo test -p quest_program

# the guest: target/riscv-guest/quest-methods/quest-guest/riscv32im-risc0-zkvm-elf/release/quest.bin
RISC0_HOME=~/.cache/muster/risc0-home cargo build --release -p quest-methods

# the e2e and the vectors link RocksDB: a C++ compiler and libclang (infra/lez/localnet.sh's header)
export PATH="$(nix build --no-link --print-out-paths 'nixpkgs#gcc^out')/bin:$PATH"
export LIBCLANG_PATH="$(nix build --no-link --print-out-paths 'nixpkgs#libclang^lib')/lib"
RISC0_SKIP_BUILD=1 cargo build --release -p quest_e2e

# on a local v0.3 zone, with the multisig port deployed beside it
infra/lez/localnet.sh
infra/lez/localnet.sh deploy programs/lez-quest/target/riscv-guest/quest-methods/quest-guest/riscv32im-risc0-zkvm-elf/release/quest.bin
infra/lez/localnet.sh deploy <lez-multisig v0.3 port>/target/riscv-guest/multisig-methods/multisig-guest/riscv32im-risc0-zkvm-elf/release/multisig.bin
LD_LIBRARY_PATH="$(nix build --no-link --print-out-paths 'nixpkgs#gcc.cc^lib')/lib" \
  programs/lez-quest/target/release/quest_e2e http://127.0.0.1:3040 <quest program> <multisig program> "$PWD/infra/lez/localnet.sh fund"
```

Rules:

- The record names nobody without their own signature: only the named taker (or, when none
  is named, anyone but the confirmer) accepts, only the confirmer confirms, only the issuer
  opens, closes and cancels. A rule is a plan or apply assertion with a test that names it.
- Plan sees no data. A claim plan cannot check (Close's taker and bounty) travels in the
  instruction, and apply checks it against the record in the same transaction.
- On v0.3 a refused call is still included and pays. The e2e judges every step by the
  state it reads back, never by inclusion.
- Any program a multisig calls with its vault's seed can move the vault, through its own
  chained calls too (a chained call carries its caller's grants). Members approve this
  program's code by its account id; say so wherever a quest is proposed.
- A change to the record or an instruction changes the vectors: regenerate them and keep
  `lez/quest.nim` byte for byte with them.
