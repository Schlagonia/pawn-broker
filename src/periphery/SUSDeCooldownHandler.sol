// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ICooldownHandler} from "../interfaces/ICooldownHandler.sol";

interface ISUSDe {
    function cooldownShares(uint256 _shares) external returns (uint256 assets);

    function unstake(address _receiver) external;
}

/// @notice PawnBroker cooldown adapter for Ethena sUSDe collateral.
contract SUSDeCooldownHandler is ICooldownHandler {
    address public immutable pawnBroker;
    address public immutable override collateralAsset;
    address public immutable override asset;

    uint256 public override pendingCollateral;
    uint256 public pendingAssets;

    modifier onlyPawnBroker() {
        require(msg.sender == pawnBroker, "not broker");
        _;
    }

    constructor(address _collateralAsset, address _pawnBroker) {
        require(_collateralAsset != address(0), "zero collateral");
        require(_pawnBroker != address(0), "zero broker");

        pawnBroker = _pawnBroker;
        collateralAsset = _collateralAsset;
        asset = IERC4626(_collateralAsset).asset();
    }

    function cooldown(uint256 _collateralAmount) external override onlyPawnBroker returns (uint256 queuedCollateral) {
        require(_collateralAmount > 0, "zero amount");
        require(pendingCollateral == 0, "pending cooldown");

        pendingAssets = ISUSDe(collateralAsset).cooldownShares(_collateralAmount);
        pendingCollateral = _collateralAmount;

        return _collateralAmount;
    }

    function claim()
        external
        override
        onlyPawnBroker
        returns (uint256 claimedAssets, uint256 finalizedCollateral)
    {
        finalizedCollateral = pendingCollateral;
        require(finalizedCollateral > 0, "no pending cooldown");

        uint256 _balanceBefore = ERC20(asset).balanceOf(msg.sender);
        ISUSDe(collateralAsset).unstake(msg.sender);
        claimedAssets = ERC20(asset).balanceOf(msg.sender) - _balanceBefore;

        pendingCollateral = 0;
        pendingAssets = 0;
    }

    function cancel(uint256) external pure override returns (uint256) {
        revert("unsupported");
    }
}
