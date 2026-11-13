# ui-nim/tests/autovoice — the voice autopilot, with no Qt and no runner

`run.sh` checks the decisions of `ui-nim/app/backend.nim`'s voice autopilot (`MUSTER_AUTOVOICE`, `MUSTER_AUTOVOICEPLAY`, docs/design/voice-notes.md S9): which voice calls it makes, in what order, and what it logs. ui-nim's flake builds on Linux only, so this is the one check of that code that also runs on a Mac. It does not replace `scripts/voice-self-test.sh`, which sends a real note between two runners.

- **The backend is the real file**, included whole. Never copy it here, never edit it to make this pass.
- **The stubs are generated, never hand-written.** `gen.py` reads `ui/src/muster_ui.rep` and `module/src/api/muster.lidl`, as the real build's contract macro and client generator do, so a new PROP, SLOT or method needs nothing here.
- **The fake stands in for `muster_module` only**: the process the backend reaches over the logos API, the one boundary a unit check may fake. Its answers keep the module's shapes (`module/src/coordination/voice_live.nim`); when those change, change `fake_module.nim` with them.
- Everything it builds goes in a scratch directory, never the tree. `KEEP=1` keeps it.
