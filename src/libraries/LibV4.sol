// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency, PoolKey} from "../interfaces/IUniswapV4.sol";

/// @notice Uniswap v4 pool-key + sqrt-price helpers.
/// @dev Post-list pools are `fee = 0`, `tickSpacing = 60`, `hooks = PenguinHook`.
///      Spacing stays 60 (same full-range bounds as the old 0.30% tier). Traders pay 1%
///      via the hook, not a PoolManager LP fee.
library LibV4 {
    uint24 internal constant POOL_FEE = 0;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant Q96 = 1 << 96;

    /// @dev Uniswap v4-core `StateLibrary.POOLS_SLOT`.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant SETTLE = 0x0b;
    uint256 internal constant SWEEP = 0x14;
    uint256 internal constant OPEN_DELTA = 0;
    address internal constant MSG_SENDER = address(1);

    function toId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function poolStateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    function nativePoolKey(address token, address hooks) internal pure returns (PoolKey memory key) {
        require(token != address(0) && hooks != address(0), "TOKEN");
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function erc20PoolKey(address tokenA, address tokenB, address hooks) internal pure returns (PoolKey memory key) {
        require(tokenA != tokenB && tokenA != address(0) && tokenB != address(0) && hooks != address(0), "PAIR");
        if (uint160(tokenA) > uint160(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hooks
        });
    }

    function tickBounds() internal pure returns (int24 lower, int24 upper) {
        lower = (MIN_TICK / TICK_SPACING) * TICK_SPACING;
        upper = (MAX_TICK / TICK_SPACING) * TICK_SPACING;
    }

    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "PRICE");
        uint256 ratio = (sqrt(amount1) << 96) / sqrt(amount0);
        require(ratio > MIN_SQRT_PRICE && ratio < MAX_SQRT_PRICE, "SQRT");
        return uint160(ratio);
    }

    /// @dev Full-range liquidity at the current price ≈ Uniswap v2 geometric mean.
    function liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        uint256 liquidity0 = mulDiv(amount0, sqrtPriceX96, Q96);
        uint256 liquidity1 = mulDiv(amount1, Q96, sqrtPriceX96);
        uint256 liq = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        require(liq > 0 && liq <= type(uint128).max, "LIQ");
        liquidity = uint128(liq);
    }

    function sqrtPriceWithinBps(uint160 actual, uint160 target, uint256 bps) internal pure returns (bool) {
        if (target == 0) return false;
        uint256 diff = actual > target ? uint256(actual) - uint256(target) : uint256(target) - uint256(actual);
        return diff * 10_000 <= uint256(target) * bps;
    }

    /// @dev Official `BeforeSwapDelta` / `BalanceDelta` packing: int128 << 128 | int128.
    function packDelta(int128 upper, int128 lower) internal pure returns (int256 packed) {
        assembly ("memory-safe") {
            packed := or(shl(128, upper), and(sub(shl(128, 1), 1), lower))
        }
    }

    function deltaUpper(int256 packed) internal pure returns (int128 upper) {
        assembly ("memory-safe") {
            upper := sar(128, packed)
        }
    }

    function deltaLower(int256 packed) internal pure returns (int128 lower) {
        assembly ("memory-safe") {
            lower := packed
        }
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /// @dev floor(a×b÷denominator) with 512-bit intermediate (Uniswap FullMath / Remco Bloemen, MIT).
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            require(denominator > prod1);
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = (0 - denominator) & denominator;
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
        }
    }
}
