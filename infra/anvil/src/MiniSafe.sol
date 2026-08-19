// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// A faithful subset of Safe 1.4.1 for the P2 anvil fixture: the same EIP-712
/// safeTxHash (identical DOMAIN/SAFE_TX type hashes), on-chain ecrecover
/// checkSignatures (ascending-owner dedup, threshold), and execTransaction. It
/// stands in for the full Safe 1.4.1 singleton deployment; muster computes the
/// identical safeTxHash off-chain, collects owner signatures, and submits here.
contract MiniSafe {
    address[] public owners;
    uint256 public threshold;
    uint256 public nonce;

    bytes32 constant DOMAIN_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    bytes32 constant SAFE_TX_TYPEHASH =
        0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    constructor(address[] memory _owners, uint256 _threshold) {
        owners = _owners;
        threshold = _threshold;
    }

    receive() external payable {}

    function isOwner(address a) public view returns (bool) {
        for (uint256 i = 0; i < owners.length; i++) if (owners[i] == a) return true;
        return false;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    function getTxHash(address to, uint256 value, bytes memory data, uint256 _nonce)
        public view returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(
            SAFE_TX_TYPEHASH, to, value, keccak256(data), uint8(0),
            uint256(0), uint256(0), uint256(0), address(0), address(0), _nonce));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(), structHash));
    }

    function execTransaction(address to, uint256 value, bytes memory data, bytes memory signatures)
        public
    {
        bytes32 txHash = getTxHash(to, value, data, nonce);
        address last = address(0);
        uint256 count = 0;
        for (uint256 i = 0; i + 65 <= signatures.length; i += 65) {
            bytes32 r; bytes32 s; uint8 v;
            assembly {
                r := mload(add(add(signatures, 0x20), i))
                s := mload(add(add(signatures, 0x40), i))
                v := byte(0, mload(add(add(signatures, 0x60), i)))
            }
            address signer = ecrecover(txHash, v, r, s);
            require(isOwner(signer), "not owner");
            require(signer > last, "unsorted or duplicate");
            last = signer;
            count++;
        }
        require(count >= threshold, "threshold not met");
        nonce++;
        (bool ok, ) = to.call{value: value}(data);
        require(ok, "exec failed");
    }
}
