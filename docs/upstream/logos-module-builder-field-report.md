# Field report: building a Rust module that shares code with another

**To:** the Logos module builder team (`logos-co/logos-module-builder`).
**From:** the Muster team (`corpetty/muster`).
**Date:** 2026-11-21. **Status:** notes and one ask, kept current as we go.

## One line

Two builds of one Logos module, `lez_msig_module`, one per LEZ line (v0.3 and v0.4, whose
dependency graphs cannot coexist), share a crate of rules that lives outside either package. The
builder compiles only the package directory, so the second build needed a staged source. That
works, but it costs import-from-derivation and a Cargo workspace trap.

**Update, 2026-11-23.** The v0.4 build is now its own module, `lez_msig_v04_module` (0.2.x), beside
`lez_msig_module` (0.1.x). A dependency resolves by name: one name meant a host, a catalogue or the
runner's module set could hold one line's build or the other, never both. With two names,
`muster_module` declares both as optional and calls the one its zone needs. Muster 0.4.0 ships
both. The shared-source issue below is unchanged: the v0.4 module still stages `../core`.

## What we hit

How to read this: **[measured]** means we ran it; **[from source]** means we read it in
`lib/mkLogosModule.nix` at 0.3.3.

1. **Only the package directory reaches the sandbox** [from source]. `rustCrateSrc` copies
   `${src}/${codegen.rust.crate}` to `rust-lib/`. A crate with a path dependency outside that
   directory (ours: `msig_core = { path = "../core" }`) cannot build. Our v0.3 package avoids it by
   making the whole program directory the package. The v0.4 package cannot: it is a sibling
   workspace.
2. **Staging the source costs import-from-derivation** [measured]. Our flake builds `src` with
   `runCommand`: copy the package, copy `../core` inside, rewrite the path. `nix build` allows that;
   `nix flake show` refuses it ("allow-import-from-derivation is disabled").
3. **A staged path dependency becomes a workspace member** [measured]. Cargo makes any path
   dependency inside the workspace directory a member, so the staged crate's dev-dependencies
   entered resolution. The package's `Cargo.lock` doesn't hold them, and the offline build failed:
   "no matching package named `bit-set` found … required by `proptest` … of package `msig_core`".
   Excluding the staged directory in the workspace fixed it.

## Ask

A way to name extra source paths a Rust module's crate needs, copied beside `rust-lib/` at the
same relative position, so a crate's `../shared` path dependencies resolve without a staged
source. The Nim path already stages the whole module source for the same reason
(`mkLogosModule.nix`, "Stage the WHOLE module source … so the crate's sibling imports resolve").

## Reproduce

`nix build "git+file://<muster>?dir=programs/lez-msig/lez04#lgx-portable"`; the staging is in
`programs/lez-msig/lez04/flake.nix` (`moduleSrc`).
