// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PenguinERC20} from "./token/PenguinERC20.sol";
import {LibMath} from "./libraries/LibMath.sol";

/// @notice Presale ERC-20. Each createPresale deploys a full copy; name, ticker, and
///         supply live in storage so runtime bytecode stays identical across tokens.
contract PenguinToken is PenguinERC20 {
    address public minter;
    bool private initialized;

    function initialize(string calldata name_, string calldata ticker_, address minter_, uint256 totalSupply_)
        external
    {
        require(!initialized, "INIT");
        require(minter_ != address(0), "MINTER");
        LibMath.validateNameTicker(name_, ticker_);
        LibMath.validatePresaleSupply(totalSupply_);
        initialized = true;
        minter = minter_;
        _setMetadata(name_, ticker_);
        _mint(minter_, totalSupply_);
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}
