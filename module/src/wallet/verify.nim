## Verified state reads (F-10, invariant 8) — the reusable core of the Nimbus
## verified proxy, in-process.
##
## An RPC endpoint is untrusted (invariant 8). To make a balance a `verified-locally`
## fact rather than a trusted one (F-10), we ask the provider for `eth_getProof` and
## verify the account's Merkle-Patricia proof against a trusted state root with
## nim-eth's `verifyMptProof` — the exact primitive the Nimbus verified proxy uses.
## A valid proof means the returned balance is authentic under that state root; a
## dishonest provider's answer fails the proof and RAISES — it can never pass as a
## real balance, and a proven-absent account is a verified zero, not a guessed one.
##
## The state root is the trust anchor. Making it TRUSTLESS needs a beacon light
## client (the Nimbus verified proxy in REST mode, run as a sidecar) that follows
## the sync committee from a weak-subjectivity checkpoint to a consensus-verified
## execution state root. That consensus link needs a running beacon endpoint and is
## deferred — this module is the half that is ours and needs no infra: given a state
## root, it verifies the provider against it.

import std/strutils
import stint
import eth/trie/[hexary_proof_verification]
import eth/common/[accounts, accounts_rlp, hashes]
import eth/rlp
import ./types
import ../hashing/keccak256

type
  VerifiedAccount* = object
    balanceRaw*: string   ## decimal base units, verified against the state root
    nonce*: uint64
    exists*: bool         ## false = proven ABSENT (a verified zero, not a guess)

proc toRoot(b: array[32, byte]): Hash32 = Hash32(Bytes32.copyFrom(b))

proc accountKey*(address: array[20, byte]): seq[byte] =
  ## The state-trie key for an account: keccak256(address).
  @(keccak256.keccak256(address))

proc verifyAccount*(proof: seq[seq[byte]], stateRoot: array[32, byte],
                    address: array[20, byte], claimed: accounts.Account): VerifiedAccount =
  ## Verify a claimed account (as returned by eth_getProof) against a trusted state
  ## root via its Merkle proof. ValidProof → the claimed fields are authentic;
  ## MissingKey → proven absent (verified zero); InvalidProof → the provider is not
  ## consistent with the state root (raise — never trust it).
  let value = rlp.encode(claimed)
  let res = verifyMptProof(proof, toRoot(stateRoot), accountKey(address), value)
  if res.isValid():
    VerifiedAccount(balanceRaw: $claimed.balance, nonce: claimed.nonce, exists: true)
  elif res.isMissing():
    VerifiedAccount(balanceRaw: "0", nonce: 0, exists: false)
  else:
    raise newException(WalletError,
      "account proof does not verify against the state root — the RPC provider is " &
      "not consistent with consensus (" & res.errorMsg & ")")

proc hexBytes*(s: string): seq[byte] =
  var h = s
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  if h.len mod 2 == 1: h = "0" & h
  for i in 0 ..< h.len div 2: result.add byte(parseHexInt(h[2*i .. 2*i+1]))

proc hash32Of(s: string): Hash32 = Hash32(Bytes32.copyFrom(hexBytes(s)))

proc verifyAccountFields*(proof: seq[seq[byte]], stateRoot: array[32, byte],
                          address: array[20, byte], nonce: uint64,
                          balanceHex, storageHashHex, codeHashHex: string): VerifiedAccount =
  ## Field-based entry point (from an eth_getProof JSON result) — keeps the eth
  ## Account type inside this module so callers (the EVM adapter) never collide it
  ## with the wallet's own Account.
  verifyAccount(proof, stateRoot, address, accounts.Account(
    nonce: nonce, balance: UInt256.fromHex(balanceHex),
    storageRoot: hash32Of(storageHashHex), codeHash: hash32Of(codeHashHex)))
