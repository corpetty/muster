## Client-side EVM transaction signing, over nim-eth (Status/Nimbus) — the piece
## that lets `submit` broadcast to any node, not just an anvil-unlocked one.
##
## We build the transaction and RLP-encode it with nim-eth, but the private key
## never leaves the keystore: we sign the computed signing hash through a closure
## (the keystore's sign op / a Keycard), then set V/R/S from that signature. So the
## reuse (RLP, the transaction type) composes with FS-4's key-behind-a-seam rule.
## EIP-155 legacy for now; typed (EIP-1559) transactions slot in the same way.

import std/typetraits
import stint
import eth/common/[transactions, transactions_rlp, base, addresses, hashes]
import eth/rlp
import ../crypto/secp256k1

proc h32ToArr(h: Hash32): array[32, byte] =
  for i in 0 ..< 32: result[i] = distinctBase(distinctBase(h))[i]

proc signLegacyTransfer*(signHash: proc(h: array[32, byte]): Signature65 {.closure.},
                         chain, nonce, gasPrice, gasLimit: uint64,
                         to: array[20, byte], value: UInt256, data: seq[byte]): seq[byte] =
  ## Build, sign (via the keystore seam), and RLP-encode an EIP-155 legacy transfer,
  ## returning the raw bytes for eth_sendRawTransaction.
  var t = Transaction(
    txType: TxLegacy, chainId: chainId(chain), nonce: nonce,
    gasPrice: gasPrice, gasLimit: gasLimit,
    to: Opt.some(Address.copyFrom(to)),
    value: value, payload: data)
  let sig = signHash(h32ToArr(rlpHashForSigning(t, true)))
  var r, s: array[32, byte]
  for i in 0 ..< 32: r[i] = sig[i]
  for i in 0 ..< 32: s[i] = sig[32 + i]
  t.R = UInt256.fromBytesBE(r)
  t.S = UInt256.fromBytesBE(s)
  t.V = uint64(int(sig[64]) - 27) + 2'u64 * chain + 35'u64   # EIP-155: recid + 2*chainId + 35
  rlp.encode(t)
