// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

interface IMorphoOracle {
    function price() external view returns (uint256);
}
