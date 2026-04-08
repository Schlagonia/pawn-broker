// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";

import {PawnBrokerFactory} from "../../PawnBrokerFactory.sol";
import {IPawnBroker} from "../../interfaces/IPawnBroker.sol";
import {MockMorphoOracle} from "../mocks/MockMorphoOracle.sol";

interface IHealthCheckStrategy is IPawnBroker {
    function setDoHealthCheck(bool _doHealthCheck) external;
}

contract MockProtocolFeeFactory {
    function protocol_fee_config() external pure returns (uint16, address) {
        return (0, address(0));
    }
}

contract MockERC20 is ERC20 {
    uint8 internal immutable assetDecimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        assetDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return assetDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract LocalSetup is Test {
    address internal constant TOKENIZED_STRATEGY =
        0xD377919FA87120584B21279a491F82D5265A139c;

    uint256 internal constant LLTV = 8e17;
    uint256 internal constant FIXED_RATE = 500;
    uint256 internal constant CALL_DURATION = 3 days;
    uint256 internal constant INITIAL_ORACLE_PRICE = 2_500e36;

    address internal management = address(0x100);
    address internal performanceFeeRecipient = address(0x200);
    address internal keeper = address(0x300);
    address internal emergencyAdmin = address(0x400);
    address internal user = address(0x500);
    address internal borrower = address(0x600);
    address internal secondBorrower = address(0x700);

    MockProtocolFeeFactory internal protocolFeeFactory;
    MockERC20 internal asset;
    MockERC20 internal collateral;
    MockMorphoOracle internal oracle;
    PawnBrokerFactory internal pawnBrokerFactory;
    IHealthCheckStrategy internal strategy;

    function setUp() public virtual {
        protocolFeeFactory = new MockProtocolFeeFactory();
        TokenizedStrategy implementation = new TokenizedStrategy(
            address(protocolFeeFactory)
        );
        vm.etch(TOKENIZED_STRATEGY, address(implementation).code);

        asset = new MockERC20("Mock Asset", "AST", 18);
        collateral = new MockERC20("Mock Collateral", "COL", 18);
        oracle = new MockMorphoOracle();
        oracle.setPrice(INITIAL_ORACLE_PRICE);

        pawnBrokerFactory = new PawnBrokerFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        strategy = IHealthCheckStrategy(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "Unit PawnBroker",
                borrower,
                address(collateral),
                address(oracle),
                LLTV,
                FIXED_RATE,
                CALL_DURATION
            )
        );

        vm.prank(management);
        strategy.acceptManagement();
    }

    function _allowAndDeposit(address owner, uint256 amount) internal {
        vm.prank(management);
        strategy.setAllowed(owner, true);

        asset.mint(owner, amount);

        vm.startPrank(owner);
        asset.approve(address(strategy), amount);
        strategy.deposit(amount, owner);
        vm.stopPrank();
    }

    function _postCollateral(uint256 amount) internal {
        collateral.mint(borrower, amount);

        vm.startPrank(borrower);
        collateral.approve(address(strategy), amount);
        strategy.postCollateral(amount);
        vm.stopPrank();
    }
}

contract FactoryRegistryTest is LocalSetup {
    function test_isDeployedPawnBroker_tracksEveryPawnBrokerForSameAsset()
        public
    {
        address secondStrategy = pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Unit PawnBroker 2",
            secondBorrower,
            address(collateral),
            address(oracle),
            LLTV,
            FIXED_RATE,
            CALL_DURATION
        );

        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(address(strategy)));
        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(secondStrategy));

        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset),
                borrower,
                address(collateral),
                address(oracle),
                LLTV,
                FIXED_RATE,
                CALL_DURATION
            ),
            address(strategy)
        );

        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset),
                secondBorrower,
                address(collateral),
                address(oracle),
                LLTV,
                FIXED_RATE,
                CALL_DURATION
            ),
            secondStrategy
        );
    }

    function test_newPawnBroker_rejectsDuplicateConfig() public {
        vm.expectRevert("pawn broker exists");
        pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Duplicate PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            FIXED_RATE,
            CALL_DURATION
        );
    }
}

contract ReportAccountingTest is LocalSetup {
    function test_reportRevertsWhenOraclePriceIsZero() public {
        uint256 liquidity = 100_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;

        _allowAndDeposit(user, liquidity);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        oracle.setPrice(0);

        vm.prank(keeper);
        vm.expectRevert("zero oracle price");
        strategy.report();

        assertEq(strategy.totalAssets(), liquidity);
    }
}

contract BorrowerRepairTest is LocalSetup {
    function test_partialRepaySucceedsAfterOverdueCall() public {
        uint256 liquidity = 100_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 callAmount = 2_000e18;
        uint256 partialRepayAmount = 1_000e18;

        _allowAndDeposit(user, liquidity);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(callAmount);

        skip(CALL_DURATION + 1);

        uint256 debtAmountBefore = strategy.totalDebt();

        asset.mint(borrower, partialRepayAmount);

        vm.startPrank(borrower);
        asset.approve(address(strategy), partialRepayAmount);
        uint256 actualRepaid = strategy.repay(partialRepayAmount);
        vm.stopPrank();

        assertEq(actualRepaid, partialRepayAmount);
        assertEq(strategy.calledDebt(), callAmount - partialRepayAmount);
        assertEq(strategy.repaidCalledDebt(), partialRepayAmount);
        assertEq(strategy.maxDebt(), liquidity - callAmount);
        assertGt(strategy.callDeadline(), 0);
        assertEq(strategy.totalDebt(), debtAmountBefore - partialRepayAmount);
    }

    function test_partialCollateralTopUpSucceedsWhileStillUnhealthy() public {
        uint256 liquidity = 100_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 19_000e18;
        uint256 topUpAmount = 1e17;

        _allowAndDeposit(user, liquidity);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        oracle.setPrice(2_300e36);

        collateral.mint(borrower, topUpAmount);

        vm.startPrank(borrower);
        collateral.approve(address(strategy), topUpAmount);
        strategy.postCollateral(topUpAmount);
        vm.expectRevert("position unhealthy");
        strategy.borrow(1e18, borrower);
        vm.stopPrank();

        assertEq(strategy.totalCollateral(), collateralAmount + topUpAmount);
        assertEq(strategy.totalDebt(), borrowAmount);
    }
}

