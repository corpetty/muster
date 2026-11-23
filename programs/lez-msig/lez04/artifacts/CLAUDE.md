# lez04/artifacts/

`msig.bin`: the DEPLOYED v0.4 guest (R0BF), the program on the LEZ 0.4.0-rc3 devnet at
`2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`, deployed immutable (D18). Its image id is the
program's identity and every private PDA derives from it, so `methods/build.rs` embeds this file
rather than rebuilding the guest (nix never needs the risc0 guest toolchain). Replace it only with a
build you deploy.
