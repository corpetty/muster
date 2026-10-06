# Raising from `except` in a `try` that also has `finally` loses the exception (Nim 2.2.2)

**exo-14f, 2026-10-06. Status: worked around in `wallet/rpc_budget.nim` (`jsonRpc`).**

## Symptom

`rpc_budget_test` and `rpc_url_redaction_test` died with `SIGSEGV: Illegal storage access`
on any refused connection. The Nim traceback named `jsonRpc` (or, after moving code around,
`probeRpc` or `withEndpoint`) and `system.nim(936)`, never the real line.

## What gdb showed

Built with `--debugger:native` and run under gdb: the fault is in the CALLER's exception
handler, right after `nimBorrowCurrentException()` returned **nil**. The runtime had an error
pending (the goto-exceptions flag) but no current exception object, and the generated
`except SomeError` type check dereferenced it.

## The shape

```nim
try:
  connectAndCall()                       # raises (connection refused)
except SomeError:
  raise newException(OtherError, "...")  # raise from an except branch …
finally:
  cleanup()                              # … of a try that also has a finally
```

The exception raised in the `except` branch does not survive the `finally` under Nim 2.2.2
(`--threads:on`, `--exceptions:goto`, the default). A ten-line program calling `jsonRpc` on
a closed port reproduces it; the same body without `finally`, with the cleanup called on each
path, raises normally.

## Rule

No `raise` inside an `except` of a `try` that has a `finally`. Clean up on each path instead
(or move the raise outside the try). A quick check over `module/` found no other instance
(2026-10-06). Report upstream to nim-lang with the repro if it is not already known.
