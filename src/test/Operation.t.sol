// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Setup, ERC20} from "./utils/Setup.sol";
import {ILiquidator} from "../interfaces/ILiquidator.sol";
import {IPawnBroker} from "../interfaces/IPawnBroker.sol";

contract ReentrantLiquidator is ILiquidator {
    IPawnBroker public immutable strategy;
    ERC20 public immutable asset;

    constructor(IPawnBroker _strategy) {
        strategy = _strategy;
        asset = ERC20(_strategy.asset());
    }

    function execute(uint256 _repayAmount) external {
        asset.approve(address(strategy), type(uint256).max);
        strategy.liquidate(_repayAmount, address(this), bytes("reenter"));
    }

    function liquidateCallback(address, address, uint256, uint256 _amountNeeded, bytes calldata _data) external {
        require(msg.sender == address(strategy), "not strategy");
        if (_data.length != 0) {
            strategy.liquidate(_amountNeeded, address(this), bytes(""));
        }
    }
}

contract OperationTest is Setup {
    function test_setupStrategyOK() public {
        assertTrue(address(strategy) != address(0));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertEq(strategy.BORROWER(), borrower);
        assertEq(strategy.COLLATERAL_ASSET(), address(collateral));
        assertEq(address(strategy.ORACLE()), address(collateralOracle));
        assertEq(strategy.LLTV(), lltv);
        assertEq(strategy.rate(), rate);
        assertEq(strategy.pendingRate(), 0);
        assertEq(strategy.pendingRateEffectiveTime(), 0);
        assertEq(strategy.liquidationBonusBps(), 100);
        assertEq(strategy.pendingLiquidationBonusBps(), 0);
        assertEq(strategy.pendingLiquidationBonusEffectiveTime(), 0);
        assertEq(strategy.CALL_DURATION(), callDuration);
        assertFalse(strategy.liquidators(liquidator));
        assertEq(strategy.totalCollateral(), 0);
        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), 0);
        assertEq(strategy.callDeadline(), 0);
        assertFalse(strategy.paused());
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
        assertEq(strategy.maxDebt(), amount);
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
        assertEq(strategy.maxDebt(), liquidity);
        assertEq(strategy.totalDebt(), borrowAmount);
        assertLe(strategy.currentLtv(), targetLtv);
        assertTrue(strategy.isHealthy());

        skip(30 days);

        uint256 repayAmount = strategy.totalDebt();
        uint256 interestAmount = repayAmount - borrowAmount;

        airdrop(asset, borrower, repayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmount);
        strategy.repay(repayAmount);
        strategy.withdrawCollateral(collateralAmount, borrower);
        vm.stopPrank();

        assertEq(strategy.totalCollateral(), 0);
        assertEq(strategy.maxDebt(), liquidity + interestAmount);
        assertEq(strategy.totalDebt(), 0);
        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.currentLtv(), 0);
        assertTrue(strategy.isHealthy());
    }

    function test_callDebtRatchetsMaxDebtAndAutoClearsWhenSatisfied() public {
        uint256 collateralAmount = defaultCollateralAmount();
        uint256 borrowAmount = defaultBorrowAmount(collateralAmount);
        uint256 liquidity = borrowAmount;
        uint256 callAmount = borrowAmount / 5;
        uint256 extraBorrowAmount = toAssetAmount(1);
        uint256 collateralWithdrawAmount = 1;

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(callAmount);

        assertEq(strategy.maxDebt(), borrowAmount - callAmount);

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
        strategy.withdrawCollateral(collateralWithdrawAmount, borrower);
        vm.expectRevert("max debt");
        strategy.borrow(extraBorrowAmount, borrower);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), callAmount);
        assertEq(strategy.callDeadline(), 0);
        assertEq(strategy.maxDebt(), borrowAmount - callAmount);
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
        airdrop(asset, liquidator, borrowAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), borrowAmount);
        (uint256 actualRepaid,) = strategy.liquidate(borrowAmount, liquidator, bytes(""));
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), callAmount);
        assertEq(strategy.callDeadline(), 0);
        assertEq(actualRepaid, callAmount);
        assertLt(strategy.totalCollateral(), collateralAmount);
        assertLt(strategy.totalDebt(), borrowAmount);
    }

    function test_liquidationCallbackCannotReenter() public {
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

        ReentrantLiquidator reentrantLiquidator = new ReentrantLiquidator(strategy);
        setLiquidator(address(reentrantLiquidator), true);
        airdrop(asset, address(reentrantLiquidator), borrowAmount);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        reentrantLiquidator.execute(callAmount);
    }
}
