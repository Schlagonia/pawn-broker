// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

interface ILiquidator {
    function liquidateCallback(
        address _token,
        address _sender,
        uint256 _amount,
        uint256 _amountNeeded,
        bytes calldata _data
    ) external;
}
