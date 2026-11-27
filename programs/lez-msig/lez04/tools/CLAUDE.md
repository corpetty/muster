# lez04/tools/

`regen.sh`: regenerates `../generated/provider_gen.rs` from `../lez_msig_v04_module.lidl` with the
logos-lidl-gen logos-module-builder 0.3.3 runs (logos-rust-sdk 040e94e8).

`idl.sh`: regenerates `../idl/lez_msig.json` with `spel generate-idl` (logos-co/spel, pinned rev on
`refactor/lez-v0.4.x`, installed once into `~/.cache/muster/spel-<rev>`; `SPEL=` overrides) from the
types `../spel.toml` names. `--check` diffs the committed IDL against a fresh one and decodes Muster's
State vector with it; CI's `lez-msig-idl` job runs it (exo-7610).
