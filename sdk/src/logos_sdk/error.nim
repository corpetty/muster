## SDK error type — the Nim counterpart of logos-rust-sdk `src/error.rs`.
##
## Raised by the *raising* generated client methods (`<method>OrRaise`) when a
## call fails at the transport/method layer or the result doesn't decode to the
## contract's declared type. The non-raising `<method>` twin returns a typed
## zero-value instead; both are generated, so a caller picks the semantics per
## call site.

import std/json

type
  LogosCallError* = object of CatchableError
    ## A failed inter-module call. `meth` is the contract method; `errorNode` is
    ## the canonical error object the ABI returned (or a reason for a decode
    ## mismatch), for callers that want to branch on it rather than the message.
    meth*: string
    errorNode*: JsonNode

proc newLogosCallError*(meth: string, errorNode: JsonNode): ref LogosCallError =
  result = newException(LogosCallError,
    meth & ": " & (if errorNode != nil: $errorNode else: "<no error detail>"))
  result.meth = meth
  result.errorNode = errorNode
