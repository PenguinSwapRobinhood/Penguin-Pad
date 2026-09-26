// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibMath} from "./libraries/LibMath.sol";
import {PenguinToken} from "./PenguinToken.sol";
import {Currency, IPenguinFactory, IV4Graduate, PoolKey} from "./interfaces/IUniswapV4.sol";

/// @title Presale
/// @notice Scheduled ETH raise, PinkSale-style rates.
///         Contributors receive `presaleRate` tokens per 1 ETH. The pool is seeded at
///         `listingRate` tokens per 1 ETH of liquidity (`listingRate` <= `presaleRate`,
///         so the open price is at least the presale price). Unsold hard-cap tokens burn.
///         `creatorPct` is the unlocked creator share of remaining ETH after the 3% fee: 0-30.
contract Presale {
    event Contributed(address indexed wallet, uint256 amount, uint256 total);
    event Withdrawn(address indexed wallet, uint256 amount, uint256 remaining);
    event Finalized(bool success, uint256 raised, address pool);
    event Cancelled(address indexed caller, uint256 raised);
    event LiquidityBurned(bytes32 indexed poolId, uint256 positionTokenId, uint128 liquidity);
    event TokensClaimed(address indexed wallet, uint256 amount);
    event Refunded(address indexed wallet, uint256 amount);

    struct Init {
        address creator;
        address token;
        address v4Graduate;
        uint64 startsAt;
        uint64 endsAt;
        uint32 creatorPct;
        uint256 presaleRate;
        uint256 listingRate;
        uint256 softCap;
        uint256 hardCap;
        uint256 minContribution;
        uint256 maxContribution;
        uint256 totalSupply;
        string imageUrl;
    }

    address public factory;
    address public creator;
    address public token;
    address public pool;
    address public v4Graduate;
    bytes32 public poolId;
    uint256 public positionTokenId;
    string public imageUrl;
    uint64 public startsAt;
    uint64 public endsAt;
    uint64 public finalizedAt;
    uint32 public creatorPct;
    /// @notice Token wei a contributor receives per 1 ETH.
    uint256 public presaleRate;
    /// @notice Token wei added to the pool per 1 ETH of liquidity. Never above `presaleRate`.
    uint256 public listingRate;
    uint256 public softCap;
    uint256 public hardCap;
    uint256 public minContribution;
    uint256 public maxContribution;
    uint256 public totalSupply;
    /// @notice Tokens claimable by contributors. Set on successful finalize: `raised * presaleRate / 1e18`.
    uint256 public communityAllocation;
    uint256 public raised;
    uint256 public participants;
    bool public finalized;
    bool public success;
    bool public cancelled;

    mapping(address => uint256) public contributed;
    mapping(address => bool) public claimed;

    uint256 private locked = 1;
    bool private initialized;

    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    function initialize(Init calldata p) external {
        require(!initialized, "INIT");
        require(p.creator != address(0), "ADDR");
        require(p.token != address(0) && p.v4Graduate != address(0), "ADDR");
        require(p.startsAt >= block.timestamp, "START");
        require(p.endsAt > p.startsAt, "ENDS");
        uint64 length = p.endsAt - p.startsAt;
        require(length >= 1 days && length <= 30 days, "DURATION");
        require(p.creatorPct <= LibMath.PRESALE_CREATOR_PCT_MAX, "CREATOR_PCT");
        require(p.softCap >= LibMath.minSoftCap(IPenguinFactory(msg.sender).production()), "SOFT_CAP");
        require(p.hardCap >= p.softCap, "CAPS");
        require(p.softCap <= type(uint256).max / 4 && p.hardCap <= p.softCap * 4, "SOFT_RATIO");
        require(p.minContribution > 0 && p.maxContribution >= p.minContribution, "WALLET_CAPS");
        require(p.maxContribution <= p.hardCap, "MAX_GT_HARD");
        uint256 supply = LibMath.presaleMint(p.hardCap, p.creatorPct, p.presaleRate, p.listingRate);
        require(PenguinToken(p.token).balanceOf(address(this)) == supply, "SUPPLY");
        (, , uint256 lpEthSoft) = LibMath.presaleEthSplit(p.softCap, p.creatorPct);
        require(LibMath.tokensAtRate(p.softCap, p.presaleRate) > 0, "LP_TOKENS");
        require(LibMath.tokensAtRate(lpEthSoft, p.listingRate) > 0, "LP_TOKENS");
        require(LibMath.tokensAtRate(p.minContribution, p.presaleRate) > 0, "MIN_TOKENS");

        initialized = true;
        locked = 1;
        factory = msg.sender;
        creator = p.creator;
        token = p.token;
        v4Graduate = p.v4Graduate;
        imageUrl = p.imageUrl;
        startsAt = p.startsAt;
        endsAt = p.endsAt;
        creatorPct = p.creatorPct;
        presaleRate = p.presaleRate;
        listingRate = p.listingRate;
        softCap = p.softCap;
        hardCap = p.hardCap;
        minContribution = p.minContribution;
        maxContribution = p.maxContribution;
        totalSupply = supply;
    }

    /// @notice Claim, LP, and burned tokens if finalized at the current `raised`.
    function previewTokenSplit()
        public
        view
        returns (uint256 communityTokens, uint256 lpTokens, uint256 burned)
    {
        if (raised == 0) return (0, 0, totalSupply);
        return LibMath.presaleTokenSplit(raised, hardCap, creatorPct, presaleRate, listingRate);
    }

    function penguinProtocol() public view returns (address) {
        return IPenguinFactory(factory).penguinProtocol();
    }

    /// @notice 0 upcoming, 1 live, 2 success, 3 failed, 4 ready (eligible to finalize).
    function status() public view returns (uint8) {
        if (finalized && success) return 2;
        if (cancelled) return 3;
        if (block.timestamp >= endsAt && raised < softCap) return 3;
        if (_readyToFinalize()) return 4;
        if (block.timestamp < startsAt) return 0;
        return 1;
    }

    /// @notice Whether `who` may call `finalize()` now.
    function canFinalize(address who) public view returns (bool) {
        if (who != creator && who != penguinProtocol()) return false;
        if (finalized || cancelled) return false;
        return _readyToFinalize();
    }

    /// @notice Whether `who` may call `cancel()` now.
    function canCancel(address who) public view returns (bool) {
        if (finalized && success) return false;
        if (cancelled) return false;
        address penguin = penguinProtocol();
        if (who == penguin) return true;
        if (who != creator) return false;
        if (block.timestamp < startsAt) return true;
        return endsAt > block.timestamp + 24 hours;
    }

    /// @notice Uniswap v4 pool seeded on success. `fee = 0`, `hooks = PenguinHook`.
    function poolInfo()
        external
        view
        returns (bytes32 id, address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        id = poolId;
        if (id == bytes32(0)) return (id, address(0), address(0), 0, 0, address(0));
        PoolKey memory key = IV4Graduate(v4Graduate).poolKeyOf(token);
        currency0 = Currency.unwrap(key.currency0);
        currency1 = Currency.unwrap(key.currency1);
        fee = key.fee;
        tickSpacing = key.tickSpacing;
        hooks = key.hooks;
    }

    function contribute() external payable nonReentrant {
        require(block.timestamp >= startsAt && block.timestamp < endsAt, "NOT_LIVE");
        require(!finalized && !cancelled, "DONE");
        require(raised < hardCap, "HARD_CAP");
        require(msg.value > 0, "ZERO");
        require(raised + msg.value <= hardCap, "HARD_CAP");
        uint256 next = contributed[msg.sender] + msg.value;
        require(next <= maxContribution, "WALLET_MAX");
        if (contributed[msg.sender] == 0) {
            require(msg.value >= minContribution || raised + msg.value == hardCap, "WALLET_MIN");
            participants += 1;
        }
        contributed[msg.sender] = next;
        raised += msg.value;
        emit Contributed(msg.sender, msg.value, next);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(block.timestamp >= startsAt && block.timestamp < endsAt, "CLOSED");
        require(!finalized && !cancelled, "CLOSED");
        require(raised < hardCap, "CLOSED");
        require(amount > 0, "ZERO");
        uint256 pledged = contributed[msg.sender];
        require(amount <= pledged, "OVER");
        uint256 remaining = pledged - amount;
        contributed[msg.sender] = remaining;
        raised -= amount;
        if (remaining == 0) participants -= 1;
        _sendEth(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, remaining);
    }

    /// @notice Seed V4 LP on success. Creator or live `penguinProtocol` only.
    function finalize() external nonReentrant {
        require(canFinalize(msg.sender), "FORBIDDEN");
        finalized = true;
        success = true;
        finalizedAt = uint64(block.timestamp);

        (uint256 platform, uint256 creatorEth, uint256 lpEth) = LibMath.presaleEthSplit(raised, creatorPct);
        (uint256 communityTokens, uint256 lpTokens,) =
            LibMath.presaleTokenSplit(raised, hardCap, creatorPct, presaleRate, listingRate);
        communityAllocation = communityTokens;

        require(PenguinToken(token).approve(v4Graduate, lpTokens), "APPROVE");
        uint128 liquidity;
        (poolId, positionTokenId, liquidity) = IV4Graduate(v4Graduate).seed{value: lpEth}(token, lpTokens);
        require(poolId != bytes32(0) && liquidity > 0, "NO_LP");
        pool = IV4Graduate(v4Graduate).poolManager();

        uint256 tokenBal = PenguinToken(token).balanceOf(address(this));
        if (tokenBal > communityTokens) PenguinToken(token).burn(tokenBal - communityTokens);

        _sendEth(penguinProtocol(), platform);
        _sendEth(creator, creatorEth);
        if (address(this).balance > 0) _sendEth(penguinProtocol(), address(this).balance);
        emit Finalized(true, raised, pool);
        emit LiquidityBurned(poolId, positionTokenId, liquidity);
    }

    /// @notice Mark the sale failed. Creator (before start or with >24h left) or penguinProtocol (anytime before success).
    function cancel() external nonReentrant {
        require(canCancel(msg.sender), "FORBIDDEN");
        cancelled = true;
        uint256 leftover = PenguinToken(token).balanceOf(address(this));
        if (leftover > 0) PenguinToken(token).burn(leftover);
        emit Cancelled(msg.sender, raised);
        emit Finalized(false, raised, address(0));
    }

    function claim() external nonReentrant {
        require(finalized && success, "NOT_SUCCESS");
        require(!claimed[msg.sender], "CLAIMED");
        uint256 pledged = contributed[msg.sender];
        require(pledged > 0, "NONE");
        claimed[msg.sender] = true;
        uint256 amount = (pledged * presaleRate) / 1e18;
        require(amount > 0, "ZERO");
        require(PenguinToken(token).transfer(msg.sender, amount), "TOKEN");
        emit TokensClaimed(msg.sender, amount);
    }

    function refund() external nonReentrant {
        require(_isFailed(), "NOT_FAIL");
        uint256 leftover = PenguinToken(token).balanceOf(address(this));
        if (leftover > 0) PenguinToken(token).burn(leftover);
        uint256 amount = contributed[msg.sender];
        require(amount > 0, "NONE");
        contributed[msg.sender] = 0;
        _sendEth(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    function _readyToFinalize() internal view returns (bool) {
        if (raised >= hardCap) return true;
        return block.timestamp >= endsAt && raised >= softCap;
    }

    function _isFailed() internal view returns (bool) {
        if (cancelled) return true;
        if (finalized && success) return false;
        return block.timestamp >= endsAt && raised < softCap;
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH_TRANSFER");
    }

    receive() external payable {
        require(msg.sender == v4Graduate, "DIRECT_ETH");
    }
}
