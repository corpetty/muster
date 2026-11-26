# lez04/methods/

Embeds the deployed v0.4 guest (`../artifacts/msig.bin`) and its image id; `MSIG_BUILD_GUEST=1` builds it with risc0-build instead. `guest/` is the actor handler over msig_core (`guest/src/bin/msig.rs`); it is excluded from the workspace and has its own lockfile.
