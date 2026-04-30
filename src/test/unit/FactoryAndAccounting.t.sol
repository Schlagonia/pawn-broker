// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";

import {PawnBrokerFactory} from "../../PawnBrokerFactory.sol";
import {ICooldownHandler} from "../../interfaces/ICooldownHandler.sol";
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

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        assetDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return assetDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCooldownHandler is ICooldownHandler {
    using SafeERC20 for ERC20;

    address public immutable override collateralAsset;
    address public immutable override asset;

    uint256 public override pendingCollateral;
    uint256 public nextFinalizedCollateral;

    constructor(address _collateralAsset, address _asset) {
        collateralAsset = _collateralAsset;
        asset = _asset;
    }

    function setNextFinalizedCollateral(uint256 _finalizedCollateral) external {
        nextFinalizedCollateral = _finalizedCollateral;
    }

    function cooldown(uint256 _collateralAmount) external override returns (uint256 queuedCollateral) {
        pendingCollateral += _collateralAmount;
        return _collateralAmount;
    }

    function claim(address _receiver) external override returns (uint256 claimedAssets, uint256 finalizedCollateral) {
        claimedAssets = ERC20(asset).balanceOf(address(this));
        finalizedCollateral = nextFinalizedCollateral == 0 ? pendingCollateral : nextFinalizedCollateral;
        finalizedCollateral = Math.min(finalizedCollateral, pendingCollateral);

        pendingCollateral -= finalizedCollateral;
        nextFinalizedCollateral = 0;

        if (claimedAssets > 0) {
            ERC20(asset).safeTransfer(_receiver, claimedAssets);
        }
    }

    function cancel(uint256 _collateralAmount) external override returns (uint256 returnedCollateral) {
        if (_collateralAmount == type(uint256).max) _collateralAmount = pendingCollateral;
        returnedCollateral = Math.min(_collateralAmount, pendingCollateral);
        pendingCollateral -= returnedCollateral;

        if (returnedCollateral > 0) {
            ERC20(collateralAsset).safeTransfer(msg.sender, returnedCollateral);
        }
    }
}

abstract contract LocalSetup is Test {
    address internal constant TOKENIZED_STRATEGY = 0xD377919FA87120584B21279a491F82D5265A139c;

    uint256 internal constant LLTV = 8e17;
    uint256 internal constant RATE = 500;
    uint256 internal constant CALL_DURATION = 3 days;
    uint256 internal constant INITIAL_ORACLE_PRICE = 2_500e36;

    address internal management = address(0x100);
    address internal performanceFeeRecipient = address(0x200);
    address internal keeper = address(0x300);
    address internal emergencyAdmin = address(0x400);
    address internal user = address(0x500);
    address internal borrower = address(0x600);
    address internal secondBorrower = address(0x700);
    address internal liquidator = address(0x800);

    MockProtocolFeeFactory internal protocolFeeFactory;
    MockERC20 internal asset;
    MockERC20 internal collateral;
    MockMorphoOracle internal oracle;
    PawnBrokerFactory internal pawnBrokerFactory;
    IHealthCheckStrategy internal strategy;

    function setUp() public virtual {
        protocolFeeFactory = new MockProtocolFeeFactory();
        TokenizedStrategy implementation = new TokenizedStrategy(address(protocolFeeFactory));
        vm.etch(TOKENIZED_STRATEGY, address(implementation).code);

        asset = new MockERC20("Mock Asset", "AST", 18);
        collateral = new MockERC20("Mock Collateral", "COL", 18);
        oracle = new MockMorphoOracle();
        oracle.setPrice(INITIAL_ORACLE_PRICE);

        pawnBrokerFactory = new PawnBrokerFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        strategy = IHealthCheckStrategy(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "Unit PawnBroker",
                borrower,
                address(collateral),
                address(oracle),
                LLTV,
                RATE,
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
    function test_isDeployedPawnBroker_tracksEveryPawnBrokerForSameAsset() public {
        address secondStrategy = pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Unit PawnBroker 2",
            secondBorrower,
            address(collateral),
            address(oracle),
            LLTV,
            RATE,
            CALL_DURATION
        );

        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(address(strategy)));
        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(secondStrategy));

        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset), borrower, address(collateral), address(oracle), LLTV, RATE, CALL_DURATION
            ),
            address(strategy)
        );

        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset), secondBorrower, address(collateral), address(oracle), LLTV, RATE, CALL_DURATION
            ),
            secondStrategy
        );
    }

    function test_newPawnBroker_allowsDuplicateConfigAndUpdatesLatestLookup() public {
        address duplicateStrategy = pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Duplicate PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            RATE,
            CALL_DURATION
        );

        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(address(strategy)));
        assertTrue(pawnBrokerFactory.isDeployedPawnBroker(duplicateStrategy));
        assertNotEq(duplicateStrategy, address(strategy));

        address[] memory duplicateMarkets = pawnBrokerFactory.pawnBrokersFor(
            address(asset), borrower, address(collateral), address(oracle), LLTV, RATE, CALL_DURATION
        );

        assertEq(duplicateMarkets.length, 2);
        assertEq(duplicateMarkets[0], address(strategy));
        assertEq(duplicateMarkets[1], duplicateStrategy);

        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset), borrower, address(collateral), address(oracle), LLTV, RATE, CALL_DURATION
            ),
            duplicateStrategy
        );
    }
}

