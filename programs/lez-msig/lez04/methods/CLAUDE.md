# lez04/methods/

Embeds the deployed v0.4 guest (`../artifacts/msig.bin`) and its image id; `MSIG_BUILD_GUEST=1` builds it with risc0-build instead. Also embeds the next, undeployed guest (`../artifacts/msig-next.bin`) as `MSIG_NEXT_ELF` / `MSIG_NEXT_ID`; under `MSIG_BUILD_GUEST=1` both names are the fresh build. `guest/` is the actor handler over msig_core (`guest/src/bin/msig.rs`); it is excluded from the workspace and has its own lockfile.
