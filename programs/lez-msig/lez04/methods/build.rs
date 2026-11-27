//! The guest is the DEPLOYED program: its image id is the program id on chain, and every private
//! PDA derives from it. So the committed `artifacts/msig.bin` is the source of truth, as LEZ
//! commits its own `artifacts/`. Its image id is computed here, and nix never needs the risc0 guest
//! toolchain. Set MSIG_BUILD_GUEST=1 to rebuild the guest with risc0-build (rzup's toolchain); then
//! deploy that build and commit its .bin (`methods/guest`, programs/lez-msig/lez04/CLAUDE.md).
//!
//! `artifacts/msig-next.bin` is the NEXT guest, built from the current core and adapter and not
//! deployed (D19's rotation, exo-3dc): embedded as `MSIG_NEXT_ELF` / `MSIG_NEXT_ID`, for the tests of
//! what the deployed program lacks. With MSIG_BUILD_GUEST=1 both names are the fresh build.
use std::{env, fs, path::PathBuf};

fn embed(name: &str, file: &str) -> String {
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let bin = dir.join("../artifacts").join(file).canonicalize().unwrap_or_else(|_| panic!("artifacts/{file}"));
    println!("cargo:rerun-if-changed={}", bin.display());
    let elf = fs::read(&bin).unwrap_or_else(|_| panic!("artifacts/{file} (or set MSIG_BUILD_GUEST=1)"));
    let id: [u32; 8] = risc0_binfmt::compute_image_id(&elf).expect("a valid R0BF guest").into();
    format!(
        "pub const {name}_ELF: &[u8] = include_bytes!(r#\"{p}\"#);\npub const {name}_PATH: &str = r#\"{p}\"#;\npub const {name}_ID: [u32; 8] = {id:?};\n",
        p = bin.display()
    )
}

fn main() {
    println!("cargo:rerun-if-env-changed=MSIG_BUILD_GUEST");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    if env::var_os("MSIG_BUILD_GUEST").is_some() {
        risc0_build::embed_methods();
        fs::write(out.join("next.rs"), "pub const MSIG_NEXT_ELF: &[u8] = MSIG_ELF;\npub const MSIG_NEXT_PATH: &str = MSIG_PATH;\npub const MSIG_NEXT_ID: [u32; 8] = MSIG_ID;\n").unwrap();
        return;
    }
    fs::write(out.join("methods.rs"), embed("MSIG", "msig.bin")).unwrap();
    fs::write(out.join("next.rs"), embed("MSIG_NEXT", "msig-next.bin")).unwrap();
}
