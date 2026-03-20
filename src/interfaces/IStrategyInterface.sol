// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function setAllowed(address owner, bool isAllowed) external;

    function setLiquidator(address liquidator, bool isAllowed) external;

    function postCollateral(uint256 amount) external;

    function borrow(uint256 amount, address receiver) external;

    function repay(uint256 amount) external returns (uint256 actualRepaid);

    function withdrawCollateral(uint256 amount, address receiver) external;

    function callDebt(uint256 amount) external;

    function clearCall() external;

    function liquidate(
        uint256 repayAmount,
        address receiver
    ) external returns (uint256 actualRepaid, uint256 collateralSeized);

    function totalDebt() external view returns (uint256);

    function totalCollateral() external view returns (uint256);

    function calledDebtAmount() external view returns (uint256);

    function callDeadline() external view returns (uint256);

    function isSolvent() external view returns (bool);

    function isHealthy() external view returns (bool);

    function currentLtv() external view returns (uint256);
}
