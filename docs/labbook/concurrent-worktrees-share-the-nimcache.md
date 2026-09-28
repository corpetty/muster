# Two worktrees running the suite at once share one nimcache (2026-09-28)

While building the split (exo-a90), a full `module/tests/run-suite.sh` went red on four
tests the change had not touched: `provenance_all_test`, `provenance_view_test`,
`phase_c_exit_test` and `schema_coverage_test`. None of them was broken. A second session,
in its own git worktree, was running the same suite at the same time.

## The shape

The runner calls `nim r` with the default nimcache, `~/.cache/nim/<testname>_r`. That
directory is keyed by the test's **name**, not by the checkout it came from. Two worktrees
building `provenance_all_test` at the same moment compile into one directory, from two
different source trees, and each can link objects the other wrote or is still writing.
The failure is at link time:

```
ld.bfd: cannot find /home/…/.cache/nim/provenance_view_test_r/@pvendor@ssecp256k1@ssrc@sprecomputed_ecmult.c.o
ld.bfd: …/provenance_all_test_r/@pnimcrypto@ssha2@ssha2_avx2.nim.c.o: in function `sha256Compress…'
```

It reads like a regression in whatever was just edited, and a plain re-run can fail again
while the other session is still building, or once the directory holds objects from the
other tree.

## What to do

- A red that is a **linker** error, not an assertion or a compile error, is suspect. Re-run
  that one test with a private cache (`--nimcache:<a scratch dir>`, plus the `FLAGS` block
  from `run-suite.sh`) before believing it. In this case all four passed.
- Don't delete the shared `~/.cache/nim/<test>_r` while another session may be building it.
- The lasting fix is for the runner to pass a per-checkout `--nimcache` (for example under
  the worktree, or keyed by a hash of `$MODULE`), so that concurrent worktrees never meet.