abstract contract CooldownSetup is LocalSetup {
    MockCooldownHandler internal cooldownHandler;

    function setUp() public virtual override {
        super.setUp();

        cooldownHandler = new MockCooldownHandler(address(collateral), address(asset));
        strategy = IHealthCheckStrategy(
            pawnBrokerFactory.newPawnBroker(
                address(asset),
                "Cooldown PawnBroker",
                borrower,
                address(collateral),
                address(oracle),
                LLTV,
                RATE,
                CALL_DURATION,
                address(cooldownHandler)
            )
        );

        vm.prank(management);
        strategy.acceptManagement();
    }

    function _openPosition(uint256 depositAmount, uint256 collateralAmount, uint256 borrowAmount) internal {
        _allowAndDeposit(user, depositAmount);
        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);
    }
}

contract CooldownFactoryTest is LocalSetup {
    function test_newPawnBrokerWithCooldownUsesSeparateRegistryKey() public {
        MockCooldownHandler cooldownHandler = new MockCooldownHandler(address(collateral), address(asset));

        address cooldownStrategy = pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Cooldown PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            RATE,
            CALL_DURATION,
            address(cooldownHandler)
        );

        assertEq(address(strategy.COOLDOWN_HANDLER()), address(0));
        assertEq(address(IPawnBroker(cooldownStrategy).COOLDOWN_HANDLER()), address(cooldownHandler));
        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset), borrower, address(collateral), address(oracle), LLTV, RATE, CALL_DURATION
            ),
            address(strategy)
        );
        assertEq(
            pawnBrokerFactory.pawnBrokerFor(
                address(asset),
                borrower,
                address(collateral),
                address(oracle),
                LLTV,
                RATE,
                CALL_DURATION,
                address(cooldownHandler)
            ),
            cooldownStrategy
        );
    }

    function test_newPawnBrokerRejectsMismatchedCooldownCollateral() public {
        MockERC20 otherCollateral = new MockERC20("Other Collateral", "OCOL", 18);
        MockCooldownHandler badHandler = new MockCooldownHandler(address(otherCollateral), address(asset));

        vm.expectRevert("bad cooldown collateral");
        pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Bad Cooldown PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            RATE,
            CALL_DURATION,
            address(badHandler)
        );
    }

    function test_newPawnBrokerRejectsMismatchedCooldownAsset() public {
        MockERC20 otherAsset = new MockERC20("Other Asset", "OAST", 18);
        MockCooldownHandler badHandler = new MockCooldownHandler(address(collateral), address(otherAsset));

        vm.expectRevert("bad cooldown asset");
        pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Bad Cooldown PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            RATE,
            CALL_DURATION,
            address(badHandler)
        );
    }
}

