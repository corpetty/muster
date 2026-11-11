## Reading a LEZ v0.3.0 transaction back (exo-267.3): getTransaction answers with the
## transaction's borsh, base64, and its block. decodeLeeTxPublic is held to an answer a real
## v0.3.0 sequencer gave (tests/vectors/lez-get-tx-v030): the funder's native transfer of 777
## to 0x22…22. The decode re-encodes to the same bytes, hashes to the hash asked for, names
## the signer's account, and refuses anything partial or padded.

import std/[json, base64, strutils, options, os]
import stint
import ../src/lez/multisig
import ../src/lez/tx as leztx
import ../src/bitcoin/tx as btx   # toHex

let v = parseJson(readFile(currentSourcePath().parentDir() & "/vectors/lez-get-tx-v030/vector.json"))
var raw: seq[byte]
for ch in base64.decode(v["result"][0].getStr()): raw.add byte(ch)

block:
  let (m, ws) = decodeLeeTxPublic(raw)
  doAssert leeTxPublic(m, ws) == raw, "the decode re-encodes to the chain's bytes"
  doAssert publicTxHash(m, ws) == v["hash"].getStr(), "and hashes to the hash the wallet reported"
  doAssert m.programAccount == NativeTokenProgram and m.shards.len == 2
  doAssert btx.toHex(m.shards[0].account) == v["from"].getStr() and btx.toHex(m.shards[1].account) == v["to"].getStr()
  doAssert m.instruction == nativeTransfer(777.stuint(128))
  doAssert m.nonces == @[v["nonce"].getInt().stuint(128)]
  doAssert m.fee.isSome and m.fee.get.payer == m.shards[0].account and m.fee.get.gasLimit == DefaultGasLimit
  doAssert ws.len == 1 and publicAccountId(ws[0].xonly) == m.shards[0].account, "the signer is the sender"
  echo "1. a real v0.3.0 getTransaction answer decodes, re-encodes byte for byte, and hashes to its hash OK"

block:
  for bad in [raw[0 ..< raw.len - 1], raw & @[0'u8], @[1'u8] & raw[1 .. ^1]]:
    var refused = false
    try: discard decodeLeeTxPublic(bad)
    except LeeTxDecodeError: refused = true
    doAssert refused, "partial, padded or not public: refused"
  echo "2. a partial, padded or non-public transaction is refused OK"

echo "lez_get_tx_test: all OK"
