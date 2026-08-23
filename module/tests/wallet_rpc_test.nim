## Smoke test for the nim-web3 RPC seam: no node, but it exercises the whole stack
## end to end — chronos event loop, the RpcHttpClient, and failure translation. An
## unreachable endpoint must raise WalletError (never hang, never return a value a
## caller could trust). Needs the full web3 closure on the path (see tests/README.md).

import ../src/wallet/evm_rpc
import ../src/wallet/types

# Nothing listens on 127.0.0.1:1 → connect is refused → WalletError, not a hang or
# a bogus balance.
var raised = false
try:
  discard rpcBalance("http://127.0.0.1:1", "0x0000000000000000000000000000000000000000", "latest")
except WalletError:
  raised = true
doAssert raised, "an unreachable RPC endpoint raises WalletError"
echo "1. unreachable RPC raises via the chronos+web3 stack OK"

echo "wallet_rpc_test: all OK"
