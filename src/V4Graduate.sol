// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal, IPenguinHook, IPenguinListing, IPoolManager, IPositionManager, IWETH, PoolKey, Currency} from "./interfaces/IUniswapV4.sol";
import {LibMath} from "./libraries/LibMath.sol";
import {LibV4} from "./libraries/LibV4.sol";

/// @title V4Graduate
/// @notice Shared helper: register the listing on `PenguinHook`, initialize the
///         ETH/token pool (`fee = 0`, `tickSpacing = 60`, `hooks = penguinHook`),
///         and lock the initial full-range position to `0xdead`.
///         The hook — not this contract — takes the post-list 1%. This contract
///         never holds or transfers the PositionManager NFT after mint.
contract V4Graduate {
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IPenguinHook public immutable penguinHook;
    address public immutable weth;
    bool public immutable useNativeEth;

    uint256 private locked = 1;

    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address poolManager_, address positionManager_, address weth_, bool useNativeEth_, address hook_) {
        require(
            poolManager_ != address(0) && positionManager_ != address(0) && weth_ != address(0) && hook_ != address(0),
            "ADDR"
        );
        poolManager = IPoolManager(poolManager_);
        positionManager = IPositionManager(positionManager_);
        penguinHook = IPenguinHook(hook_);
        weth = weth_;
        useNativeEth = useNativeEth_;
    }

    /// @notice Pull `tokenAmount` + `msg.value` ETH from the caller, register the
    ///         listing on the hook, seed the ETH/token pool, and lock the initial position.
    function seed(address token, uint256 tokenAmount)
        external
        payable
        nonReentrant
        returns (bytes32 poolId, uint256 positionTokenId, uint128 liquidity)
    {
        require(token != address(0) && tokenAmount > 0 && msg.value > 0, "EMPTY");
        require(IERC20Minimal(token).transferFrom(msg.sender, address(this), tokenAmount), "TOKEN");

        address creator_ = IPenguinListing(msg.sender).creator();
        penguinHook.register(token, creator_, msg.sender);

        PoolKey memory key = poolKeyOf(token);
        poolId = LibV4.toId(key);

        bool tokenIsC1 = Currency.unwrap(key.currency1) == token;
        uint256 amount0 = tokenIsC1 ? msg.value : tokenAmount;
        uint256 amount1 = tokenIsC1 ? tokenAmount : msg.value;
        uint160 sqrtPriceX96 = LibV4.encodeSqrtRatioX96(amount1, amount0);
        _initializeOrCheck(key, poolId, sqrtPriceX96);

        liquidity = LibV4.liquidityForAmounts(sqrtPriceX96, amount0, amount1);
        require(amount0 <= type(uint128).max && amount1 <= type(uint128).max, "AMT");

        uint256 ethForPm = _deliverToPositionManager(token, tokenAmount);

        positionTokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities{value: ethForPm}(
            _mintPayload(key, liquidity, amount0, amount1), block.timestamp
        );
        require(positionManager.ownerOf(positionTokenId) == LibMath.DEAD, "NOT_BURNED");

        _returnLeftovers(token, msg.sender);
    }

    function poolKeyOf(address token) public view returns (PoolKey memory) {
        address hooks = address(penguinHook);
        if (useNativeEth) return LibV4.nativePoolKey(token, hooks);
        return LibV4.erc20PoolKey(weth, token, hooks);
    }

    function _initializeOrCheck(PoolKey memory key, bytes32 poolId, uint160 sqrtPriceX96) internal {
        try poolManager.initialize(key, sqrtPriceX96) {}
        catch {
            uint160 current = uint160(uint256(poolManager.extsload(LibV4.poolStateSlot(poolId))));
            require(current != 0, "NO_POOL");
            require(LibV4.sqrtPriceWithinBps(current, sqrtPriceX96, 200), "POOL_PRICE");
        }
    }

    function _deliverToPositionManager(address token, uint256 tokenAmount) internal returns (uint256 ethForPm) {
        address pm = address(positionManager);
        require(IERC20Minimal(token).transfer(pm, tokenAmount), "TOKEN_PM");
        if (useNativeEth) {
            return msg.value;
        }
        IWETH(weth).deposit{value: msg.value}();
        require(IWETH(weth).transfer(pm, msg.value), "WETH_PM");
        return 0;
    }

    function _mintPayload(PoolKey memory key, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (bytes memory)
    {
        (int24 tickLower, int24 tickUpper) = LibV4.tickBounds();
        bytes memory actions = abi.encodePacked(
            uint8(LibV4.MINT_POSITION), uint8(LibV4.SETTLE), uint8(LibV4.SETTLE), uint8(LibV4.SWEEP), uint8(LibV4.SWEEP)
        );
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), uint128(amount0), uint128(amount1), LibMath.DEAD, bytes("")
        );
        params[1] = abi.encode(key.currency0, LibV4.OPEN_DELTA, false);
        params[2] = abi.encode(key.currency1, LibV4.OPEN_DELTA, false);
        params[3] = abi.encode(key.currency0, LibV4.MSG_SENDER);
        params[4] = abi.encode(key.currency1, LibV4.MSG_SENDER);
        return abi.encode(actions, params);
    }

    function _returnLeftovers(address token, address to) internal {
        uint256 tok = IERC20Minimal(token).balanceOf(address(this));
        if (tok > 0) require(IERC20Minimal(token).transfer(to, tok), "TOKEN_BACK");
        if (!useNativeEth) {
            uint256 wrapped = IERC20Minimal(weth).balanceOf(address(this));
            if (wrapped > 0) require(IERC20Minimal(weth).transfer(to, wrapped), "WETH_BACK");
        }
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            (bool ok,) = to.call{value: ethBal}("");
            require(ok, "ETH_BACK");
        }
    }

    receive() external payable {}
}
