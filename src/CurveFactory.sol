// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CurveLaunch} from "./CurveLaunch.sol";
import {LibMath} from "./libraries/LibMath.sol";

/// @title CurveFactory
/// @notice Permissionless quick-launch factory. Deployer is `owner` and can
///         `setPenguinProtocol` (live fee wallet for all listings from this factory),
///         `lockProduction` (one-way test → prod create/curve scale), or
///         `transferOwnership`. Nothing else is admin-gated.
contract CurveFactory {
    event LaunchCreated(address indexed launch, address indexed creator, string name, string ticker);
    event PenguinProtocolUpdated(address indexed penguinProtocol);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProductionLocked();

    address public immutable v4Graduate;
    address public penguinProtocol;
    address public owner;
    /// @dev False at deploy (cheap live-test fees). `lockProduction` is permanent.
    bool public production;

    mapping(address => bool) public isLaunch;
    address[] public allLaunches;

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

    function createLaunch(string calldata name, string calldata ticker, string calldata imageUrl)
        external
        payable
        returns (address launch)
    {
        require(msg.value == launchFee(), "LAUNCH_FEE");
        CurveLaunch deployed = new CurveLaunch();
        deployed.initialize(msg.sender, v4Graduate, name, ticker, imageUrl, phantomQuote(), graduationQuote());
        launch = address(deployed);
        isLaunch[launch] = true;
        allLaunches.push(launch);
        emit LaunchCreated(launch, msg.sender, name, ticker);
        _sendEth(penguinProtocol, msg.value);
    }

    function allLaunchesLength() external view returns (uint256) {
        return allLaunches.length;
    }

    function launchFee() public view returns (uint256) {
        return LibMath.launchFee(production);
    }

    function phantomQuote() public view returns (uint256) {
        return LibMath.phantomQuote(production);
    }

    function graduationQuote() public view returns (uint256) {
        return LibMath.graduationQuote(production);
    }

    /// @notice Permanently switch this factory to production create + curve scale.
    ///         In-flight listings keep the phantom/graduation snapshotted at their create.
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
