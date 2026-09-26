// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibMath} from "./libraries/LibMath.sol";
import {PenguinToken} from "./PenguinToken.sol";
import {Presale} from "./Presale.sol";

/// @title PresaleFactory
/// @notice Permissionless presale factory. Deployer is `owner` and can
///         `setPenguinProtocol` (live fee wallet for all presales from this factory),
///         `lockProduction` (one-way test to prod create fee and min soft cap), or
///         `transferOwnership`. Nothing else is admin-gated.
contract PresaleFactory {
    event PresaleCreated(
        address indexed presale, address indexed creator, address indexed token, string name, string ticker
    );
    event PenguinProtocolUpdated(address indexed penguinProtocol);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProductionLocked();

    address public immutable v4Graduate;

    address public penguinProtocol;
    address public owner;
    /// @dev False at deploy (cheap live-test create fee). `lockProduction` is permanent.
    bool public production;

    mapping(address => bool) public isPresale;
    mapping(address => address) public tokenOf;
    address[] public allPresales;

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address penguinProtocol_, address v4Graduate_) {
        require(penguinProtocol_ != address(0) && v4Graduate_ != address(0), "ADDR");
        owner = msg.sender;
        penguinProtocol = penguinProtocol_;
        v4Graduate = v4Graduate_;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function createPresale(
        string calldata name,
        string calldata ticker,
        string calldata imageUrl,
        uint256 presaleRate,
        uint256 listingRate,
        uint64 startsAt,
        uint64 endsAt,
        uint32 creatorPct,
        uint256 softCap,
        uint256 hardCap,
        uint256 minContribution,
        uint256 maxContribution
    ) external payable returns (address presale) {
        require(msg.value == launchFee(), "LAUNCH_FEE");
        require(bytes(imageUrl).length <= LibMath.MAX_IMAGE_LEN, "IMAGE");
        require(softCap >= minSoftCap(), "SOFT_CAP");

        Presale.Init memory p;
        p.creator = msg.sender;
        p.v4Graduate = v4Graduate;
        p.startsAt = startsAt;
        p.endsAt = endsAt;
        p.creatorPct = creatorPct;
        p.presaleRate = presaleRate;
        p.listingRate = listingRate;
        p.softCap = softCap;
        p.hardCap = hardCap;
        p.minContribution = minContribution;
        p.maxContribution = maxContribution;
        p.totalSupply = LibMath.presaleMint(hardCap, creatorPct, presaleRate, listingRate);
        p.imageUrl = imageUrl;
        presale = _spawn(name, ticker, p);
    }

    /// @dev Separate frame so `createPresale`'s calldata args stay under the Yul stack limit.
    function _spawn(string calldata name, string calldata ticker, Presale.Init memory p)
        internal
        returns (address presale)
    {
        Presale sale = new Presale();
        PenguinToken token = new PenguinToken();
        p.token = address(token);
        token.initialize(name, ticker, address(sale), p.totalSupply);
        sale.initialize(p);

        presale = address(sale);
        isPresale[presale] = true;
        tokenOf[presale] = address(token);
        allPresales.push(presale);
        emit PresaleCreated(presale, msg.sender, address(token), name, ticker);
        _sendEth(penguinProtocol, msg.value);
    }

    function allPresalesLength() external view returns (uint256) {
        return allPresales.length;
    }

    function launchFee() public view returns (uint256) {
        return LibMath.presaleLaunchFee(production);
    }

    /// @notice Current create-time soft-cap floor. Test: 0.00001 ETH. Prod: 0.25 ETH.
    function minSoftCap() public view returns (uint256) {
        return LibMath.minSoftCap(production);
    }

    /// @notice Permanently switch this factory to the production create fee and min soft cap.
    function lockProduction() external onlyOwner {
        require(!production, "PRODUCTION");
        production = true;
        emit ProductionLocked();
    }

    function setPenguinProtocol(address penguinProtocol_) external onlyOwner {
        require(penguinProtocol_ != address(0), "PENGUIN_PROTOCOL");
        penguinProtocol = penguinProtocol_;
        emit PenguinProtocolUpdated(penguinProtocol_);
    }

    function transferOwnership(address next) external onlyOwner {
        require(next != address(0), "OWNER");
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH_TRANSFER");
    }
}