contract CooldownAccountingTest is CooldownSetup {
    function test_onlyBorrowerManagementOrLiquidatorCanUseCooldown() public {
        vm.prank(secondBorrower);
        vm.expectRevert("not cooldown operator");
        strategy.initiateCooldown(1);

        vm.prank(secondBorrower);
        vm.expectRevert("not cooldown operator");
        strategy.cancelCooldown(1);

        vm.prank(secondBorrower);
        vm.expectRevert("not cooldown operator");
        strategy.claimCooldown();
    }

    function test_initiateCooldownKeepsTotalCollateralAndReducesAvailable() public {
        uint256 collateralAmount = 10e18;
        uint256 cooldownAmount = 4e18;

        _postCollateral(collateralAmount);

        vm.prank(borrower);
        uint256 queuedCollateral = strategy.initiateCooldown(cooldownAmount);

        assertEq(queuedCollateral, cooldownAmount);
        assertEq(strategy.totalCollateral(), collateralAmount);
        assertEq(strategy.availableCollateral(), collateralAmount - cooldownAmount);
        assertEq(strategy.pendingCooldownCollateral(), cooldownAmount);
        assertEq(collateral.balanceOf(address(cooldownHandler)), cooldownAmount);
    }

    function test_withdrawCannotUseCoolingCollateral() public {
        uint256 collateralAmount = 10e18;
        uint256 cooldownAmount = 8e18;

        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.initiateCooldown(cooldownAmount);

        vm.prank(borrower);
        vm.expectRevert("collateral cooling down");
        strategy.withdrawCollateral(3e18, borrower);

        vm.prank(borrower);
        strategy.withdrawCollateral(2e18, borrower);

        assertEq(strategy.totalCollateral(), cooldownAmount);
        assertEq(strategy.availableCollateral(), 0);
    }

    function test_cancelCooldownReturnsCollateralWithoutChangingTotalCollateral() public {
        uint256 collateralAmount = 10e18;
        uint256 cooldownAmount = 4e18;
        uint256 cancelAmount = 2e18;

        _postCollateral(collateralAmount);

        vm.prank(borrower);
        strategy.initiateCooldown(cooldownAmount);

        vm.prank(management);
        uint256 returnedCollateral = strategy.cancelCooldown(cancelAmount);

        assertEq(returnedCollateral, cancelAmount);
        assertEq(strategy.totalCollateral(), collateralAmount);
        assertEq(strategy.availableCollateral(), collateralAmount - cooldownAmount + cancelAmount);
        assertEq(strategy.pendingCooldownCollateral(), cooldownAmount - cancelAmount);
    }

    function test_liquidationOnlySeizesAvailableCollateral() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 cooldownAmount = 9e18;

        _openPosition(depositAmount, collateralAmount, borrowAmount);

        vm.prank(borrower);
        strategy.initiateCooldown(cooldownAmount);

        oracle.setPrice(500e36);

        vm.prank(management);
        strategy.setLiquidator(liquidator, true);

        asset.mint(liquidator, borrowAmount);
        vm.startPrank(liquidator);
        asset.approve(address(strategy), borrowAmount);
        (uint256 actualRepaid, uint256 collateralSeized) = strategy.liquidate(borrowAmount, liquidator, bytes(""));
        vm.stopPrank();

        assertEq(actualRepaid, 500e18);
        assertEq(collateralSeized, 1e18);
        assertEq(strategy.totalCollateral(), cooldownAmount);
        assertEq(strategy.availableCollateral(), 0);
    }

    function test_claimCooldownRepaysDebtAndReducesCollateral() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 cooldownAmount = 4e18;
        uint256 finalizedCollateral = 2e18;
        uint256 claimedAssets = 5_000e18;

        _openPosition(depositAmount, collateralAmount, borrowAmount);

        vm.prank(borrower);
        strategy.initiateCooldown(cooldownAmount);

        cooldownHandler.setNextFinalizedCollateral(finalizedCollateral);
        asset.mint(address(cooldownHandler), claimedAssets);

        vm.prank(management);
        (uint256 actualClaimedAssets, uint256 actualFinalizedCollateral, uint256 debtRepaid) = strategy.claimCooldown();

        assertEq(actualClaimedAssets, claimedAssets);
        assertEq(actualFinalizedCollateral, finalizedCollateral);
        assertEq(debtRepaid, claimedAssets);
        assertEq(strategy.totalDebt(), borrowAmount - claimedAssets);
        assertEq(strategy.totalCollateral(), collateralAmount - finalizedCollateral);
        assertEq(strategy.pendingCooldownCollateral(), cooldownAmount - finalizedCollateral);
        assertEq(asset.balanceOf(address(strategy)), claimedAssets);
    }

    function test_claimCooldownSatisfiesCalledDebt() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 callAmount = 3_000e18;
        uint256 claimedAssets = 4_000e18;

        _openPosition(depositAmount, collateralAmount, borrowAmount);

        vm.prank(management);
        strategy.callDebt(callAmount);

        vm.prank(borrower);
        strategy.initiateCooldown(2e18);

        cooldownHandler.setNextFinalizedCollateral(2e18);
        asset.mint(address(cooldownHandler), claimedAssets);

        vm.prank(liquidator);
        vm.expectRevert("not cooldown operator");
        strategy.claimCooldown();

        vm.prank(management);
        (,, uint256 debtRepaid) = strategy.claimCooldown();

        assertEq(debtRepaid, claimedAssets);
        assertEq(strategy.calledDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), callAmount);
        assertEq(strategy.callDeadline(), 0);
        assertEq(strategy.totalDebt(), borrowAmount - claimedAssets);
    }

    function test_managementAndLiquidatorCannotInitiateCooldownWhileHealthyWithoutCall() public {
        _postCollateral(10e18);

        vm.prank(management);
        strategy.setLiquidator(liquidator, true);

        vm.prank(management);
        vm.expectRevert("cooldown not allowed");
        strategy.initiateCooldown(1e18);

        vm.prank(liquidator);
        vm.expectRevert("cooldown not allowed");
        strategy.initiateCooldown(1e18);
    }

    function test_managementCanInitiateCooldownAfterOverdueDebtCall() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;
        uint256 callAmount = 1_000e18;

        _openPosition(depositAmount, collateralAmount, borrowAmount);

        vm.prank(management);
        strategy.callDebt(callAmount);

        vm.prank(management);
        vm.expectRevert("cooldown not allowed");
        strategy.initiateCooldown(1e18);

        skip(CALL_DURATION + 1);

        vm.prank(management);
        uint256 queuedCollateral = strategy.initiateCooldown(1e18);

        assertEq(queuedCollateral, 1e18);
        assertEq(strategy.pendingCooldownCollateral(), 1e18);
    }

    function test_approvedLiquidatorCanInitiateCooldownWhenUnhealthy() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 borrowAmount = 10_000e18;

        _openPosition(depositAmount, collateralAmount, borrowAmount);

        vm.prank(management);
        strategy.setLiquidator(liquidator, true);

        oracle.setPrice(500e36);

        vm.prank(liquidator);
        uint256 queuedCollateral = strategy.initiateCooldown(1e18);

        assertEq(queuedCollateral, 1e18);
        assertEq(strategy.pendingCooldownCollateral(), 1e18);
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
        uint256 accruedInterest = debtAmountBefore - borrowAmount;

        asset.mint(borrower, partialRepayAmount);

        vm.startPrank(borrower);
        asset.approve(address(strategy), partialRepayAmount);
        uint256 actualRepaid = strategy.repay(partialRepayAmount);
        vm.stopPrank();

        assertEq(actualRepaid, partialRepayAmount);
        assertEq(strategy.calledDebt(), callAmount - partialRepayAmount);
        assertEq(strategy.repaidCalledDebt(), partialRepayAmount);
        assertEq(strategy.maxDebt(), liquidity - callAmount + accruedInterest);
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

