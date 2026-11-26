# lez04/artifacts/

`msig.bin`: the DEPLOYED v0.4 guest (R0BF), the program on the LEZ 0.4.0-rc3 devnet at
`2tTh5nUpBxtTAoQBCQbzmG32JGapm2KaEpH9oxktGanG`, deployed immutable (D18). Its image id is the
program's identity and every private PDA derives from it, so `methods/build.rs` embeds this file
rather than rebuilding the guest (nix never needs the risc0 guest toolchain). Replace it only with a
build you deploy.

`msig-next.bin`: the NEXT guest, built from the current core and adapter (D19's rotation, exo-3dc) with
`MSIG_BUILD_GUEST=1` (rzup 1.91.1, image id `c2ca1f993d4c3d2a28934c17d7189500b59a05186932d7d803729bf07ace80c9`), and NOT deployed anywhere. A different image, so a different program id and
different private PDAs. `methods/build.rs` embeds it as `MSIG_NEXT_ELF`, and the tests of what the
deployed program lacks (`host/tests/v04_rotation.rs`) run it. Once it is deployed, it replaces
`msig.bin` and this file goes.
