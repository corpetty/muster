# programs/lez-msig/methods/

`msig_methods` embeds `MSIG_ELF` (the R0BF `.bin` that `infra/lez/localnet.sh deploy` takes) and
`MSIG_ID` (its image id). By default `build.rs` reads the deployed guest, `../artifacts/msig.bin`,
and computes its image id; `MSIG_BUILD_GUEST=1` builds `guest/` with risc0-build instead. The guest
is its own cargo project (`[workspace]` in its manifest), built with rzup's risc0 toolchain.
