//! Builds the v0.4 guest with risc0-build (rzup's risc0 toolchain). Until a v0.4 build is
//! deployed there is no committed artifact; once one is, this follows ../../methods/build.rs and
//! embeds the deployed .bin instead (its image id is the program's identity).
fn main() {
    risc0_build::embed_methods();
}
