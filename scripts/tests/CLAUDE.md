# scripts/tests — tests of the self-tests themselves

A self-test (`scripts/*-self-test.sh`) gives its verdict by reading runners' logs. What it
reads there can be held without a runner: a test here feeds the script lines cut from a real
run and checks what it concludes.

- `voice-self-test-replay.py` holds `scripts/voice-self-test.sh`'s verdict (voice notes, S9)
  through its `VOICE_REPLAY=<dir>` mode, and `scripts/lib/ui_log.py`, the reader of ui-host's
  relay, on relayed lines cut each way it undoes. Run `python3 scripts/tests/voice-self-test-replay.py`;
  give it another copy of the script as its argument to see that copy's verdicts. It launches
  nothing and opens no device.
- `fixtures/voice-relay/` is cut verbatim from a Linux CI run's logs (fork run 39836679442,
  at `bbae7d8`; the test's docstring says which lines). Never edit those lines by hand: a case
  that needs another line builds it in the test, quoted as ui-host quotes (the test checks its
  quoting against every whole relayed line in the fixtures).
