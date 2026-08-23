## Verified state reads: the wallet verifies a provider's account against a trusted
## state root via a Merkle proof (the Nimbus verified-proxy primitive, reused
## in-process from nim-eth). Self-contained — builds a state trie, generates the
## proof, and verifies it; no node needed. The trustless state-root source (beacon
## light client) is a deferred sidecar; this proves the verification itself.
## Needs the nim-eth closure on the path (see tests/README.md).

import std/typetraits
import stint
import eth/trie/[hexary, db]
import eth/common/[accounts, hashes]
import eth/rlp
import ../src/wallet/verify
import ../src/wallet/types
import ../src/hashing/keccak256

proc rootBytes(h: Hash32): array[32, byte] =
  for i in 0 ..< 32: result[i] = distinctBase(distinctBase(h))[i]

# A mini state trie holding one account (keccak(address) -> rlp(account)).
var memdb = newMemoryDB()
var trie = initHexaryTrie(memdb)
let address = [byte 0x70, 0x99, 0x79, 0x70, 0xC5, 0x18, 0x12, 0xdc, 0x3A, 0x01,
               0x0C, 0x7d, 0x01, 0xb5, 0x0e, 0x0d, 0x17, 0xdc, 0x79, 0xC8]
let acct = accounts.Account(nonce: 7'u64, balance: u256"1000000000000000000",
                   storageRoot: emptyRoot, codeHash: emptyKeccak256)
let key = @(keccak256.keccak256(address))
trie.put(key, rlp.encode(acct))
let root = rootBytes(trie.rootHash())
let proof = trie.getBranch(key)

# 1. A valid account verifies, and its balance is authentic under the root.
let v = verifyAccount(proof, root, address, acct)
doAssert v.exists, "the account is present"
doAssert v.balanceRaw == "1000000000000000000", "1 ETH, verified against the state root"
echo "1. valid account verifies against the state root OK"

# 2. A tampered claim (a lying provider) fails the proof and raises — it can never
#    pass as a real balance.
var forged = acct
forged.balance = u256"999999999999999999999"
var forgedRejected = false
try: discard verifyAccount(proof, root, address, forged)
except WalletError: forgedRejected = true
doAssert forgedRejected, "a claim inconsistent with the state root is refused, not trusted"
echo "2. tampered balance refused (verified, not trusted) OK"

# 3. An absent account is proven absent — a verified zero, not a guess.
let absentAddr = [byte 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                  0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11]
let absentProof = trie.getBranch(@(keccak256.keccak256(absentAddr)))
let a = verifyAccount(absentProof, root, absentAddr, accounts.Account())
doAssert not a.exists and a.balanceRaw == "0", "proven-absent account is a verified zero"
echo "3. proven-absent account is a verified zero OK"

echo "wallet_verify_test: all OK"