contract RateManagementTest is LocalSetup {
    uint256 internal constant NEW_RATE = 1_000;
    uint256 internal constant SECOND_RATE = 2_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_BPS = 10_000;

    function _openPosition(uint256 borrowAmount) internal {
        _allowAndDeposit(user, 100_000e18);
        _postCollateral(100e18);

        vm.prank(borrower);
        strategy.borrow(borrowAmount, borrower);
    }

    function _interest(uint256 debt, uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        uint256 annualInterest = (debt * rate) / MAX_BPS;
        return (annualInterest * elapsed) / SECONDS_PER_YEAR;
    }

    function test_managementCanScheduleRateWithCallDurationDelay() public {
        uint256 expectedEffectiveTime = block.timestamp + CALL_DURATION;

        vm.prank(management);
        strategy.setRate(NEW_RATE);

        assertEq(strategy.rate(), RATE);
        assertEq(strategy.pendingRate(), NEW_RATE);
        assertEq(strategy.pendingRateEffectiveTime(), expectedEffectiveTime);

        skip(CALL_DURATION);

        assertEq(strategy.rate(), RATE);
        assertEq(strategy.pendingRate(), NEW_RATE);
    }

    function test_nonManagementCannotSetRate() public {
        vm.prank(borrower);
        vm.expectRevert("!management");
        strategy.setRate(NEW_RATE);
    }

    function test_setRateRejectsRateAboveMaxBps() public {
        vm.prank(management);
        vm.expectRevert("bad rate");
        strategy.setRate(MAX_BPS + 1);
    }

    function test_constructorRejectsRateAboveMaxBps() public {
        vm.expectRevert("bad rate");
        pawnBrokerFactory.newPawnBroker(
            address(asset),
            "Bad Rate PawnBroker",
            borrower,
            address(collateral),
            address(oracle),
            LLTV,
            MAX_BPS + 1,
            CALL_DURATION
        );
    }

    function test_scheduledRateDoesNotAffectDebtBeforeCallDuration() public {
        uint256 borrowAmount = 10_000e18;
        _openPosition(borrowAmount);

        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(CALL_DURATION - 1);

        assertEq(strategy.totalDebt(), borrowAmount + _interest(borrowAmount, RATE, CALL_DURATION - 1));
    }

    function test_scheduledRateDoesNotAffectDebtPreviewAfterCallDuration() public {
        uint256 borrowAmount = 10_000e18;
        _openPosition(borrowAmount);

        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(CALL_DURATION + 1 days);

        uint256 expectedDebt = borrowAmount + _interest(borrowAmount, RATE, CALL_DURATION + 1 days);

        assertEq(strategy.totalDebt(), expectedDebt);
        assertEq(strategy.rate(), RATE);
    }

    function test_accrueInterestDoesNotApplyPendingRateAutomatically() public {
        uint256 borrowAmount = 10_000e18;
        _openPosition(borrowAmount);

        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(CALL_DURATION + 1);

        asset.mint(borrower, 1);
        vm.startPrank(borrower);
        asset.approve(address(strategy), 1);
        strategy.repay(1);
        vm.stopPrank();

        assertEq(strategy.rate(), RATE);
        assertEq(strategy.pendingRate(), NEW_RATE);
        assertEq(strategy.totalDebt(), borrowAmount + _interest(borrowAmount, RATE, CALL_DURATION + 1) - 1);
    }

    function test_applyPendingRateRejectsBeforeCallDuration() public {
        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(CALL_DURATION - 1);

        vm.prank(management);
        vm.expectRevert("rate not ready");
        strategy.applyPendingRate();
    }

    function test_applyPendingRateUsesOldRateThenNewRateForFutureAccrual() public {
        uint256 borrowAmount = 10_000e18;
        _openPosition(borrowAmount);

        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(CALL_DURATION + 1);

        uint256 debtBeforeApply = borrowAmount + _interest(borrowAmount, RATE, CALL_DURATION + 1);

        vm.prank(management);
        strategy.applyPendingRate();

        assertEq(strategy.rate(), NEW_RATE);
        assertEq(strategy.pendingRate(), 0);
        assertEq(strategy.pendingRateEffectiveTime(), 0);
        assertEq(strategy.totalDebt(), debtBeforeApply);

        skip(1 days);

        assertEq(strategy.totalDebt(), debtBeforeApply + _interest(debtBeforeApply, NEW_RATE, 1 days));
    }

    function test_newScheduleOverwritesPendingRateAndResetsEffectiveTime() public {
        vm.prank(management);
        strategy.setRate(NEW_RATE);

        skip(1 days);

        uint256 expectedEffectiveTime = block.timestamp + CALL_DURATION;
        vm.prank(management);
        strategy.setRate(SECOND_RATE);

        assertEq(strategy.rate(), RATE);
        assertEq(strategy.pendingRate(), SECOND_RATE);
        assertEq(strategy.pendingRateEffectiveTime(), expectedEffectiveTime);

        skip(CALL_DURATION - 1);
        assertEq(strategy.rate(), RATE);

        skip(1);
        assertEq(strategy.rate(), RATE);
        assertEq(strategy.pendingRate(), SECOND_RATE);
    }
}

