// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Frozen Penguin Pad economics. Create + graduation ETH scale switch with
///         factory `production` (test by default; `lockProduction` is one-way to prod).
///         Trade/presale bps are the same in both modes.
library LibMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DENOM = 10_000;

    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant CURVE_SUPPLY = 800_000_000 * 1e18;
    uint256 internal constant LP_SUPPLY = 200_000_000 * 1e18;

    /// @dev Production create + curve scale (current product spec).
    uint256 internal constant PROD_LAUNCH_FEE = WAD / 4000;
    uint256 internal constant PROD_PRESALE_LAUNCH_FEE = 1e17;
    uint256 internal constant PROD_GRADUATION_QUOTE = 42 * 1e17;
    /// @dev graduation / 3. Last curve price then equals 4.2 ETH / 200M LP.
    uint256 internal constant PROD_PHANTOM_QUOTE = 14 * 1e17;
    uint256 internal constant PROD_MIN_SOFT_CAP = 25 * 1e16;

    /// @dev Cheap live-test create + curve scale. Same 1.4/4.2 phantom ratio as prod.
    uint256 internal constant TEST_LAUNCH_FEE = WAD / 1_000_000;
    uint256 internal constant TEST_PRESALE_LAUNCH_FEE = 1e13;
    uint256 internal constant TEST_GRADUATION_QUOTE = 1e15;
    uint256 internal constant TEST_PHANTOM_QUOTE = (TEST_GRADUATION_QUOTE * PROD_PHANTOM_QUOTE) / PROD_GRADUATION_QUOTE;
    uint256 internal constant TEST_MIN_SOFT_CAP = 1e13;

    uint256 internal constant TRADE_FEE_BPS = 100;
    uint256 internal constant CREATOR_SHARE_BPS = 7500;
    uint256 internal constant PLATFORM_SHARE_BPS = 2500;

    uint256 internal constant SNIPE_TAX_START_BPS = 9900;
    uint256 internal constant SNIPE_TAX_DURATION = 5;

    uint256 internal constant PRESALE_FEE_BPS = 300;
    uint256 internal constant PRESALE_CREATOR_PCT_MAX = 30;
    /// @dev Soft cap must be at least this share of the hard cap (PinkSale: 25%).
    uint256 internal constant PRESALE_MIN_SOFT_NUM = 1;
    uint256 internal constant PRESALE_MIN_SOFT_DEN = 4;
    /// @dev Presale min mint: 1 whole token. Supply is hard-cap presale tokens + hard-cap LP tokens.
    uint256 internal constant PRESALE_MIN_SUPPLY = 1e18;
    /// @dev Presale max mint: 1e15 whole tokens (1e15 * 1e18). Keeps `supply * bps` and V4 uint128 amounts in range.
    uint256 internal constant PRESALE_MAX_SUPPLY = 1e15 * 1e18;

    uint256 internal constant MAX_NAME_LEN = 64;
    uint256 internal constant MAX_TICKER_LEN = 12;
    uint256 internal constant MAX_IMAGE_LEN = 512;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function bpsOf(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps == 0) return 0;
        return (amount * bps) / BPS_DENOM;
    }

    /// @dev Bounds for a presale mint. The 70/30 split is not required; supply is rate times cap.
    function validatePresaleSupply(uint256 supply) internal pure {
        require(supply >= PRESALE_MIN_SUPPLY, "SUPPLY_MIN");
        require(supply <= PRESALE_MAX_SUPPLY, "SUPPLY_MAX");
    }

    /// @dev ETH split of a successful raise. 3% to penguinProtocol, then `creatorPct` of the rest to the creator.
    function presaleEthSplit(uint256 raisedAmt, uint32 creatorPct_)
        internal
        pure
        returns (uint256 platform, uint256 creatorEth, uint256 lpEth)
    {
        platform = bpsOf(raisedAmt, PRESALE_FEE_BPS);
        uint256 remaining = raisedAmt - platform;
        creatorEth = (remaining * creatorPct_) / 100;
        lpEth = remaining - creatorEth;
    }

    /// @dev Token wei bought by `ethAmount` at `rate` (token wei per 1 ETH).
    function tokensAtRate(uint256 ethAmount, uint256 rate) internal pure returns (uint256) {
        require(rate > 0, "RATE");
        require(ethAmount <= type(uint256).max / rate, "RATE");
        return (ethAmount * rate) / WAD;
    }

    /// @dev Tokens minted at create: hard-cap presale allocation plus LP tokens for the
    ///      post-fee hard-cap ETH that will seed the pool. `listingRate` must be
    ///      <= `presaleRate` so the pool cannot open below the presale price.
    function presaleMint(uint256 hardCap_, uint32 creatorPct_, uint256 presaleRate_, uint256 listingRate_)
        internal
        pure
        returns (uint256 supply)
    {
        require(listingRate_ > 0 && listingRate_ <= presaleRate_, "LIST_RATE");
        (, , uint256 lpEthFull) = presaleEthSplit(hardCap_, creatorPct_);
        require(lpEthFull > 0, "LP_ETH");
        uint256 presaleTokens = tokensAtRate(hardCap_, presaleRate_);
        uint256 lpTokens = tokensAtRate(lpEthFull, listingRate_);
        require(presaleTokens > 0 && lpTokens > 0, "LP_TOKENS");
        supply = presaleTokens + lpTokens;
        require(supply >= PRESALE_MIN_SUPPLY && supply <= PRESALE_MAX_SUPPLY, "SUPPLY");
    }

    /// @dev Actual claim and LP amounts for `raisedAmt`. Unsold hard-cap tokens are `burned`.
    function presaleTokenSplit(
        uint256 raisedAmt,
        uint256 hardCap_,
        uint32 creatorPct_,
        uint256 presaleRate_,
        uint256 listingRate_
    ) internal pure returns (uint256 communityTokens, uint256 lpTokens, uint256 burned) {
        uint256 supply = presaleMint(hardCap_, creatorPct_, presaleRate_, listingRate_);
        (, , uint256 lpEth) = presaleEthSplit(raisedAmt, creatorPct_);
        require(lpEth > 0, "LP_ETH");
        communityTokens = tokensAtRate(raisedAmt, presaleRate_);
        lpTokens = tokensAtRate(lpEth, listingRate_);
        require(communityTokens > 0 && lpTokens > 0, "LP_TOKENS");
        require(communityTokens + lpTokens <= supply, "SUPPLY");
        burned = supply - communityTokens - lpTokens;
    }

    function launchFee(bool production) internal pure returns (uint256) {
        return production ? PROD_LAUNCH_FEE : TEST_LAUNCH_FEE;
    }

    function presaleLaunchFee(bool production) internal pure returns (uint256) {
        return production ? PROD_PRESALE_LAUNCH_FEE : TEST_PRESALE_LAUNCH_FEE;
    }

    function minSoftCap(bool production) internal pure returns (uint256) {
        return production ? PROD_MIN_SOFT_CAP : TEST_MIN_SOFT_CAP;
    }

    function graduationQuote(bool production) internal pure returns (uint256) {
        return production ? PROD_GRADUATION_QUOTE : TEST_GRADUATION_QUOTE;
    }

    function phantomQuote(bool production) internal pure returns (uint256) {
        return production ? PROD_PHANTOM_QUOTE : TEST_PHANTOM_QUOTE;
    }

    function initialVirtualToken(uint256 phantom, uint256 graduation) internal pure returns (uint256) {
        require(graduation > 0, "GRADUATION");
        return (CURVE_SUPPLY * (phantom + graduation)) / graduation;
    }

    function initialVirtualToken(bool production) internal pure returns (uint256) {
        return initialVirtualToken(phantomQuote(production), graduationQuote(production));
    }

    /// @dev Uniswap-v2 amount-out: dy = dx * y / (x + dx). Rounding favors the curve.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        require(amountIn > 0, "ZERO_IN");
        require(reserveIn > 0 && reserveOut > 0, "BAD_RESERVE");
        return (amountIn * reserveOut) / (reserveIn + amountIn);
    }

    /// @dev Inverse of getAmountOut, rounded up so the buyer always receives at least `amountOut`.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        require(amountOut > 0, "ZERO_OUT");
        require(reserveIn > 0 && amountOut < reserveOut, "BAD_OUT");
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        return (numerator + denominator - 1) / denominator;
    }

    function decayingBuyTaxBps(uint256 createdAt, uint256 nowTs) internal pure returns (uint256) {
        uint256 snipe;
        if (nowTs <= createdAt) {
            snipe = SNIPE_TAX_START_BPS;
        } else {
            uint256 elapsed = nowTs - createdAt;
            if (elapsed >= SNIPE_TAX_DURATION) return 0;
            uint256 remaining = SNIPE_TAX_DURATION - elapsed;
            snipe = (SNIPE_TAX_START_BPS * remaining) / SNIPE_TAX_DURATION;
        }
        uint256 maxSnipe = BPS_DENOM - TRADE_FEE_BPS - 1;
        return snipe > maxSnipe ? maxSnipe : snipe;
    }

    struct QuoteFees {
        uint256 tradeFee;
        uint256 creatorCut;
        uint256 platformCut;
        uint256 snipeCut;
        uint256 fee;
        uint256 netQuote;
    }

    function quoteFees(uint256 quoteAmount, uint256 snipeBps) internal pure returns (QuoteFees memory fees) {
        require(quoteAmount > 0, "ZERO_QUOTE");
        fees.tradeFee = bpsOf(quoteAmount, TRADE_FEE_BPS);
        fees.creatorCut = bpsOf(fees.tradeFee, CREATOR_SHARE_BPS);
        fees.platformCut = fees.tradeFee - fees.creatorCut;
        fees.snipeCut = bpsOf(quoteAmount, snipeBps);
        fees.fee = fees.tradeFee + fees.snipeCut;
        require(fees.fee < quoteAmount, "FEE_CONSUMES");
        fees.netQuote = quoteAmount - fees.fee;
    }

    function grossQuoteForNet(uint256 netQuote, uint256 snipeBps) internal pure returns (uint256 gross) {
        uint256 keepBps = BPS_DENOM - TRADE_FEE_BPS - snipeBps;
        require(keepBps > 0, "FEE_CONSUMES");
        gross = (netQuote * BPS_DENOM + keepBps - 1) / keepBps;
        if (gross == 0) gross = 1;
        while (quoteFees(gross, snipeBps).netQuote < netQuote) {
            unchecked {
                ++gross;
            }
        }
    }

    function validateNameTicker(string memory name, string memory ticker) internal pure {
        bytes memory nameBytes = bytes(name);
        bytes memory tickerBytes = bytes(ticker);
        require(nameBytes.length > 0 && nameBytes.length <= MAX_NAME_LEN, "NAME");
        require(tickerBytes.length > 0 && tickerBytes.length <= MAX_TICKER_LEN, "TICKER");
    }
}
