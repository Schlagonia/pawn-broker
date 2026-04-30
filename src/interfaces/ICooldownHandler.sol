// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

interface ICooldownHandler {
    function collateralAsset() external view returns (address);

    function asset() external view returns (address);

    function pendingCollateral() external view returns (uint256);

    function cooldown(uint256 _collateralAmount) external returns (uint256 queuedCollateral);

    function claim() external returns (uint256 claimedAssets, uint256 finalizedCollateral);

    function cancel(uint256 _collateralAmount) external returns (uint256 returnedCollateral);
}
