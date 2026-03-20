// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

interface IMorphoOracle {
    /// @notice Returns the collateral price scaled for loan-to-value math.
    function price() external view returns (uint256);
}
