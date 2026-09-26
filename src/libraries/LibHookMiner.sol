// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice CREATE2 salt search so `PenguinHook` lands on an address whose low 14 bits
///         match Uniswap v4-core `Hooks` flags (`src/libraries/Hooks.sol`).
library LibHookMiner {
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);
    /// @dev v4-core `Hooks.sol`: BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP |
    ///      BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
    uint160 internal constant REQUIRED_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint256 internal constant MAX_ITER = 200_000;

    function computeCreate2(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_ITER; ++i) {
            salt = bytes32(i);
            hook = computeCreate2(deployer, salt, initCodeHash);
            if (uint160(hook) & FLAG_MASK == flags) return (hook, salt);
        }
        revert("SALT");
    }
}
