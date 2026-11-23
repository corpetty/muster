//! The guest is the DEPLOYED program: its image id is the program id on chain, and every private
//! PDA derives from it. So the committed `artifacts/msig.bin` is the source of truth, as LEZ
//! commits its own `artifacts/`. Its image id is computed here, and nix never needs the risc0 guest
//! toolchain. Set MSIG_BUILD_GUEST=1 to rebuild the guest with risc0-build (rzup's toolchain); then
//! deploy that build and commit its .bin (`methods/guest`, programs/lez-msig/lez04/CLAUDE.md).
use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=MSIG_BUILD_GUEST");
    if env::var_os("MSIG_BUILD_GUEST").is_some() {
        risc0_build::embed_methods();
        return;
    }
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let bin = dir.join("../artifacts/msig.bin").canonicalize().expect("artifacts/msig.bin: the deployed guest");
    println!("cargo:rerun-if-changed={}", bin.display());
    let elf = fs::read(&bin).expect("artifacts/msig.bin: the deployed guest (or set MSIG_BUILD_GUEST=1)");
    let id: [u32; 8] = risc0_binfmt::compute_image_id(&elf).expect("a valid R0BF guest").into();
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("methods.rs");
    fs::write(out, format!(
        "pub const MSIG_ELF: &[u8] = include_bytes!(r#\"{p}\"#);\npub const MSIG_PATH: &str = r#\"{p}\"#;\npub const MSIG_ID: [u32; 8] = {id:?};\n",
        p = bin.display()
    )).unwrap();
}
