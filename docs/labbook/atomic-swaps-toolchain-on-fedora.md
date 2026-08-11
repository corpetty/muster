# Getting the eth-lez-atomic-swaps toolchain up on Fedora 43 (2026-08-10)

Context: the txn-pipeline speed build (`demo/`) is patterned on `logos-co/eth-lez-atomic-swaps`; its `make setup` (→ `lgs setup`, builds the LEZ v0.2.2 localnet stack from source) needed four host-environment fixes on this box. None are bugs in the stack itself; all are Fedora/host quirks. Record them for the demo runbook and the article's reproducibility notes.

## Prerequisites that were already present
- Rust 1.93 via rustup (repo pins 1.93.0 in `rust-toolchain.toml`)
- Determinate Nix 3.15.1 with flakes; podman (accepted by scaffold as the container runtime)
- `logos-blockchain-circuits` bundle at `~/.logos-blockchain-circuits` (v0.4.1; scaffold.toml wants 0.4.2 — watch whether setup refetches)

## Installed for this work
- `lgs` / `logos-scaffold` 0.1.1: `cargo install --path .` from `logos-co/scaffold` at pin `6789ec04b2ad256186a5894710c419b42d16e479` (the commit atomic-swaps' README requires)
- Foundry 1.7.1 from **nixpkgs** (`nix profile add nixpkgs#foundry`) — the vendor `curl | bash` installer was deliberately not used
- `cargo-risczero` **deferred**: crates.io build failed on host, but scaffold drives guest builds through a container runtime and localnet sets `risc0_dev_mode = true`, so it may never be needed. Revisit only if a build step demands it.

## The four fixes

1. **bindgen can't find `stdbool.h`** (librocksdb-sys, building `sequencer_service`).
   Fedora ships clang headers via `clang-resource-filesystem` but bindgen doesn't pass the resource dir.
   Fix: `export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/lib/clang/21/include"`

2. **scaffold refuses its own LEZ cache clone** ("does not match requested source").
   Global gitconfig `url.https://github.com/.insteadOf = git@github.com:` rewrites `git remote get-url`, and scaffold's `source_matches` (src/repo.rs) compares effective URLs without unifying ssh/https forms.
   Fix: edit atomic-swaps `scaffold.toml` `[repos.lez].source` to the https URL.
   Upstream issue to file on logos-co/scaffold (chip spawned in session).

3. **No host C++ compiler** (`cc-rs: failed to find tool "c++"`, wallet/sequencer C++ deps).
   Box has clang-libs only, no g++.
   Fix: run setup inside `nix shell nixpkgs#gcc` rather than dnf-installing gcc-c++.

4. **wallet crate needs pcsclite via pkg-config** (Keycard/smartcard dep).
   Fix: `PKG_CONFIG_PATH=$(nix build nixpkgs#pcsclite.dev --no-link --print-out-paths)/lib/pkgconfig` plus `nix shell nixpkgs#pkg-config`.
   Note: link-time only for now; if the wallet binary later fails to find `libpcsclite.so.1` at runtime, add the non-dev `pcsclite` lib dir to `LD_LIBRARY_PATH` or bite the bullet and `dnf install pcsc-lite-devel`.

## Working invocation (as of attempt 5, in progress)

```bash
export PATH="$HOME/.cargo/bin:$PATH"
export BINDGEN_EXTRA_CLANG_ARGS="-I/usr/lib/clang/21/include"
export PKG_CONFIG_PATH="$(nix build nixpkgs#pcsclite.dev --no-link --print-out-paths)/lib/pkgconfig"
cd ~/Github/logos-co/eth-lez-atomic-swaps
nix shell nixpkgs#gcc nixpkgs#pkg-config --command make setup
```

Open question for the demo's own Makefile: wrap these exports in a `scripts/host-env.sh` so `make setup` works first-try on a fresh Fedora box.
