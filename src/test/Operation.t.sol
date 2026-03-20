// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function test_setupStrategyOK() public {
        assertTrue(address(strategy) != address(0));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertEq(strategy.totalCollateral(), 0);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.calledDebtAmount(), 0);
        assertEq(strategy.callDeadline(), 0);
        assertTrue(strategy.isSolvent());
        assertTrue(strategy.isHealthy());
        assertEq(strategy.currentLtv(), 0);
    }

    function test_onlyAllowedCanDeposit() public {
        uint256 amount = toAssetAmount(100_000);

        airdrop(asset, stranger, amount);

        vm.startPrank(stranger);
        asset.approve(address(strategy), amount);
        vm.expectRevert();
        strategy.deposit(amount, stranger);
        vm.stopPrank();

        setAllowed(stranger, true);

        vm.startPrank(stranger);
        strategy.deposit(amount, stranger);
        vm.stopPrank();

        assertEq(strategy.totalAssets(), amount);
    }

    function test_borrowRepayWithdrawFlow() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        assertEq(strategy.totalCollateral(), collateralAmount);
        assertEq(strategy.totalDebt(), borrowAmount);
        assertLe(strategy.currentLtv(), targetLtv);
        assertTrue(strategy.isHealthy());

        skip(30 days);

        uint256 repayAmount = strategy.totalDebt();

        airdrop(asset, borrower, repayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmount);
        strategy.repay(repayAmount);
        strategy.withdrawCollateral(collateralAmount, borrower);
        vm.stopPrank();

        assertEq(strategy.totalCollateral(), 0);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.calledDebtAmount(), 0);
        assertEq(strategy.currentLtv(), 0);
        assertTrue(strategy.isHealthy());
    }

    function test_callDebtBlocksBorrowAndWithdrawUntilCleared() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);
        uint256 callAmount = borrowAmount / 5;
        uint256 extraBorrowAmount = toAssetAmount(1);
        uint256 collateralWithdrawAmount = toCollateralAmount(1);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(callAmount);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.borrow(extraBorrowAmount, borrower);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.withdrawCollateral(collateralWithdrawAmount, borrower);

        airdrop(asset, borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.expectRevert("debt called");
        strategy.borrow(extraBorrowAmount, borrower);
        vm.expectRevert("debt called");
        strategy.withdrawCollateral(collateralWithdrawAmount, borrower);
        vm.stopPrank();

        assertEq(strategy.calledDebtAmount(), 0);
        assertGt(strategy.callDeadline(), 0);

        vm.prank(management);
        strategy.clearCall();

        vm.prank(borrower);
        strategy.borrow(extraBorrowAmount, borrower);
    }

    function test_overdueCallCanBeLiquidated() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);
        uint256 callAmount = borrowAmount / 5;

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(callAmount);

        skip(callDuration + 1);

        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, callAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), callAmount);
        strategy.liquidate(callAmount, liquidator);
        vm.stopPrank();

        assertEq(strategy.calledDebtAmount(), 0);
        assertLt(strategy.totalCollateral(), collateralAmount);
        assertLt(strategy.totalDebt(), borrowAmount);
    }
}
