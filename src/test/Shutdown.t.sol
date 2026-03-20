// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup, IStrategyInterface} from "./utils/Setup.sol";

contract ShutdownTest is Setup {
    function test_shutdownBlocksNewDeposits() public {
        uint256 amount = toAssetAmount(100_000);

        airdrop(asset, user, amount);
        setAllowed(user, true);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.startPrank(user);
        asset.approve(address(strategy), amount);
        vm.expectRevert();
        strategy.deposit(amount, user);
        vm.stopPrank();
    }

    function test_shutdownBlocksNewBorrowButAllowsRepayAndWithdraw() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);
        uint256 extraBorrowAmount = toAssetAmount(1);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(borrower);
        vm.expectRevert("shutdown");
        strategy.borrow(extraBorrowAmount, borrower);

        uint256 repayAmount = strategy.totalDebt();

        airdrop(asset, borrower, repayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmount);
        strategy.repay(repayAmount);
        strategy.withdrawCollateral(collateralAmount, borrower);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.totalCollateral(), 0);
        assertTrue(strategy.isHealthy());
        assertEq(strategy.currentLtv(), 0);
    }
}
