# Retired specs

Specs here are **no longer graded** (`scripts/grade-specs.sh` and exophial's `spec_dir`
read `contracts/specs/*.spec.json` only, not this directory) and their probes are gone.
They stay as the record of what was once required and why it stopped being required.
Reinstating one is a deliberate decision behind a new ADR, not a `git mv` back.

| spec | was | retired | why |
|---|---|---|---|
| `derived-exo-f60` | invariant 9 as "anonymous drivers stay anonymous end to end" (catastrophic; five `probe_anon_*` probes over `intents/anon_state.nim`) | 2026-09-23, ADR-015 (epic `exo-dec`) | Muster's privacy goal is being private toward everyone **outside** the room — the room is the boundary — not signer anonymity inside it. No shipped driver was anonymous; the model was exercised only by its own probes, and the live contribute path would have de-anonymized a room-native anonymous driver anyway. Carrying it cost a named/anonymous dual path through every identity-bearing feature. `MembershipModel` was deleted, so an anonymous driver is unrepresentable. Invariant 9's number now carries the property the code already cited it for: what the client says about a member is only what that member disclosed. |
