// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICooldownHandler} from "../interfaces/ICooldownHandler.sol";

interface ISyrupPool is IERC4626 {
    function requestRedeem(uint256 _shares, address _owner) external returns (uint256 exitShares);

    function removeShares(uint256 _shares, address _owner) external returns (uint256 removedShares);
}

/// @notice PawnBroker cooldown adapter for Maple Syrup collateral.
contract SyrupCooldownHandler is ICooldownHandler {
    using SafeERC20 for ERC20;

    address public immutable pawnBroker;
    address public immutable override collateralAsset;
    address public immutable override asset;

    uint256 public override pendingCollateral;

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

        queuedCollateral = ISyrupPool(collateralAsset).requestRedeem(_collateralAmount, address(this));
        require(queuedCollateral > 0, "nothing queued");

        pendingCollateral += queuedCollateral;
    }

    function claim()
        external
        override
        onlyPawnBroker
        returns (uint256 claimedAssets, uint256 finalizedCollateral)
    {
        claimedAssets = ERC20(asset).balanceOf(address(this));
        require(claimedAssets > 0, "nothing claimed");

        finalizedCollateral = Math.min(pendingCollateral, IERC4626(collateralAsset).convertToShares(claimedAssets));
        require(finalizedCollateral > 0, "no finalized collateral");

        pendingCollateral -= finalizedCollateral;
        ERC20(asset).safeTransfer(msg.sender, claimedAssets);
    }

    function cancel(uint256 _collateralAmount) external override onlyPawnBroker returns (uint256 returnedCollateral) {
        uint256 _pendingCollateral = pendingCollateral;
        if (_collateralAmount == type(uint256).max) _collateralAmount = _pendingCollateral;
        require(_collateralAmount > 0, "zero amount");

        returnedCollateral = ISyrupPool(collateralAsset).removeShares(_collateralAmount, address(this));
        require(returnedCollateral > 0, "nothing returned");

        pendingCollateral = returnedCollateral >= _pendingCollateral ? 0 : _pendingCollateral - returnedCollateral;

        ERC20(collateralAsset).safeTransfer(msg.sender, returnedCollateral);
    }
}
