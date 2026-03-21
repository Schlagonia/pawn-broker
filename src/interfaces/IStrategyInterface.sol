// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    /// @notice Sets whether an address may deposit into the strategy.
    function setAllowed(address _owner, bool _isAllowed) external;

    /// @notice Sets whether an address may liquidate unhealthy or overdue debt.
    function setLiquidator(address _liquidator, bool _isAllowed) external;

    /// @notice Posts additional collateral for the borrower position.
    function postCollateral(uint256 _amount) external;

    /// @notice Borrows strategy assets against posted collateral.
    function borrow(uint256 _amount, address _receiver) external;

    /// @notice Repays outstanding debt.
    function repay(uint256 _amount) external returns (uint256 actualRepaid);

    /// @notice Withdraws posted collateral when no debt call is active.
    function withdrawCollateral(uint256 _amount, address _receiver) external;

    /// @notice Calls debt and starts the repayment deadline window.
    function callDebt(uint256 _amount) external;

    /// @notice Repays debt and seizes collateral from a liquidatable position.
    function liquidate(
        uint256 _repayAmount,
        address _receiver
    ) external returns (uint256 actualRepaid, uint256 collateralSeized);

    /// @notice Returns current debt including accrued but unapplied interest.
    function totalDebt() external view returns (uint256);

    /// @notice Returns the amount of collateral currently posted.
    function totalCollateral() external view returns (uint256);

    /// @notice Returns the current global debt ceiling enforced on new borrowing.
    function maxDebt() external view returns (uint256);

    /// @notice Returns the remaining debt reduction required by an active debt call.
    function calledDebtAmount() external view returns (uint256);

    /// @notice Returns the called debt already repaid and still sitting idle in the strategy.
    function repaidCalledDebt() external view returns (uint256);

    /// @notice Returns the active call deadline, or zero when no call is active.
    function callDeadline() external view returns (uint256);

    /// @notice Returns whether the current position is within the configured LLTV.
    function isSolvent() external view returns (bool);

    /// @notice Returns whether the current position is solvent and not overdue.
    function isHealthy() external view returns (bool);

    /// @notice Returns the current loan-to-value ratio scaled by `1e18`.
    function currentLtv() external view returns (uint256);
}
