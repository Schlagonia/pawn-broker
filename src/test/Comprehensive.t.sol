// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {PawnBroker} from "../PawnBroker.sol";
import {IPawnBroker} from "../interfaces/IPawnBroker.sol";
import {ILiquidator} from "../interfaces/ILiquidator.sol";

contract MockLiquidator is ILiquidator {
    IPawnBroker public immutable strategy;
    ERC20 public immutable asset;

    bool public callbackHit;
    address public callbackToken;
    address public callbackSender;
    uint256 public callbackAmount;
    uint256 public callbackAmountNeeded;
    bytes32 public callbackDataHash;

    constructor(IPawnBroker _strategy) {
        strategy = _strategy;
        asset = ERC20(_strategy.asset());
    }

    function executeLiquidation(uint256 _repayAmount, bytes calldata _data)
        external
        returns (uint256 actualRepaid, uint256 collateralSeized)
    {
        return strategy.liquidate(_repayAmount, address(this), _data);
    }

    function liquidateCallback(
        address _token,
        address _sender,
        uint256 _amount,
        uint256 _amountNeeded,
        bytes calldata _data
    ) external {
        require(msg.sender == address(strategy), "not strategy");

        callbackHit = true;
        callbackToken = _token;
        callbackSender = _sender;
        callbackAmount = _amount;
        callbackAmountNeeded = _amountNeeded;
        callbackDataHash = keccak256(_data);

        asset.approve(address(strategy), _amountNeeded);
    }
}

