// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency, IHooks, IPenguinListing, IPoolManager, IV4Graduate, IERC20Minimal, PoolKey, SwapParams} from "./interfaces/IUniswapV4.sol";
import {LibHookMiner} from "./libraries/LibHookMiner.sol";
import {LibMath} from "./libraries/LibMath.sol";
import {LibV4} from "./libraries/LibV4.sol";

/// @title PenguinHook
/// @notice Uniswap v4 hook for graduated / finalized listings.
///         Pool swap fee is 0; this contract takes 1% of the ETH/WETH quote leg
///         (`TRADE_FEE_BPS`) and splits 75% creator / 25% penguinProtocol — same as the curve.
///         Both cuts are pushed on each swap (unlike on-curve, which accrues until graduate).
///         If the creator wallet rejects ETH/WETH, that share accrues and they pull it
///         with `claimCreatorFees(token)`. Does not hold or transfer the burned PositionManager NFT.
contract PenguinHook {
    /// @dev Same bits as `LibHookMiner.REQUIRED_FLAGS` (v4-core hook flags in the address).
    function requiredFlags() external pure returns (uint160) {
        return LibHookMiner.REQUIRED_FLAGS;
    }

    event Registered(address indexed token, address indexed creator, address indexed listing);
    event SwapFeeTaken(address indexed token, uint256 fee, uint256 creatorCut, uint256 platformCut);
    event CreatorFeesClaimed(address indexed token, address indexed creator, uint256 amount);

    struct Listing {
        address creator;
        address listing;
        bool registered;
    }

    IPoolManager public immutable poolManager;
    address public immutable weth;
    address public immutable graduate;

    mapping(address => Listing) public listings;
    mapping(address => uint256) public creatorFeesAccrued;

    uint256 private locked = 1;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "NOT_PM");
        _;
    }

    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(address poolManager_, address weth_, address graduate_) {
        require(poolManager_ != address(0) && weth_ != address(0) && graduate_ != address(0), "ADDR");
        poolManager = IPoolManager(poolManager_);
        weth = weth_;
        graduate = graduate_;
    }

    /// @notice Called by `V4Graduate.seed` before `PoolManager.initialize`.
    ///         `listing_` is the CurveLaunch or Presale; platform fees follow that factory's live `penguinProtocol`.
    function register(address token, address creator_, address listing_) external {
        require(msg.sender == graduate, "NOT_GRADUATE");
        require(token != address(0) && creator_ != address(0) && listing_ != address(0), "ADDR");
        Listing storage L = listings[token];
        if (L.registered) {
            require(L.creator == creator_ && L.listing == listing_, "LISTED");
            return;
        }
        listings[token] = Listing({creator: creator_, listing: listing_, registered: true});
        emit Registered(token, creator_, listing_);
    }

    /// @notice Only a pool `V4Graduate` registered may initialize. Strangers cannot
    ///         attach this hook to an arbitrary token.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        require(sender == graduate, "NOT_GRADUATE");
        require(key.hooks == address(this), "HOOK");
        require(key.fee == LibV4.POOL_FEE, "FEE");
        require(key.tickSpacing == LibV4.TICK_SPACING, "SPACING");
        require(listings[_tokenOf(key)].registered, "NOT_LISTED");
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Take 1% of the quote when ETH/WETH is the specified currency (exact-in
    ///         buy or exact-out sell).
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int256, uint24)
    {
        (Currency quote, bool quoteIsC0) = _quoteCurrency(key);
        if (_specifiedIsC0(params) != quoteIsC0) {
            return (IHooks.beforeSwap.selector, 0, 0);
        }
        uint256 fee = _feeOn(params.amountSpecified);
        if (fee == 0) return (IHooks.beforeSwap.selector, 0, 0);
        _takeAndSplit(key, quote, fee);
        return (IHooks.beforeSwap.selector, LibV4.packDelta(int128(int256(fee)), 0), 0);
    }

    /// @notice Take 1% of the quote when ETH/WETH is the unspecified currency (exact-in
    ///         sell or exact-out buy).
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        (Currency quote, bool quoteIsC0) = _quoteCurrency(key);
        if (_specifiedIsC0(params) == quoteIsC0) {
            return (IHooks.afterSwap.selector, 0);
        }
        int128 unspec = quoteIsC0 ? LibV4.deltaUpper(delta) : LibV4.deltaLower(delta);
        uint256 fee = _feeOn(int256(unspec));
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        _takeAndSplit(key, quote, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Fallback if auto-push to the creator failed (wallet rejected ETH/WETH).
    function claimCreatorFees(address token) external nonReentrant returns (uint256 amount) {
        Listing storage L = listings[token];
        require(msg.sender == L.creator, "NOT_CREATOR");
        amount = creatorFeesAccrued[token];
        require(amount > 0, "NO_FEES");
        creatorFeesAccrued[token] = 0;
        _pay(_quoteCurrencyGlobal(), L.creator, amount);
        emit CreatorFeesClaimed(token, L.creator, amount);
    }

    function _takeAndSplit(PoolKey calldata key, Currency quote, uint256 fee) internal {
        address token = _tokenOf(key);
        Listing storage L = listings[token];
        require(L.registered, "NOT_LISTED");
        poolManager.take(quote, address(this), fee);
        uint256 creatorCut = LibMath.bpsOf(fee, LibMath.CREATOR_SHARE_BPS);
        uint256 platformCut = fee - creatorCut;
        _pay(quote, IPenguinListing(L.listing).penguinProtocol(), platformCut);
        if (_tryPay(quote, L.creator, creatorCut)) {
            emit CreatorFeesClaimed(token, L.creator, creatorCut);
        } else {
            creatorFeesAccrued[token] += creatorCut;
        }
        emit SwapFeeTaken(token, fee, creatorCut, platformCut);
    }

    function _feeOn(int256 amount) internal pure returns (uint256 fee) {
        require(amount != type(int256).min, "AMT");
        uint256 absAmount = amount < 0 ? uint256(-amount) : uint256(amount);
        fee = LibMath.bpsOf(absAmount, LibMath.TRADE_FEE_BPS);
        require(fee <= uint256(uint128(type(int128).max)), "FEE");
    }

    function _specifiedIsC0(SwapParams calldata params) internal pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _quoteCurrency(PoolKey calldata key) internal view returns (Currency quote, bool quoteIsC0) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0) || c0 == weth) return (key.currency0, true);
        if (c1 == address(0) || c1 == weth) return (key.currency1, false);
        revert("NO_QUOTE");
    }

    function _quoteCurrencyGlobal() internal view returns (Currency) {
        if (IV4Graduate(graduate).useNativeEth()) return Currency.wrap(address(0));
        return Currency.wrap(weth);
    }

    function _tokenOf(PoolKey calldata key) internal view returns (address) {
        (, bool quoteIsC0) = _quoteCurrency(key);
        return quoteIsC0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
    }

    function _pay(Currency currency, address to, uint256 amount) internal {
        require(_tryPay(currency, to, amount), Currency.unwrap(currency) == address(0) ? "ETH_TRANSFER" : "TOKEN");
    }

    function _tryPay(Currency currency, address to, uint256 amount) internal returns (bool) {
        if (amount == 0) return true;
        address raw = Currency.unwrap(currency);
        if (raw == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            return ok;
        }
        try IERC20Minimal(raw).transfer(to, amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    receive() external payable {}
}
