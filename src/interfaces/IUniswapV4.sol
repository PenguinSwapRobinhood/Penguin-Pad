// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal official Uniswap v4 types. Penguin pools use `fee = 0` and `hooks = PenguinHook`.
type Currency is address;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Official v4 `SwapParams` (`types/PoolOperation.sol`).
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function extsload(bytes32 slot) external view returns (bytes32);
    function take(Currency currency, address to, uint256 amount) external;
}

interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Official `IHooks` callbacks we implement. Other hook fns are unflagged and omitted.
interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, int256, uint24);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        int256 delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
}

interface IV4Graduate {
    function seed(address token, uint256 tokenAmount)
        external
        payable
        returns (bytes32 poolId, uint256 positionTokenId, uint128 liquidity);

    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function weth() external view returns (address);
    function useNativeEth() external view returns (bool);
    function penguinHook() external view returns (address);
    function poolKeyOf(address token) external view returns (PoolKey memory);
}

interface IPenguinFactory {
    function penguinProtocol() external view returns (address);
    function owner() external view returns (address);
    function production() external view returns (bool);
}

interface IPenguinListing {
    function creator() external view returns (address);
    function penguinProtocol() external view returns (address);
}

interface IPenguinHook {
    function register(address token, address creator_, address listing_) external;
    function claimCreatorFees(address token) external returns (uint256 amount);
    function creatorFeesAccrued(address token) external view returns (uint256);
}

interface IERC20Minimal {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}
