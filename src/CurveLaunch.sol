// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibMath} from "./libraries/LibMath.sol";
import {PenguinERC20} from "./token/PenguinERC20.sol";
import {Currency, IPenguinFactory, IV4Graduate, PoolKey} from "./interfaces/IUniswapV4.sol";

/// @title CurveLaunch
/// @notice Bonding-curve ERC-20. Each createLaunch deploys a full copy of this contract
///         (own address, name, ticker, Blockscout /token page). Runtime bytecode is
///         identical across launches so one Blockscout + Sourcify verify covers every
///         later token. At the snapshotted graduation quote (0.001 ETH test / 4.2 ETH prod)
///         the remaining inventory plus 200M LP tokens
///         seed a Uniswap v4 pool with PenguinHook (fee 0); initial liquidity is permanently burned.
///         Curve buy/sell then revert. On-curve 1% (75% creator / 25% platform) accrues until
///         `_graduate()`; snipe tax is paid immediately. After listing, PenguinHook pays on each swap.
contract CurveLaunch is PenguinERC20 {
    enum Status {
        Curve,
        Graduated
    }

    event Buy(address indexed buyer, uint256 quoteIn, uint256 tokensOut, bool graduated);
    event Sell(address indexed seller, uint256 tokenIn, uint256 quoteOut);
    event Graduated(uint256 quoteReserve, uint256 tokenReserve);
    event LiquidityBurned(bytes32 indexed poolId, uint256 positionTokenId, uint128 liquidity);
    event CreatorFeesClaimed(address indexed creator, uint256 amount);

    address public factory;
    address public creator;
    address public v4Graduate;
    address public pair;
    bytes32 public poolId;
    uint256 public positionTokenId;
    string public imageUrl;
    uint64 public createdAt;
    Status public status;

    uint256 public phantomQuote;
    uint256 public graduationQuote;
    uint256 public virtualQuote;
    uint256 public virtualToken;
    uint256 public realQuoteRaised;
    uint256 public tokensSold;
    uint256 public creatorFeesAccrued;
    uint256 public platformFeesAccrued;
    uint256 public poolQuote;
    uint256 public poolToken;

    uint256 private locked = 1;
    bool private initialized;

    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    modifier onCurve() {
        require(status == Status.Curve, "GRADUATED");
        _;
    }

    function initialize(
        address creator_,
        address v4Graduate_,
        string calldata name_,
        string calldata ticker_,
        string calldata imageUrl_,
        uint256 phantomQuote_,
        uint256 graduationQuote_
    ) external {
        require(!initialized, "INIT");
        require(creator_ != address(0) && v4Graduate_ != address(0), "ADDR");
        require(phantomQuote_ > 0 && graduationQuote_ > 0, "CURVE");
        LibMath.validateNameTicker(name_, ticker_);
        require(bytes(imageUrl_).length <= LibMath.MAX_IMAGE_LEN, "IMAGE");

        initialized = true;
        locked = 1;
        factory = msg.sender;
        creator = creator_;
        v4Graduate = v4Graduate_;
        imageUrl = imageUrl_;
        createdAt = uint64(block.timestamp);
        _setMetadata(name_, ticker_);

        phantomQuote = phantomQuote_;
        graduationQuote = graduationQuote_;
        virtualQuote = phantomQuote_;
        virtualToken = LibMath.initialVirtualToken(phantomQuote_, graduationQuote_);
        _mint(address(this), LibMath.TOTAL_SUPPLY);
    }

    function penguinProtocol() public view returns (address) {
        return IPenguinFactory(factory).penguinProtocol();
    }

    /// @notice The launch contract is the ERC-20. One address for trading, token page, and Blockscout.
    function token() external view returns (address) {
        return address(this);
    }

    function ticker() external view returns (string memory) {
        return symbol();
    }

    /// @notice Uniswap v4 pool used after graduation. `fee = 0`, `hooks = PenguinHook`.
    function poolInfo()
        external
        view
        returns (bytes32 id, address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        id = poolId;
        if (id == bytes32(0)) return (id, address(0), address(0), 0, 0, address(0));
        (currency0, currency1, fee, tickSpacing, hooks) = _decodeKey(IV4Graduate(v4Graduate).poolKeyOf(address(this)));
    }

    function _decodeKey(PoolKey memory key)
        private
        pure
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        currency0 = Currency.unwrap(key.currency0);
        currency1 = Currency.unwrap(key.currency1);
        fee = key.fee;
        tickSpacing = key.tickSpacing;
        hooks = key.hooks;
    }

    function remainingCurveTokens() public view returns (uint256) {
        if (tokensSold >= LibMath.CURVE_SUPPLY) return 0;
        return LibMath.CURVE_SUPPLY - tokensSold;
    }

    function quoteBuy(uint256 quoteIn) external view onCurve returns (uint256 tokensOut, uint256 fee) {
        (tokensOut, fee,) = _quoteCurveBuy(quoteIn);
    }

    function quoteSell(uint256 tokenIn) external view onCurve returns (uint256 quoteOut, uint256 fee) {
        require(tokenIn <= tokensSold, "OVERSOLD");
        uint256 rawQuote = LibMath.getAmountOut(tokenIn, virtualToken, virtualQuote);
        LibMath.QuoteFees memory fees = LibMath.quoteFees(rawQuote, 0);
        return (fees.netQuote, fees.fee);
    }

    function buy() external payable nonReentrant onCurve returns (uint256 tokensOut) {
        require(msg.value > 0, "ZERO_QUOTE");
        uint256 spent;
        bool graduated;
        (tokensOut, spent, graduated) = _buyCurve(msg.value);
        if (msg.value > spent) {
            _sendEth(msg.sender, msg.value - spent);
        }
        emit Buy(msg.sender, spent, tokensOut, graduated);
    }

    function sell(uint256 tokenIn) external nonReentrant onCurve returns (uint256 quoteOut) {
        require(tokenIn > 0, "ZERO_IN");
        quoteOut = _sellCurve(tokenIn);
        emit Sell(msg.sender, tokenIn, quoteOut);
    }

    /// @notice Fallback if the graduate auto-push to the creator failed (wallet rejected ETH).
    function claimCreatorFees() external nonReentrant returns (uint256 amount) {
        require(msg.sender == creator, "NOT_CREATOR");
        amount = creatorFeesAccrued;
        require(amount > 0, "NO_FEES");
        creatorFeesAccrued = 0;
        _sendEth(creator, amount);
        emit CreatorFeesClaimed(creator, amount);
    }

    function _quoteCurveBuy(uint256 quoteIn)
        internal
        view
        returns (uint256 tokensOut, uint256 fee, uint256 quoteSpent)
    {
        uint256 remaining = remainingCurveTokens();
        require(remaining > 0, "SOLD_OUT");
        uint256 snipeBps = LibMath.decayingBuyTaxBps(createdAt, block.timestamp);
        LibMath.QuoteFees memory fees = LibMath.quoteFees(quoteIn, snipeBps);
        quoteSpent = quoteIn;
        tokensOut = LibMath.getAmountOut(fees.netQuote, virtualQuote, virtualToken);
        if (tokensOut > remaining) {
            tokensOut = remaining;
            uint256 netNeeded = LibMath.getAmountIn(tokensOut, virtualQuote, virtualToken);
            quoteSpent = LibMath.grossQuoteForNet(netNeeded, snipeBps);
            fees = LibMath.quoteFees(quoteSpent, snipeBps);
        }
        fee = fees.fee;
    }

    function _buyCurve(uint256 quoteIn) internal returns (uint256 tokensOut, uint256 quoteSpent, bool graduated) {
        uint256 remaining = remainingCurveTokens();
        require(remaining > 0, "SOLD_OUT");

        uint256 snipeBps = LibMath.decayingBuyTaxBps(createdAt, block.timestamp);
        LibMath.QuoteFees memory fees = LibMath.quoteFees(quoteIn, snipeBps);
        quoteSpent = quoteIn;
        tokensOut = LibMath.getAmountOut(fees.netQuote, virtualQuote, virtualToken);
        uint256 netIntoCurve = fees.netQuote;

        if (tokensOut > remaining) {
            tokensOut = remaining;
            uint256 netNeeded = LibMath.getAmountIn(tokensOut, virtualQuote, virtualToken);
            quoteSpent = LibMath.grossQuoteForNet(netNeeded, snipeBps);
            require(quoteIn >= quoteSpent, "UNDERPAY");
            fees = LibMath.quoteFees(quoteSpent, snipeBps);
            if (fees.netQuote > netNeeded) {
                fees.platformCut += fees.netQuote - netNeeded;
                fees.fee += fees.netQuote - netNeeded;
                fees.netQuote = netNeeded;
            }
            netIntoCurve = netNeeded;
        }

        require(tokensOut > 0, "ZERO_OUT");
        virtualQuote += netIntoCurve;
        virtualToken -= tokensOut;
        realQuoteRaised += netIntoCurve;
        tokensSold += tokensOut;

        _transfer(address(this), msg.sender, tokensOut);
        _accrueTradeFees(fees);

        if (status == Status.Curve && realQuoteRaised >= graduationQuote) {
            _graduate();
            graduated = true;
        }
    }

    function _sellCurve(uint256 tokenIn) internal returns (uint256 quoteOut) {
        require(tokenIn <= tokensSold, "OVERSOLD");
        uint256 rawQuote = LibMath.getAmountOut(tokenIn, virtualToken, virtualQuote);
        require(rawQuote > 0, "ZERO_OUT");
        LibMath.QuoteFees memory fees = LibMath.quoteFees(rawQuote, 0);

        virtualQuote -= rawQuote;
        virtualToken += tokenIn;
        realQuoteRaised = realQuoteRaised > rawQuote ? realQuoteRaised - rawQuote : 0;
        tokensSold -= tokenIn;
        quoteOut = fees.netQuote;

        _transfer(msg.sender, address(this), tokenIn);
        _accrueTradeFees(fees);
        _sendEth(msg.sender, quoteOut);
    }

    function _graduate() internal {
        uint256 tokenReserve = balanceOf[address(this)];
        uint256 quoteReserve = realQuoteRaised;
        require(quoteReserve > 0 && tokenReserve > 0, "EMPTY_POOL");

        _payoutPlatform();
        _payoutAccruedCreator();

        allowance[address(this)][v4Graduate] = tokenReserve;
        emit Approval(address(this), v4Graduate, tokenReserve);

        // After fee payouts: keep leftover creator-fee ETH (only if auto-push
        // failed) and any unrefunded buy excess. Only unused LP ETH returned
        // by V4Graduate (balance above this) is swept to penguinProtocol.
        uint256 ethKeep = address(this).balance - quoteReserve;

        uint128 liquidity;
        (poolId, positionTokenId, liquidity) =
            IV4Graduate(v4Graduate).seed{value: quoteReserve}(address(this), tokenReserve);
        require(poolId != bytes32(0) && liquidity > 0, "NO_LP");

        pair = IV4Graduate(v4Graduate).poolManager();
        status = Status.Graduated;
        poolQuote = quoteReserve;
        poolToken = tokenReserve;

        uint256 leftoverTokens = balanceOf[address(this)];
        if (leftoverTokens > 0) {
            _transfer(address(this), LibMath.DEAD, leftoverTokens);
        }
        if (address(this).balance > ethKeep) {
            _sendEth(penguinProtocol(), address(this).balance - ethKeep);
        }

        emit Graduated(quoteReserve, tokenReserve);
        emit LiquidityBurned(poolId, positionTokenId, liquidity);
    }

    function _accrueTradeFees(LibMath.QuoteFees memory fees) internal {
        if (fees.snipeCut > 0) _sendEth(penguinProtocol(), fees.snipeCut);
        creatorFeesAccrued += fees.creatorCut;
        platformFeesAccrued += fees.platformCut;
    }

    function _payoutPlatform() internal {
        uint256 amount = platformFeesAccrued;
        if (amount == 0) return;
        platformFeesAccrued = 0;
        _sendEth(penguinProtocol(), amount);
    }

    function _payoutAccruedCreator() internal {
        uint256 amount = creatorFeesAccrued;
        if (amount == 0) return;
        if (_trySendEth(creator, amount)) {
            creatorFeesAccrued = 0;
            emit CreatorFeesClaimed(creator, amount);
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        require(_trySendEth(to, amount), "ETH_TRANSFER");
    }

    function _trySendEth(address to, uint256 amount) internal returns (bool ok) {
        if (amount == 0) return true;
        (ok,) = to.call{value: amount}("");
    }

    receive() external payable {
        require(msg.sender == v4Graduate, "DIRECT_ETH");
    }
}
