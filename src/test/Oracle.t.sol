// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Setup} from "./utils/Setup.sol";

contract OracleTest is Setup {
    function test_oracleCapsBorrowAtLltv() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmountAtLltv = borrowAmountForLtv(collateralAmount, lltv);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        vm.expectRevert("position unhealthy");
        strategy.borrow(borrowAmountAtLltv + 1, borrower);

        vm.prank(borrower);
        strategy.borrow(borrowAmountAtLltv, borrower);
    }

    function test_liveOracleLiquidationSeizesExpectedCollateral() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);
        uint256 liquidateAmount = borrowAmount / 5;

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(liquidateAmount);

        skip(callDuration + 1);

        setLiquidator(liquidator, true);
        uint256 debtBeforeLiquidation = strategy.totalDebt();
        uint256 expectedCollateralSeized = Math.mulDiv(
            liquidateAmount,
            1e36,
            collateralOracle.price()
        );

        airdrop(asset, liquidator, liquidateAmount);
        vm.startPrank(liquidator);
        asset.approve(address(strategy), liquidateAmount);
        strategy.liquidate(liquidateAmount, liquidator);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), debtBeforeLiquidation - liquidateAmount);
        assertEq(
            strategy.totalCollateral(),
            collateralAmount - expectedCollateralSeized
        );
    }
}