contract MaxDebtAccountingTest is LocalSetup {
    function test_depositAndWithdrawUpdateMaxDebtThroughHooks() public {
        uint256 depositAmount = 10_000e18;
        uint256 withdrawAmount = 2_000e18;

        _allowAndDeposit(user, depositAmount);
        assertEq(strategy.maxDebt(), depositAmount);

        vm.prank(user);
        strategy.withdraw(withdrawAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount - withdrawAmount);
    }

    function test_withdrawConsumesRepaidCalledDebtBeforeReducingMaxDebt()
        public
    {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 callAmount = 2_000e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(management);
        strategy.callDebt(callAmount);

        asset.mint(borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), depositAmount - callAmount);
        assertEq(strategy.repaidCalledDebt(), callAmount);
        assertEq(strategy.callDeadline(), 0);

        vm.prank(user);
        strategy.withdraw(callAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount - callAmount);
        assertEq(strategy.repaidCalledDebt(), 0);
    }

    function test_withdrawOfRepaidInterestDoesNotReduceMaxDebt() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 8_000e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        skip(365 days);

        uint256 interestAmount = strategy.totalDebt() - borrowAmount;

        asset.mint(borrower, interestAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), interestAmount);
        strategy.repay(interestAmount);
        vm.stopPrank();

        vm.prank(user);
        strategy.withdraw(interestAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount);
    }
}

contract DepositorSelfCallTest is LocalSetup {
    address internal otherDepositor = address(0x800);

    function test_callDebtByShares_locksSharesAndReducesBorrowHeadroom()
        public
    {
        uint256 depositAmount = 100e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 20e18;
        uint256 calledShares = 50e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        uint256 debtCalled = strategy.callDebtByShares(calledShares);

        assertEq(debtCalled, 10e18);
        assertEq(strategy.calledShares(user), calledShares);
        assertEq(strategy.calledDebt(), debtCalled);
        assertEq(strategy.maxCallableShares(user), calledShares);
        assertEq(strategy.maxDebt(), depositAmount - debtCalled);
        assertGt(strategy.callDeadline(), 0);
    }

    function test_callDebtByShares_usesRemainingCallableSupply() public {
        uint256 depositAmount = 50e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 20e18;

        _allowAndDeposit(user, depositAmount);
        _allowAndDeposit(otherDepositor, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        uint256 firstCall = strategy.callDebtByShares(depositAmount);

        vm.prank(otherDepositor);
        uint256 secondCall = strategy.callDebtByShares(depositAmount);

        assertEq(firstCall, 10e18);
        assertEq(secondCall, 10e18);
        assertEq(strategy.calledDebt(), borrowAmount);
    }

    function test_callDebtByShares_blocksTransferOfLockedShares() public {
        uint256 depositAmount = 100e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 20e18;
        uint256 calledShares = 50e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        strategy.callDebtByShares(calledShares);

        vm.prank(user);
        assertTrue(strategy.transfer(otherDepositor, 50e18));

        vm.prank(user);
        vm.expectRevert("locked called shares");
        strategy.transfer(otherDepositor, 1);
    }

    function test_repayLeavesCalledSharesFrozenUntilRedeemed() public {
        uint256 depositAmount = 100e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 20e18;
        uint256 calledShares = 50e18;
        uint256 repayAmount = 4e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        strategy.callDebtByShares(calledShares);

        asset.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), repayAmount);
        strategy.repay(repayAmount);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 6e18);
        assertEq(strategy.calledShares(user), calledShares);
        assertEq(strategy.availableWithdrawLimit(user), 84e18);

        vm.prank(user);
        uint256 assetsOut = strategy.redeem(calledShares, user, user);

        assertEq(assetsOut, calledShares);
        assertEq(strategy.balanceOf(user), 50e18);
        assertEq(strategy.calledShares(user), 0);
        assertEq(strategy.calledDebt(), 6e18);
    }

    function test_repayTreatsManagementAndDepositorCallsAsSingleBucket()
        public
    {
        uint256 depositAmount = 100e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 40e18;
        uint256 borrowerRepay = 15e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        strategy.callDebtByShares(50e18);

        vm.prank(management);
        strategy.callDebt(10e18);

        asset.mint(borrower, borrowerRepay);
        vm.startPrank(borrower);
        asset.approve(address(strategy), borrowerRepay);
        strategy.repay(borrowerRepay);
        vm.stopPrank();

        assertEq(strategy.calledDebt(), 15e18);
        assertEq(strategy.calledShares(user), 50e18);
        assertEq(strategy.repaidCalledDebt(), 15e18);
    }

    function test_redeemConsumesCalledSharesBeforeUnlockedShares() public {
        uint256 depositAmount = 50e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 40e18;
        uint256 calledShareAmount = 25e18;

        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);

        vm.prank(user);
        strategy.callDebtByShares(calledShareAmount);

        vm.prank(user);
        strategy.redeem(10e18, user, user);

        assertEq(strategy.calledShares(user), 15e18);
    }
}