contract MaxDebtAccountingTest is LocalSetup {
    function _openFullUtilizedPosition(uint256 depositAmount, uint256 collateralAmount) internal {
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

    function test_withdrawConsumesRepaidCalledDebtBeforeReducingMaxDebt() public {
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

    function test_fullUtilizationPartialRepayThenFullIdleWithdrawCutsMaxDebt() public {
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

    function test_fullUtilizationFullRepayIncludingInterestThenFullWithdrawZerosMaxDebt() public {
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
        assertEq(strategy.maxDebt(), totalOwed);

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

    function test_fullUtilizationPartialCallRepayCallThenFullIdleWithdrawDoesNotDoubleCutMaxDebt() public {
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

    function test_fullUtilizationFullCallPartialRepayThenFullIdleWithdrawKeepsMaxDebtAtZero() public {
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

    function test_withdrawOfRepaidInterestReturnsMaxDebtToOriginalDeposit() public {
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

        assertEq(strategy.maxDebt(), depositAmount + interestAmount);

        vm.prank(user);
        strategy.withdraw(interestAmount, user, user);

        assertEq(strategy.maxDebt(), depositAmount);
    }

    function test_fullUtilizationRepaidInterestCanBeReborrowed() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        skip(365 days);

        uint256 interestAmount = strategy.totalDebt() - depositAmount;

        asset.mint(borrower, interestAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), interestAmount);
        strategy.repay(interestAmount);
        vm.stopPrank();

        assertEq(strategy.totalDebt(), depositAmount);
        assertEq(strategy.maxDebt(), depositAmount + interestAmount);
        assertEq(asset.balanceOf(address(strategy)), interestAmount);

        vm.prank(borrower);
        strategy.borrow(interestAmount, borrower);

        assertEq(strategy.totalDebt(), depositAmount + interestAmount);
        assertEq(strategy.maxDebt(), depositAmount + interestAmount);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }

    function test_partialCallAccruedInterestLeavesCalledDebtFixedAndGrowsMaxDebt() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;
        uint256 callAmount = 4_000e18;
        uint256 triggerRepayAmount = 1e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        vm.prank(management);
        strategy.callDebt(callAmount);

        skip(365 days);

        asset.mint(borrower, triggerRepayAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), triggerRepayAmount);
        strategy.repay(triggerRepayAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), 6_500e18);
        assertEq(strategy.calledDebt(), 3_999e18);
        assertEq(strategy.repaidCalledDebt(), triggerRepayAmount);
        assertEq(strategy.totalDebt(), 10_499e18);
    }

    function test_fullCallAccruedInterestRemainsNonBorrowable() public {
        uint256 depositAmount = 10_000e18;
        uint256 collateralAmount = 10e18;

        _openFullUtilizedPosition(depositAmount, collateralAmount);

        vm.prank(management);
        strategy.callDebt(depositAmount);

        skip(365 days);

        uint256 interestAmount = strategy.totalDebt() - depositAmount;

        asset.mint(borrower, interestAmount);
        vm.startPrank(borrower);
        asset.approve(address(strategy), interestAmount);
        strategy.repay(interestAmount);
        vm.stopPrank();

        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.calledDebt(), depositAmount);
        assertEq(strategy.repaidCalledDebt(), interestAmount);
        assertEq(strategy.totalDebt(), depositAmount);
        assertGt(strategy.callDeadline(), 0);

        vm.prank(user);
        strategy.withdraw(interestAmount, user, user);

        assertEq(strategy.maxDebt(), 0);
        assertEq(strategy.repaidCalledDebt(), 0);
        assertEq(asset.balanceOf(address(strategy)), 0);
    }
}