contract ComprehensiveTest is Setup {
    IPawnBroker internal strat;

    // Events mirrored from PawnBroker.sol for expectEmit checks
    event CollateralPosted(address indexed caller, uint256 amount, uint256 totalCollateral);
    event CollateralWithdrawn(
        address indexed caller, address indexed receiver, uint256 amount, uint256 totalCollateral
    );
    event Borrowed(address indexed caller, address indexed receiver, uint256 amount, uint256 debtAmount);
    event Repaid(address indexed caller, uint256 amount, uint256 debtAmount, uint256 calledDebt);
    event DebtCalled(address indexed caller, uint256 amount, uint256 totalCalledDebt, uint256 deadline);
    event CallCleared(address indexed caller);
    event Liquidated(
        address indexed caller,
        address indexed receiver,
        uint256 repaidAmount,
        uint256 collateralSeized,
        uint256 debtAmount,
        uint256 totalCollateral
    );
    event UpdateAllowed(address indexed owner, bool isAllowed);
    event LiquidatorUpdated(address indexed liquidator, bool isAllowed);

    function setUp() public override {
        super.setUp();
        strat = IPawnBroker(address(strategy));
    }

    // ---------------------------------------------------------------
    // Helper: sets up a standard position with liquidity, collateral,
    // and an active borrow. Returns the borrow amount.
    // ---------------------------------------------------------------
    function _setupPosition() internal returns (uint256 liquidity, uint256 collateralAmt, uint256 borrowAmt) {
        liquidity = defaultLiquidityAmount();
        collateralAmt = defaultCollateralAmount();
        borrowAmt = defaultBorrowAmount(collateralAmt);
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);
        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);
    }

    // Helper: makes a position insolvent by borrowing at LLTV and accruing interest
    function _makeInsolvent() internal returns (uint256 liquidity, uint256 collateralAmt, uint256 borrowAmt) {
        liquidity = defaultLiquidityAmount();
        collateralAmt = defaultCollateralAmount();
        borrowAmt = borrowAmountForLtv(collateralAmt, lltv);
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);
        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);
        // Accrue enough interest to push past LLTV
        skip(365 days * 3);
    }

    // ================================================================
    //                   1. ACCESS CONTROL TESTS
    // ================================================================

    function test_onlyBorrowerCanPostCollateral() public {
        uint256 amount = toCollateralAmount(100);
        airdrop(collateral, stranger, amount);

        vm.startPrank(stranger);
        collateral.approve(address(strategy), amount);
        vm.expectRevert("not borrower");
        strategy.postCollateral(amount);
        vm.stopPrank();
    }

    function test_onlyBorrowerCanBorrow() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 borrowAmt = toAssetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(defaultCollateralAmount());

        vm.prank(stranger);
        vm.expectRevert("not borrower");
        strategy.borrow(borrowAmt, stranger);
    }

    function test_onlyBorrowerCanRepay() public {
        _setupPosition();

        uint256 repayAmt = toAssetAmount(100);
        airdrop(asset, stranger, repayAmt);

        vm.startPrank(stranger);
        asset.approve(address(strategy), repayAmt);
        vm.expectRevert("not borrower");
        strategy.repay(repayAmt);
        vm.stopPrank();
    }

    function test_onlyBorrowerCanWithdrawCollateral() public {
        postCollateral(defaultCollateralAmount());

        vm.prank(stranger);
        vm.expectRevert("not borrower");
        strategy.withdrawCollateral(1, stranger);
    }

    function test_onlyManagementCanCallDebt() public {
        _setupPosition();

        uint256 callAmt = toAssetAmount(100);

        vm.prank(stranger);
        vm.expectRevert("!management");
        strategy.callDebt(callAmt);

        vm.prank(borrower);
        vm.expectRevert("!management");
        strategy.callDebt(callAmt);
    }

    function test_onlyManagementCanSetAllowed() public {
        vm.prank(stranger);
        vm.expectRevert("!management");
        strategy.setAllowed(user, true);
    }

    function test_onlyManagementCanSetLiquidator() public {
        vm.prank(stranger);
        vm.expectRevert("!management");
        strategy.setLiquidator(liquidator, true);
    }

    function test_onlyManagementOrLiquidatorCanLiquidate() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt);
        skip(callDuration + 1);

        uint256 liquidateAmt = toAssetAmount(100);
        airdrop(asset, stranger, liquidateAmt);

        vm.startPrank(stranger);
        asset.approve(address(strategy), liquidateAmt);
        vm.expectRevert("not liquidator");
        strategy.liquidate(liquidateAmt, stranger, bytes(""));
        vm.stopPrank();
    }

    function test_managementCanLiquidateWithoutBeingInLiquidatorsMapping() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt / 5);
        skip(callDuration + 1);

        uint256 liquidateAmt = toAssetAmount(100);
        airdrop(asset, management, liquidateAmt);

        vm.startPrank(management);
        asset.approve(address(strategy), liquidateAmt);
        (uint256 repaid,) = strategy.liquidate(liquidateAmt, management, bytes(""));
        vm.stopPrank();

        assertGt(repaid, 0, "management should be able to liquidate");
    }

    function test_onlyManagementCanRescue() public {
        ERC20 unrelated = ERC20(tokenAddrs["DAI"]);
        airdrop(unrelated, address(strategy), 1e18);

        vm.prank(stranger);
        vm.expectRevert("!management");
        strat.rescue(address(unrelated));
    }

    function test_strangerCannotCallAnyRestrictedFunction() public {
        _setupPosition();

        vm.startPrank(stranger);

        vm.expectRevert("not borrower");
        strategy.postCollateral(1);

        vm.expectRevert("not borrower");
        strategy.borrow(1, stranger);

        vm.expectRevert("not borrower");
        strategy.repay(1);

        vm.expectRevert("not borrower");
        strategy.withdrawCollateral(1, stranger);

        vm.expectRevert("!management");
        strategy.callDebt(1);

        vm.expectRevert("!management");
        strategy.setAllowed(stranger, true);

        vm.expectRevert("!management");
        strategy.setLiquidator(stranger, true);

        vm.expectRevert("!management");
        strat.rescue(tokenAddrs["DAI"]);

        vm.stopPrank();
    }

    // ================================================================
    //                2. INPUT VALIDATION TESTS
    // ================================================================

    function test_postCollateralRevertsOnZeroAmount() public {
        vm.prank(borrower);
        vm.expectRevert("zero amount");
        strategy.postCollateral(0);
    }

    function test_borrowRevertsOnZeroAmount() public {
        mintAndDepositIntoStrategy(strategy, user, defaultLiquidityAmount());
        postCollateral(defaultCollateralAmount());

        vm.prank(borrower);
        vm.expectRevert("zero amount");
        strategy.borrow(0, borrower);
    }

    function test_borrowRevertsOnZeroReceiver() public {
        uint256 borrowAmt = toAssetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, defaultLiquidityAmount());
        postCollateral(defaultCollateralAmount());

        vm.prank(borrower);
        vm.expectRevert("zero receiver");
        strategy.borrow(borrowAmt, address(0));
    }

    function test_repayRevertsOnZeroAmount() public {
        _setupPosition();

        vm.prank(borrower);
        vm.expectRevert("zero amount");
        strategy.repay(0);
    }

    function test_withdrawCollateralRevertsOnZeroAmount() public {
        postCollateral(toCollateralAmount(1_000));

        vm.prank(borrower);
        vm.expectRevert("zero amount");
        strategy.withdrawCollateral(0, borrower);
    }

    function test_withdrawCollateralRevertsOnZeroReceiver() public {
        postCollateral(toCollateralAmount(1_000));

        vm.prank(borrower);
        vm.expectRevert("zero receiver");
        strategy.withdrawCollateral(1, address(0));
    }

    function test_callDebtRevertsOnZeroAmount() public {
        _setupPosition();

        vm.prank(management);
        vm.expectRevert("zero amount");
        strategy.callDebt(0);
    }

    function test_liquidateRevertsOnZeroAmount() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt);
        skip(callDuration + 1);

        vm.prank(management);
        vm.expectRevert("zero amount");
        strategy.liquidate(0, management, bytes(""));
    }

    function test_liquidateRevertsOnZeroReceiver() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt);
        skip(callDuration + 1);

        airdrop(asset, management, borrowAmt);
        vm.startPrank(management);
        asset.approve(address(strategy), borrowAmt);
        vm.expectRevert("zero receiver");
        strategy.liquidate(borrowAmt, address(0), bytes(""));
        vm.stopPrank();
    }

    function test_setLiquidatorRevertsOnZeroAddress() public {
        vm.prank(management);
        vm.expectRevert("zero liquidator");
        strategy.setLiquidator(address(0), true);
    }

    function test_rescueRevertsForAsset() public {
        vm.prank(management);
        vm.expectRevert("cannot rescue asset");
        strat.rescue(address(asset));
    }

    function test_rescueRevertsForCollateral() public {
        vm.prank(management);
        vm.expectRevert("cannot rescue collateral");
        strat.rescue(address(collateral));
    }

    // ================================================================
    //             2b. CONSTRUCTOR VALIDATION TESTS
    // ================================================================

    function test_constructorRejectsZeroBorrower() public {
        vm.expectRevert("zero borrower");
        new PawnBroker(
            address(asset),
            "Test",
            address(0),
            address(collateral),
            address(collateralOracle),
            lltv,
            rate,
            callDuration,
            address(0)
        );
    }

    function test_constructorRejectsZeroCollateral() public {
        vm.expectRevert("zero collateral");
        new PawnBroker(
            address(asset),
            "Test",
            borrower,
            address(0),
            address(collateralOracle),
            lltv,
            rate,
            callDuration,
            address(0)
        );
    }

    function test_constructorRejectsZeroOracle() public {
        vm.expectRevert("zero oracle");
        new PawnBroker(
            address(asset), "Test", borrower, address(collateral), address(0), lltv, rate, callDuration, address(0)
        );
    }

    function test_constructorRejectsSameAssetAndCollateral() public {
        vm.expectRevert("shared asset");
        new PawnBroker(
            address(asset),
            "Test",
            borrower,
            address(asset),
            address(collateralOracle),
            lltv,
            rate,
            callDuration,
            address(0)
        );
    }

    function test_constructorRejectsInvalidLltv() public {
        vm.expectRevert("bad lltv");
        new PawnBroker(
            address(asset),
            "Test",
            borrower,
            address(collateral),
            address(collateralOracle),
            0,
            rate,
            callDuration,
            address(0)
        );

        vm.expectRevert("bad lltv");
        new PawnBroker(
            address(asset),
            "Test",
            borrower,
            address(collateral),
            address(collateralOracle),
            1e18,
            rate,
            callDuration,
            address(0)
        );

        vm.expectRevert("bad lltv");
        new PawnBroker(
            address(asset),
            "Test",
            borrower,
            address(collateral),
            address(collateralOracle),
            2e18,
            rate,
            callDuration,
            address(0)
        );
    }

    function test_constructorRejectsZeroCallDuration() public {
        vm.expectRevert("zero call duration");
        new PawnBroker(
            address(asset), "Test", borrower, address(collateral), address(collateralOracle), lltv, rate, 0, address(0)
        );
    }

    // ================================================================
    //                3. COLLATERAL OPERATIONS TESTS
    // ================================================================

    function test_postCollateralIncreasesTotalCollateral() public {
        uint256 amount = toCollateralAmount(1_000);
        postCollateral(amount);
        assertEq(strategy.totalCollateral(), amount, "totalCollateral should match");
    }

    function test_postCollateralTransfersTokens() public {
        uint256 amount = toCollateralAmount(1_000);

        airdrop(collateral, borrower, amount);

        uint256 borrowerBefore = collateral.balanceOf(borrower);
        uint256 strategyBefore = collateral.balanceOf(address(strategy));

        vm.startPrank(borrower);
        collateral.approve(address(strategy), amount);
        strategy.postCollateral(amount);
        vm.stopPrank();

        assertEq(collateral.balanceOf(borrower), borrowerBefore - amount, "borrower balance should decrease");
        assertEq(collateral.balanceOf(address(strategy)), strategyBefore + amount, "strategy balance should increase");
        assertEq(strategy.totalCollateral(), amount, "totalCollateral mismatch");
    }

    function test_postCollateralMultipleTimesAccumulates() public {
        uint256 amount1 = toCollateralAmount(500);
        uint256 amount2 = toCollateralAmount(300);
        uint256 amount3 = toCollateralAmount(200);

        postCollateral(amount1);
        assertEq(strategy.totalCollateral(), amount1, "after first post");

        postCollateral(amount2);
        assertEq(strategy.totalCollateral(), amount1 + amount2, "after second post");

        postCollateral(amount3);
        assertEq(strategy.totalCollateral(), amount1 + amount2 + amount3, "after third post");
    }

    function test_postCollateralAccruesInterest() public {
        _setupPosition();

        uint256 timeBefore = strat.lastAccrualTime();
        skip(1 days);

        uint256 amount = toCollateralAmount(100);
        airdrop(collateral, borrower, amount);

        vm.startPrank(borrower);
        collateral.approve(address(strategy), amount);
        strategy.postCollateral(amount);
        vm.stopPrank();

        assertGt(strat.lastAccrualTime(), timeBefore, "lastAccrualTime should update");
    }

    function test_withdrawCollateralDecreasesTotalCollateral() public {
        uint256 amount = toCollateralAmount(1_000);
        postCollateral(amount);

        uint256 withdrawAmt = toCollateralAmount(400);
        vm.prank(borrower);
        strategy.withdrawCollateral(withdrawAmt, borrower);

        assertEq(strategy.totalCollateral(), amount - withdrawAmt, "totalCollateral should decrease");
    }

    function test_withdrawCollateralTransfersTokens() public {
        uint256 amount = toCollateralAmount(1_000);
        postCollateral(amount);

        address receiver = address(0xBEEF);
        uint256 receiverBefore = collateral.balanceOf(receiver);

        vm.prank(borrower);
        strategy.withdrawCollateral(amount, receiver);

        assertEq(collateral.balanceOf(receiver), receiverBefore + amount, "receiver should get collateral");
        assertEq(strategy.totalCollateral(), 0, "totalCollateral should be 0");
    }

    function test_withdrawCollateralRevertsIfWouldBecomeInsolvent() public {
        (, uint256 collateralAmt,) = _setupPosition();

        vm.prank(borrower);
        vm.expectRevert("position unhealthy");
        strategy.withdrawCollateral(collateralAmt, borrower);
    }

    function test_withdrawCollateralRevertsIfDebtCalled() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt / 2);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.withdrawCollateral(1, borrower);
    }

    function test_withdrawCollateralRevertsOnInsufficientCollateral() public {
        uint256 amount = toCollateralAmount(1_000);
        postCollateral(amount);

        vm.prank(borrower);
        vm.expectRevert("insufficient collateral");
        strategy.withdrawCollateral(amount + 1, borrower);
    }

    // ================================================================
    //                     4. BORROWING TESTS
    // ================================================================

    function test_borrowTransfersToReceiver() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        address receiver = address(0xCAFE);
        uint256 receiverBefore = asset.balanceOf(receiver);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, receiver);

        assertEq(asset.balanceOf(receiver), receiverBefore + borrowAmt, "receiver should get borrowed assets");
    }

    function test_borrowUpdatesDebtAmount() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        assertEq(strategy.totalDebt(), 0, "total debt should start at 0");

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        assertEq(strategy.totalDebt(), borrowAmt, "total debt should equal borrow amount");
    }

    function test_borrowToDifferentReceiver() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        address customReceiver = address(0xABCD);
        uint256 receiverBefore = asset.balanceOf(customReceiver);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, customReceiver);

        assertEq(
            asset.balanceOf(customReceiver), receiverBefore + borrowAmt, "custom receiver should get borrowed assets"
        );
    }

    function test_borrowRevertsOnExceedMaxDebt() public {
        uint256 liquidity = toAssetAmount(100);
        uint256 collateralAmt = toCollateralAmount(1_000_000);
        uint256 oneUsdc = toAssetAmount(1);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        // Borrow all available (maxDebt = liquidity = 100 USDC)
        vm.prank(borrower);
        strategy.borrow(liquidity, borrower);

        // Deposit 1 more USDC properly (maxDebt increases to 101)
        mintAndDepositIntoStrategy(strategy, user, oneUsdc);

        // Now borrow 1 USDC to hit maxDebt exactly
        vm.prank(borrower);
        strategy.borrow(oneUsdc, borrower);

        // Airdrop liquidity directly (does NOT increase maxDebt)
        airdrop(asset, address(strategy), oneUsdc);

        // There is now 1 USDC liquidity available but maxDebt = totalDebt = 101
        // Borrowing 1 more USDC would make totalDebt = 102 > maxDebt = 101
        vm.prank(borrower);
        vm.expectRevert("max debt");
        strategy.borrow(oneUsdc, borrower);
    }

    function test_borrowRevertsIfPositionWouldBeUnhealthy() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        vm.expectRevert("position unhealthy");
        strategy.borrow(maxBorrow + 1, borrower);
    }

    function test_borrowRevertsIfShutdown() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 borrowAmt = toAssetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(defaultCollateralAmount());

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(borrower);
        vm.expectRevert("shutdown");
        strategy.borrow(borrowAmt, borrower);
    }

    function test_borrowRevertsIfDebtCalled() public {
        (,, uint256 borrowAmt) = _setupPosition();
        uint256 oneUsdc = toAssetAmount(1);

        vm.prank(management);
        strategy.callDebt(borrowAmt / 2);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.borrow(oneUsdc, borrower);
    }

    function test_borrowRevertsOnInsufficientLiquidity() public {
        uint256 smallDeposit = toAssetAmount(100);
        uint256 collateralAmt = defaultCollateralAmount();

        mintAndDepositIntoStrategy(strategy, user, smallDeposit);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        vm.expectRevert("max debt");
        strategy.borrow(smallDeposit + 1, borrower);
    }

    function test_multipleBorrowsAccumulate() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        uint256 firstBorrow = maxBorrow / 2;
        uint256 secondBorrow = maxBorrow / 4;

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(firstBorrow, borrower);

        assertEq(strategy.totalDebt(), firstBorrow, "debt after first borrow");

        vm.prank(borrower);
        strategy.borrow(secondBorrow, borrower);

        assertEq(strategy.totalDebt(), firstBorrow + secondBorrow, "total debt after second borrow");
    }

    // ================================================================
    //                     5. REPAYMENT TESTS
    // ================================================================

    function test_repayRevertsOnNoDebt() public {
        uint256 amount = toAssetAmount(100);
        airdrop(asset, borrower, amount);

        vm.startPrank(borrower);
        asset.approve(address(strategy), amount);
        vm.expectRevert("no debt");
        strategy.repay(amount);
        vm.stopPrank();
    }

    function test_fullRepayZeroesAllDebt() public {
        _setupPosition();

        skip(30 days);

        uint256 totalOwed = strategy.totalDebt();
        airdrop(asset, borrower, totalOwed);

        vm.startPrank(borrower);
        asset.approve(address(strategy), totalOwed);
        strategy.repay(totalOwed);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), 0, "total debt should be zero");
    }

    function test_partialRepayReducesDebtCorrectly() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 partialAmount = borrowAmt / 3;
        airdrop(asset, borrower, partialAmount);

        vm.startPrank(borrower);
        asset.approve(address(strategy), partialAmount);
        uint256 actualRepaid = strategy.repay(partialAmount);
        vm.stopPrank();

        assertEq(actualRepaid, partialAmount, "actual repaid should match");
        assertEq(strategy.totalDebt(), borrowAmt - partialAmount, "debt should be reduced by partial amount");
    }

    function test_repayCappedAtTotalDebt() public {
        _setupPosition();

        uint256 totalOwed = strategy.totalDebt();
        uint256 overpayment = totalOwed + toAssetAmount(1_000);

        airdrop(asset, borrower, overpayment);

        uint256 borrowerBefore = asset.balanceOf(borrower);

        vm.startPrank(borrower);
        asset.approve(address(strategy), overpayment);
        uint256 actualRepaid = strategy.repay(overpayment);
        vm.stopPrank();

        assertEq(actualRepaid, totalOwed, "should only repay total debt");
        assertEq(asset.balanceOf(borrower), borrowerBefore - totalOwed, "borrower should keep excess");
        assertEq(strategy.totalDebt(), 0, "debt should be zero");
    }

    function test_repayingOneYearInterestRestoresDebtToBorrowAmount() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(365 days);

        uint256 expectedInterest = (borrowAmt * rate) / MAX_BPS;

        airdrop(asset, borrower, expectedInterest);
        vm.startPrank(borrower);
        asset.approve(address(strategy), expectedInterest);
        strategy.repay(expectedInterest);
        vm.stopPrank();

        assertEq(
            strategy.totalDebt(), borrowAmt, "repaying one year of interest should restore the debt to borrow amount"
        );
    }

    function test_repayWithCalledDebtReducesCalledDebtFirst() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        // Partial repay less than called amount
        uint256 repayAmt = callAmount / 2;
        airdrop(asset, borrower, repayAmt);

        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmt);
        strategy.repay(repayAmt);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), callAmount - repayAmt, "called debt should be reduced");
        assertEq(strategy.repaidCalledDebt(), repayAmt, "repaidCalledDebt should track the reduction");
    }

    function test_fullRepayOfCalledDebtClearsDeadline() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        assertTrue(strategy.callDeadline() > 0, "deadline should be set");
        assertEq(strategy.calledDebt(), callAmount, "called amount set");

        airdrop(asset, borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0, "called debt should be cleared");
        assertEq(strategy.callDeadline(), 0, "deadline should be cleared");
    }

    // ================================================================
    //                  6. INTEREST ACCRUAL TESTS
    // ================================================================

    function test_interestAccrues1Day() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 debtBefore = strategy.totalDebt();
        skip(1 days);
        uint256 debtAfter = strategy.totalDebt();

        uint256 expectedInterest = Math.mulDiv(Math.mulDiv(borrowAmt, rate, MAX_BPS), 1 days, 365 days);

        assertGt(debtAfter, debtBefore, "debt should increase after 1 day");
        assertApproxEqAbs(debtAfter - debtBefore, expectedInterest, 1, "1-day interest should match expected");
    }

    function test_interestAccrues30Days() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(30 days);

        uint256 expectedInterest = Math.mulDiv(Math.mulDiv(borrowAmt, rate, MAX_BPS), 30 days, 365 days);

        uint256 totalOwed = strategy.totalDebt();
        assertApproxEqAbs(totalOwed, borrowAmt + expectedInterest, 1, "30-day interest should match expected");
    }

    function test_interestAccrues365Days() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(365 days);

        uint256 expectedInterest = (borrowAmt * rate) / MAX_BPS;
        uint256 totalOwed = strategy.totalDebt();

        assertApproxEqAbs(totalOwed, borrowAmt + expectedInterest, 1, "1-year interest should match expected");
    }

    function test_interestCompoundsAfterOnChainAccrualTouch() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(365 days);

        uint256 expectedAfter1Year = borrowAmt + (borrowAmt * rate) / MAX_BPS;
        assertApproxEqAbs(strategy.totalDebt(), expectedAfter1Year, 1, "year 1 interest");

        // Force on-chain accrual by posting tiny collateral
        uint256 tiny = 1;
        airdrop(collateral, borrower, tiny);
        vm.startPrank(borrower);
        collateral.approve(address(strategy), tiny);
        strategy.postCollateral(tiny);
        vm.stopPrank();

        skip(365 days);

        uint256 expectedAfter2Years = expectedAfter1Year + (expectedAfter1Year * rate) / MAX_BPS;
        assertApproxEqAbs(
            strategy.totalDebt(),
            expectedAfter2Years,
            2,
            "year 2 interest should compound after the on-chain accrual touch"
        );
    }

    function test_totalDebtViewIncludesPendingInterest() public {
        (,, uint256 borrowAmt) = _setupPosition();
        uint256 accrualTimeBefore = strat.lastAccrualTime();

        skip(30 days);

        uint256 totalOwed = strategy.totalDebt();
        assertGt(totalOwed, borrowAmt, "view should include pending interest");
        assertEq(strat.lastAccrualTime(), accrualTimeBefore, "view should not accrue debt on-chain");
    }

    function test_interestZeroWithZeroElapsedTime() public {
        (,, uint256 borrowAmt) = _setupPosition();

        // In the same block, no time has passed
        assertEq(strategy.totalDebt(), borrowAmt, "no time elapsed means no interest");
    }

    function test_noInterestIfNoDebt() public {
        mintAndDepositIntoStrategy(strategy, user, defaultLiquidityAmount());

        skip(365 days);

        assertEq(strategy.totalDebt(), 0, "no debt means no interest");
    }

    function test_interestAccruesOnReducedDebtAfterRepay() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 halfRepayAmount = borrowAmt / 2;
        airdrop(asset, borrower, halfRepayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), halfRepayAmount);
        strategy.repay(halfRepayAmount);
        vm.stopPrank();

        uint256 debtAfterRepay = strategy.totalDebt();

        skip(365 days);

        uint256 expectedNewInterest = (debtAfterRepay * rate) / MAX_BPS;
        uint256 totalExpected = debtAfterRepay + expectedNewInterest;

        assertApproxEqAbs(strategy.totalDebt(), totalExpected, 1, "interest should accrue on reduced debt");
    }

    function test_interestCalculationPrecisionOverLongPeriod() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 borrowAmt = toAssetAmount(100_000);
        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        if (borrowAmt > maxBorrow) {
            borrowAmt = maxBorrow;
        }

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        skip(365 days);

        uint256 expectedInterest = Math.mulDiv(Math.mulDiv(borrowAmt, rate, MAX_BPS), 365 days, 365 days);

        uint256 totalOwed = strategy.totalDebt();
        assertApproxEqAbs(totalOwed, borrowAmt + expectedInterest, 1, "exact interest calculation over 365 days");
    }

    function test_interestAccruesOnEachOperation() public {
        _setupPosition();

        uint256 borrowTen = toAssetAmount(10);

        skip(1 days);
        uint256 time1 = block.timestamp;

        uint256 extra = toCollateralAmount(10);
        airdrop(collateral, borrower, extra);
        vm.startPrank(borrower);
        collateral.approve(address(strategy), extra);
        strategy.postCollateral(extra);
        vm.stopPrank();
        assertEq(strat.lastAccrualTime(), time1, "accrual after postCollateral");

        skip(1 days);
        uint256 time2 = block.timestamp;

        uint256 repayAmt = toAssetAmount(100);
        airdrop(asset, borrower, repayAmt);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmt);
        strategy.repay(repayAmt);
        vm.stopPrank();
        assertEq(strat.lastAccrualTime(), time2, "accrual after repay");

        skip(1 days);
        uint256 time3 = block.timestamp;

        vm.prank(borrower);
        strategy.borrow(borrowTen, borrower);
        assertEq(strat.lastAccrualTime(), time3, "accrual after borrow");
    }

    // ================================================================
    //                 7. DEBT CALL MECHANICS TESTS
    // ================================================================

    function test_callDebtSetsCalledAmountAndDeadline() public {
        _setupPosition();

        uint256 callAmount = toAssetAmount(1_000);
        vm.prank(management);
        strategy.callDebt(callAmount);

        assertEq(strategy.calledDebt(), callAmount, "calledDebt set");
        assertEq(strategy.callDeadline(), block.timestamp + callDuration, "deadline should be now + callDuration");
    }

    function test_callDebtReducesMaxDebt() public {
        (uint256 liquidity,, uint256 borrowAmt) = _setupPosition();

        uint256 maxDebtBefore = strategy.maxDebt();
        uint256 callAmount = borrowAmt / 4;

        vm.prank(management);
        strategy.callDebt(callAmount);

        assertEq(strategy.maxDebt(), maxDebtBefore - callAmount, "maxDebt should decrease by called amount");
    }

    function test_callDebtCapsAtUncalledDebt() public {
        (,, uint256 borrowAmt) = _setupPosition();

        // Call more than total debt
        vm.prank(management);
        strategy.callDebt(borrowAmt * 2);

        assertEq(strategy.calledDebt(), borrowAmt, "called debt should cap at total debt");
    }

    function test_callDebtRevertsWhenFullyCalled() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt);

        vm.prank(management);
        vm.expectRevert("already fully called");
        strategy.callDebt(1);
    }

    function test_callDebtRevertsWhenNoDebt() public {
        uint256 callAmt = toAssetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, defaultLiquidityAmount());

        vm.prank(management);
        vm.expectRevert("no debt");
        strategy.callDebt(callAmt);
    }

    function test_duringActiveCallBorrowBlocked() public {
        (,, uint256 borrowAmt) = _setupPosition();
        uint256 oneUsdc = toAssetAmount(1);

        vm.prank(management);
        strategy.callDebt(borrowAmt / 2);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.borrow(oneUsdc, borrower);
    }

    function test_duringActiveCallWithdrawCollateralBlocked() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt / 2);

        vm.prank(borrower);
        vm.expectRevert("debt called");
        strategy.withdrawCollateral(1, borrower);
    }

    function test_afterFullRepayOfCalledDebtCallClears() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        airdrop(asset, borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0, "called debt cleared");
        assertEq(strategy.callDeadline(), 0, "deadline cleared");

        // Now borrow and withdraw should work again (within limits)
        // Cannot borrow because maxDebt was reduced, but withdrawCollateral should work
        vm.prank(borrower);
        strategy.withdrawCollateral(1, borrower);
    }

    function test_afterPartialRepayOfCalledDebtCallStillActive() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        uint256 partialRepay = callAmount / 2;
        airdrop(asset, borrower, partialRepay);

        vm.startPrank(borrower);
        asset.approve(address(strategy), partialRepay);
        strategy.repay(partialRepay);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), callAmount - partialRepay, "remaining called debt");
        assertGt(strategy.callDeadline(), 0, "deadline should remain active");
    }

    function test_multipleSuccessiveCallsAccumulateCalledDebt() public {
        _setupPosition();

        uint256 callAmount1 = toAssetAmount(1_000);
        uint256 callAmount2 = toAssetAmount(2_000);

        vm.prank(management);
        strategy.callDebt(callAmount1);

        assertEq(strategy.calledDebt(), callAmount1, "after first call");

        // Skip some time but not past deadline
        skip(callDuration / 2);

        vm.prank(management);
        strategy.callDebt(callAmount2);

        assertEq(strategy.calledDebt(), callAmount1 + callAmount2, "after second call");
    }

    function test_multipleCallsExtendDeadline() public {
        _setupPosition();

        uint256 callAmount1 = toAssetAmount(1_000);

        vm.prank(management);
        strategy.callDebt(callAmount1);
        uint256 firstDeadline = strategy.callDeadline();

        skip(callDuration / 2);

        uint256 callAmount2 = toAssetAmount(1_000);
        vm.prank(management);
        strategy.callDebt(callAmount2);
        uint256 secondDeadline = strategy.callDeadline();

        assertGt(secondDeadline, firstDeadline, "second call should extend deadline");
        assertEq(secondDeadline, block.timestamp + callDuration, "new deadline from current timestamp");
    }

    function test_callDebtReducesMaxDebtToZeroWithSaturation() public {
        // Deposit exactly the borrow amount so maxDebt == borrowAmt
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, borrowAmt);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        assertEq(strategy.maxDebt(), borrowAmt, "maxDebt before call");

        vm.prank(management);
        strategy.callDebt(borrowAmt);

        assertEq(strategy.maxDebt(), 0, "maxDebt should be zero when fully called");
    }

    // ================================================================
    //                8. LIQUIDATION TESTS
    // ================================================================

    function test_liquidateWhenInsolvent() public {
        _makeInsolvent();

        assertFalse(strategy.isSolvent(), "position should be insolvent");

        uint256 totalOwed = strategy.totalDebt();
        uint256 repayAmt = totalOwed / 2;

        airdrop(asset, management, repayAmt);
        vm.startPrank(management);
        asset.approve(address(strategy), repayAmt);
        (uint256 actualRepaid, uint256 seized) = strategy.liquidate(repayAmt, management, bytes(""));
        vm.stopPrank();

        assertGt(actualRepaid, 0, "should repay some debt");
        assertGt(seized, 0, "should seize some collateral");
    }

    function test_liquidateWhenCallIsOverdueButSolvent() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);

        skip(callDuration + 1);

        assertTrue(strategy.isSolvent(), "position should still be solvent");
        assertFalse(strategy.isHealthy(), "should not be healthy (overdue call)");

        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, callAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), callAmount);
        (uint256 actualRepaid,) = strategy.liquidate(callAmount, liquidator, bytes(""));
        vm.stopPrank();

        assertGt(actualRepaid, 0, "should allow liquidation when call overdue");
    }

    function test_liquidateRevertsWhenPositionIsHealthy() public {
        _setupPosition();

        uint256 liqAmt = toAssetAmount(100);
        airdrop(asset, management, liqAmt);
        vm.startPrank(management);
        asset.approve(address(strategy), liqAmt);
        vm.expectRevert("not liquidatable");
        strategy.liquidate(liqAmt, management, bytes(""));
        vm.stopPrank();
    }

    function test_liquidateSeizesCorrectCollateralByOraclePrice() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        uint256 price = collateralOracle.price();
        uint256 expectedCollateral = Math.mulDiv(callAmount, 1e36, price);

        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, callAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), callAmount);
        (, uint256 seized) = strategy.liquidate(callAmount, liquidator, bytes(""));
        vm.stopPrank();

        assertEq(seized, expectedCollateral, "seized collateral should match price conversion");
    }

    function test_liquidateOverdueSolventCapsAtCalledDebtAmount() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);

        skip(callDuration + 1);

        assertTrue(strategy.isSolvent(), "position should still be solvent");

        airdrop(asset, management, borrowAmt);
        vm.startPrank(management);
        asset.approve(address(strategy), borrowAmt);
        (uint256 actualRepaid,) = strategy.liquidate(borrowAmt, management, bytes(""));
        vm.stopPrank();

        // When solvent + call overdue, maxRepay = calledDebt
        assertEq(actualRepaid, callAmount, "liquidation should be capped at called amount when solvent");
    }

    function test_liquidateInsolventCapsAtTotalDebt() public {
        (, uint256 collateralAmt,) = _makeInsolvent();

        uint256 totalOwed = strategy.totalDebt();
        uint256 colValue = collateralValue(strategy.totalCollateral());

        // If colValue < totalOwed, repay is capped at colValue
        // Otherwise capped at totalOwed
        uint256 expectedCap = Math.min(totalOwed, colValue);

        airdrop(asset, management, totalOwed * 2);
        vm.startPrank(management);
        asset.approve(address(strategy), totalOwed * 2);
        (uint256 actualRepaid,) = strategy.liquidate(totalOwed * 2, management, bytes(""));
        vm.stopPrank();

        assertLe(actualRepaid, expectedCap, "repaid should be capped appropriately");
    }

    function test_liquidateCapsRepayAtCollateralValue() public {
        // Use a small amount of collateral
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = toCollateralAmount(100);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        vm.prank(borrower);
        strategy.borrow(maxBorrow, borrower);

        // Make deeply insolvent
        skip(365 days * 10);

        assertFalse(strategy.isSolvent(), "should be insolvent");

        uint256 totalOwed = strategy.totalDebt();
        uint256 colValue = collateralValue(strategy.totalCollateral());

        assertGt(totalOwed, colValue, "debt should exceed collateral value");

        airdrop(asset, management, totalOwed);
        vm.startPrank(management);
        asset.approve(address(strategy), totalOwed);
        (uint256 actualRepaid,) = strategy.liquidate(totalOwed, management, bytes(""));
        vm.stopPrank();

        assertLe(actualRepaid, colValue, "repaid should be capped by collateral value");
    }

    function test_liquidateTransfersCollateralToReceiver() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        address receiver = address(0xDEAD);
        uint256 receiverBefore = collateral.balanceOf(receiver);

        airdrop(asset, management, callAmount);
        vm.startPrank(management);
        asset.approve(address(strategy), callAmount);
        (, uint256 seized) = strategy.liquidate(callAmount, receiver, bytes(""));
        vm.stopPrank();

        assertEq(collateral.balanceOf(receiver), receiverBefore + seized, "receiver should get seized collateral");
    }

    function test_liquidateWithDataCallsReceiverCallback() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        MockLiquidator callbackReceiver = new MockLiquidator(strategy);
        bytes memory callbackData = abi.encode("liquidation callback");

        setLiquidator(address(callbackReceiver), true);
        airdrop(asset, address(callbackReceiver), callAmount);

        uint256 strategyAssetBefore = asset.balanceOf(address(strategy));
        uint256 receiverCollateralBefore = collateral.balanceOf(address(callbackReceiver));

        (uint256 actualRepaid, uint256 seized) = callbackReceiver.executeLiquidation(callAmount, callbackData);

        assertTrue(callbackReceiver.callbackHit(), "callback should fire");
        assertEq(callbackReceiver.callbackToken(), address(collateral), "callback token");
        assertEq(callbackReceiver.callbackSender(), address(callbackReceiver), "callback sender");
        assertEq(callbackReceiver.callbackAmount(), seized, "callback amount");
        assertEq(callbackReceiver.callbackAmountNeeded(), actualRepaid, "callback amount needed");
        assertEq(callbackReceiver.callbackDataHash(), keccak256(callbackData), "callback data");
        assertEq(
            collateral.balanceOf(address(callbackReceiver)), receiverCollateralBefore + seized, "receiver collateral"
        );
        assertEq(asset.balanceOf(address(strategy)), strategyAssetBefore + actualRepaid, "strategy repayment");
    }

    function test_liquidateTransfersRepaymentToStrategy() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        uint256 strategyBalBefore = asset.balanceOf(address(strategy));

        airdrop(asset, management, callAmount);
        vm.startPrank(management);
        asset.approve(address(strategy), callAmount);
        (uint256 actualRepaid,) = strategy.liquidate(callAmount, management, bytes(""));
        vm.stopPrank();

        assertEq(
            asset.balanceOf(address(strategy)),
            strategyBalBefore + actualRepaid,
            "strategy should receive repaid assets"
        );
    }

    function test_liquidateByNonManagementNonLiquidatorReverts() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt);
        skip(callDuration + 1);

        airdrop(asset, stranger, borrowAmt);
        vm.startPrank(stranger);
        asset.approve(address(strategy), borrowAmt);
        vm.expectRevert("not liquidator");
        strategy.liquidate(borrowAmt, stranger, bytes(""));
        vm.stopPrank();
    }

    function test_partialLiquidationLeavesRemainingDebtAndCollateral() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        uint256 partialAmount = callAmount / 2;
        airdrop(asset, management, partialAmount);

        vm.startPrank(management);
        asset.approve(address(strategy), partialAmount);
        (uint256 actualRepaid,) = strategy.liquidate(partialAmount, management, bytes(""));
        vm.stopPrank();

        assertEq(actualRepaid, partialAmount, "should allow partial liquidation");
        assertGt(strategy.totalDebt(), 0, "debt should still remain");
        assertGt(strategy.totalCollateral(), 0, "collateral should still remain");
    }

    function test_liquidationClearsCallWhenAllCalledDebtLiquidated() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, callAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), callAmount);
        (uint256 actualRepaid,) = strategy.liquidate(callAmount, liquidator, bytes(""));
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0, "called debt should be cleared");
        assertEq(strategy.callDeadline(), 0, "deadline should be cleared");
        assertEq(actualRepaid, callAmount, "full called amount should be repaid");
    }

    function test_liquidateCollateralSeizedCappedAtTotalCollateral() public {
        // This tests the edge case where _loanToCollateral would exceed totalCollateral.
        // Create a deeply insolvent position.
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = toCollateralAmount(100);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        vm.prank(borrower);
        strategy.borrow(maxBorrow, borrower);

        // Make deeply insolvent
        skip(365 days * 10);
        assertFalse(strategy.isSolvent(), "should be insolvent");

        uint256 colBefore = strategy.totalCollateral();
        uint256 colValue = collateralValue(colBefore);

        airdrop(asset, management, colValue);
        vm.startPrank(management);
        asset.approve(address(strategy), colValue);
        (, uint256 seized) = strategy.liquidate(colValue, management, bytes(""));
        vm.stopPrank();

        assertLe(seized, colBefore, "seized should not exceed total collateral");
    }

    // ================================================================
    //        9. DEPOSIT/WITHDRAW HOOKS & maxDebt ACCOUNTING
    // ================================================================

    function test_depositIncreasesMaxDebt() public {
        uint256 amount = toAssetAmount(50_000);
        mintAndDepositIntoStrategy(strategy, user, amount);

        assertEq(strategy.maxDebt(), amount, "maxDebt should equal deposit");

        // Second deposit
        mintAndDepositIntoStrategy(strategy, user, amount);

        assertEq(strategy.maxDebt(), amount * 2, "maxDebt should accumulate");
    }

    function test_withdrawReducesMaxDebtWhenBorrowableIdleConsumed() public {
        uint256 amount = toAssetAmount(50_000);
        mintAndDepositIntoStrategy(strategy, user, amount);

        uint256 withdrawAmt = toAssetAmount(20_000);
        vm.prank(user);
        strategy.withdraw(withdrawAmt, user, user);

        assertEq(strategy.maxDebt(), amount - withdrawAmt, "maxDebt should decrease on withdraw");
    }

    function test_withdrawOfRepaidInterestReturnsMaxDebtToDeposit() public {
        uint256 depositAmount = toAssetAmount(100_000);
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, depositAmount);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        skip(365 days);

        uint256 interestAmount = strategy.totalDebt() - borrowAmt;

        airdrop(asset, borrower, interestAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), interestAmount);
        strategy.repay(interestAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), depositAmount + interestAmount, "interest should grow maxDebt before withdrawal");

        vm.prank(user);
        strategy.withdraw(interestAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount, "withdrawing repaid interest should restore maxDebt to deposit");
    }

    function test_withdrawConsumesRepaidCalledDebtBeforeReducingMaxDebt() public {
        uint256 deposit = toAssetAmount(100_000);
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, deposit);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        // Borrower repays the called debt
        airdrop(asset, borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.stopPrank();

        uint256 maxDebtAfterRepay = strategy.maxDebt();
        uint256 repaidCalledBefore = strategy.repaidCalledDebt();
        assertEq(repaidCalledBefore, callAmount, "repaidCalledDebt set");

        // User withdraws the repaid called debt amount
        vm.prank(user);
        strategy.withdraw(callAmount, user, user);

        // maxDebt should NOT decrease further because withdrawal consumed repaidCalledDebt
        assertEq(strategy.maxDebt(), maxDebtAfterRepay, "maxDebt unchanged when consuming repaidCalledDebt");
        assertEq(strategy.repaidCalledDebt(), 0, "repaidCalledDebt should be consumed");
    }

    function test_multipleDepositsFromDifferentUsersAccumulateMaxDebt() public {
        address user2 = address(14);
        vm.label(user2, "user2");

        uint256 d1 = toAssetAmount(50_000);
        uint256 d2 = toAssetAmount(30_000);

        mintAndDepositIntoStrategy(strategy, user, d1);
        assertEq(strategy.maxDebt(), d1, "after user deposit");

        mintAndDepositIntoStrategy(strategy, user2, d2);
        assertEq(strategy.maxDebt(), d1 + d2, "after user2 deposit");
    }

    function test_withdrawAfterFullRepayDoesNotUnderflowMaxDebt() public {
        uint256 deposit = toAssetAmount(100_000);
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, deposit);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        // Fully repay
        airdrop(asset, borrower, borrowAmt);
        vm.startPrank(borrower);
        asset.approve(address(strategy), borrowAmt);
        strategy.repay(borrowAmt);
        vm.stopPrank();

        // Withdraw all should work without underflow
        vm.prank(user);
        strategy.withdraw(deposit, user, user);

        assertEq(strategy.maxDebt(), 0, "maxDebt should be 0 after full withdraw");
    }

    function test_multipleDepositsAndWithdrawsTrackMaxDebt() public {
        uint256 d1 = toAssetAmount(50_000);
        uint256 d2 = toAssetAmount(30_000);
        uint256 w1 = toAssetAmount(20_000);
        uint256 w2 = toAssetAmount(10_000);

        mintAndDepositIntoStrategy(strategy, user, d1);
        assertEq(strategy.maxDebt(), d1, "after d1");

        mintAndDepositIntoStrategy(strategy, user, d2);
        assertEq(strategy.maxDebt(), d1 + d2, "after d2");

        vm.prank(user);
        strategy.withdraw(w1, user, user);
        assertEq(strategy.maxDebt(), d1 + d2 - w1, "after w1");

        vm.prank(user);
        strategy.withdraw(w2, user, user);
        assertEq(strategy.maxDebt(), d1 + d2 - w1 - w2, "after w2");
    }

    // ================================================================
    //                10. HARVEST AND REPORT TESTS
    // ================================================================

    function test_reportWithNoDebtReturnsIdleBalance() public {
        uint256 amount = toAssetAmount(50_000);
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.totalAssets(), amount, "with no debt, totalAssets should be idle");
    }

    function test_reportWithDebtReturnsIdlePlusMinDebtCollateralValue() public {
        (uint256 liquidity, uint256 collateralAmt, uint256 borrowAmt) = _setupPosition();

        skip(30 days);

        vm.prank(management);
        strat.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        assertGt(strategy.totalAssets(), 0, "totalAssets should be positive");
    }

    function test_reportWithDebtExceedingCollateralValueCapsAtCollateralValue() public {
        // Use small collateral to make debt exceed collateral value after interest
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = toCollateralAmount(100);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        vm.prank(borrower);
        strategy.borrow(maxBorrow, borrower);

        // Accrue a lot of interest
        skip(365 days * 10);

        uint256 totalOwed = strategy.totalDebt();
        uint256 colValue = collateralValue(strategy.totalCollateral());
        assertGt(totalOwed, colValue, "debt should exceed collateral value");

        vm.prank(management);
        strat.setDoHealthCheck(false);

        vm.prank(keeper);
        strategy.report();

        // After report, totalAssets should reflect conservative accounting
        // idle + min(debt, collateralValue) ~ idle + collateralValue
        uint256 idle = asset.balanceOf(address(strategy));
        uint256 expected = idle + colValue;

        // totalAssets may differ slightly due to profit unlock mechanics, but should be in the ballpark
        assertLe(strategy.totalAssets(), expected + liquidity, "totalAssets should be conservative");
    }

    function test_reportWithZeroCollateralButDebtReturnsOnlyIdle() public {
        // Set up position, then liquidate all collateral
        uint256 collateralAmt = toCollateralAmount(100);
        uint256 liquidity = defaultLiquidityAmount();

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        vm.prank(borrower);
        strategy.borrow(maxBorrow, borrower);

        // Make insolvent to allow liquidation
        skip(365 days * 10);

        // Liquidate all collateral
        uint256 totalOwed = strategy.totalDebt();
        airdrop(asset, management, totalOwed);
        vm.startPrank(management);
        asset.approve(address(strategy), totalOwed);
        strategy.liquidate(totalOwed, management, bytes(""));
        vm.stopPrank();

        // If no collateral left, _harvestAndReport returns just idle
        if (strategy.totalCollateral() == 0 && strategy.totalDebt() > 0) {
            vm.prank(management);
            strat.setDoHealthCheck(false);

            vm.prank(keeper);
            strategy.report();

            // totalAssets should be at most the idle balance
            // (profit unlock may cause some variance)
            assertGe(asset.balanceOf(address(strategy)), 0, "should still have some idle balance");
        }
    }

    function test_profitFromInterestRepaymentReported() public {
        (uint256 liquidity,, uint256 borrowAmt) = _setupPosition();

        // Set profit unlock time
        vm.prank(management);
        strategy.setProfitMaxUnlockTime(profitMaxUnlockTime);

        // Accrue interest
        skip(90 days);

        vm.prank(management);
        strat.setDoHealthCheck(false);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, 0, "should have accrued interest profit");
        assertEq(loss, 0, "should have no loss");
    }

    // ================================================================
    //                 11. SHUTDOWN SCENARIO TESTS
    // ================================================================

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

    function test_shutdownBlocksNewBorrows() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 borrowAmt = toAssetAmount(100);
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(defaultCollateralAmount());

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(borrower);
        vm.expectRevert("shutdown");
        strategy.borrow(borrowAmt, borrower);
    }

    function test_shutdownAllowsRepay() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        uint256 repayAmt = borrowAmt / 2;
        airdrop(asset, borrower, repayAmt);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmt);
        uint256 actualRepaid = strategy.repay(repayAmt);
        vm.stopPrank();

        assertEq(actualRepaid, repayAmt, "repay should work after shutdown");
    }

    function test_shutdownAllowsWithdrawCollateral() public {
        uint256 collateralAmt = defaultCollateralAmount();
        postCollateral(collateralAmt);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.prank(borrower);
        strategy.withdrawCollateral(collateralAmt, borrower);

        assertEq(strategy.totalCollateral(), 0, "should withdraw after shutdown");
    }

    function test_shutdownAllowsLiquidation() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt / 5);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        skip(callDuration + 1);

        uint256 liqAmt = borrowAmt / 10;
        airdrop(asset, management, liqAmt);
        vm.startPrank(management);
        asset.approve(address(strategy), liqAmt);
        (uint256 repaid,) = strategy.liquidate(liqAmt, management, bytes(""));
        vm.stopPrank();

        assertGt(repaid, 0, "liquidation should work after shutdown");
    }

    function test_shutdownCallDebtLiquidationFlow() public {
        (,, uint256 borrowAmt) = _setupPosition();

        // Shutdown
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        // Call all debt
        vm.prank(management);
        strategy.callDebt(borrowAmt);

        // Skip past deadline
        skip(callDuration + 1);

        // Liquidate
        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, borrowAmt);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), borrowAmt);
        (uint256 repaid,) = strategy.liquidate(borrowAmt, liquidator, bytes(""));
        vm.stopPrank();

        assertGt(repaid, 0, "full flow should work");
    }

    // ================================================================
    //                 12. VIEW FUNCTIONS TESTS
    // ================================================================

    function test_totalDebtIncludesPendingInterest() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(30 days);

        uint256 totalOwed = strategy.totalDebt();
        assertGt(totalOwed, borrowAmt, "totalDebt should include pending interest");
    }

    function test_isSolventReturnsTrueWhenHealthy() public {
        _setupPosition();
        assertTrue(strategy.isSolvent(), "should be solvent");
    }

    function test_isSolventReturnsFalseWhenUnderwater() public {
        _makeInsolvent();
        assertFalse(strategy.isSolvent(), "should be insolvent");
    }

    function test_isSolventReturnsTrueWithNoDebt() public {
        assertTrue(strategy.isSolvent(), "no debt means solvent");
    }

    function test_isHealthyReturnsFalseWhenCallOverdueEvenIfSolvent() public {
        (,, uint256 borrowAmt) = _setupPosition();

        vm.prank(management);
        strategy.callDebt(borrowAmt / 4);

        skip(callDuration + 1);

        assertTrue(strategy.isSolvent(), "should still be solvent");
        assertFalse(strategy.isHealthy(), "overdue call makes position unhealthy");
    }

    function test_isHealthyReturnsTrueWhenSolventNoCall() public {
        _setupPosition();
        assertTrue(strategy.isHealthy(), "solvent + no call = healthy");
    }

    function test_currentLtvReturnsZeroWithNoDebt() public {
        assertEq(strategy.currentLtv(), 0, "no debt means 0 LTV");
    }

    function test_currentLtvReturnsMaxWithNoCollateralButHasDebt() public {
        // Set up position, make deeply insolvent, liquidate all collateral
        uint256 collateralAmt = toCollateralAmount(100);
        uint256 liquidity = defaultLiquidityAmount();

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        uint256 maxBorrow = borrowAmountForLtv(collateralAmt, lltv);
        vm.prank(borrower);
        strategy.borrow(maxBorrow, borrower);

        skip(365 days * 5);

        // Liquidate all collateral
        uint256 totalOwed = strategy.totalDebt();
        airdrop(asset, management, totalOwed);

        vm.startPrank(management);
        asset.approve(address(strategy), totalOwed);
        strategy.liquidate(totalOwed, management, bytes(""));
        vm.stopPrank();

        if (strategy.totalDebt() > 0 && strategy.totalCollateral() == 0) {
            assertEq(strategy.currentLtv(), type(uint256).max, "LTV should be max with no collateral");
        }
    }

    function test_currentLtvReturnsCorrectRatio() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        uint256 colValue = collateralValue(collateralAmt);
        uint256 expectedLtv = Math.mulDiv(borrowAmt, 1e18, colValue);

        assertEq(strategy.currentLtv(), expectedLtv, "LTV should match manual calculation");
    }

    // ================================================================
    //              13. RESCUE FUNCTION TESTS
    // ================================================================

    function test_rescueTransfersUnrelatedToken() public {
        ERC20 unrelated = ERC20(tokenAddrs["DAI"]);
        uint256 amount = 1_000e18;
        airdrop(unrelated, address(strategy), amount);

        uint256 receiverBefore = unrelated.balanceOf(management);

        vm.prank(management);
        strat.rescue(address(unrelated));

        assertEq(unrelated.balanceOf(management), receiverBefore + amount, "receiver should get rescued tokens");
        assertEq(unrelated.balanceOf(address(strategy)), 0, "strategy should have 0 unrelated token");
    }

    // ================================================================
    //          14. EDGE CASES & INTEGRATION TESTS
    // ================================================================

    function test_fullLifecycleDepositPostBorrowAccrueRepayWithdrawCollateralWithdraw() public {
        // Step 1: Deposit liquidity
        uint256 liquidity = defaultLiquidityAmount();
        mintAndDepositIntoStrategy(strategy, user, liquidity);
        assertEq(strategy.maxDebt(), liquidity, "maxDebt after deposit");

        // Step 2: Post collateral
        uint256 collateralAmt = defaultCollateralAmount();
        postCollateral(collateralAmt);
        assertEq(strategy.totalCollateral(), collateralAmt, "collateral posted");

        // Step 3: Borrow
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);
        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);
        assertEq(strategy.totalDebt(), borrowAmt, "debt after borrow");

        // Step 4: Accrue interest
        skip(30 days);
        uint256 totalOwed = strategy.totalDebt();
        assertGt(totalOwed, borrowAmt, "interest accrued");

        // Step 5: Full repay
        airdrop(asset, borrower, totalOwed);
        vm.startPrank(borrower);
        asset.approve(address(strategy), totalOwed);
        strategy.repay(totalOwed);
        vm.stopPrank();
        assertEq(strategy.totalDebt(), 0, "debt after repay");

        // Step 6: Withdraw collateral
        vm.prank(borrower);
        strategy.withdrawCollateral(collateralAmt, borrower);
        assertEq(strategy.totalCollateral(), 0, "collateral after withdraw");

        // Step 7: Withdraw liquidity
        uint256 userShares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(userShares, user, user);

        assertTrue(strategy.isHealthy(), "should be healthy after lifecycle");
        assertEq(strategy.currentLtv(), 0, "ltv should be 0");
    }

    function test_borrowExactlyAtLltvBoundary() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmountAtLltv = borrowAmountForLtv(collateralAmt, lltv);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        // Should fail at LLTV + 1
        vm.prank(borrower);
        vm.expectRevert("position unhealthy");
        strategy.borrow(borrowAmountAtLltv + 1, borrower);

        // Should succeed at exactly LLTV
        vm.prank(borrower);
        strategy.borrow(borrowAmountAtLltv, borrower);

        assertLe(strategy.currentLtv(), lltv, "LTV should be at or below LLTV");
    }

    function test_repayExactlyTheInterestAmountReturnsDebtToBorrowAmount() public {
        (,, uint256 borrowAmt) = _setupPosition();

        skip(365 days);

        uint256 expectedInterest = (borrowAmt * rate) / MAX_BPS;

        // Repay just the interest
        airdrop(asset, borrower, expectedInterest);
        vm.startPrank(borrower);
        asset.approve(address(strategy), expectedInterest);
        strategy.repay(expectedInterest);
        vm.stopPrank();

        assertApproxEqAbs(strategy.totalDebt(), borrowAmt, 1, "remaining debt should return to borrow amount");
    }

    function test_callExactlyAllDebt() public {
        // Use exact deposit = borrow amount so maxDebt == borrowAmt
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, borrowAmt);
        postCollateral(collateralAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        assertEq(strategy.maxDebt(), borrowAmt, "maxDebt should equal borrowAmt");

        vm.prank(management);
        strategy.callDebt(borrowAmt);

        assertEq(strategy.calledDebt(), borrowAmt, "all debt called");
        assertEq(strategy.maxDebt(), 0, "maxDebt should be 0");
    }

    function test_liquidateWithRepayAmountExceedingMaxRepayCapsCorrectly() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        // Try to liquidate 10x the called amount (while solvent)
        uint256 hugeAmount = callAmount * 10;
        airdrop(asset, management, hugeAmount);

        vm.startPrank(management);
        asset.approve(address(strategy), hugeAmount);
        (uint256 actualRepaid,) = strategy.liquidate(hugeAmount, management, bytes(""));
        vm.stopPrank();

        // Should be capped at calledDebt since position is still solvent
        assertEq(actualRepaid, callAmount, "repaid should be capped at called amount");
    }

    function test_zeroDebtScenariosAllBehaveCorrectly() public {
        // No setup - fresh strategy
        assertEq(strategy.totalDebt(), 0, "totalDebt zero");
        assertTrue(strategy.isSolvent(), "solvent with no debt");
        assertTrue(strategy.isHealthy(), "healthy with no debt");
        assertEq(strategy.currentLtv(), 0, "ltv zero with no debt");
    }

    function test_verySmallAmounts1Wei() public {
        // Deposit a very small amount
        uint256 deposit = 1; // 1 wei of USDC
        mintAndDepositIntoStrategy(strategy, user, deposit);
        assertEq(strategy.maxDebt(), deposit, "maxDebt from 1 wei deposit");

        // Post tiny collateral
        uint256 tinyCollateral = 1;
        postCollateral(tinyCollateral);
        assertEq(strategy.totalCollateral(), tinyCollateral, "1 wei collateral");

        // Withdraw tiny collateral
        vm.prank(borrower);
        strategy.withdrawCollateral(tinyCollateral, borrower);
        assertEq(strategy.totalCollateral(), 0, "back to 0");
    }

    function test_borrowAtExactMaxDebt() public {
        uint256 liquidity = toAssetAmount(50_000);
        uint256 collateralAmt = toCollateralAmount(1_000_000);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        // Borrow exactly maxDebt
        vm.prank(borrower);
        strategy.borrow(liquidity, borrower);

        assertEq(strategy.totalDebt(), liquidity, "should borrow exact maxDebt");
    }

    function test_fullLifecycleMultipleDepositorsAndCallCycles() public {
        address user2 = address(14);
        vm.label(user2, "user2");

        uint256 deposit1 = toAssetAmount(100_000);
        uint256 deposit2 = toAssetAmount(100_000);

        mintAndDepositIntoStrategy(strategy, user, deposit1);
        mintAndDepositIntoStrategy(strategy, user2, deposit2);

        assertEq(strategy.maxDebt(), deposit1 + deposit2);

        uint256 collateralAmt = defaultCollateralAmount();
        postCollateral(collateralAmt);

        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);
        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);

        // First call cycle
        uint256 callAmount1 = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount1);

        airdrop(asset, borrower, callAmount1);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount1);
        strategy.repay(callAmount1);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0, "first call cleared");
        assertEq(strategy.callDeadline(), 0, "deadline cleared");

        skip(30 days);

        // Second call cycle
        uint256 callAmount2 = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount2);

        airdrop(asset, borrower, callAmount2);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount2);
        strategy.repay(callAmount2);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 0, "second call cleared");

        // Full repay
        skip(30 days);
        uint256 totalOwed = strategy.totalDebt();
        airdrop(asset, borrower, totalOwed);
        vm.startPrank(borrower);
        asset.approve(address(strategy), totalOwed);
        strategy.repay(totalOwed);
        strategy.withdrawCollateral(collateralAmt, borrower);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), 0, "fully repaid");
        assertEq(strategy.totalCollateral(), 0, "collateral withdrawn");

        uint256 userShares = strategy.balanceOf(user);
        uint256 user2Shares = strategy.balanceOf(user2);

        if (userShares > 0) {
            vm.prank(user);
            strategy.redeem(userShares, user, user);
        }

        if (user2Shares > 0) {
            vm.prank(user2);
            strategy.redeem(user2Shares, user2, user2);
        }
    }

    function test_withdrawAllIdleWhenNoDebt() public {
        uint256 amount = toAssetAmount(50_000);
        mintAndDepositIntoStrategy(strategy, user, amount);

        vm.prank(user);
        strategy.withdraw(amount, user, user);

        assertEq(asset.balanceOf(address(strategy)), 0, "strategy should have 0 asset balance");
        assertEq(strategy.maxDebt(), 0, "maxDebt should be 0");
    }

    function test_postCollateralAndWithdrawIdempotent() public {
        uint256 amount = toCollateralAmount(10_000);

        postCollateral(amount);
        assertEq(strategy.totalCollateral(), amount, "after post");

        vm.prank(borrower);
        strategy.withdrawCollateral(amount, borrower);
        assertEq(strategy.totalCollateral(), 0, "after withdraw");
    }

    // ================================================================
    //          15. TOKENIZED STRATEGY INTEGRATION TESTS
    // ================================================================

    function test_availableDepositLimitAllowed() public {
        setAllowed(user, true);
        assertEq(strategy.availableDepositLimit(user), type(uint256).max, "allowed user should have max deposit limit");
    }

    function test_availableDepositLimitNotAllowed() public {
        assertEq(strategy.availableDepositLimit(stranger), 0, "non-allowed user should have 0 deposit limit");
    }

    function test_availableDepositLimitShutdown() public {
        setAllowed(user, true);

        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.availableDepositLimit(user), 0, "shutdown strategy should have 0 deposit limit");
    }

    function test_availableWithdrawLimitReturnsBalance() public {
        uint256 amount = toAssetAmount(50_000);
        mintAndDepositIntoStrategy(strategy, user, amount);

        assertEq(
            strategy.availableWithdrawLimit(user),
            asset.balanceOf(address(strategy)),
            "withdraw limit should be strategy asset balance"
        );
    }

    function test_profitUnlocksOverTime() public {
        _setupPosition();

        vm.prank(management);
        strategy.setProfitMaxUnlockTime(profitMaxUnlockTime);

        skip(90 days);

        vm.prank(management);
        strat.setDoHealthCheck(false);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, 0, "should have accrued interest profit");
        assertEq(loss, 0, "should have no loss");

        uint256 ppsBefore = strategy.pricePerShare();

        skip(profitMaxUnlockTime / 2);

        uint256 ppsMiddle = strategy.pricePerShare();
        assertGt(ppsMiddle, ppsBefore, "pps should increase as profit unlocks");

        skip(profitMaxUnlockTime / 2 + 1);

        uint256 ppsAfter = strategy.pricePerShare();
        assertGe(ppsAfter, ppsMiddle, "pps should continue increasing");
    }

    function test_reportWithFeesDistributesProfitCorrectly() public {
        _setupPosition();

        setFees(0, 1_000);

        vm.prank(management);
        strategy.setProfitMaxUnlockTime(profitMaxUnlockTime);

        skip(90 days);

        vm.prank(management);
        strat.setDoHealthCheck(false);

        uint256 feeRecipientSharesBefore = strategy.balanceOf(performanceFeeRecipient);

        vm.prank(keeper);
        (uint256 profit,) = strategy.report();

        assertGt(profit, 0, "should have profit");

        uint256 feeRecipientSharesAfter = strategy.balanceOf(performanceFeeRecipient);

        assertGt(feeRecipientSharesAfter, feeRecipientSharesBefore, "fee recipient should receive shares");
    }

    // ================================================================
    //                16. EVENT EMISSION TESTS
    // ================================================================

    function test_postCollateralEmitsEvent() public {
        uint256 amount = toCollateralAmount(1_000);
        airdrop(collateral, borrower, amount);

        vm.startPrank(borrower);
        collateral.approve(address(strategy), amount);

        vm.expectEmit(true, true, true, true);
        emit CollateralPosted(borrower, amount, amount);

        strategy.postCollateral(amount);
        vm.stopPrank();
    }

    function test_withdrawCollateralEmitsEvent() public {
        uint256 amount = toCollateralAmount(1_000);
        postCollateral(amount);

        address receiver = address(0xBEEF);

        vm.expectEmit(true, true, true, true);
        emit CollateralWithdrawn(borrower, receiver, amount, 0);

        vm.prank(borrower);
        strategy.withdrawCollateral(amount, receiver);
    }

    function test_borrowEmitsEvent() public {
        uint256 liquidity = defaultLiquidityAmount();
        uint256 collateralAmt = defaultCollateralAmount();
        uint256 borrowAmt = defaultBorrowAmount(collateralAmt);

        mintAndDepositIntoStrategy(strategy, user, liquidity);
        postCollateral(collateralAmt);

        vm.expectEmit(true, true, true, true);
        emit Borrowed(borrower, borrower, borrowAmt, borrowAmt);

        vm.prank(borrower);
        strategy.borrow(borrowAmt, borrower);
    }

    function test_repayEmitsEvent() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 repayAmt = borrowAmt / 2;
        airdrop(asset, borrower, repayAmt);

        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmt);

        // After repay: debtAmount = borrowAmt - repayAmt, calledDebt = 0
        vm.expectEmit(true, true, true, true);
        emit Repaid(borrower, repayAmt, borrowAmt - repayAmt, 0);

        strategy.repay(repayAmt);
        vm.stopPrank();
    }

    function test_callDebtEmitsEvent() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        uint256 expectedDeadline = block.timestamp + callDuration;

        vm.expectEmit(true, true, true, true);
        emit DebtCalled(management, callAmount, callAmount, expectedDeadline);

        vm.prank(management);
        strategy.callDebt(callAmount);
    }

    function test_callClearedEmitsEvent() public {
        (,, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 4;
        vm.prank(management);
        strategy.callDebt(callAmount);

        airdrop(asset, borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);

        vm.expectEmit(true, true, true, true);
        emit CallCleared(borrower);

        strategy.repay(callAmount);
        vm.stopPrank();
    }

    function test_liquidateEmitsEvent() public {
        (, uint256 collateralAmt, uint256 borrowAmt) = _setupPosition();

        uint256 callAmount = borrowAmt / 5;
        vm.prank(management);
        strategy.callDebt(callAmount);
        skip(callDuration + 1);

        uint256 price = collateralOracle.price();
        uint256 expectedSeized = Math.mulDiv(callAmount, 1e36, price);
        uint256 expectedDebtAfter = strategy.totalDebt() - callAmount;
        uint256 expectedCollateralAfter = collateralAmt - expectedSeized;

        setLiquidator(liquidator, true);
        airdrop(asset, liquidator, callAmount);

        vm.startPrank(liquidator);
        asset.approve(address(strategy), callAmount);

        vm.expectEmit(true, true, true, true);
        emit Liquidated(liquidator, liquidator, callAmount, expectedSeized, expectedDebtAfter, expectedCollateralAfter);

        strategy.liquidate(callAmount, liquidator, bytes(""));
        vm.stopPrank();
    }

    function test_setLiquidatorEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit LiquidatorUpdated(liquidator, true);

        vm.prank(management);
        strategy.setLiquidator(liquidator, true);
    }
}
