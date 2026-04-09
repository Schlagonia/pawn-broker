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
    function _openFullUtilizedPosition(
        uint256 depositAmount,
        uint256 collateralAmount
    ) internal {
        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(depositAmount, borrower);
    }

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

    function test_fullUtilizationPartialRepayThenFullIdleWithdrawCutsMaxDebt()
        public
    {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 partialRepayAmount = 2_000e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        asset.mint(borrower, partialRepayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), partialRepayAmount);
        strategy.repay(partialRepayAmount);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.maxDebt(), depositAmount);
        assertEq(asset.balanceOf(address(strategy)), partialRepayAmount);

        vm.prank(user);
        strategy.withdraw(partialRepayAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.totalDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.repaidCalledDebt(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_fullUtilizationFullRepayIncludingInterestThenFullWithdrawZerosMaxDebt()
        public
    {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        skip(365 days);

        uint256 totalOwed = strategy.totalDebt();
        assertGt(totalOwed, depositAmount);

        asset.mint(borrower, totalOwed);
        vm.startPrank(borrower);
        asset.approve(address(strategy), totalOwed);
        strategy.repay(totalOwed);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), 0);
        assertEq(asset.balanceOf(address(strategy)), totalOwed);

        vm.startPrank(management);
        strategy.setPerformanceFee(0);
        strategy.setProfitMaxUnlockTime(0);
        vm.stopPrank();

        vm.prank(keeper);
        strategy.report();

        uint256 userShares = strategy.balanceOf(user);
        vm.prank(user);
        strategy.redeem(userShares, user, user);

        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.totalDebt(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_fullUtilizationPartialCallRepayCallThenFullIdleWithdrawDoesNotDoubleCutMaxDebt()
        public
    {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 callAmount = 4_000e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        vm.prank(management);
        strategy.callDebt(callAmount);

        asset.mint(borrower, callAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), callAmount);
        strategy.repay(callAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), depositAmount - callAmount);
        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), callAmount);
        assertEq(asset.balanceOf(address(strategy)), callAmount);

        vm.prank(user);
        strategy.withdraw(callAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount - callAmount);
        assertEq(strategy.totalDebt(), depositAmount - callAmount);
        assertEq(strategy.repaidCalledDebt(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_fullUtilizationFullCallPartialRepayThenFullIdleWithdrawKeepsMaxDebtAtZero()
        public
    {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 partialRepayAmount = 4_000e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        vm.prank(management);
        strategy.callDebt(depositAmount);

        asset.mint(borrower, partialRepayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), partialRepayAmount);
        strategy.repay(partialRepayAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.calledDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.repaidCalledDebt(), partialRepayAmount);
        assertGt(strategy.callDeadline(), 0);

        vm.prank(user);
        strategy.withdraw(partialRepayAmount, user, user);

        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.totalDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.calledDebt(), depositAmount - partialRepayAmount);
        assertEq(strategy.repaidCalledDebt(), 0);
        assertGt(strategy.callDeadline(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
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
